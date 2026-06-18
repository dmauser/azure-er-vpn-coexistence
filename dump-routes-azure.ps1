<#
.SYNOPSIS
Dump Azure route views for the ER/VPN coexistence lab.

.USAGE
.\dump-routes-azure.ps1 [-ResourceGroup <rg>] [-CircuitName <name>]
  [-ErGatewayName <name>] [-Nics <nic[]>] [-Advertised] [-Yes]

.PARAMETER ResourceGroup
Azure resource group. Defaults to AZURE_ROUTE_RG or lab-er-vpn-coexistence.

.PARAMETER CircuitName
ExpressRoute circuit name. Defaults to AZURE_ROUTE_CIRCUIT,
terraform output -raw expressroute_circuit_name when available, or az-hub-er-circuit.

.PARAMETER ErGatewayName
ExpressRoute virtual network gateway name. Defaults to AZURE_ROUTE_ER_GATEWAY or Az-Hub-ergw.

.PARAMETER Nics
NIC names for VM effective route dumps. Defaults to AZURE_ROUTE_NICS or auto-discovery in the resource group; falls back to the three lab NICs.

.PARAMETER Advertised
Also dump ExpressRoute gateway advertised routes.

.PARAMETER Yes
Non-interactive mode; accept defaults and active subscription.
#>

[CmdletBinding()]
param(
    [string]$ResourceGroup = $(if ($env:AZURE_ROUTE_RG) { $env:AZURE_ROUTE_RG } else { "lab-er-vpn-coexistence" }),
    [string]$CircuitName = $(if ($env:AZURE_ROUTE_CIRCUIT) { $env:AZURE_ROUTE_CIRCUIT } else { "az-hub-er-circuit" }),
    [string]$ErGatewayName = $(if ($env:AZURE_ROUTE_ER_GATEWAY) { $env:AZURE_ROUTE_ER_GATEWAY } else { "Az-Hub-ergw" }),
    [string[]]$Nics = $(if ($env:AZURE_ROUTE_NICS) { $env:AZURE_ROUTE_NICS -split "," } else { @() }),
    [switch]$Advertised = $($env:AZURE_ROUTE_ADVERTISED -match "^(1|true|yes|y)$"),
    [switch]$Yes = $($env:AZURE_ROUTE_YES -match "^(1|true|yes|y)$")
)

$ErrorActionPreference = "Continue"
$DefaultNics = @("Az-Hub-lxvm-nic", "Az-Spk1-lxvm-nic", "Az-Spk2-lxvm-nic")
$PeeringName = "AzurePrivatePeering"

function Test-Interactive {
    return [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
}

function Read-WithDefault {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Value
    )
    if ((Test-Interactive) -and -not $Yes) {
        $reply = Read-Host "$Label [$Value]"
        if ($reply) { return $reply }
    }
    return $Value
}

function Write-Section {
    param([Parameter(Mandatory = $true)][string]$Title)
    Write-Host ""
    Write-Host "========== $Title =========="
}

function Write-Note {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "NOTE: $Message"
}

function Set-CircuitNameFromTerraform {
    if ((Get-Command terraform -ErrorAction SilentlyContinue) -and (Test-Path -Path "terraform\azure" -PathType Container)) {
        $tfOutput = & terraform -chdir=terraform\azure output -raw expressroute_circuit_name 2>$null
        if ($LASTEXITCODE -eq 0 -and $tfOutput -and $tfOutput -ne "null") {
            $script:CircuitName = $tfOutput.Trim()
        }
    }
}

function Assert-AzReady {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        Write-Error "Azure CLI 'az' is not installed or not on PATH."
        exit 1
    }
    & az account show 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Azure CLI is not logged in. Run 'az login' first."
        exit 1
    }
}

function Confirm-Subscription {
    Write-Section "Active Azure subscription"
    & az account show --query "{name:name,id:id,tenantId:tenantId}" -o table
    if ((Test-Interactive) -and -not $Yes) {
        $reply = Read-Host "Continue with this subscription? [Y/n]"
        if ($reply -and $reply -notmatch "^(y|yes)$") {
            Write-Host "Aborted."
            exit 0
        }
    }
}

function Get-RouteDumpNics {
    if ($Nics.Count -gt 0) {
        Write-Note "Using NICs supplied by parameter/env."
        return $Nics
    }

    $discovered = & az network nic list -g $ResourceGroup --query "[].name" -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and $discovered) {
        Write-Note "Using NICs discovered in resource group '$ResourceGroup'."
        return @($discovered | Where-Object { $_ })
    }

    Write-Note "NIC discovery failed or returned none; using lab defaults."
    return $DefaultNics
}

function Invoke-AzGracefully {
    param(
        [Parameter(Mandatory = $true)][string]$UnavailableMessage,
        [Parameter(Mandatory = $true)][string[]]$AzArgs
    )
    & az @AzArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Note $UnavailableMessage
    }
}

function Dump-CircuitRoutes {
    param([Parameter(Mandatory = $true)][string]$Path)
    Write-Host "-- ExpressRoute circuit route table ($Path)"
    Invoke-AzGracefully `
        -UnavailableMessage "Circuit routes unavailable for path '$Path' (circuit not provisioned, ExpressRoute disabled, or peering missing). Continuing." `
        -AzArgs @("network", "express-route", "list-route-table", "--resource-group", $ResourceGroup, "--name", $CircuitName, "--peering-name", $PeeringName, "--path", $Path, "-o", "table")
}

function Dump-EffectiveRoutes {
    param([Parameter(Mandatory = $true)][string[]]$RouteNics)
    foreach ($nic in $RouteNics) {
        if (-not $nic) { continue }
        Write-Host "-- Effective routes for NIC: $nic"
        Invoke-AzGracefully `
            -UnavailableMessage "Effective routes unavailable for NIC '$nic'. Continuing." `
            -AzArgs @("network", "nic", "show-effective-route-table", "--resource-group", $ResourceGroup, "--name", $nic, "-o", "table")
        Write-Host ""
    }
}

function Dump-GatewayRoutes {
    Write-Host "-- ExpressRoute gateway learned routes: $ErGatewayName"
    Invoke-AzGracefully `
        -UnavailableMessage "Learned routes unavailable (ER gateway/connection may not exist). Continuing." `
        -AzArgs @("network", "vnet-gateway", "list-learned-routes", "--resource-group", $ResourceGroup, "--name", $ErGatewayName, "-o", "table")

    if ($Advertised) {
        Write-Host ""
        Write-Host "-- ExpressRoute gateway advertised routes: $ErGatewayName"
        Invoke-AzGracefully `
            -UnavailableMessage "Advertised routes unavailable (ER gateway/connection may not exist). Continuing." `
            -AzArgs @("network", "vnet-gateway", "list-advertised-routes", "--resource-group", $ResourceGroup, "--name", $ErGatewayName, "-o", "table")
    }
}

Assert-AzReady
Set-CircuitNameFromTerraform

$ResourceGroup = Read-WithDefault -Label "Resource group" -Value $ResourceGroup
$CircuitName = Read-WithDefault -Label "ExpressRoute circuit name" -Value $CircuitName
$ErGatewayName = Read-WithDefault -Label "ExpressRoute gateway name" -Value $ErGatewayName

Confirm-Subscription
$RouteNics = Get-RouteDumpNics

Write-Section "ExpressRoute circuit routes only"
Dump-CircuitRoutes -Path "primary"
Write-Host ""
Dump-CircuitRoutes -Path "secondary"

Write-Section "VM effective routes"
Dump-EffectiveRoutes -RouteNics $RouteNics

Write-Section "ExpressRoute gateway learned routes"
Dump-GatewayRoutes

