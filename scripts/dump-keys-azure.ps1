<#
.SYNOPSIS
Dump the Azure ExpressRoute circuit service key for the ER/VPN coexistence lab.

.USAGE
.\dump-keys-azure.ps1 [-ResourceGroup <rg>] [-CircuitName <name>] [-Yes]

.PARAMETER ResourceGroup
Azure resource group. Defaults to AZURE_KEYS_RG or lab-ervpn-coexist.

.PARAMETER CircuitName
ExpressRoute circuit name. Defaults to AZURE_KEYS_CIRCUIT,
terraform output -raw expressroute_circuit_name when available, or az-hub-er-circuit.

.PARAMETER Yes
Non-interactive mode; accept defaults and active subscription.

.NOTES
The service key is sensitive. It is printed to the console on purpose so you can
hand it to the connectivity provider. Do not capture this output into logs.
#>

[CmdletBinding()]
param(
    [string]$ResourceGroup = $(if ($env:AZURE_KEYS_RG) { $env:AZURE_KEYS_RG } else { "lab-ervpn-coexist" }),
    [string]$CircuitName = $(if ($env:AZURE_KEYS_CIRCUIT) { $env:AZURE_KEYS_CIRCUIT } else { "az-hub-er-circuit" }),
    [switch]$Yes = $($env:AZURE_KEYS_YES -match "^(1|true|yes|y)$")
)

$ErrorActionPreference = "Continue"

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

function Get-AzureTfDir {
    return Join-Path (Split-Path -Parent $PSScriptRoot) 'terraform\azure'
}

function Get-TerraformOutput {
    param([Parameter(Mandatory = $true)][string]$Name)
    $azTfDir = Get-AzureTfDir
    if ((Get-Command terraform -ErrorAction SilentlyContinue) -and (Test-Path -Path $azTfDir -PathType Container)) {
        $value = & terraform -chdir=$azTfDir output -raw $Name 2>$null
        if ($LASTEXITCODE -eq 0 -and $value -and $value -ne "null") {
            return $value.Trim()
        }
    }
    return ""
}

function Set-CircuitNameFromTerraform {
    $name = Get-TerraformOutput -Name "expressroute_circuit_name"
    if ($name) { $script:CircuitName = $name }
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

Assert-AzReady
Set-CircuitNameFromTerraform

$ResourceGroup = Read-WithDefault -Label "Resource group" -Value $ResourceGroup
$CircuitName = Read-WithDefault -Label "ExpressRoute circuit name" -Value $CircuitName

Confirm-Subscription

Write-Section "ExpressRoute circuit service key"
Write-Host "Circuit: $CircuitName (resource group: $ResourceGroup)"
Write-Host ""

# Prefer the Terraform state value (exact, no extra API call); fall back to az.
$serviceKey = Get-TerraformOutput -Name "expressroute_service_key"
$source = "terraform output (expressroute_service_key)"

if (-not $serviceKey) {
    $serviceKey = & az network express-route show --resource-group $ResourceGroup --name $CircuitName --query "serviceKey" -o tsv 2>$null
    if ($LASTEXITCODE -ne 0) { $serviceKey = "" }
    $source = "az network express-route show"
}

if ($serviceKey) {
    Write-Host ("   {0,-14} {1}" -f "Service key:", $serviceKey)
    Write-Host ("   {0,-14} {1}" -f "Source:", $source)
}
else {
    Write-Note "Service key unavailable. The circuit may not be provisioned, or ExpressRoute is disabled (enable_expressroute=false). Continuing."
}

Write-Host ""
