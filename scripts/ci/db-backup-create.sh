#!/usr/bin/env bash
# Create a production/beta DB backup on the target VM and emit a backup id.
#
# Usage:
#   db-backup-create.sh --target <prod|beta> --image-tag <tag>
#
# Output (stdout):
#   BACKUP_ID=<id>
#   BACKUP_FILE=<absolute path>
#   BACKUP_SHA256_FILE=<absolute path>

set -euo pipefail

TARGET=""
IMAGE_TAG=""

AZURE_SUBSCRIPTION="${AZURE_SUBSCRIPTION:-}"
AZURE_RG="${AZURE_RG:-}"
VM_NAME="${VM_NAME:-}"
CONTAINER_NAME="${CONTAINER_NAME:-yojana-v5}"
BACKUP_DIR="${BACKUP_DIR:-/opt/yojana/backups}"
IMAGE_BASE="${IMAGE_BASE:-girish17/yojana}"

usage() {
  cat <<'USAGE'
Usage:
  scripts/ci/db-backup-create.sh --target <prod|beta> --image-tag <tag>

Required args:
  --target       Deployment target label (used in backup naming)
  --image-tag    Image tag being promoted/deployed

Required env:
  AZURE_RG, VM_NAME

Optional env:
  AZURE_SUBSCRIPTION, CONTAINER_NAME, BACKUP_DIR, IMAGE_BASE
  AZ_CLIENT_ID, AZ_CLIENT_SECRET, AZ_TENANT_ID (if az is not already logged in)
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET="${2:-}"
      shift 2
      ;;
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

[[ -n "$TARGET" ]] || { echo "--target is required" >&2; exit 2; }
[[ -n "$IMAGE_TAG" ]] || { echo "--image-tag is required" >&2; exit 2; }
[[ -n "$AZURE_RG" ]] || { echo "AZURE_RG env is required" >&2; exit 2; }
[[ -n "$VM_NAME" ]] || { echo "VM_NAME env is required" >&2; exit 2; }

sanitize() {
  printf "%s" "$1" | tr -c '[:alnum:]._-' '_'
}

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

ts="$(date +%Y%m%d-%H%M%S)"
tag_part="$(sanitize "$IMAGE_TAG")"
backup_id="${TARGET}-${tag_part}-${ts}"
dump_file="${backup_id}.dump"
dump_path="${BACKUP_DIR}/${dump_file}"
sha_file="${dump_path}.sha256"

remote_script="$(cat <<SCRIPT
set -euo pipefail
mkdir -p "${BACKUP_DIR}" /tmp/yojana-backups
docker exec "${CONTAINER_NAME}" bash -lc 'set -euo pipefail; PGPASSWORD=openproject pg_dump -h 127.0.0.1 -U openproject -d openproject -Fc -f "/tmp/yojana-backups/${dump_file}"'
docker cp "${CONTAINER_NAME}:/tmp/yojana-backups/${dump_file}" "${dump_path}"
test -s "${dump_path}"
sha256sum "${dump_path}" | awk '{print \$1}' > "${sha_file}"
docker exec "${CONTAINER_NAME}" bash -lc 'rm -f "/tmp/yojana-backups/${dump_file}"' || true
SCRIPT
)"

rc "create backup ${backup_id}" "$remote_script"

echo "BACKUP_ID=${backup_id}"
echo "BACKUP_FILE=${dump_path}"
echo "BACKUP_SHA256_FILE=${sha_file}"
echo "TARGET_IMAGE=${IMAGE_BASE}:${IMAGE_TAG}"
