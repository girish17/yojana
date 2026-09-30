#!/usr/bin/env bash
# Provision an Azure T4 GPU VM and set up the Yojana AI host stack.
#
# Phases (matches docs/notes + T4 migration plan):
#   provision - create VM (idempotent), NVIDIA driver extension, container toolkit
#   ollama    - install native Ollama, bind 0.0.0.0:11434, pull models (backgrounded + polled)
#   verify    - host nvidia-smi, local /api/tags, warm default model, print ai_settings guidance
#
# Usage:
#   bash scripts/provision/setup-t4-ai.sh provision
#   bash scripts/provision/setup-t4-ai.sh ollama
#   bash scripts/provision/setup-t4-ai.sh verify
#
# Required env (only if not already logged in with az):
#   AZ_CLIENT_ID, AZ_CLIENT_SECRET, AZ_TENANT_ID
#
# Optional env (defaults match the deployed beta host, aether-gpu-01):
#   AZURE_SUBSCRIPTION  subscription id (aether/startup-credit sub)
#   AZURE_RG=aether-rg
#   REGION=eastus
#   VM_NAME=aether-gpu-01
#   SKU=Standard_NC4as_T4_v3
#   ADMIN_USER=azureuser
#   MODELS="qwen3:14b llama3.2:3b"
#   DRIVER_EXT_VERSION=1.6
set -euo pipefail

AZURE_SUBSCRIPTION="${AZURE_SUBSCRIPTION:?set AZURE_SUBSCRIPTION (e.g. the aether/startup-credit sub used by yojana-ma)}"
AZURE_RG="${AZURE_RG:-aether-rg}"
REGION="${REGION:-eastus}"
VM_NAME="${VM_NAME:-aether-gpu-01}"
SKU="${SKU:-Standard_NC4as_T4_v3}"
ADMIN_USER="${ADMIN_USER:-azureuser}"
MODELS="${MODELS:-qwen3:14b llama3.2:3b}"
DRIVER_EXT_VERSION="${DRIVER_EXT_VERSION:-1.6}"
PULL_PID="/tmp/t4-models-pull.pid"
PULL_LOG="/tmp/t4-models-pull.log"

step="${1:?usage: setup-t4-ai.sh <provision|ollama|verify>}"

# --- authenticate -----------------------------------------------------------
if [ -n "${AZ_CLIENT_ID:-}" ]; then
  az login --service-principal -u "$AZ_CLIENT_ID" -p "$AZ_CLIENT_SECRET" --tenant "$AZ_TENANT_ID" --output none
fi
az account set --subscription "$AZURE_SUBSCRIPTION" --output none

# --- run-command helpers (root on VM, no ssh needed) ------------------------
rc() {
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

vm_out() {
  az vm run-command invoke --subscription "$AZURE_SUBSCRIPTION" --resource-group "$AZURE_RG" --name "$VM_NAME" \
    --command-id RunShellScript --scripts "$@" 2>/dev/null \
    | python3 -c "import sys,json
d=json.load(sys.stdin)
m=d['value'][0]['message']
stdout=m.split('[stdout]')[1].split('[stderr]')[0] if '[stdout]' in m else ''
sys.stdout.write(stdout.strip())"
}

# --- provision --------------------------------------------------------------
provision() {
  echo "==> Checking $SKU availability in $REGION..."
  if [ -z "$(az vm list-skus --location "$REGION" --size "$SKU" -o tsv 2>/dev/null)" ]; then
    echo "ERROR: $SKU not offered in $REGION. Pick a region where NCasT4_v3 is available:"
    az vm list-skus --location "$REGION" -o table 2>/dev/null | grep -i 'NC.*T4' || true
    exit 1
  fi

  if ! az vm show --resource-group "$AZURE_RG" --name "$VM_NAME" --output none 2>/dev/null; then
    echo "==> Creating $VM_NAME ($SKU) in $REGION/$AZURE_RG..."
    SSH_KEY="${SSH_PUBLIC_KEY:-$HOME/.ssh/id_ed25519.pub}"
    [ -f "$SSH_KEY" ] || SSH_KEY="$HOME/.ssh/id_rsa.pub"
    [ -f "$SSH_KEY" ] || { echo "ERROR: no SSH public key found (set SSH_PUBLIC_KEY)"; exit 1; }
    az vm create --subscription "$AZURE_SUBSCRIPTION" --resource-group "$AZURE_RG" \
      --name "$VM_NAME" --size "$SKU" --location "$REGION" \
      --image Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest \
      --os-disk-size-gb 256 --storage-sku Premium_LRS \
      --admin-username "$ADMIN_USER" --authentication-type ssh --ssh-key-values "$SSH_KEY" \
      --public-ip-sku Standard --output none
    az vm open-port --resource-group "$AZURE_RG" --name "$VM_NAME" --port 80 --output none
    az vm open-port --resource-group "$AZURE_RG" --name "$VM_NAME" --port 443 --output none
    echo "    created; public IP: $(az vm list-ip-addresses -g "$AZURE_RG" -n "$VM_NAME" -o tsv --query 'virtualMachine.network.publicIpAddresses[0].ipAddress' 2>/dev/null || echo 'pending')"
  else
    echo "==> VM $VM_NAME already exists; skipping create"
  fi

  echo "==> Installing NVIDIA GPU driver extension v$DRIVER_EXT_VERSION..."
  az vm extension set --subscription "$AZURE_SUBSCRIPTION" --resource-group "$AZURE_RG" \
    --vm-name "$VM_NAME" --name NvidiaGpuDriverLinux --publisher Microsoft.HpcCompute \
    --version "$DRIVER_EXT_VERSION" --output none

  echo "==> Rebooting VM for driver..."
  az vm restart --subscription "$AZURE_SUBSCRIPTION" --resource-group "$AZURE_RG" \
    --name "$VM_NAME" --output none

  echo "==> Verifying nvidia-smi sees the T4..."
  if ! rc "nvidia-smi" "nvidia-smi -L"; then
    echo "ERROR: T4 not visible after driver install"
    exit 1
  fi

  echo "==> Installing nvidia-container-toolkit + configuring Docker runtime..."
  rc "container toolkit" \
    "curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg && \
     curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
       sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' > /etc/apt/sources.list.d/nvidia-container-toolkit.list && \
     apt-get update -qq && apt-get install -yq --no-install-recommends nvidia-container-toolkit && \
     nvidia-ctk runtime configure --runtime=docker && systemctl restart docker && echo TOOLKIT_OK" \
    || exit 1

  echo "==> PROVISION COMPLETE"
}

# --- ollama -----------------------------------------------------------------
pull_models() {
  echo "==> Pulling models (backgrounded): $MODELS..."
  rc "models pull start" \
    "rm -f $PULL_PID $PULL_LOG; nohup bash -c 'for m in $MODELS; do echo PULLING \$m; HOME=/root ollama pull \$m || exit 1; done' >$PULL_LOG 2>&1 & echo \$! > $PULL_PID" \
    || return 1
  for i in $(seq 1 60); do
    sleep 20
    local state
    state="$(vm_out "if kill -0 \$(cat $PULL_PID 2>/dev/null) 2>/dev/null; then echo RUNNING; else echo DONE; fi; tail -n 2 $PULL_LOG 2>/dev/null")"
    echo "    pull state: $state"
    if echo "$state" | grep -q 'DONE'; then
      if echo "$state" | grep -qi 'panic\|error\|failed'; then
        echo "ERROR: model pull failed"
        return 1
      fi
      return 0
    fi
  done
  echo "ERROR: model pull did not finish after ~20 min"
  return 1
}

ollama_setup() {
  echo "==> Installing native Ollama + binding 0.0.0.0:11434..."
  rc "install ollama" \
    "curl -fsSL https://ollama.com/install.sh | sh && \
     mkdir -p /etc/systemd/system/ollama.service.d && \
     printf '[Service]\nEnvironment=\"OLLAMA_HOST=0.0.0.0:11434\"\nEnvironment=\"OLLAMA_KEEP_ALIVE=-1\"\n' > /etc/systemd/system/ollama.service.d/override.conf && \
     systemctl daemon-reload && systemctl enable --now ollama && systemctl restart ollama && \
     for i in \$(seq 1 30); do curl -sf http://127.0.0.1:11434/api/tags >/dev/null && break; sleep 2; done && \
     curl -sf http://127.0.0.1:11434/api/tags >/dev/null && echo OLLAMA_UP" \
    || exit 1

  pull_models || exit 1
  echo "==> OLLAMA SETUP COMPLETE"
}

# --- verify -----------------------------------------------------------------
verify() {
  echo "==> Host GPU:"
  rc "nvidia-smi" "nvidia-smi -L && nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader"

  echo "==> Ollama endpoint + models:"
  rc "api tags" "curl -s http://127.0.0.1:11434/api/tags"

  local default_model="${MODELS%% *}"
  echo "==> Warming default model ($default_model) to confirm GPU offload..."
  rc "warm model" \
    "HOME=/root ollama run $default_model 'Reply with only the word ok' 2>&1 | tail -n 5; \
     nvidia-smi --query-gpu=memory.used --format=csv,noheader; HOME=/root ollama ps"

  cat <<'GUIDANCE'

==> NEXT STEPS (inside the Yojana app container / Rails console):
  Ai::Setting.instance.update!(
    ollama_endpoint: "http://172.17.0.1:11434",   # verify Docker bridge gateway first
    default_model:   "<default_model from MODELS>"
  )
  bundle exec rake ai:setup                        # re-pull via app-side /api/pull if needed

  From the app container, confirm reachability:
    curl -s http://172.17.0.1:11434/api/tags
GUIDANCE
}

case "$step" in
  provision) provision ;;
  ollama)    ollama_setup ;;
  verify)    verify ;;
  *) echo "usage: setup-t4-ai.sh <provision|ollama|verify>"; exit 2 ;;
esac
