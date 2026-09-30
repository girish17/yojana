#!/usr/bin/env bash
# Yojana deploy to a target VM (runs on the CI VM/Jenkins).
# NOTE: stop-start swap, not zero-downtime blue-green - the image embeds its own
# Postgres on PGDATA_HOST, so green cannot boot while the old container still
# holds the data dir. We stop the old container first (~2-4 min outage), then
# green boots on :8081, and Caddy is switched once green is healthy.
# Host header note: the app rejects `Host: localhost` (400), so health checks
# must send `-H "Host: $HOSTNAME"`.
# Targets are selected via env: VM_NAME / AZURE_RG / AZURE_SUBSCRIPTION / HOSTNAME
# (e.g. prod=`element`/AZUREQUANTUM, beta=`aether-gpu-01`/aether-rg).
# Primary path: az vm run-command (root on VM; no passwordless sudo needed locally).
#
# Requires env (Jenkins credentials.yml inject via withCredentials):
#   AZ_CLIENT_ID, AZ_CLIENT_SECRET, AZ_TENANT_ID
# Optional overrides (defaults from .env):
#   AZURE_SUBSCRIPTION, AZURE_RG, VM_NAME, IMAGE_BASE, CONTAINER_NAME,
#   VOLUME_NAME, PGDATA_HOST, SECRET_FILE, BACKUP_DIR, HOSTNAME
#
# Usage: deploy-yojana.sh <IMAGE_TAG>
# Exit codes: 0 = deployed, 1 = failure (rollback attempted within the phase), 2 = usage
set -euo pipefail

IMAGE_TAG="${1:?usage: deploy-yojana.sh <IMAGE_TAG>}"
: "${AZ_CLIENT_ID:?AZ_CLIENT_ID env required}"; : "${AZ_CLIENT_SECRET:?AZ_CLIENT_SECRET env required}"; : "${AZ_TENANT_ID:?AZ_TENANT_ID env required}"

AZURE_SUBSCRIPTION="${AZURE_SUBSCRIPTION:-5a1ef3e9-7b40-4163-b0ff-d0b8d2ec6e62}"
AZURE_RG="${AZURE_RG:-AZUREQUANTUM}"
VM_NAME="${VM_NAME:-element}"
IMAGE_BASE="${IMAGE_BASE:-girish17/yojana}"
CONTAINER_NAME="${CONTAINER_NAME:-yojana-v5}"
BLUE_NAME="yojana-blue"
GREEN_NAME="yojana-green"
VOLUME_NAME="${VOLUME_NAME:-yojana_opdata}"
PGDATA_HOST="${PGDATA_HOST:-/opt/yojana/pgdata}"
SECRET_FILE="${SECRET_FILE:-/opt/yojana/secret_key_base.txt}"
BACKUP_DIR="${BACKUP_DIR:-/opt/yojana/backups}"
HOSTNAME="${HOSTNAME:-yojana.girishm.info}"

TS="$(date +%Y%m%d-%H%M%S)"
TARGET_IMAGE="$IMAGE_BASE:$IMAGE_TAG"
LOCK="/tmp/yojana-deploy.lock"
RESULT="/tmp/yojana-deploy-result.txt"
PULL_PID="/tmp/yojana-pull.pid"
PULL_LOG="/tmp/yojana-pull.log"

# --- authenticate -----------------------------------------------------------
az login --service-principal -u "$AZ_CLIENT_ID" -p "$AZ_CLIENT_SECRET" --tenant "$AZ_TENANT_ID" --output none
az account set --subscription "$AZURE_SUBSCRIPTION" --output none
echo "==> Authenticated as $AZ_CLIENT_ID (Azure SP, subscription $AZURE_SUBSCRIPTION)"

# --- az vm run-command wrapper ----------------------------------------------
rc() { # desc, script...
  local desc="$1"; shift
  echo "==> [$desc]"
  local out
  out="$(az vm run-command invoke \
        --subscription "$AZURE_SUBSCRIPTION" --resource-group "$AZURE_RG" --name "$VM_NAME" \
        --command-id RunShellScript --scripts "$@" 2>&1)"
  echo "$out" | tail -n 15
  if ! echo "$out" | grep -q '"code": *"ProvisioningState/succeeded"'; then
    echo "ERROR: run-command [$desc] failed:"
    echo "$out"
    return 1
  fi
}

# az vm run-command stdout extractor (returns the [stdout] block of the message)
vm_out() { # script...
  az vm run-command invoke --subscription "$AZURE_SUBSCRIPTION" --resource-group "$AZURE_RG" --name "$VM_NAME" \
    --command-id RunShellScript --scripts "$@" 2>/dev/null \
    | python3 -c "import sys,json
d=json.load(sys.stdin)
m=d['value'][0]['message']
stdout=m.split('[stdout]')[1].split('[stderr]')[0] if '[stdout]' in m else ''
sys.stdout.write(stdout.strip())"
}

# Pull runs in the background and is polled (image is large; run-command itself
# can outlive the default agent timeout).
pull_image() {
  echo "==> Pulling $TARGET_IMAGE (backgrounded)..."
  rc "pull start" "rm -f $PULL_PID $PULL_LOG; nohup docker pull $TARGET_IMAGE >$PULL_LOG 2>&1 & echo \\\$! > $PULL_PID" \
    || return 1
  for i in $(seq 1 40); do
    sleep 20
    local state
    state="$(vm_out "if kill -0 \$(cat $PULL_PID 2>/dev/null) 2>/dev/null; then echo RUNNING; else echo DONE; fi; tail -n 3 $PULL_LOG 2>/dev/null")"
    echo "    pull state: $state"
    if echo "$state" | grep -q 'DONE'; then
      return 0
    fi
  done
  echo "ERROR: docker pull did not finish after ~13 minutes"
  return 1
}

# --- Phase 1: backup + pull (live container unaffected) ----------------------
echo "############ PHASE 1 (backup + pull) ############"
if rc "backup pg_dump" \
    "docker exec $CONTAINER_NAME bash -c \"mkdir -p /tmp/yojana-backups && PGPASSWORD=openproject pg_dump -h 127.0.0.1 -U openproject -d openproject -Fc -f /tmp/yojana-backups/pre-$TS.dump 2>&1 | tail -n 2\"" \
    "docker cp $CONTAINER_NAME:/tmp/yojana-backups/pre-$TS.dump $BACKUP_DIR/pre-$TS.dump 2>/dev/null && ls -lh $BACKUP_DIR/pre-$TS.dump"; then
  echo "    backup -> $BACKUP_DIR/pre-$TS.dump"
else
  echo "WARN: backup failed (continuing; pg_dump may have timed out)"
fi

if ! pull_image; then
  echo "ERROR: image pull failed - production untouched"
  exit 1
fi

# --- Phase 2: start green on :8081 + migrate + verify ------------------------
echo "############ PHASE 2 (green) ############"
SECRET="$(vm_out "cat $SECRET_FILE")"
[ -n "$SECRET" ] || { echo "ERROR: could not read $SECRET_FILE"; exit 1; }

echo "==> Stopping $CONTAINER_NAME (embedded Postgres owns $PGDATA_HOST; only one instance can hold it)"
if ! rc "stop old primary" \
    "docker stop $CONTAINER_NAME 2>/dev/null || true" \
    "docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'"; then
  echo "ERROR: could not stop $CONTAINER_NAME - aborting (production untouched)"
  exit 1
fi

echo "==> Starting green container on 8081 (mounts: $VOLUME_NAME, $PGDATA_HOST)"
if ! rc "start green" \
    "docker rm -f $GREEN_NAME 2>/dev/null || true" \
    "docker run -d --name $GREEN_NAME -p 8081:80 \
      -v $VOLUME_NAME:/var/openproject/assets \
      -v $PGDATA_HOST:/var/openproject/pgdata \
      -e SECRET_KEY_BASE=$SECRET \
      -e OPENPROJECT_HOST__NAME=$HOSTNAME \
      -e RAILS_ENV=production \
      -e OPENPROJECT_EDITION=standard \
      -e OPENPROJECT_ATTACHMENTS__STORAGE__PATH=/var/openproject/assets/files \
      $TARGET_IMAGE"; then
  echo "ROLLBACK: cannot start green - restarting old primary"
  rc "rollback: restart old primary" "docker start $CONTAINER_NAME 2>/dev/null || true"
  exit 1
fi

echo "==> Waiting for Postgres init + app readiness (up to ~8 min)..."
GREEN_OK=""
for i in $(seq 1 24); do
  sleep 20
  code="$(vm_out "curl -s -o /dev/null -w '%{http_code}' -H 'Host: $HOSTNAME' http://localhost:8081")"
  echo "    green health attempt $i -> ${code:-timeout/not-ready}"
  state="$(vm_out "docker ps --filter name=$GREEN_NAME --format '{{.Status}}'")"
  echo "    green container: $state"
  if [ "$code" = "200" ]; then GREEN_OK=1; break; fi
  if [ -n "$state" ] && [ "${state#Up}" = "$state" ]; then
    echo "    green container not running: $state"
    break
  fi
done
if [ -z "$GREEN_OK" ]; then
  echo "ERROR: green container did not become healthy"
  rc "green diagnostics" "docker logs $GREEN_NAME --tail 60 2>&1"
  rc "rollback: restart old primary" "docker rm -f $GREEN_NAME 2>/dev/null || true; docker start $CONTAINER_NAME 2>/dev/null || true"
  echo "ROLLBACK: old primary restarted on 8080"
  exit 1
fi
echo "==> Green healthy on 8081"

if ! rc "run migrations" "docker exec $GREEN_NAME rake db:migrate"; then
  echo "ERROR: migrations failed on green"
  rc "rollback: restart old primary" "docker rm -f $GREEN_NAME 2>/dev/null || true; docker start $CONTAINER_NAME 2>/dev/null || true"
  echo "ROLLBACK: old primary restarted on 8080"
  exit 1
fi
echo "==> Migrations applied on green"

# --- Phase 3: swap traffic + rename containers --------------------------------
echo "############ PHASE 3 (swap) ############"
if ! rc "swap caddy -> 8081" \
    "sudo sed -i 's/localhost:8080/localhost:8081/' /etc/caddy/Caddyfile && sudo systemctl reload caddy && echo CADDY_SWAPPED"; then
  echo "ERROR: Caddy swap failed - old config still active (no traffic loss). Restoring."
  rc "rollback: caddy -> 8080" "sudo sed -i 's/localhost:8081/localhost:8080/' /etc/caddy/Caddyfile && sudo systemctl reload caddy || true"
  rc "rollback: remove green" "docker rm -f $GREEN_NAME 2>/dev/null || true"
  exit 1
fi

if ! rc "rename containers + stop blue" \
    "if docker inspect $CONTAINER_NAME >/dev/null 2>&1; then docker rename $CONTAINER_NAME $BLUE_NAME; docker stop $BLUE_NAME || true; fi" \
    "docker rename $GREEN_NAME $CONTAINER_NAME" \
    "docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'"; then
  echo "ERROR: rename/stop failed - attempting rollback to :8080"
  rc "rollback: caddy -> 8080" "sudo sed -i 's/localhost:8081/localhost:8080/' /etc/caddy/Caddyfile && sudo systemctl reload caddy || true; docker start $BLUE_NAME 2>/dev/null || true"
  exit 1
fi

echo "############ DEPLOY COMPLETE ############"
echo "Deployed $TARGET_IMAGE; primary=$CONTAINER_NAME (on 8080), previous kept as $BLUE_NAME"
echo "Backup: $BACKUP_DIR/pre-$TS.dump"
echo "Cleanup after confidence period: docker rm $BLUE_NAME && rm -f $BACKUP_DIR/pre-$TS.dump /tmp/pre-$TS.dump"