#!/usr/bin/env bash
# Restore drill for a previously created backup.
#
# Current starter behavior:
# - Restores the dump into a temporary DB on the target VM container
# - Optionally verifies basic schema presence
# - Drops the temporary DB afterwards
#
# Usage:
#   db-restore-drill.sh --target <prod|beta> --backup-id <id> [--verify]

set -euo pipefail

TARGET=""
BACKUP_ID=""
VERIFY="false"

AZURE_SUBSCRIPTION="${AZURE_SUBSCRIPTION:-}"
AZURE_RG="${AZURE_RG:-}"
VM_NAME="${VM_NAME:-}"
CONTAINER_NAME="${CONTAINER_NAME:-yojana-v5}"
BACKUP_DIR="${BACKUP_DIR:-/opt/yojana/backups}"

usage() {
  cat <<'USAGE'
Usage:
  scripts/ci/db-restore-drill.sh --target <prod|beta> --backup-id <id> [--verify]

Required args:
  --target       Deployment target label
  --backup-id    Backup id emitted by db-backup-create.sh

Optional args:
  --verify       Run a lightweight SQL check after restore

Required env:
  AZURE_RG, VM_NAME

Optional env:
  AZURE_SUBSCRIPTION, CONTAINER_NAME, BACKUP_DIR
  AZ_CLIENT_ID, AZ_CLIENT_SECRET, AZ_TENANT_ID (if az is not already logged in)
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET="${2:-}"
      shift 2
      ;;
    --backup-id)
      BACKUP_ID="${2:-}"
      shift 2
      ;;
    --verify)
      VERIFY="true"
      shift
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

[[ -n "$TARGET" ]] || { echo "--target is required" >&2; exit 2; }
[[ -n "$BACKUP_ID" ]] || { echo "--backup-id is required" >&2; exit 2; }
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

  echo "$out" | tail -n 30

  if ! echo "$out" | grep -q '"code": *"ProvisioningState/succeeded"'; then
    echo "ERROR: run-command [$desc] failed" >&2
    return 1
  fi
}

az_auth

backup_file="${BACKUP_DIR}/${BACKUP_ID}.dump"
tmp_db="restore_drill_${BACKUP_ID//[^[:alnum:]_]/_}_$$"
tmp_dump="/tmp/${tmp_db}.dump"

remote_script="$(cat <<SCRIPT
set -euo pipefail

test -s "${backup_file}"
docker cp "${backup_file}" "${CONTAINER_NAME}:${tmp_dump}"

docker exec "${CONTAINER_NAME}" bash -s -- "${tmp_db}" "${tmp_dump}" "${VERIFY}" <<'INNER'
set -euo pipefail
tmp_db="\$1"
tmp_dump="\$2"
verify="\$3"

cleanup() {
  su - postgres -c "dropdb --if-exists \"\$tmp_db\"" >/dev/null 2>&1 || true
  rm -f "\$tmp_dump" || true
}
trap cleanup EXIT

su - postgres -c "createdb \"\$tmp_db\""
su - postgres -c "pg_restore -d \"\$tmp_db\" \"\$tmp_dump\""

if [ "\$verify" = "true" ]; then
  table_count="\$(su - postgres -c "psql -d \"\$tmp_db\" -Atqc \"SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';\"")"
  [ "\${table_count:-0}" -gt 0 ] || { echo "restore verification failed: no public tables" >&2; exit 1; }
fi
INNER
SCRIPT
)"

rc "restore drill ${BACKUP_ID}" "$remote_script"

echo "RESTORE_DRILL_OK target=${TARGET} backup_id=${BACKUP_ID} verify=${VERIFY}"
