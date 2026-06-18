#!/usr/bin/env bash
#
# Dump Azure route views for the ER/VPN coexistence lab.
#
# Usage:
#   ./dump-routes-azure.sh [--resource-group RG] [--circuit-name NAME]
#                          [--er-gateway-name NAME] [--nics NIC1,NIC2]
#                          [--advertised] [--yes]
#
# Environment overrides:
#   AZURE_ROUTE_RG, AZURE_ROUTE_CIRCUIT, AZURE_ROUTE_ER_GATEWAY,
#   AZURE_ROUTE_NICS, AZURE_ROUTE_ADVERTISED=true, AZURE_ROUTE_YES=true
#
# The script prompts with sensible defaults when run interactively. It uses
# Azure CLI control-plane commands only; VM public IPs are not required.

set -u

DEFAULT_RG="lab-er-vpn-coexistence"
DEFAULT_CIRCUIT="az-hub-er-circuit"
DEFAULT_ER_GW="Az-Hub-ergw"
DEFAULT_NICS=("Az-Hub-lxvm-nic" "Az-Spk1-lxvm-nic" "Az-Spk2-lxvm-nic")
PEERING_NAME="AzurePrivatePeering"

RG="${AZURE_ROUTE_RG:-$DEFAULT_RG}"
CIRCUIT="${AZURE_ROUTE_CIRCUIT:-$DEFAULT_CIRCUIT}"
ER_GW="${AZURE_ROUTE_ER_GATEWAY:-$DEFAULT_ER_GW}"
NICS_CSV="${AZURE_ROUTE_NICS:-}"
YES="${AZURE_ROUTE_YES:-false}"
INCLUDE_ADVERTISED="${AZURE_ROUTE_ADVERTISED:-false}"

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource-group|-g)
      RG="$2"; shift 2 ;;
    --circuit-name|-c)
      CIRCUIT="$2"; shift 2 ;;
    --er-gateway-name|-e)
      ER_GW="$2"; shift 2 ;;
    --nics|-n)
      NICS_CSV="$2"; shift 2 ;;
    --advertised)
      INCLUDE_ADVERTISED="true"; shift ;;
    --yes|-y)
      YES="true"; shift ;;
    --help|-h)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2 ;;
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

try_terraform_circuit_name() {
  if command -v terraform >/dev/null 2>&1 && [[ -d "terraform/azure" ]]; then
    local tf_output
    tf_output="$(terraform -chdir=terraform/azure output -raw expressroute_circuit_name 2>/dev/null)"
    if [[ -n "$tf_output" && "$tf_output" != "null" ]]; then
      CIRCUIT="$tf_output"
    fi
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
  local sub
  sub="$(az account show --query "{name:name,id:id,tenantId:tenantId}" -o table 2>/dev/null)"
  section "Active Azure subscription"
  echo "$sub"
  if [[ -t 0 ]] && ! is_true "$YES"; then
    local reply
    read -r -p "Continue with this subscription? [Y/n]: " reply
    case "${reply:-Y}" in
      y|Y|yes|YES) ;;
      *) echo "Aborted."; exit 0 ;;
    esac
  fi
}

discover_nics() {
  local discovered
  if [[ -n "$NICS_CSV" ]]; then
    IFS=',' read -r -a NICS <<< "$NICS_CSV"
    note "Using NICs supplied by flag/env."
    return
  fi

  discovered="$(az network nic list -g "$RG" --query "[].name" -o tsv 2>/dev/null)"
  if [[ -n "$discovered" ]]; then
    NICS=()
    while IFS= read -r nic; do
      [[ -n "$nic" ]] && NICS+=("$nic")
    done <<< "$discovered"
    note "Using NICs discovered in resource group '$RG'."
  else
    NICS=("${DEFAULT_NICS[@]}")
    note "NIC discovery failed or returned none; using lab defaults."
  fi
}

dump_circuit_routes_for_path() {
  local path="$1"
  echo "-- ExpressRoute circuit route table ($path)"
  if ! az network express-route list-route-table \
    --resource-group "$RG" \
    --name "$CIRCUIT" \
    --peering-name "$PEERING_NAME" \
    --path "$path" \
    -o table; then
    note "Circuit routes unavailable for path '$path' (circuit not provisioned, ExpressRoute disabled, or peering missing). Continuing."
  fi
}

dump_effective_routes() {
  local nic
  for nic in "${NICS[@]}"; do
    [[ -z "$nic" ]] && continue
    echo "-- Effective routes for NIC: $nic"
    if ! az network nic show-effective-route-table --resource-group "$RG" --name "$nic" -o table; then
      note "Effective routes unavailable for NIC '$nic'. Continuing."
    fi
    echo
  done
}

dump_gateway_routes() {
  echo "-- ExpressRoute gateway learned routes: $ER_GW"
  if ! az network vnet-gateway list-learned-routes --resource-group "$RG" --name "$ER_GW" -o table; then
    note "Learned routes unavailable (ER gateway/connection may not exist). Continuing."
  fi
  if is_true "$INCLUDE_ADVERTISED"; then
    echo
    echo "-- ExpressRoute gateway advertised routes: $ER_GW"
    if ! az network vnet-gateway list-advertised-routes --resource-group "$RG" --name "$ER_GW" -o table; then
      note "Advertised routes unavailable (ER gateway/connection may not exist). Continuing."
    fi
  fi
}

require_az
try_terraform_circuit_name

RG="$(prompt_default "Resource group" "$RG")"
CIRCUIT="$(prompt_default "ExpressRoute circuit name" "$CIRCUIT")"
ER_GW="$(prompt_default "ExpressRoute gateway name" "$ER_GW")"

confirm_subscription
discover_nics

section "ExpressRoute circuit routes only"
dump_circuit_routes_for_path "primary"
echo
dump_circuit_routes_for_path "secondary"

section "VM effective routes"
dump_effective_routes

section "ExpressRoute gateway learned routes"
dump_gateway_routes
