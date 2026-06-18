<#
.SYNOPSIS
Dump GCP routing state for the azure-er-vpn-coexistence2 lab (friendly view).

.USAGE
.\dump-routes-gcp.ps1 [-Project <id>] [-Region <region>] [-Network <name>] [-Router <name>] [-Tunnel <name>] [-Gateway <name>] [-Route <name>] [-Raw] [-NoPrompt]

.PARAMETER Project
GCP project ID. Defaults from $env:GCP_PROJECT, $env:GOOGLE_CLOUD_PROJECT, then gcloud config.

.PARAMETER Region
GCP region. Defaults from $env:GCP_REGION, then us-central1.

.PARAMETER Network
VPC network name. Defaults from $env:GCP_NETWORK, then vpnlab-vpc.

.PARAMETER Router
Cloud Router name. Defaults from $env:GCP_ROUTER, then vpnlab-router.

.PARAMETER Tunnel
VPN tunnel name. Defaults from $env:GCP_VPN_TUNNEL, then vpn-to-azure.

.PARAMETER Gateway
Classic VPN gateway name. Defaults from $env:GCP_VPN_GATEWAY, then onpremvpn.

.PARAMETER Route
VPN static route name. Defaults from $env:GCP_VPN_ROUTE, then vpn-to-azure-route-1.

.PARAMETER Raw
Show full raw gcloud YAML/describe output (verbose mode).

.PARAMETER NoPrompt
Do not prompt; use parameters, environment, and defaults.

.EXAMPLE
.\dump-routes-gcp.ps1

.EXAMPLE
.\dump-routes-gcp.ps1 -Project my-project -Region us-central1 -NoPrompt

.EXAMPLE
.\dump-routes-gcp.ps1 -Raw
#>

[CmdletBinding()]
param(
    [string]$Project = $(if ($env:GCP_PROJECT) { $env:GCP_PROJECT } elseif ($env:GOOGLE_CLOUD_PROJECT) { $env:GOOGLE_CLOUD_PROJECT } else { "" }),
    [string]$Region = $(if ($env:GCP_REGION) { $env:GCP_REGION } else { "us-central1" }),
    [string]$Network = $(if ($env:GCP_NETWORK) { $env:GCP_NETWORK } else { "vpnlab-vpc" }),
    [string]$Router = $(if ($env:GCP_ROUTER) { $env:GCP_ROUTER } else { "vpnlab-router" }),
    [string]$Tunnel = $(if ($env:GCP_VPN_TUNNEL) { $env:GCP_VPN_TUNNEL } else { "vpn-to-azure" }),
    [string]$Gateway = $(if ($env:GCP_VPN_GATEWAY) { $env:GCP_VPN_GATEWAY } else { "onpremvpn" }),
    [string]$Route = $(if ($env:GCP_VPN_ROUTE) { $env:GCP_VPN_ROUTE } else { "vpn-to-azure-route-1" }),
    [switch]$Raw,
    [switch]$NoPrompt
)

$ErrorActionPreference = "Continue"
$Bar = "--------------------------------------------------------------------------------"

function Write-Banner {
    param([string]$Title)
    Write-Host ""
    Write-Host $Bar
    Write-Host "  $Title"
    Write-Host $Bar
}

function Write-Sub {
    param([string]$Title)
    Write-Host ""
    Write-Host ">> $Title"
}

function Write-Kv {
    param([string]$Label, [string]$Value)
    Write-Host ("   {0,-20} {1}" -f $Label, $Value)
}

function Write-Note {
    param([string]$Message)
    Write-Host "   - $Message"
}

function Invoke-GCloud {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    if ($Raw) {
        Write-Host ("+ gcloud " + ($Arguments -join " "))
    }
    & gcloud @Arguments
    if ($LASTEXITCODE -ne 0) {
        Write-Host "   (gcloud exited with code $LASTEXITCODE; continuing)"
    }
}

function Get-GCloudValue {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    $result = (& gcloud @Arguments 2>$null)
    if ($LASTEXITCODE -ne 0) { return "" }
    return ($result | Select-Object -First 1)
}

function Confirm-Value {
    param([string]$Label, [string]$Value)
    if ($NoPrompt -or -not [Environment]::UserInteractive) {
        return $Value
    }
    $answer = Read-Host "$Label [$Value]"
    if ([string]::IsNullOrWhiteSpace($answer)) {
        return $Value
    }
    return $answer
}

if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) {
    throw "gcloud is not installed or not in PATH."
}

$activeAccount = (& gcloud auth list --filter "status:ACTIVE" --format "value(account)" 2>$null | Select-Object -First 1)
if ([string]::IsNullOrWhiteSpace($activeAccount)) {
    throw "No active gcloud account found. Run 'gcloud auth login' or configure application credentials first."
}
$configuredProject = (& gcloud config get-value project 2>$null)
if ([string]::IsNullOrWhiteSpace($Project)) {
    $Project = $configuredProject
}
if ([string]::IsNullOrWhiteSpace($Project)) {
    $Project = "YOUR_GCP_PROJECT_ID"
}

$Project = Confirm-Value "GCP project" $Project
$Region = Confirm-Value "GCP region" $Region
$Network = Confirm-Value "VPC network" $Network
$Router = Confirm-Value "Cloud Router" $Router
$Tunnel = Confirm-Value "VPN tunnel" $Tunnel
$Gateway = Confirm-Value "Classic VPN gateway" $Gateway
$Route = Confirm-Value "VPN static route" $Route

if ([string]::IsNullOrWhiteSpace($Project) -or $Project -eq "YOUR_GCP_PROJECT_ID") {
    throw "Set a valid project with -Project, GCP_PROJECT, GOOGLE_CLOUD_PROJECT, or the prompt."
}

Write-Banner "GCP ROUTE & VPN DUMP"
Write-Kv "Account" $activeAccount
Write-Kv "Project" $Project
Write-Kv "Region" $Region
Write-Kv "VPC network" $Network
Write-Kv "Cloud Router" $Router
Write-Kv "Classic VPN gw" $Gateway
Write-Kv "VPN tunnel" $Tunnel
Write-Kv "VPN static route" $Route

# ---------------------------------------------------------------------------
# Gather state for the health summary.
# ---------------------------------------------------------------------------
$tunRaw = Get-GCloudValue compute vpn-tunnels describe $Tunnel --region $Region --project $Project `
    --format="value[separator='~'](status,detailedStatus,peerIp,ikeVersion,localTrafficSelector.list(),remoteTrafficSelector.list(),targetVpnGateway.basename())"
$tStatus = ""; $tDetail = ""; $tPeer = ""; $tIke = ""; $tLocal = ""; $tRemote = ""; $tGw = ""
if (-not [string]::IsNullOrWhiteSpace($tunRaw)) {
    $parts = $tunRaw -split "~"
    $tStatus = $parts[0]; $tDetail = $parts[1]; $tPeer = $parts[2]; $tIke = $parts[3]
    $tLocal = $parts[4]; $tRemote = $parts[5]; $tGw = $parts[6]
}

$gwRaw = Get-GCloudValue compute target-vpn-gateways describe $Gateway --region $Region --project $Project `
    --format="value[separator='~'](status,network.basename(),tunnels.map().basename().list())"
$gStatus = ""; $gNetwork = ""; $gTunnels = ""
if (-not [string]::IsNullOrWhiteSpace($gwRaw)) {
    $parts = $gwRaw -split "~"
    $gStatus = $parts[0]; $gNetwork = $parts[1]; $gTunnels = $parts[2]
}

$rtRaw = Get-GCloudValue compute routes describe $Route --project $Project `
    --format="value[separator='~'](destRange,priority,nextHopVpnTunnel.basename(),network.basename())"
$rDest = ""; $rPrio = ""; $rTunnel = ""; $rNet = ""
if (-not [string]::IsNullOrWhiteSpace($rtRaw)) {
    $parts = $rtRaw -split "~"
    $rDest = $parts[0]; $rPrio = $parts[1]; $rTunnel = $parts[2]; $rNet = $parts[3]
}

& gcloud compute routers describe $Router --region $Region --project $Project *> $null
$routerExists = ($LASTEXITCODE -eq 0)

switch ($tStatus) {
    "ESTABLISHED" { $tMark = "[ UP ]" }
    "" { $tMark = "[ n/a]"; $tStatus = "not found"; $tDetail = "tunnel '$Tunnel' not found in $Region" }
    default { $tMark = "[DOWN]" }
}
switch ($gStatus) {
    "READY" { $gMark = "[ OK ]" }
    "" { $gMark = "[ n/a]"; $gStatus = "not found" }
    default { $gMark = "[WARN]" }
}
if (-not [string]::IsNullOrWhiteSpace($rDest)) { $rMark = "[ OK ]" } else { $rMark = "[FAIL]" }
if ($routerExists) { $bMark = "[ OK ]"; $bText = "$Router present" } else { $bMark = "[ n/a]"; $bText = "not configured (interconnect/BGP disabled)" }

Write-Sub "Health summary"
$routeText = if ($rDest) { "$rDest via $rTunnel" } else { "missing" }
Write-Host ("   {0,-22} {1,-7} {2}" -f "VPN tunnel", $tMark, "$tStatus - $tDetail")
Write-Host ("   {0,-22} {1,-7} {2}" -f "Classic VPN gateway", $gMark, $gStatus)
Write-Host ("   {0,-22} {1,-7} {2}" -f "VPN static route", $rMark, $routeText)
Write-Host ("   {0,-22} {1,-7} {2}" -f "Cloud Router (BGP)", $bMark, $bText)

# ---------------------------------------------------------------------------
# VPN tunnel detail.
# ---------------------------------------------------------------------------
Write-Sub "VPN tunnel detail: $Tunnel"
if (-not [string]::IsNullOrWhiteSpace($tunRaw)) {
    Write-Kv "Status" $tStatus
    Write-Kv "Detail" $tDetail
    Write-Kv "Peer IP (Azure)" $tPeer
    Write-Kv "IKE version" $tIke
    Write-Kv "Local selector" $tLocal
    Write-Kv "Remote selector" $tRemote
    Write-Kv "Target gateway" $tGw
}
else {
    Write-Note "Tunnel '$Tunnel' not found in region '$Region'."
}

# ---------------------------------------------------------------------------
# Classic VPN gateway + forwarding rules.
# ---------------------------------------------------------------------------
Write-Sub "Classic VPN gateway: $Gateway"
if (-not [string]::IsNullOrWhiteSpace($gwRaw)) {
    Write-Kv "Status" $gStatus
    Write-Kv "Network" $gNetwork
    Write-Kv "Tunnels" $gTunnels
}
else {
    Write-Note "Gateway '$Gateway' not found in region '$Region'."
}
Write-Host ""
Write-Host "   Forwarding rules (IPsec ports):"
Invoke-GCloud compute forwarding-rules list `
    --project $Project `
    --regions $Region `
    --filter "target:targetVpnGateways/$Gateway" `
    --format "table[box](name:label=NAME, IPAddress:label=PUBLIC_IP, IPProtocol:label=PROTO, ports.list():label=PORTS)"

# ---------------------------------------------------------------------------
# VPN static route detail.
# ---------------------------------------------------------------------------
Write-Sub "VPN-backed static route: $Route"
if (-not [string]::IsNullOrWhiteSpace($rtRaw)) {
    Write-Kv "Destination" $rDest
    Write-Kv "Priority" $rPrio
    Write-Kv "Next hop tunnel" $rTunnel
    Write-Kv "Network" $rNet
}
else {
    Write-Note "Route '$Route' not found."
}

# ---------------------------------------------------------------------------
# All VPC routes (static + dynamic).
# ---------------------------------------------------------------------------
Write-Sub "VPC routes for network: $Network"
Invoke-GCloud compute routes list `
    --project $Project `
    --filter "network:$Network" `
    --format "table[box](name:label=ROUTE, destRange:label=DESTINATION, priority:label=PRIO, nextHopVpnTunnel.basename():label=VPN_TUNNEL, nextHopGateway.basename():label=GATEWAY, nextHopIp:label=NEXT_HOP_IP, routeType:label=TYPE)"

# ---------------------------------------------------------------------------
# Cloud Router BGP status (only when a router exists).
# ---------------------------------------------------------------------------
Write-Sub "Cloud Router BGP status: $Router"
if ($routerExists) {
    Write-Host "   BGP peers:"
    Invoke-GCloud compute routers get-status $Router --region $Region --project $Project `
        --format "table[box](result.bgpPeerStatus[].name:label=PEER, result.bgpPeerStatus[].state:label=STATE, result.bgpPeerStatus[].ipAddress:label=LOCAL_IP, result.bgpPeerStatus[].peerIpAddress:label=PEER_IP, result.bgpPeerStatus[].numLearnedRoutes:label=LEARNED, result.bgpPeerStatus[].uptime:label=UPTIME)"
    Write-Host ""
    Write-Host "   Best learned routes:"
    Invoke-GCloud compute routers get-status $Router --region $Region --project $Project `
        --format "table[box](result.bestRoutes[].destRange:label=DESTINATION, result.bestRoutes[].nextHopIp:label=NEXT_HOP_IP, result.bestRoutes[].priority:label=PRIO)"
}
else {
    Write-Note "Cloud Router '$Router' not found in region '$Region'."
    Write-Note "Expected when terraform/gcp enable_interconnect=false (Classic VPN uses static routes). Continuing."
}

# ---------------------------------------------------------------------------
# Firewall rules for reachability context.
# ---------------------------------------------------------------------------
Write-Sub "Firewall rules on network: $Network"
Invoke-GCloud compute firewall-rules list `
    --project $Project `
    --filter "network:$Network" `
    --format "table[box](name:label=NAME, direction:label=DIR, priority:label=PRIO, sourceRanges.list():label=SOURCE_RANGES, allowed[].map().firewall_rule().list():label=ALLOW, disabled:label=DISABLED)"

# ---------------------------------------------------------------------------
# Optional raw detail.
# ---------------------------------------------------------------------------
if ($Raw) {
    Write-Banner "RAW DETAIL (-Raw)"
    Write-Sub "vpn-tunnels describe"
    Invoke-GCloud compute vpn-tunnels describe $Tunnel --region $Region --project $Project --format yaml
    Write-Sub "target-vpn-gateways describe"
    Invoke-GCloud compute target-vpn-gateways describe $Gateway --region $Region --project $Project --format yaml
    Write-Sub "routes describe"
    Invoke-GCloud compute routes describe $Route --project $Project --format yaml
    if ($routerExists) {
        Write-Sub "routers get-status"
        Invoke-GCloud compute routers get-status $Router --region $Region --project $Project --format yaml
    }
}

Write-Banner "DONE"
Write-Host "GCP route dump completed. Re-run with -Raw for full gcloud detail."
