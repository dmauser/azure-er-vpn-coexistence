#!/usr/bin/env bash
#
# Dump the Azure ExpressRoute circuit service key for the ER/VPN coexistence lab.
#
# Usage:
#   ./dump-keys-azure.sh [--resource-group RG] [--circuit-name NAME] [--yes]
#
# Environment overrides:
#   AZURE_KEYS_RG, AZURE_KEYS_CIRCUIT, AZURE_KEYS_YES=true
#
# The service key is sensitive. It is printed to the console on purpose so you
# can hand it to the connectivity provider. Do not capture this output into logs.

set -u

DEFAULT_RG="lab-ervpn-coexist"
DEFAULT_CIRCUIT="az-hub-er-circuit"

RG="${AZURE_KEYS_RG:-$DEFAULT_RG}"
CIRCUIT="${AZURE_KEYS_CIRCUIT:-$DEFAULT_CIRCUIT}"
YES="${AZURE_KEYS_YES:-false}"

usage() {
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource-group|-g) RG="$2"; shift 2 ;;
    --circuit-name|-c) CIRCUIT="$2"; shift 2 ;;
    --yes|-y) YES="true"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

is_true() {
  local value
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    1|true|yes|y) return 0 ;;
    *) return 1 ;;
  esac
}

prompt_default() {
  local label="$1"
  local current="$2"
  local reply
  if [[ -t 0 ]] && ! is_true "$YES"; then
    read -r -p "$label [$current]: " reply
    echo "${reply:-$current}"
  else
    echo "$current"
  fi
}

section() {
  printf '\n========== %s ==========\n' "$1"
}

note() {
  printf 'NOTE: %s\n' "$1"
}

azure_tf_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

terraform_output() {
  local name="$1"
  local az_tf_dir
  az_tf_dir="$(azure_tf_dir)/terraform/azure"
  if command -v terraform >/dev/null 2>&1 && [[ -d "$az_tf_dir" ]]; then
    local value
    value="$(terraform -chdir="$az_tf_dir" output -raw "$name" 2>/dev/null)"
    if [[ -n "$value" && "$value" != "null" ]]; then
      printf '%s' "$value"
      return
    fi
  fi
  printf ''
}

try_terraform_circuit_name() {
  local name
  name="$(terraform_output expressroute_circuit_name)"
  if [[ -n "$name" ]]; then
    CIRCUIT="$name"
  fi
}

require_az() {
  if ! command -v az >/dev/null 2>&1; then
    echo "ERROR: Azure CLI 'az' is not installed or not on PATH." >&2
    exit 1
  fi
  if ! az account show >/dev/null 2>&1; then
    echo "ERROR: Azure CLI is not logged in. Run 'az login' first." >&2
    exit 1
  fi
}

confirm_subscription() {
  section "Active Azure subscription"
  az account show --query "{name:name,id:id,tenantId:tenantId}" -o table 2>/dev/null
  if [[ -t 0 ]] && ! is_true "$YES"; then
    local reply
    read -r -p "Continue with this subscription? [Y/n]: " reply
    case "${reply:-Y}" in
      y|Y|yes|YES) ;;
      *) echo "Aborted."; exit 0 ;;
    esac
  fi
}

require_az
try_terraform_circuit_name

RG="$(prompt_default "Resource group" "$RG")"
CIRCUIT="$(prompt_default "ExpressRoute circuit name" "$CIRCUIT")"

confirm_subscription

section "ExpressRoute circuit service key"
echo "Circuit: $CIRCUIT (resource group: $RG)"
echo

# Prefer the Terraform state value (exact, no extra API call); fall back to az.
SERVICE_KEY="$(terraform_output expressroute_service_key)"
SOURCE="terraform output (expressroute_service_key)"

if [[ -z "$SERVICE_KEY" ]]; then
  SERVICE_KEY="$(az network express-route show --resource-group "$RG" --name "$CIRCUIT" --query "serviceKey" -o tsv 2>/dev/null || true)"
  SOURCE="az network express-route show"
fi

if [[ -n "$SERVICE_KEY" ]]; then
  printf '   %-14s %s\n' "Service key:" "$SERVICE_KEY"
  printf '   %-14s %s\n' "Source:" "$SOURCE"
else
  note "Service key unavailable. The circuit may not be provisioned, or ExpressRoute is disabled (enable_expressroute=false). Continuing."
fi

echo
