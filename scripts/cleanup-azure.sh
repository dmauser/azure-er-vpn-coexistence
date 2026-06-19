#!/usr/bin/env bash
# =============================================================================
# cleanup-azure.sh - Tear down ONLY the Azure side of the ER/VPN coexistence lab
# =============================================================================
# Runs `terraform destroy` against terraform/azure only. The GCP side is left
# untouched - use cleanup-gcp.sh for that.
#
# ORDER MATTERS: destroy Azure BEFORE GCP. The Azure Local Network Gateway and
# VPN connection are planned from GCP's Terraform remote state, so the GCP state
# file must still exist when Azure is destroyed. Run this script first, then
# cleanup-gcp.sh.
#
# Usage:
#   ./cleanup-azure.sh [--location <region>] [--vm-username <name>]
#                      [--vm-password <pwd>] [--auto-approve]
#
#   --location       Azure region the lab was deployed to (default: centralus).
#   --vm-username    VM admin username used at deploy time (default: azureuser).
#   --vm-password    VM admin password (irrelevant for destroy; placeholder used
#                    if omitted, since Terraform still requires the variable).
#   --resource-group Azure resource group (default: lab-ervpn-coexist). Used to
#                    clear an orphaned ExpressRoute connection before destroy (needs az).
#   --auto-approve   Skip the 'yes' confirmation for terraform destroy.

set -euo pipefail

# Scripts live in <repo>/scripts; terraform dirs are resolved from the repo root.
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly AZURE_DIR="terraform/azure"

RED='\033[0;31m'; YLW='\033[1;33m'; GRN='\033[0;32m'; CYN='\033[0;36m'; NC='\033[0m'
banner() { printf "\n${CYN}==========================================================\n  %s\n==========================================================${NC}\n" "$*"; }
step()   { printf "\n${CYN}---- %s ----${NC}\n" "$*"; }
ok()     { printf "${GRN}  [ok]  %s${NC}\n" "$*"; }
warn()   { printf "${YLW}  [!]   %s${NC}\n" "$*"; }
fail()   { printf "${RED}  [x]   ERROR: %s${NC}\n" "$*" >&2; exit 1; }

LOCATION="centralus"
VM_USERNAME="azureuser"
VM_PASSWORD=""
RESOURCE_GROUP="lab-ervpn-coexist"
AUTO_APPROVE_FLAG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --location)       LOCATION="$2"; shift 2 ;;
    --vm-username)    VM_USERNAME="$2"; shift 2 ;;
    --vm-password)    VM_PASSWORD="$2"; shift 2 ;;
    --resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
    --auto-approve)   AUTO_APPROVE_FLAG="-auto-approve"; shift ;;
    -h|--help)        grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                fail "Unknown argument: $1" ;;
  esac
done

command -v terraform >/dev/null 2>&1 || fail "terraform is not installed or not on PATH."

# Best-effort removal of an ExpressRoute gateway connection that exists in Azure but is no
# longer tracked in Terraform state (e.g. left behind by an earlier failed destroy). While
# present it blocks the ER gateway delete with VirtualNetworkGatewayCannotBeDeleted. Requires
# az; skipped silently if az is missing or not logged in.
remove_orphaned_er_connection() {
  local rg="$1" name="ER-Connection-to-Onprem"
  command -v az >/dev/null 2>&1 || return 0
  az account show >/dev/null 2>&1 || return 0
  if az network vpn-connection show --name "${name}" --resource-group "${rg}" --query id --output tsv >/dev/null 2>&1; then
    step "Removing orphaned ExpressRoute connection (${name})"
    if az network vpn-connection delete --name "${name}" --resource-group "${rg}" >/dev/null 2>&1; then
      ok "Deleted ${name}"
    else
      warn "Could not delete ${name} via az; Terraform destroy may fail if it is orphaned."
    fi
  fi
}

# Terraform still requires vm_admin_password to be set even on destroy.
if [[ -n "${VM_PASSWORD}" ]]; then
  export TF_VAR_vm_admin_password="${VM_PASSWORD}"
elif [[ -z "${TF_VAR_vm_admin_password:-}" ]]; then
  export TF_VAR_vm_admin_password="PlaceholderForDestroy!1"
fi

cd "${REPO_ROOT}"

banner "CLEANUP - Azure resources only"
warn "This permanently destroys the Azure side of the lab (connections, gateways, VMs, VNets, NSGs)."
warn "Destroy Azure BEFORE GCP - the Azure LNG/VPN connection references GCP Terraform state."

extra_args=()
[[ -n "${AUTO_APPROVE_FLAG}" ]] && extra_args+=("${AUTO_APPROVE_FLAG}")

# OneDrive intermittently places a byte-range lock on the .tfstate file, which makes
# Terraform's terraform_remote_state read fail during the (lengthy) refresh phase with
# "another process has locked a portion of the file". Copy the peer GCP state to a temp
# file outside the synced folder and point the data source at that stable copy.
TEMP_STATE=""
cleanup_temp() { [[ -n "${TEMP_STATE}" && -f "${TEMP_STATE}" ]] && rm -f "${TEMP_STATE}"; }
trap 'cleanup_temp; unset TF_VAR_vm_admin_password || true' EXIT

GCP_STATE="${REPO_ROOT}/terraform/gcp/terraform.tfstate"
if [[ -f "${GCP_STATE}" ]]; then
  candidate="$(mktemp "${TMPDIR:-/tmp}/az-er-vpn-gcp-state.XXXXXX")"
  copied="false"
  for _ in 1 2 3 4 5; do
    if cp "${GCP_STATE}" "${candidate}" 2>/dev/null; then copied="true"; break; fi
    sleep 2
  done
  if [[ "${copied}" == "true" ]]; then
    TEMP_STATE="${candidate}"
    extra_args+=(-var "gcp_remote_state_path=${TEMP_STATE}")
  else
    rm -f "${candidate}" 2>/dev/null || true
    warn "Could not copy GCP state to a temp file (OneDrive lock); using the original path."
  fi
fi

step "terraform init (azure)"
terraform -chdir="${AZURE_DIR}" init -input=false

# Clear a possibly-orphaned ER connection before destroy so the ER gateway can be deleted.
remove_orphaned_er_connection "${RESOURCE_GROUP}"

step "terraform destroy (azure)"
# enable_expressroute/enable_er_connection are forced true so that, if an ER circuit and ER
# gateway connection exist in state, Terraform tears the connection down BEFORE the
# (always-present) ER gateway. For a destroy this never creates anything: resources absent
# from state are skipped. Without it the ER gateway delete fails with
# VirtualNetworkGatewayCannotBeDeleted.
terraform -chdir="${AZURE_DIR}" destroy -input=false \
  -var "location=${LOCATION}" \
  -var "vm_admin_username=${VM_USERNAME}" \
  -var "enable_onprem_connection=true" \
  -var "enable_expressroute=true" \
  -var "enable_er_connection=true" \
  "${extra_args[@]}"

unset TF_VAR_vm_admin_password || true

banner "AZURE CLEANUP COMPLETE"
ok "Azure lab resources removed."
warn "Run cleanup-gcp.sh next to remove the GCP on-prem side."
warn "If ExpressRoute was deployed, cancel Megaport VXCs at https://portal.megaport.com."
