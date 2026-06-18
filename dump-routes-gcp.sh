#!/usr/bin/env bash
#
# Dump GCP routing state for the azure-er-vpn-coexistence2 lab (friendly view).
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
#   --raw               Show full raw gcloud YAML/describe output (verbose mode)
#   --no-prompt         Do not prompt; use flags/env/defaults
#   -h, --help          Show this help
#
# Examples:
#   ./dump-routes-gcp.sh
#   ./dump-routes-gcp.sh --project my-project --region us-central1 --no-prompt
#   ./dump-routes-gcp.sh --raw   # full detail for deep troubleshooting

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
RAW=0

usage() {
  sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
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
    --raw) RAW=1; shift ;;
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

# Run a gcloud command, echoing it only in --raw mode; never aborts the script.
run() {
  if [ "$RAW" -eq 1 ]; then
    printf '+ gcloud %s\n' "$*"
  fi
  gcloud "$@"
  local status=$?
  if [ "$status" -ne 0 ]; then
    printf '   (gcloud exited with code %s; continuing)\n' "$status" >&2
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

banner "GCP ROUTE & VPN DUMP"
kv "Account" "$ACTIVE_ACCOUNT"
kv "Project" "$PROJECT"
kv "Region" "$REGION"
kv "VPC network" "$NETWORK"
kv "Cloud Router" "$ROUTER"
kv "Classic VPN gw" "$GATEWAY"
kv "VPN tunnel" "$TUNNEL"
kv "VPN static route" "$ROUTE"

# ---------------------------------------------------------------------------
# Gather state for the health summary.
# ---------------------------------------------------------------------------
TUN_RAW="$(gcloud compute vpn-tunnels describe "$TUNNEL" --region "$REGION" --project "$PROJECT" \
  --format="value[separator='~'](status,detailedStatus,peerIp,ikeVersion,localTrafficSelector.list(),remoteTrafficSelector.list(),targetVpnGateway.basename())" 2>/dev/null || true)"
T_STATUS=""; T_DETAIL=""; T_PEER=""; T_IKE=""; T_LOCAL=""; T_REMOTE=""; T_GW=""
if [ -n "$TUN_RAW" ]; then
  IFS='~' read -r T_STATUS T_DETAIL T_PEER T_IKE T_LOCAL T_REMOTE T_GW <<< "$TUN_RAW"
fi

GW_RAW="$(gcloud compute target-vpn-gateways describe "$GATEWAY" --region "$REGION" --project "$PROJECT" \
  --format="value[separator='~'](status,network.basename(),tunnels.map().basename().list())" 2>/dev/null || true)"
G_STATUS=""; G_NETWORK=""; G_TUNNELS=""
if [ -n "$GW_RAW" ]; then
  IFS='~' read -r G_STATUS G_NETWORK G_TUNNELS <<< "$GW_RAW"
fi

RT_RAW="$(gcloud compute routes describe "$ROUTE" --project "$PROJECT" \
  --format="value[separator='~'](destRange,priority,nextHopVpnTunnel.basename(),network.basename())" 2>/dev/null || true)"
R_DEST=""; R_PRIO=""; R_TUNNEL=""; R_NET=""
if [ -n "$RT_RAW" ]; then
  IFS='~' read -r R_DEST R_PRIO R_TUNNEL R_NET <<< "$RT_RAW"
fi

ROUTER_EXISTS=0
if gcloud compute routers describe "$ROUTER" --region "$REGION" --project "$PROJECT" >/dev/null 2>&1; then
  ROUTER_EXISTS=1
fi

case "$T_STATUS" in
  ESTABLISHED) T_MARK="[ UP ]" ;;
  "") T_MARK="[ n/a]"; T_STATUS="not found"; T_DETAIL="tunnel '$TUNNEL' not found in $REGION" ;;
  *) T_MARK="[DOWN]" ;;
esac
case "$G_STATUS" in
  READY) G_MARK="[ OK ]" ;;
  "") G_MARK="[ n/a]"; G_STATUS="not found" ;;
  *) G_MARK="[WARN]" ;;
esac
if [ -n "$R_DEST" ]; then R_MARK="[ OK ]"; else R_MARK="[FAIL]"; fi
if [ "$ROUTER_EXISTS" -eq 1 ]; then B_MARK="[ OK ]"; B_TEXT="$ROUTER present"; else B_MARK="[ n/a]"; B_TEXT="not configured (interconnect/BGP disabled)"; fi

sub "Health summary"
printf '   %-22s %-7s %s\n' "VPN tunnel" "$T_MARK" "$T_STATUS - $T_DETAIL"
printf '   %-22s %-7s %s\n' "Classic VPN gateway" "$G_MARK" "$G_STATUS"
printf '   %-22s %-7s %s\n' "VPN static route" "$R_MARK" "${R_DEST:-missing}${R_DEST:+ via $R_TUNNEL}"
printf '   %-22s %-7s %s\n' "Cloud Router (BGP)" "$B_MARK" "$B_TEXT"

# ---------------------------------------------------------------------------
# VPN tunnel detail.
# ---------------------------------------------------------------------------
sub "VPN tunnel detail: $TUNNEL"
if [ -n "$TUN_RAW" ]; then
  kv "Status" "$T_STATUS"
  kv "Detail" "$T_DETAIL"
  kv "Peer IP (Azure)" "$T_PEER"
  kv "IKE version" "$T_IKE"
  kv "Local selector" "$T_LOCAL"
  kv "Remote selector" "$T_REMOTE"
  kv "Target gateway" "$T_GW"
else
  note "Tunnel '$TUNNEL' not found in region '$REGION'."
fi

# ---------------------------------------------------------------------------
# Classic VPN gateway + forwarding rules.
# ---------------------------------------------------------------------------
sub "Classic VPN gateway: $GATEWAY"
if [ -n "$GW_RAW" ]; then
  kv "Status" "$G_STATUS"
  kv "Network" "$G_NETWORK"
  kv "Tunnels" "$G_TUNNELS"
else
  note "Gateway '$GATEWAY' not found in region '$REGION'."
fi
printf '\n   Forwarding rules (IPsec ports):\n'
run compute forwarding-rules list \
  --project "$PROJECT" \
  --regions "$REGION" \
  --filter "target:targetVpnGateways/$GATEWAY" \
  --format "table[box](name:label=NAME, IPAddress:label=PUBLIC_IP, IPProtocol:label=PROTO, ports.list():label=PORTS)"

# ---------------------------------------------------------------------------
# VPN static route detail.
# ---------------------------------------------------------------------------
sub "VPN-backed static route: $ROUTE"
if [ -n "$RT_RAW" ]; then
  kv "Destination" "$R_DEST"
  kv "Priority" "$R_PRIO"
  kv "Next hop tunnel" "$R_TUNNEL"
  kv "Network" "$R_NET"
else
  note "Route '$ROUTE' not found."
fi

# ---------------------------------------------------------------------------
# All VPC routes (static + dynamic).
# ---------------------------------------------------------------------------
sub "VPC routes for network: $NETWORK"
run compute routes list \
  --project "$PROJECT" \
  --filter "network:$NETWORK" \
  --format "table[box](name:label=ROUTE, destRange:label=DESTINATION, priority:label=PRIO, nextHopVpnTunnel.basename():label=VPN_TUNNEL, nextHopGateway.basename():label=GATEWAY, nextHopIp:label=NEXT_HOP_IP, routeType:label=TYPE)"

# ---------------------------------------------------------------------------
# Cloud Router BGP status (only when a router exists).
# ---------------------------------------------------------------------------
sub "Cloud Router BGP status: $ROUTER"
if [ "$ROUTER_EXISTS" -eq 1 ]; then
  printf '   BGP peers:\n'
  run compute routers get-status "$ROUTER" --region "$REGION" --project "$PROJECT" \
    --format "table[box](result.bgpPeerStatus[].name:label=PEER, result.bgpPeerStatus[].state:label=STATE, result.bgpPeerStatus[].ipAddress:label=LOCAL_IP, result.bgpPeerStatus[].peerIpAddress:label=PEER_IP, result.bgpPeerStatus[].numLearnedRoutes:label=LEARNED, result.bgpPeerStatus[].uptime:label=UPTIME)"
  printf '\n   Best learned routes:\n'
  run compute routers get-status "$ROUTER" --region "$REGION" --project "$PROJECT" \
    --format "table[box](result.bestRoutes[].destRange:label=DESTINATION, result.bestRoutes[].nextHopIp:label=NEXT_HOP_IP, result.bestRoutes[].priority:label=PRIO)"
else
  note "Cloud Router '$ROUTER' not found in region '$REGION'."
  note "Expected when terraform/gcp enable_interconnect=false (Classic VPN uses static routes). Continuing."
fi

# ---------------------------------------------------------------------------
# Firewall rules for reachability context.
# ---------------------------------------------------------------------------
sub "Firewall rules on network: $NETWORK"
run compute firewall-rules list \
  --project "$PROJECT" \
  --filter "network:$NETWORK" \
  --format "table[box](name:label=NAME, direction:label=DIR, priority:label=PRIO, sourceRanges.list():label=SOURCE_RANGES, allowed[].map().firewall_rule().list():label=ALLOW, disabled:label=DISABLED)"

# ---------------------------------------------------------------------------
# Optional raw detail.
# ---------------------------------------------------------------------------
if [ "$RAW" -eq 1 ]; then
  banner "RAW DETAIL (--raw)"
  sub "vpn-tunnels describe"
  run compute vpn-tunnels describe "$TUNNEL" --region "$REGION" --project "$PROJECT" --format yaml
  sub "target-vpn-gateways describe"
  run compute target-vpn-gateways describe "$GATEWAY" --region "$REGION" --project "$PROJECT" --format yaml
  sub "routes describe"
  run compute routes describe "$ROUTE" --project "$PROJECT" --format yaml
  if [ "$ROUTER_EXISTS" -eq 1 ]; then
    sub "routers get-status"
    run compute routers get-status "$ROUTER" --region "$REGION" --project "$PROJECT" --format yaml
  fi
fi

banner "DONE"
echo "GCP route dump completed. Re-run with --raw for full gcloud detail."
