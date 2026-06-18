#!/usr/bin/env bash
#
# Dump GCP routing state for the azure-er-vpn-coexistence2 lab.
#
# Usage:
#   ./dump-routes-gcp.sh [options]
#
# Options / environment overrides:
#   --project <id>       GCP project ID (env: GCP_PROJECT or GOOGLE_CLOUD_PROJECT)
#   --region <region>   GCP region (env: GCP_REGION, default: us-central1)
#   --network <name>    VPC network name (env: GCP_NETWORK, default: vpnlab-vpc)
#   --router <name>     Cloud Router name (env: GCP_ROUTER, default: vpnlab-router)
#   --tunnel <name>     VPN tunnel name (env: GCP_VPN_TUNNEL, default: vpn-to-azure)
#   --gateway <name>    Classic VPN gateway name (env: GCP_VPN_GATEWAY, default: onpremvpn)
#   --route <name>      Static route name (env: GCP_VPN_ROUTE, default: vpn-to-azure-route-1)
#   --no-prompt         Do not prompt; use flags/env/defaults
#   -h, --help          Show this help
#
# Examples:
#   ./dump-routes-gcp.sh
#   ./dump-routes-gcp.sh --project my-project --region us-central1 --no-prompt
#   GCP_PROJECT=my-project GCP_REGION=us-central1 ./dump-routes-gcp.sh --no-prompt

set -u

DEFAULT_REGION="us-central1"
DEFAULT_NETWORK="vpnlab-vpc"
DEFAULT_ROUTER="vpnlab-router"
DEFAULT_TUNNEL="vpn-to-azure"
DEFAULT_GATEWAY="onpremvpn"
DEFAULT_ROUTE="vpn-to-azure-route-1"

PROJECT="${GCP_PROJECT:-${GOOGLE_CLOUD_PROJECT:-}}"
REGION="${GCP_REGION:-$DEFAULT_REGION}"
NETWORK="${GCP_NETWORK:-$DEFAULT_NETWORK}"
ROUTER="${GCP_ROUTER:-$DEFAULT_ROUTER}"
TUNNEL="${GCP_VPN_TUNNEL:-$DEFAULT_TUNNEL}"
GATEWAY="${GCP_VPN_GATEWAY:-$DEFAULT_GATEWAY}"
ROUTE="${GCP_VPN_ROUTE:-$DEFAULT_ROUTE}"
NO_PROMPT=0

usage() {
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project) PROJECT="${2:-}"; shift 2 ;;
    --region) REGION="${2:-}"; shift 2 ;;
    --network) NETWORK="${2:-}"; shift 2 ;;
    --router) ROUTER="${2:-}"; shift 2 ;;
    --tunnel) TUNNEL="${2:-}"; shift 2 ;;
    --gateway) GATEWAY="${2:-}"; shift 2 ;;
    --route) ROUTE="${2:-}"; shift 2 ;;
    --no-prompt) NO_PROMPT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

section() {
  printf '\n================================================================================\n'
  printf '%s\n' "$1"
  printf '================================================================================\n'
}

run() {
  printf '+ %s\n' "$*"
  "$@"
  local status=$?
  if [ "$status" -ne 0 ]; then
    printf 'NOTE: command failed with exit code %s; continuing.\n' "$status" >&2
  fi
  return 0
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

if ! command -v gcloud >/dev/null 2>&1; then
  echo "ERROR: gcloud is not installed or not in PATH." >&2
  exit 1
fi

section "GCLOUD AUTHENTICATION"
run gcloud auth list
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

PROJECT="$(prompt_value "GCP project" "$PROJECT")"
REGION="$(prompt_value "GCP region" "$REGION")"
NETWORK="$(prompt_value "VPC network" "$NETWORK")"
ROUTER="$(prompt_value "Cloud Router" "$ROUTER")"
TUNNEL="$(prompt_value "VPN tunnel" "$TUNNEL")"
GATEWAY="$(prompt_value "Classic VPN gateway" "$GATEWAY")"
ROUTE="$(prompt_value "VPN static route" "$ROUTE")"

if [ -z "$PROJECT" ] || [ "$PROJECT" = "YOUR_GCP_PROJECT_ID" ]; then
  echo "ERROR: set a valid project with --project, GCP_PROJECT, GOOGLE_CLOUD_PROJECT, or the prompt." >&2
  exit 1
fi

section "SELECTED GCP LAB DEFAULTS"
cat <<EOF
Project:             $PROJECT
Region:              $REGION
VPC network:         $NETWORK
Cloud Router:        $ROUTER
Classic VPN gateway: $GATEWAY
VPN tunnel:          $TUNNEL
VPN static route:    $ROUTE
EOF

section "VPC ROUTES: STATIC + DYNAMIC NEXT HOPS"
run gcloud compute routes list \
  --project "$PROJECT" \
  --filter "network:$NETWORK" \
  --format "table(name,destRange,priority,nextHopVpnTunnel,nextHopGateway,nextHopPeering,nextHopInterconnectAttachment,nextHopIp,nextHopInstance,routeStatus,routeType)"

section "VPN TUNNEL STATUS"
run gcloud compute vpn-tunnels list \
  --project "$PROJECT" \
  --regions "$REGION" \
  --filter "name=($TUNNEL)" \
  --format "table(name,region,targetVpnGateway,peerIp,status,detailedStatus)"
run gcloud compute vpn-tunnels describe "$TUNNEL" \
  --region "$REGION" \
  --project "$PROJECT" \
  --format yaml

section "CLASSIC VPN GATEWAY + FORWARDING RULES"
run gcloud compute target-vpn-gateways describe "$GATEWAY" \
  --region "$REGION" \
  --project "$PROJECT" \
  --format yaml
run gcloud compute forwarding-rules list \
  --project "$PROJECT" \
  --regions "$REGION" \
  --filter "target:targetVpnGateways/$GATEWAY" \
  --format "table(name,region,IPAddress,IPProtocol,ports,target)"

section "VPN-BACKED STATIC ROUTE"
run gcloud compute routes describe "$ROUTE" \
  --project "$PROJECT" \
  --format yaml
run gcloud compute routes list \
  --project "$PROJECT" \
  --filter "name=($ROUTE) OR nextHopVpnTunnel:$TUNNEL" \
  --format "table(name,network,destRange,priority,nextHopVpnTunnel,routeStatus,routeType)"

section "CLOUD ROUTER BGP STATUS"
if gcloud compute routers describe "$ROUTER" --region "$REGION" --project "$PROJECT" >/dev/null 2>&1; then
  run gcloud compute routers get-status "$ROUTER" \
    --region "$REGION" \
    --project "$PROJECT" \
    --format yaml
  run gcloud compute routers describe "$ROUTER" \
    --region "$REGION" \
    --project "$PROJECT" \
    --format yaml
else
  echo "NOTE: Cloud Router '$ROUTER' was not found in region '$REGION'."
  echo "      This is expected when terraform/gcp enable_interconnect=false; continuing."
fi

section "FIREWALL RULES FOR REACHABILITY CONTEXT"
run gcloud compute firewall-rules list \
  --project "$PROJECT" \
  --filter "network:$NETWORK" \
  --format "table(name,direction,priority,sourceRanges,allowed,disabled)"

section "DONE"
echo "GCP route dump completed."
