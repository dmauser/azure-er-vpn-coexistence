#!/usr/bin/env bash
# =============================================================================
# deploy.sh - Azure ER/VPN Coexistence Lab deployment wrapper (Linux/macOS)
# =============================================================================
# Validates prerequisites and orchestrates the 3-apply Terraform deployment.
#
# Azure VMs have NO public IP (reached via Serial Console / boot diagnostics).
# The auto-detected public IP is used ONLY for the GCP SSH firewall allow-list
# (caller_source_ip) - it is no longer applied to the Azure side.
#
# Run './deploy.sh --help' for full usage.

set -euo pipefail

# --- constants ---------------------------------------------------------------
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly AZURE_RG="lab-er-vpn-coexistence"
readonly AZURE_VPN_CONN="Azure-to-OnpremGCP"
readonly GCP_TUNNEL="vpn-to-azure"
readonly AZURE_DIR="terraform/azure"
readonly GCP_DIR="terraform/gcp"

# defaults applied when the user presses Enter (or runs non-interactively)
readonly DEFAULT_USERNAME="azureuser"
readonly DEFAULT_LOCATION="centralus"
readonly DEFAULT_REGION="us-central1"

# --- mutable state (overridable via flags / prompts) -------------------------
MODE="deploy"
AUTO_APPROVE_FLAG=""
ENABLE_ER="false"
SUBSCRIPTION=""
PROJECT=""
CALLER_IP=""
VM_USERNAME=""
VM_PASSWORD=""
AZURE_LOCATION=""
GCP_REGION=""
GCP_ZONE=""

# --- output helpers ----------------------------------------------------------
RED='\033[0;31m'
YLW='\033[1;33m'
GRN='\033[0;32m'
CYN='\033[0;36m'
NC='\033[0m'

banner() {
  printf "\n${CYN}==========================================================\n  %s\n==========================================================${NC}\n" "$*"
}
step() { printf "\n${CYN}---- %s ----${NC}\n" "$*"; }
ok()   { printf "${GRN}  [ok]  %s${NC}\n" "$*"; }
warn() { printf "${YLW}  [!]   %s${NC}\n" "$*"; }
fail() { printf "${RED}  [x]   ERROR: %s${NC}\n" "$*" >&2; exit 1; }

# --- usage -------------------------------------------------------------------
usage() {
  cat <<'HELPTEXT'
Azure ER/VPN Coexistence Lab - deployment wrapper

USAGE
  ./deploy.sh [SUBCOMMAND] [OPTIONS]

SUBCOMMANDS  (default: deploy)
  check    Validate prerequisites only, then exit.
  deploy   Validate prereqs then run the full 3-apply Terraform deployment.
  destroy  Destroy all resources in reverse order (Azure first, then GCP).

OPTIONS
  --auto-approve          Skip 'yes' confirmation for terraform apply/destroy.
  --expressroute          Run the optional ExpressRoute/Interconnect stage.
  --subscription <id>     Set the Azure subscription before validating.
  --project <id>          Set the GCP project before validating.
  --location <region>     Azure region (default: centralus). Prompted if interactive.
  --region <region>       GCP region (default: us-central1). Prompted if interactive.
  --zone <zone>           GCP zone (default: <region>-c). Prompted if interactive.
  --vm-username <name>    VM admin username (default: azureuser). Prompted if interactive.
  --vm-password <pass>    VM admin password (prompted securely if omitted).
  --caller-ip <ip>        Override auto-detected public IP (GCP SSH firewall; no mask).
  -h, --help              Show this help.

NOTES
  * Azure VMs have no public IP - log in with Azure Serial Console
    (az serialconsole connect / portal) or from a peer VM across the tunnel.
  * The public IP is used ONLY for the GCP SSH firewall (caller_source_ip).
  * Azure location, GCP region, and the ExpressRoute peering location
    (default Chicago) are independent - they need not share a geography.

EXAMPLES
  ./deploy.sh check
  ./deploy.sh deploy --project my-gcp-project
  ./deploy.sh deploy --auto-approve --project my-gcp-project --location eastus2
  ./deploy.sh deploy --expressroute --project my-gcp-project
  ./deploy.sh destroy --auto-approve --project my-gcp-project
HELPTEXT
}

# --- argument parsing --------------------------------------------------------
parse_args() {
  if [[ $# -eq 0 ]]; then return; fi

  # Optional leading subcommand
  case "$1" in
    check|deploy|destroy) MODE="$1"; shift ;;
    -h|--help) usage; exit 0 ;;
  esac

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --auto-approve) AUTO_APPROVE_FLAG="-auto-approve"; shift ;;
      --expressroute) ENABLE_ER="true"; shift ;;
      --subscription)
        [[ $# -ge 2 ]] || fail "--subscription requires a value"
        SUBSCRIPTION="$2"; shift 2 ;;
      --project)
        [[ $# -ge 2 ]] || fail "--project requires a value"
        PROJECT="$2"; shift 2 ;;
      --location)
        [[ $# -ge 2 ]] || fail "--location requires a value"
        AZURE_LOCATION="$2"; shift 2 ;;
      --region)
        [[ $# -ge 2 ]] || fail "--region requires a value"
        GCP_REGION="$2"; shift 2 ;;
      --zone)
        [[ $# -ge 2 ]] || fail "--zone requires a value"
        GCP_ZONE="$2"; shift 2 ;;
      --vm-username)
        [[ $# -ge 2 ]] || fail "--vm-username requires a value"
        VM_USERNAME="$2"; shift 2 ;;
      --vm-password)
        [[ $# -ge 2 ]] || fail "--vm-password requires a value"
        VM_PASSWORD="$2"; shift 2 ;;
      --caller-ip)
        [[ $# -ge 2 ]] || fail "--caller-ip requires a value"
        CALLER_IP="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) fail "Unknown option '$1'. Run: ./deploy.sh --help" ;;
    esac
  done
}

# --- prerequisite validation -------------------------------------------------
check_prereqs() {
  banner "PREREQUISITE CHECK"

  step "Tool installations"

  if ! command -v terraform &>/dev/null; then
    fail "terraform not found.
  Windows: winget install Hashicorp.Terraform
  macOS:   brew install hashicorp/tap/terraform
  Linux:   https://developer.hashicorp.com/terraform/install"
  fi
  ok "terraform: $(terraform version | head -1)"

  if ! command -v az &>/dev/null; then
    fail "az CLI not found.
  Windows: winget install Microsoft.AzureCLI
  macOS:   brew install azure-cli
  Linux:   https://aka.ms/InstallAzureCLIDeb"
  fi
  ok "az CLI: $(az version --query '"azure-cli"' -o tsv 2>/dev/null)"

  if ! command -v gcloud &>/dev/null; then
    fail "gcloud not found.
  Windows: winget install Google.CloudSDK
  Others:  https://cloud.google.com/sdk/docs/install"
  fi
  ok "$(gcloud --version 2>/dev/null | head -1)"

  step "Azure authentication"

  if [[ -n "${SUBSCRIPTION}" ]]; then
    az account set --subscription "${SUBSCRIPTION}" \
      || fail "Could not set subscription '${SUBSCRIPTION}'. Run: az login"
  fi
  AZ_NAME=$(az account show --query name -o tsv 2>/dev/null) \
    || fail "Not logged in to Azure.
  Run: az login
  Then set subscription: az account set --subscription <NAME_OR_ID>"
  AZ_ID=$(az account show --query id -o tsv 2>/dev/null)
  ok "Azure subscription: ${AZ_NAME} (${AZ_ID})"

  step "GCP authentication"

  if [[ -n "${PROJECT}" ]]; then
    gcloud config set project "${PROJECT}" --quiet 2>/dev/null \
      || fail "Could not set GCP project '${PROJECT}'."
  fi

  ACTIVE_ACCT=$(gcloud auth list --filter="status:ACTIVE" --format="value(account)" 2>/dev/null \
    | head -1 || true)
  [[ -n "${ACTIVE_ACCT}" ]] \
    || fail "No active GCP account.
  Run: gcloud auth login"
  ok "GCP account: ${ACTIVE_ACCT}"

  if ! gcloud auth application-default print-access-token &>/dev/null; then
    fail "GCP Application Default Credentials not set.
  Run: gcloud auth application-default login"
  fi
  ok "GCP Application Default Credentials: present"

  GCP_PROJ=$(gcloud config get-value project 2>/dev/null | tr -d '[:space:]' || true)
  [[ -n "${GCP_PROJ}" && "${GCP_PROJ}" != "(unset)" ]] \
    || fail "No GCP project configured.
  Run: gcloud config set project <PROJECT_ID>"
  # Propagate discovered project if not provided via --project flag
  [[ -z "${PROJECT}" ]] && PROJECT="${GCP_PROJ}"
  ok "GCP project: ${PROJECT}"

  step "Public IP detection (GCP SSH firewall)"

  if [[ -z "${CALLER_IP}" ]]; then
    CALLER_IP=$(curl -4 -s --max-time 5 https://ifconfig.io 2>/dev/null \
              || curl -4 -s --max-time 5 https://api.ipify.org 2>/dev/null \
              || echo "")
    [[ -n "${CALLER_IP}" ]] \
      || fail "Could not auto-detect public IP.
  Override with: --caller-ip <YOUR_IP>"
  fi
  [[ "${CALLER_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "Invalid IPv4 address: '${CALLER_IP}'. Use --caller-ip to override."
  ok "Public IP: ${CALLER_IP}  (used only for GCP caller_source_ip)"

  echo
  ok "All prerequisite checks passed."
}

# Validates Azure VM password complexity. Echoes nothing; returns 0/!0.
password_is_valid() {
  local p="$1"
  [[ ${#p} -ge 12 && ${#p} -le 72 ]] || return 1
  local classes=0
  [[ "$p" == *[a-z]* ]] && classes=$((classes+1))
  [[ "$p" == *[A-Z]* ]] && classes=$((classes+1))
  [[ "$p" == *[0-9]* ]] && classes=$((classes+1))
  [[ "$p" == *[^a-zA-Z0-9]* ]] && classes=$((classes+1))
  [[ $classes -ge 3 ]]
}

password_validation_message() {
  local p="$1"
  local missing=()
  local issues=()
  [[ ${#p} -ge 12 ]] || issues+=("too short (${#p}/12)")
  [[ ${#p} -le 72 ]] || issues+=("too long (${#p}/72)")
  [[ "$p" == *[a-z]* ]] || missing+=("lowercase")
  [[ "$p" == *[A-Z]* ]] || missing+=("uppercase")
  [[ "$p" == *[0-9]* ]] || missing+=("digit")
  [[ "$p" == *[^a-zA-Z0-9]* ]] || missing+=("special")
  if (( ${#missing[@]} > 1 )); then
    issues+=("needs at least 3 of 4 categories; missing: ${missing[*]}")
  fi
  printf "Password must be 12-72 chars and include at least 3 of: lowercase, uppercase, digit, special"
  if (( ${#issues[@]} > 0 )); then
    printf " (%s)" "$(IFS='; '; echo "${issues[*]}")"
  fi
  printf "."
}

# --- collect required inputs (region / zone / username / password) -----------
collect_inputs() {
  banner "DEPLOYMENT SETTINGS  (press Enter to accept the [default])"

  local interactive="false"
  [[ -t 0 ]] && interactive="true"
  local in

  # VM admin username
  if [[ -z "${VM_USERNAME}" ]]; then
    if [[ "${interactive}" == "true" ]]; then
      read -r -p "  VM admin username [${DEFAULT_USERNAME}]: " in
      VM_USERNAME="${in:-${DEFAULT_USERNAME}}"
    else
      VM_USERNAME="${DEFAULT_USERNAME}"
    fi
  fi

  # Azure location
  if [[ -z "${AZURE_LOCATION}" ]]; then
    if [[ "${interactive}" == "true" ]]; then
      read -r -p "  Azure region / location [${DEFAULT_LOCATION}]: " in
      AZURE_LOCATION="${in:-${DEFAULT_LOCATION}}"
    else
      AZURE_LOCATION="${DEFAULT_LOCATION}"
    fi
  fi

  # GCP region
  if [[ -z "${GCP_REGION}" ]]; then
    if [[ "${interactive}" == "true" ]]; then
      read -r -p "  GCP region [${DEFAULT_REGION}]: " in
      GCP_REGION="${in:-${DEFAULT_REGION}}"
    else
      GCP_REGION="${DEFAULT_REGION}"
    fi
  fi

  # GCP zone (derived default <region>-c, changeable)
  if [[ -z "${GCP_ZONE}" ]]; then
    local zdefault="${GCP_REGION}-c"
    if [[ "${interactive}" == "true" ]]; then
      read -r -p "  GCP zone [${zdefault}]: " in
      GCP_ZONE="${in:-${zdefault}}"
    else
      GCP_ZONE="${zdefault}"
    fi
  fi

  ok "VM admin username: ${VM_USERNAME}"
  ok "Azure location:    ${AZURE_LOCATION}"
  ok "GCP region / zone: ${GCP_REGION} / ${GCP_ZONE}"

  # VM admin password - never echoed; passed to Terraform via TF_VAR_ env var
  # so it never appears in the process list (ps aux) or shell history.
  if [[ -z "${VM_PASSWORD}" && -z "${TF_VAR_vm_admin_password:-}" ]]; then
    if [[ "${interactive}" != "true" ]]; then
      fail "No password supplied. For non-interactive runs export TF_VAR_vm_admin_password or pass --vm-password."
    fi
    while true; do
      local VM_PASSWORD_CONFIRM=""
      read -r -s -p "  VM admin password (12-72 chars, at least 3 of: upper, lower, digit, special): " VM_PASSWORD
      echo
      if ! password_is_valid "${VM_PASSWORD}"; then
        warn "$(password_validation_message "${VM_PASSWORD}")"
        continue
      fi
      read -r -s -p "  Confirm VM admin password: " VM_PASSWORD_CONFIRM
      echo
      if [[ "${VM_PASSWORD}" != "${VM_PASSWORD_CONFIRM}" ]]; then
        warn "Passwords do not match - try again."
        VM_PASSWORD=""
        continue
      fi
      break
    done
  fi
  if [[ -z "${VM_PASSWORD}" && -n "${TF_VAR_vm_admin_password:-}" ]]; then
    password_is_valid "${TF_VAR_vm_admin_password}" || fail "Password must be 12-72 chars and include at least 3 of: lowercase, uppercase, digit, special."
  fi
  if [[ -n "${VM_PASSWORD}" ]]; then
    password_is_valid "${VM_PASSWORD}" || fail "Password must be 12-72 chars and include at least 3 of: lowercase, uppercase, digit, special."
    export TF_VAR_vm_admin_password="${VM_PASSWORD}"
    trap 'unset TF_VAR_vm_admin_password 2>/dev/null || true' EXIT
    VM_PASSWORD="(exported via TF_VAR)"
  fi
}

# --- terraform wrappers ------------------------------------------------------
tf_apply() {
  local chdir="$1"; shift
  local extra_args=()
  [[ -n "${AUTO_APPROVE_FLAG}" ]] && extra_args+=("${AUTO_APPROVE_FLAG}")
  terraform -chdir="${chdir}" apply -input=false "${extra_args[@]}" "$@"
}

tf_destroy() {
  local chdir="$1"; shift
  local extra_args=()
  [[ -n "${AUTO_APPROVE_FLAG}" ]] && extra_args+=("${AUTO_APPROVE_FLAG}")
  terraform -chdir="${chdir}" destroy -input=false "${extra_args[@]}" "$@"
}

# --- VPN verification --------------------------------------------------------
verify_vpn() {
  banner "VPN VERIFICATION"

  step "Azure - VPN connection status"
  AZ_STATUS=$(az network vpn-connection show \
    --name "${AZURE_VPN_CONN}" \
    --resource-group "${AZURE_RG}" \
    --query connectionStatus \
    --output tsv 2>/dev/null \
    || echo "unavailable (may not have converged yet)")
  ok "Azure connection status: ${AZ_STATUS}"

  step "GCP - VPN tunnel status"
  GCP_STATUS=$(gcloud compute vpn-tunnels describe "${GCP_TUNNEL}" \
    --region "${GCP_REGION}" \
    --format="value(status,detailedStatus)" 2>/dev/null \
    || echo "unavailable (may not have converged yet)")
  ok "GCP tunnel status: ${GCP_STATUS}"

  step "SSH into GCP VM"
  ok "Command: gcloud compute ssh vpnlab-vm1 --zone ${GCP_ZONE}"
  ok "  (If envname was changed from the default, use: gcloud compute ssh <envname>-vm1 --zone ${GCP_ZONE})"
  ok "  First SSH generates an SSH key pair and may prompt for a passphrase - this is normal."
  ok "  To force Cloud IAP tunnel: gcloud compute ssh vpnlab-vm1 --zone ${GCP_ZONE} --tunnel-through-iap"

  step "Azure VMs (no public IP) - use Serial Console"
  ok "  az serialconsole connect --name Az-Hub-lxvm --resource-group ${AZURE_RG}"
  ok "  (or Azure portal > VM > Help > Serial console). Sign in with the VM admin credentials."
}

# --- deploy ------------------------------------------------------------------
run_deploy() {
  banner "DEPLOY - 3-APPLY ORDER"
  cd "${SCRIPT_DIR}"

  # -- Step 1: Azure base -----------------------------------------------------
  step "Step 1 - Azure base (VPN gateway + ExpressRoute gateway)"
  warn "Azure gateway provisioning takes ~30-45 minutes on first apply."
  warn "Terraform will appear to 'hang' on azurerm_virtual_network_gateway - this is NORMAL."
  warn "Do NOT cancel. Monitor in the Azure portal: Virtual network gateways."
  echo

  terraform -chdir="${AZURE_DIR}" init -input=false
  tf_apply "${AZURE_DIR}" \
    -var "location=${AZURE_LOCATION}" \
    -var "vm_admin_username=${VM_USERNAME}" \
    -var "enable_onprem_connection=false"

  # -- Step 2: GCP ------------------------------------------------------------
  step "Step 2 - GCP (Classic VPN gateway + tunnel + firewall + VM)"
  # TF_VAR_vm_admin_password in env is ignored by the GCP provider - harmless.
  terraform -chdir="${GCP_DIR}" init -input=false
  tf_apply "${GCP_DIR}" \
    -var "project=${PROJECT}" \
    -var "region=${GCP_REGION}" \
    -var "zone=${GCP_ZONE}" \
    -var "caller_source_ip=${CALLER_IP}"

  # -- Step 3: Azure connection ----------------------------------------------
  step "Step 3 - Azure connection (Local Network Gateway + VPN connection)"
  tf_apply "${AZURE_DIR}" \
    -var "location=${AZURE_LOCATION}" \
    -var "vm_admin_username=${VM_USERNAME}" \
    -var "enable_onprem_connection=true"

  verify_vpn

  if [[ "${ENABLE_ER}" == "true" ]]; then
    run_expressroute
  fi

  banner "DEPLOYMENT COMPLETE"
  ok "Site-to-Site VPN deployment finished. See verification output above."
  ok "Re-run with --expressroute when ready to add the ExpressRoute/Interconnect path."
}

# --- optional ExpressRoute / Partner Interconnect stage ----------------------
run_expressroute() {
  banner "EXPRESSROUTE / INTERCONNECT STAGE  (OPTIONAL - BILLABLE)"
  warn "Billable resources: ExpressRoute circuit, Cloud Router, Partner Interconnect VLAN attachment."
  echo

  step "Step 4a - GCP: Cloud Router + Partner Interconnect VLAN attachment"
  tf_apply "${GCP_DIR}" \
    -var "project=${PROJECT}" \
    -var "region=${GCP_REGION}" \
    -var "zone=${GCP_ZONE}" \
    -var "caller_source_ip=${CALLER_IP}" \
    -var "enable_interconnect=true"

  step "Step 4b - Azure: ExpressRoute circuit + ER gateway connection"
  # enable_expressroute=true creates az-hub-er-circuit AND the ER gateway connection.
  # If the circuit is not yet Provisioned (Megaport VXC not active), the connection
  # may remain non-functional until Megaport activates; re-run with --expressroute
  # after the circuit reaches 'Provisioned' to retry the attachment.
  tf_apply "${AZURE_DIR}" \
    -var "location=${AZURE_LOCATION}" \
    -var "vm_admin_username=${VM_USERNAME}" \
    -var "enable_onprem_connection=true" \
    -var "enable_expressroute=true"

  step "Step 4c - Retrieve pairing keys for Megaport"
  echo
  printf "${CYN}  GCP Partner Interconnect pairing key  ->  paste into Megaport 'Google Cloud' VXC:${NC}\n"
  terraform -chdir="${GCP_DIR}" output -raw interconnect_pairing_key 2>/dev/null \
    || warn "Pairing key not yet available - the VLAN attachment may still be provisioning."
  echo

  printf "${CYN}  Azure ExpressRoute service key  ->  paste into Megaport 'Azure ExpressRoute' VXC:${NC}\n"
  terraform -chdir="${AZURE_DIR}" output -raw expressroute_service_key 2>/dev/null \
    || warn "Service key not yet available."
  echo

  warn "=========================================================="
  warn "  STOP - MANUAL MEGAPORT ACTION REQUIRED BEFORE CONTINUING"
  warn "=========================================================="
  warn "1. Log in to https://portal.megaport.com"
  warn "2. Create a VXC to Google Cloud  ->  paste the GCP pairing key above."
  warn "3. Create a VXC to Azure ExpressRoute  ->  paste the Azure service key above."
  warn "4. Wait for BOTH VXCs to show 'Active' in Megaport AND for the Azure ER"
  warn "   circuit 'az-hub-er-circuit' to show 'Provisioned' in the Azure portal."
  warn "5. Once the circuit is Provisioned, re-run this script with --expressroute"
  warn "   to attach the ER circuit to the ER gateway (the apply is idempotent):"
  warn "       ./deploy.sh deploy --expressroute [same options as before]"
  echo
  ok "Script stopping here intentionally. Save the keys above - you need them in Megaport."
  unset TF_VAR_vm_admin_password || true
  exit 0
}

# --- destroy -----------------------------------------------------------------
run_destroy() {
  banner "DESTROY - REVERSE ORDER  (Azure first, then GCP)"
  warn "This permanently destroys ALL lab resources in this deployment."
  cd "${SCRIPT_DIR}"

  step "1 - Destroy Azure resources (connections, gateways, VMs, VNets, NSGs)"
  # Pass enable_onprem_connection=true so Terraform can plan the LNG + VPN connection
  # teardown while the GCP state file still exists (remote_state data source resolves).
  warn "Azure must be destroyed first - LNG and VPN connection reference GCP state."
  tf_destroy "${AZURE_DIR}" \
    -var "location=${AZURE_LOCATION}" \
    -var "vm_admin_username=${VM_USERNAME}" \
    -var "enable_onprem_connection=true"

  step "2 - Destroy GCP resources (VPN tunnel, VM, VPC, firewall)"
  tf_destroy "${GCP_DIR}" \
    -var "project=${PROJECT}" \
    -var "region=${GCP_REGION}" \
    -var "zone=${GCP_ZONE}" \
    -var "caller_source_ip=${CALLER_IP}"

  banner "DESTROY COMPLETE"
  ok "All lab resources removed."
  warn "If ExpressRoute (Step 4) was deployed, cancel Megaport VXCs at https://portal.megaport.com."
}

# --- main --------------------------------------------------------------------
main() {
  parse_args "$@"

  case "${MODE}" in
    check)
      check_prereqs
      ;;
    deploy)
      check_prereqs
      collect_inputs
      run_deploy
      unset TF_VAR_vm_admin_password || true
      ;;
    destroy)
      check_prereqs
      collect_inputs
      run_destroy
      unset TF_VAR_vm_admin_password || true
      ;;
  esac
}

main "$@"
