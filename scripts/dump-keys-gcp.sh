#!/usr/bin/env bash
#
# Dump the GCP Partner Interconnect VLAN attachment pairing key for the
# azure-er-vpn-coexistence2 lab.
#
# Usage:
#   ./dump-keys-gcp.sh [options]
#
# Options / environment overrides:
#   --project <id>      GCP project ID (env: GCP_PROJECT or GOOGLE_CLOUD_PROJECT)
#   --region <region>   GCP region (env: GCP_REGION, default: us-central1)
#   --attachment <name> VLAN attachment name (env: GCP_INTERCONNECT_ATTACHMENT,
#                       default: terraform output or vpnlab-vlan)
#   --no-prompt         Do not prompt; use flags/env/defaults
#   -h, --help          Show this help
#
# The pairing key is what you hand to the connectivity provider to provision the
# VXC against your VLAN attachment. It is read from the GCP module's Terraform
# output (interconnect_pairing_key) when available, otherwise from
# `gcloud compute interconnects attachments describe`. The key is sensitive; do
# not capture this output into logs. Requires enable_interconnect=true.

set -u

DEFAULT_REGION="us-central1"
DEFAULT_ATTACHMENT="vpnlab-vlan"

PROJECT="${GCP_PROJECT:-${GOOGLE_CLOUD_PROJECT:-}}"
REGION="${GCP_REGION:-$DEFAULT_REGION}"
ATTACHMENT="${GCP_INTERCONNECT_ATTACHMENT:-$DEFAULT_ATTACHMENT}"
ATTACHMENT_OVERRIDDEN="${GCP_INTERCONNECT_ATTACHMENT:+1}"
NO_PROMPT=0

usage() {
  sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project) PROJECT="${2:-}"; shift 2 ;;
    --region) REGION="${2:-}"; shift 2 ;;
    --attachment) ATTACHMENT="${2:-}"; ATTACHMENT_OVERRIDDEN=1; shift 2 ;;
    --no-prompt) NO_PROMPT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

BAR="--------------------------------------------------------------------------------"

banner() {
  printf '\n%s\n  %s\n%s\n' "$BAR" "$1" "$BAR"
}

sub() {
  printf '\n>> %s\n' "$1"
}

kv() {
  printf '   %-20s %s\n' "$1" "$2"
}

note() {
  printf '   - %s\n' "$1"
}

prompt_value() {
  local label="$1"
  local current="$2"
  local answer
  if [ "$NO_PROMPT" -eq 1 ] || [ ! -t 0 ]; then
    printf '%s' "$current"
    return
  fi
  printf '%s [%s]: ' "$label" "$current" >&2
  read -r answer || answer=""
  if [ -n "$answer" ]; then
    printf '%s' "$answer"
  else
    printf '%s' "$current"
  fi
}

gcp_tf_output() {
  local name="$1"
  local gcp_tf_dir
  gcp_tf_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/terraform/gcp"
  if command -v terraform >/dev/null 2>&1 && [[ -d "$gcp_tf_dir" ]]; then
    local value
    value="$(terraform -chdir="$gcp_tf_dir" output -raw "$name" 2>/dev/null)"
    if [[ -n "$value" && "$value" != "null" ]]; then
      printf '%s' "$value"
      return
    fi
  fi
  printf ''
}

if ! command -v gcloud >/dev/null 2>&1; then
  echo "ERROR: gcloud is not installed or not in PATH." >&2
  exit 1
fi

ACTIVE_ACCOUNT="$(gcloud auth list --filter "status:ACTIVE" --format "value(account)" 2>/dev/null | head -n 1 || true)"
if [ -z "$ACTIVE_ACCOUNT" ]; then
  echo "ERROR: no active gcloud account found. Run 'gcloud auth login' or configure application credentials first." >&2
  exit 1
fi
CONFIG_PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
if [ -z "$PROJECT" ]; then
  PROJECT="$CONFIG_PROJECT"
fi
if [ -z "$PROJECT" ]; then
  PROJECT="YOUR_GCP_PROJECT_ID"
fi

# Resolve the attachment name from Terraform when not overridden.
if [ -z "$ATTACHMENT_OVERRIDDEN" ]; then
  TF_ATTACHMENT="$(gcp_tf_output interconnect_attachment_name)"
  if [ -n "$TF_ATTACHMENT" ]; then
    ATTACHMENT="$TF_ATTACHMENT"
  fi
fi

PROJECT="$(prompt_value "GCP project" "$PROJECT")"
REGION="$(prompt_value "GCP region" "$REGION")"
ATTACHMENT="$(prompt_value "Interconnect VLAN attachment" "$ATTACHMENT")"

if [ -z "$PROJECT" ] || [ "$PROJECT" = "YOUR_GCP_PROJECT_ID" ]; then
  echo "ERROR: set a valid project with --project, GCP_PROJECT, GOOGLE_CLOUD_PROJECT, or the prompt." >&2
  exit 1
fi

banner "GCP INTERCONNECT PAIRING KEY DUMP"
kv "Account" "$ACTIVE_ACCOUNT"
kv "Project" "$PROJECT"
kv "Region" "$REGION"
kv "VLAN attachment" "$ATTACHMENT"

# ---------------------------------------------------------------------------
# Pairing key — prefer the GCP module's Terraform output; fall back to gcloud.
# ---------------------------------------------------------------------------
sub "Partner Interconnect pairing key"
PAIRING_KEY="$(gcp_tf_output interconnect_pairing_key)"
SOURCE="terraform output (gcp: interconnect_pairing_key)"

if [ -z "$PAIRING_KEY" ]; then
  PAIRING_KEY="$(gcloud compute interconnects attachments describe "$ATTACHMENT" --region "$REGION" --project "$PROJECT" --format="value(pairingKey)" 2>/dev/null | head -n 1 || true)"
  SOURCE="gcloud compute interconnects attachments describe"
fi

if [ -n "$PAIRING_KEY" ]; then
  kv "Pairing key" "$PAIRING_KEY"
  kv "Source" "$SOURCE"
else
  note "Pairing key unavailable. Interconnect may be disabled (enable_interconnect=false) or the attachment '$ATTACHMENT' is not provisioned in region '$REGION'. Continuing."
fi

banner "DONE"
