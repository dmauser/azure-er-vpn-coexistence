#!/usr/bin/env bash
# =============================================================================
# cleanup-gcp.sh - Tear down ONLY the GCP (simulated on-prem) side of the lab
# =============================================================================
# Runs `terraform destroy` against terraform/gcp only. The Azure side is left
# untouched - use cleanup-azure.sh for that.
#
# ORDER MATTERS: destroy Azure BEFORE GCP. The Azure Local Network Gateway and
# VPN connection are planned from GCP's Terraform remote state, so destroy the
# Azure side first (cleanup-azure.sh), then run this script.
#
# Usage:
#   ./cleanup-gcp.sh --project <gcp-project> [--region <region>] [--zone <zone>]
#                    [--caller-ip <ip>] [--auto-approve]
#
#   --project        GCP project ID the lab was deployed to (required).
#   --region         GCP region (default: us-central1).
#   --zone           GCP zone (default: <region>-c).
#   --caller-ip      Value for caller_source_ip (irrelevant for destroy;
#                    placeholder used if omitted).
#   --auto-approve   Skip the 'yes' confirmation for terraform destroy.

set -euo pipefail

# Scripts live in <repo>/scripts; terraform dirs are resolved from the repo root.
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly GCP_DIR="terraform/gcp"

RED='\033[0;31m'; YLW='\033[1;33m'; GRN='\033[0;32m'; CYN='\033[0;36m'; NC='\033[0m'
banner() { printf "\n${CYN}==========================================================\n  %s\n==========================================================${NC}\n" "$*"; }
step()   { printf "\n${CYN}---- %s ----${NC}\n" "$*"; }
ok()     { printf "${GRN}  [ok]  %s${NC}\n" "$*"; }
warn()   { printf "${YLW}  [!]   %s${NC}\n" "$*"; }
fail()   { printf "${RED}  [x]   ERROR: %s${NC}\n" "$*" >&2; exit 1; }

PROJECT=""
REGION="us-central1"
ZONE=""
CALLER_IP="0.0.0.0"
AUTO_APPROVE_FLAG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)      PROJECT="$2"; shift 2 ;;
    --region)       REGION="$2"; shift 2 ;;
    --zone)         ZONE="$2"; shift 2 ;;
    --caller-ip)    CALLER_IP="$2"; shift 2 ;;
    --auto-approve) AUTO_APPROVE_FLAG="-auto-approve"; shift ;;
    -h|--help)      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)              fail "Unknown argument: $1" ;;
  esac
done

[[ -n "${PROJECT}" ]] || fail "--project is required."
[[ -n "${ZONE}" ]] || ZONE="${REGION}-c"

command -v terraform >/dev/null 2>&1 || fail "terraform is not installed or not on PATH."

cd "${REPO_ROOT}"

banner "CLEANUP - GCP resources only"
warn "This permanently destroys the GCP on-prem side of the lab (VPN tunnel, VM, VPC, firewall)."
warn "Destroy Azure FIRST (cleanup-azure.sh) - the Azure side references GCP Terraform state."

extra_args=()
[[ -n "${AUTO_APPROVE_FLAG}" ]] && extra_args+=("${AUTO_APPROVE_FLAG}")

# OneDrive intermittently places a byte-range lock on the .tfstate file, which makes
# Terraform's terraform_remote_state read fail during the (lengthy) refresh phase with
# "another process has locked a portion of the file". Copy the peer Azure state to a temp
# file outside the synced folder and point the data source at that stable copy.
TEMP_STATE=""
cleanup_temp() { [[ -n "${TEMP_STATE}" && -f "${TEMP_STATE}" ]] && rm -f "${TEMP_STATE}"; }
trap cleanup_temp EXIT

AZURE_STATE="${REPO_ROOT}/terraform/azure/terraform.tfstate"
if [[ -f "${AZURE_STATE}" ]]; then
  candidate="$(mktemp "${TMPDIR:-/tmp}/az-er-vpn-azure-state.XXXXXX")"
  copied="false"
  for _ in 1 2 3 4 5; do
    if cp "${AZURE_STATE}" "${candidate}" 2>/dev/null; then copied="true"; break; fi
    sleep 2
  done
  if [[ "${copied}" == "true" ]]; then
    TEMP_STATE="${candidate}"
    extra_args+=(-var "azure_remote_state_path=${TEMP_STATE}")
  else
    rm -f "${candidate}" 2>/dev/null || true
    warn "Could not copy Azure state to a temp file (OneDrive lock); using the original path."
  fi
fi

step "terraform init (gcp)"
terraform -chdir="${GCP_DIR}" init -input=false

step "terraform destroy (gcp)"
terraform -chdir="${GCP_DIR}" destroy -input=false \
  -var "project=${PROJECT}" \
  -var "region=${REGION}" \
  -var "zone=${ZONE}" \
  -var "caller_source_ip=${CALLER_IP}" \
  "${extra_args[@]}"

banner "GCP CLEANUP COMPLETE"
ok "GCP lab resources removed."
