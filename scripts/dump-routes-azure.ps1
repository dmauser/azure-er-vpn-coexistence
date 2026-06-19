<#
.SYNOPSIS
Dump Azure route views for the ER/VPN coexistence lab.

.USAGE
.\dump-routes-azure.ps1 [-ResourceGroup <rg>] [-CircuitName <name>]
  [-ErGatewayName <name>] [-VpnGatewayName <name>] [-Nics <nic[]>]
  [-Components <nics,circuit,ergw,vpngw|all>] [-Advertised] [-Yes]

.PARAMETER ResourceGroup
Azure resource group. Defaults to AZURE_ROUTE_RG or lab-ervpn-coexist.

.PARAMETER CircuitName
ExpressRoute circuit name. Defaults to AZURE_ROUTE_CIRCUIT,
terraform output -raw expressroute_circuit_name when available, or az-hub-er-circuit.

.PARAMETER ErGatewayName
ExpressRoute virtual network gateway name. Defaults to AZURE_ROUTE_ER_GATEWAY or Az-Hub-ergw.

.PARAMETER VpnGatewayName
VPN virtual network gateway name. Defaults to AZURE_ROUTE_VPN_GATEWAY or Az-Hub-vpngw.

.PARAMETER Nics
NIC names for VM effective route dumps. Defaults to AZURE_ROUTE_NICS or auto-discovery in the resource group; falls back to the three lab NICs.

.PARAMETER Components
Comma-separated list of components to dump: nics, circuit, ergw, vpngw (or all).
Defaults to AZURE_ROUTE_COMPONENTS. When omitted in interactive mode you are prompted to choose; otherwise all components are dumped.

.PARAMETER Advertised
Also dump ExpressRoute/VPN gateway advertised routes.

.PARAMETER Yes
Non-interactive mode; accept defaults and active subscription.
#>

[CmdletBinding()]
param(
    [string]$ResourceGroup = $(if ($env:AZURE_ROUTE_RG) { $env:AZURE_ROUTE_RG } else { "lab-ervpn-coexist" }),
    [string]$CircuitName = $(if ($env:AZURE_ROUTE_CIRCUIT) { $env:AZURE_ROUTE_CIRCUIT } else { "az-hub-er-circuit" }),
    [string]$ErGatewayName = $(if ($env:AZURE_ROUTE_ER_GATEWAY) { $env:AZURE_ROUTE_ER_GATEWAY } else { "Az-Hub-ergw" }),
    [string]$VpnGatewayName = $(if ($env:AZURE_ROUTE_VPN_GATEWAY) { $env:AZURE_ROUTE_VPN_GATEWAY } else { "Az-Hub-vpngw" }),
    [string[]]$Nics = $(if ($env:AZURE_ROUTE_NICS) { $env:AZURE_ROUTE_NICS -split "," } else { @() }),
    [string[]]$Components = $(if ($env:AZURE_ROUTE_COMPONENTS) { $env:AZURE_ROUTE_COMPONENTS -split "," } else { @() }),
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
    $azTfDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'terraform\azure'
    if ((Get-Command terraform -ErrorAction SilentlyContinue) -and (Test-Path -Path $azTfDir -PathType Container)) {
        $tfOutput = & terraform -chdir=$azTfDir output -raw expressroute_circuit_name 2>$null
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
        -AzArgs @("network", "express-route", "list-route-tables", "--resource-group", $ResourceGroup, "--name", $CircuitName, "--peering-name", $PeeringName, "--path", $Path, "-o", "table")
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
    param(
        [Parameter(Mandatory = $true)][string]$GatewayName,
        [Parameter(Mandatory = $true)][string]$Kind
    )
    Write-Host "-- $Kind gateway learned routes: $GatewayName"
    Invoke-AzGracefully `
        -UnavailableMessage "Learned routes unavailable ($Kind gateway/connection may not exist). Continuing." `
        -AzArgs @("network", "vnet-gateway", "list-learned-routes", "--resource-group", $ResourceGroup, "--name", $GatewayName, "-o", "table")

    if ($Advertised) {
        Write-Host ""
        Write-Host "-- $Kind gateway advertised routes: $GatewayName"
        $peers = & az network vnet-gateway list-bgp-peer-status --resource-group $ResourceGroup --name $GatewayName --query "value[].neighbor" -o tsv 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $peers) {
            Write-Note "Advertised routes unavailable ($Kind gateway has no BGP peers, or gateway/connection may not exist). Continuing."
            return
        }
        foreach ($peer in (@($peers | Where-Object { $_ } | Select-Object -Unique))) {
            Write-Host "   advertised to peer ${peer}:"
            Invoke-AzGracefully `
                -UnavailableMessage "Advertised routes unavailable for peer '$peer'. Continuing." `
                -AzArgs @("network", "vnet-gateway", "list-advertised-routes", "--resource-group", $ResourceGroup, "--name", $GatewayName, "--peer", $peer, "-o", "table")
            Write-Host ""
        }
    }
}

$ValidComponents = @("nics", "circuit", "ergw", "vpngw")

function Resolve-Components {
    $normalized = @($Components | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })

    if ($normalized -contains "all") { return $ValidComponents }

    if ($normalized.Count -gt 0) {
        $selected = @($normalized | Where-Object { $ValidComponents -contains $_ })
        $invalid = @($normalized | Where-Object { $ValidComponents -notcontains $_ -and $_ -ne "all" })
        if ($invalid.Count -gt 0) { Write-Note "Ignoring unknown component(s): $($invalid -join ', ')." }
        if ($selected.Count -gt 0) { return $selected }
    }

    if ((Test-Interactive) -and -not $Yes) {
        Write-Section "Select route components to dump"
        Write-Host "  1) VMs / NICs effective routes"
        Write-Host "  2) ExpressRoute circuit routes"
        Write-Host "  3) ExpressRoute gateway routes"
        Write-Host "  4) VPN gateway routes"
        Write-Host "Enter numbers separated by commas (e.g. 1,3,4), or press Enter for all."
        $reply = Read-Host "Components [all]"
        if ($reply) {
            $map = @{ "1" = "nics"; "2" = "circuit"; "3" = "ergw"; "4" = "vpngw" }
            $picked = @()
            foreach ($token in ($reply -split "[,\s]+")) {
                $t = $token.Trim()
                if (-not $t) { continue }
                if ($map.ContainsKey($t)) { $picked += $map[$t] }
                elseif ($ValidComponents -contains $t.ToLower()) { $picked += $t.ToLower() }
                else { Write-Note "Ignoring unknown selection: $t." }
            }
            $picked = @($picked | Select-Object -Unique)
            if ($picked.Count -gt 0) { return $picked }
        }
    }

    return $ValidComponents
}

Assert-AzReady
Set-CircuitNameFromTerraform

$SelectedComponents = Resolve-Components
Write-Note "Components selected: $($SelectedComponents -join ', ')"

$ResourceGroup = Read-WithDefault -Label "Resource group" -Value $ResourceGroup
if ($SelectedComponents -contains "circuit") {
    $CircuitName = Read-WithDefault -Label "ExpressRoute circuit name" -Value $CircuitName
}
if ($SelectedComponents -contains "ergw") {
    $ErGatewayName = Read-WithDefault -Label "ExpressRoute gateway name" -Value $ErGatewayName
}
if ($SelectedComponents -contains "vpngw") {
    $VpnGatewayName = Read-WithDefault -Label "VPN gateway name" -Value $VpnGatewayName
}

Confirm-Subscription

if ($SelectedComponents -contains "circuit") {
    Write-Section "ExpressRoute circuit routes only"
    Dump-CircuitRoutes -Path "primary"
    Write-Host ""
    Dump-CircuitRoutes -Path "secondary"
}

if ($SelectedComponents -contains "nics") {
    $RouteNics = Get-RouteDumpNics
    Write-Section "VM effective routes"
    Dump-EffectiveRoutes -RouteNics $RouteNics
}

if ($SelectedComponents -contains "ergw") {
    Write-Section "ExpressRoute gateway learned routes"
    Dump-GatewayRoutes -GatewayName $ErGatewayName -Kind "ExpressRoute"
}

if ($SelectedComponents -contains "vpngw") {
    Write-Section "VPN gateway learned routes"
    Dump-GatewayRoutes -GatewayName $VpnGatewayName -Kind "VPN"
}

