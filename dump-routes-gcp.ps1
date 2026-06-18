<#
.SYNOPSIS
Dump GCP routing state for the azure-er-vpn-coexistence2 lab.

.USAGE
.\dump-routes-gcp.ps1 [-Project <id>] [-Region <region>] [-Network <name>] [-Router <name>] [-Tunnel <name>] [-Gateway <name>] [-Route <name>] [-NoPrompt]

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

.PARAMETER NoPrompt
Do not prompt; use parameters, environment, and defaults.

.EXAMPLE
.\dump-routes-gcp.ps1

.EXAMPLE
.\dump-routes-gcp.ps1 -Project my-project -Region us-central1 -NoPrompt
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
    [switch]$NoPrompt
)

$ErrorActionPreference = "Continue"

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "================================================================================"
    Write-Host $Title
    Write-Host "================================================================================"
}

function Invoke-GCloud {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    Write-Host ("+ gcloud " + ($Arguments -join " "))
    & gcloud @Arguments
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "gcloud exited with code $LASTEXITCODE; continuing."
    }
}

function Confirm-Value {
    param(
        [string]$Label,
        [string]$Value
    )
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

Write-Section "GCLOUD AUTHENTICATION"
Invoke-GCloud auth list
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

Write-Section "SELECTED GCP LAB DEFAULTS"
@"
Project:             $Project
Region:              $Region
VPC network:         $Network
Cloud Router:        $Router
Classic VPN gateway: $Gateway
VPN tunnel:          $Tunnel
VPN static route:    $Route
"@ | Write-Host

Write-Section "VPC ROUTES: STATIC + DYNAMIC NEXT HOPS"
Invoke-GCloud compute routes list `
    --project $Project `
    --filter "network:$Network" `
    --format "table(name,destRange,priority,nextHopVpnTunnel,nextHopGateway,nextHopPeering,nextHopInterconnectAttachment,nextHopIp,nextHopInstance,routeStatus,routeType)"

Write-Section "VPN TUNNEL STATUS"
Invoke-GCloud compute vpn-tunnels list `
    --project $Project `
    --regions $Region `
    --filter "name=($Tunnel)" `
    --format "table(name,region,targetVpnGateway,peerIp,status,detailedStatus)"
Invoke-GCloud compute vpn-tunnels describe $Tunnel `
    --region $Region `
    --project $Project `
    --format yaml

Write-Section "CLASSIC VPN GATEWAY + FORWARDING RULES"
Invoke-GCloud compute target-vpn-gateways describe $Gateway `
    --region $Region `
    --project $Project `
    --format yaml
Invoke-GCloud compute forwarding-rules list `
    --project $Project `
    --regions $Region `
    --filter "target:targetVpnGateways/$Gateway" `
    --format "table(name,region,IPAddress,IPProtocol,ports,target)"

Write-Section "VPN-BACKED STATIC ROUTE"
Invoke-GCloud compute routes describe $Route `
    --project $Project `
    --format yaml
Invoke-GCloud compute routes list `
    --project $Project `
    --filter "name=($Route) OR nextHopVpnTunnel:$Tunnel" `
    --format "table(name,network,destRange,priority,nextHopVpnTunnel,routeStatus,routeType)"

Write-Section "CLOUD ROUTER BGP STATUS"
& gcloud compute routers describe $Router --region $Region --project $Project *> $null
if ($LASTEXITCODE -eq 0) {
    Invoke-GCloud compute routers get-status $Router `
        --region $Region `
        --project $Project `
        --format yaml
    Invoke-GCloud compute routers describe $Router `
        --region $Region `
        --project $Project `
        --format yaml
}
else {
    Write-Host "NOTE: Cloud Router '$Router' was not found in region '$Region'."
    Write-Host "      This is expected when terraform/gcp enable_interconnect=false; continuing."
}

Write-Section "FIREWALL RULES FOR REACHABILITY CONTEXT"
Invoke-GCloud compute firewall-rules list `
    --project $Project `
    --filter "network:$Network" `
    --format "table(name,direction,priority,sourceRanges,allowed,disabled)"

Write-Section "DONE"
Write-Host "GCP route dump completed."
