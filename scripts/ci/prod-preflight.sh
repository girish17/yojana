#!/usr/bin/env bash
# Starter prod preflight gate.
#
# Checks:
# - target image is resolvable in registry
# - VM is reachable via az run-command
# - Caddy is active
# - primary app container is running
# - backup directory writable
# - minimum free disk threshold
# - current prod /login responds with 2xx/3xx

set -euo pipefail

IMAGE_TAG=""

AZURE_SUBSCRIPTION="${AZURE_SUBSCRIPTION:-}"
AZURE_RG="${AZURE_RG:-}"
VM_NAME="${VM_NAME:-}"
CONTAINER_NAME="${CONTAINER_NAME:-yojana-v5}"
BACKUP_DIR="${BACKUP_DIR:-/opt/yojana/backups}"
HOSTNAME="${HOSTNAME:-yojana.girishm.info}"
IMAGE_BASE="${IMAGE_BASE:-girish17/yojana}"
MIN_FREE_MB="${MIN_FREE_MB:-5120}"

usage() {
  cat <<'USAGE'
Usage:
  scripts/ci/prod-preflight.sh --image-tag <tag>

Required args:
  --image-tag    Artifact tag intended for production deploy

Required env:
  AZURE_RG, VM_NAME

Optional env:
  AZURE_SUBSCRIPTION, CONTAINER_NAME, BACKUP_DIR, HOSTNAME, IMAGE_BASE, MIN_FREE_MB
  AZ_CLIENT_ID, AZ_CLIENT_SECRET, AZ_TENANT_ID (if az is not already logged in)
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image-tag)
      IMAGE_TAG="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

[[ -n "$IMAGE_TAG" ]] || { echo "--image-tag is required" >&2; exit 2; }
[[ -n "$AZURE_RG" ]] || { echo "AZURE_RG env is required" >&2; exit 2; }
[[ -n "$VM_NAME" ]] || { echo "VM_NAME env is required" >&2; exit 2; }

az_auth() {
  if [[ -n "${AZ_CLIENT_ID:-}" && -n "${AZ_CLIENT_SECRET:-}" && -n "${AZ_TENANT_ID:-}" ]]; then
    az login --service-principal \
      -u "$AZ_CLIENT_ID" \
      -p "$AZ_CLIENT_SECRET" \
      --tenant "$AZ_TENANT_ID" \
      --output none
  fi

  if [[ -n "$AZURE_SUBSCRIPTION" ]]; then
    az account set --subscription "$AZURE_SUBSCRIPTION" --output none
  else
    AZURE_SUBSCRIPTION="$(az account show --query id -o tsv)"
  fi
}

rc() {
  local desc="$1"
  local script="$2"
  local out

  echo "==> [$desc]"
  out="$(az vm run-command invoke \
          --subscription "$AZURE_SUBSCRIPTION" \
          --resource-group "$AZURE_RG" \
          --name "$VM_NAME" \
          --command-id RunShellScript \
          --scripts "$script" 2>&1)"

  echo "$out" | tail -n 20

  if ! echo "$out" | grep -q '"code": *"ProvisioningState/succeeded"'; then
    echo "ERROR: run-command [$desc] failed" >&2
    return 1
  fi
}

az_auth

target_image="${IMAGE_BASE}:${IMAGE_TAG}"

echo "==> [artifact check] ${target_image}"
docker buildx imagetools inspect "$target_image" >/dev/null

rc "vm + service checks" "set -euo pipefail
systemctl is-active caddy >/dev/null
docker ps --filter name=${CONTAINER_NAME} --format '{{.Names}} {{.Status}}' | grep -q '^${CONTAINER_NAME} Up'
mkdir -p '${BACKUP_DIR}'
test -w '${BACKUP_DIR}'
avail=\$(df -Pm / | awk 'NR==2 {print \$4}')
[ \"\$avail\" -ge ${MIN_FREE_MB} ]
"

echo "==> [endpoint check] https://${HOSTNAME}/login"
http_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "https://${HOSTNAME}/login")"
case "$http_code" in
  2*|3*) ;;
  *)
    echo "Preflight failed: /login returned HTTP $http_code" >&2
    exit 1
    ;;
esac

echo "PREFLIGHT_OK image=${target_image} host=${HOSTNAME}"
