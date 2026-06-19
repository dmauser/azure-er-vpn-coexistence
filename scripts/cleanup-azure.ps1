#Requires -Version 5.1
<#
.SYNOPSIS
    Tear down ONLY the Azure side of the ER/VPN coexistence lab (Windows / PowerShell).

.DESCRIPTION
    Runs `terraform destroy` against terraform/azure only. The GCP side is left
    untouched - use cleanup-gcp.ps1 for that.

    ORDER MATTERS: destroy Azure BEFORE GCP. The Azure Local Network Gateway and
    VPN connection are planned from GCP's Terraform remote state, so the GCP state
    file must still exist when Azure is destroyed. Running this script first (then
    cleanup-gcp.ps1) preserves that order.

    enable_onprem_connection=true is passed so Terraform can plan the teardown of
    the Local Network Gateway + VPN connection while the GCP state is still present.

.PARAMETER Location
    Azure region the lab was deployed to (default: centralus).

.PARAMETER VmUsername
    VM admin username used at deploy time (default: azureuser).

.PARAMETER VmPassword
    VM admin password as a SecureString. The value is irrelevant for a destroy but
    Terraform still requires the variable to be set; a placeholder is used if omitted.

.PARAMETER AutoApprove
    Skip the interactive 'yes' confirmation for terraform destroy.

.PARAMETER ResourceGroup
    Azure resource group (default: lab-ervpn-coexist). Used to clear an orphaned
    ExpressRoute gateway connection (via az) before destroy so the ER gateway can be deleted.

.EXAMPLE
    .\cleanup-azure.ps1

.EXAMPLE
    .\cleanup-azure.ps1 -Location eastus2 -AutoApprove
#>
[CmdletBinding()]
param(
    [string]       $Location    = 'centralus',
    [string]       $VmUsername  = 'azureuser',
    [SecureString] $VmPassword,
    [string]       $ResourceGroup = 'lab-ervpn-coexist',
    [switch]       $AutoApprove
)

$ErrorActionPreference = 'Stop'

# Scripts live in <repo>/scripts; terraform dirs are resolved from the repo root.
$RepoRoot = Split-Path -Parent $PSScriptRoot
$AzureDir = 'terraform/azure'

function Write-Banner([string]$Text) {
    Write-Host ''
    Write-Host ('=' * 60) -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('=' * 60) -ForegroundColor Cyan
}
function Write-Step([string]$Text) { Write-Host ''; Write-Host "---- $Text ----" -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host "  [ok]  $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "  [!]   $Text" -ForegroundColor Yellow }
function Write-Fail([string]$Text) { Write-Host "  [x]   ERROR: $Text" -ForegroundColor Red; exit 1 }

function Invoke-Tf {
    param([string[]] $TfArgs)
    & terraform @TfArgs
    if ($LASTEXITCODE -ne 0) { Write-Fail "terraform exited with code $LASTEXITCODE" }
}

# Best-effort removal of an ExpressRoute gateway connection that exists in Azure but is no
# longer tracked in Terraform state (e.g. left behind by an earlier failed destroy). While
# present it blocks the ER gateway delete with VirtualNetworkGatewayCannotBeDeleted. Requires
# az; skipped silently if az is missing or not logged in. Terraform-managed connections are
# unaffected (deleting an already-gone resource is a no-op for the later destroy).
function Remove-OrphanedErConnection {
    param([string] $ResourceGroup, [string] $Name = 'ER-Connection-to-Onprem')
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { return }
    & az account show 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) { return }
    $id = & az network vpn-connection show --name $Name --resource-group $ResourceGroup --query id --output tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and $id) {
        Write-Step "Removing orphaned ExpressRoute connection ($Name)"
        & az network vpn-connection delete --name $Name --resource-group $ResourceGroup 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Ok "Deleted $Name" }
        else { Write-Warn "Could not delete $Name via az; Terraform destroy may fail if it is orphaned." }
    }
}

# OneDrive intermittently places a byte-range lock on the .tfstate file, which makes
# Terraform's terraform_remote_state read fail during the (lengthy) refresh phase with
# "another process has locked a portion of the file". Copy the peer GCP state to a temp
# file outside the synced folder and point the data source at that stable copy.
function Copy-PeerStateToTemp {
    param([string] $SourcePath)
    if (-not (Test-Path -LiteralPath $SourcePath)) { return $null }
    $dest = Join-Path ([System.IO.Path]::GetTempPath()) "az-er-vpn-gcp-state-$PID.tfstate"
    for ($i = 1; $i -le 5; $i++) {
        try { Copy-Item -LiteralPath $SourcePath -Destination $dest -Force; return $dest }
        catch { Start-Sleep -Seconds 2 }
    }
    Write-Warn "Could not copy GCP state to a temp file (OneDrive lock); using the original path."
    return $null
}

if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
    Write-Fail "terraform is not installed or not on PATH."
}

# Terraform still requires vm_admin_password to be set even on destroy.
if ($VmPassword) {
    $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($VmPassword))
    $env:TF_VAR_vm_admin_password = $plain
}
elseif (-not $env:TF_VAR_vm_admin_password) {
    # Value is unused for a destroy; supply a placeholder so Terraform can plan.
    $env:TF_VAR_vm_admin_password = 'PlaceholderForDestroy!1'
}

Set-Location $RepoRoot

Write-Banner 'CLEANUP - Azure resources only'
Write-Warn 'This permanently destroys the Azure side of the lab (connections, gateways, VMs, VNets, NSGs).'
Write-Warn 'Destroy Azure BEFORE GCP - the Azure LNG/VPN connection references GCP Terraform state.'

$tfAutoApprove = if ($AutoApprove) { @('-auto-approve') } else { @() }

# Azure reads the GCP state (enable_onprem_connection=true) — read a temp copy to dodge OneDrive locks.
$peerVar   = @()
$tempState = Copy-PeerStateToTemp -SourcePath (Join-Path $RepoRoot 'terraform/gcp/terraform.tfstate')
if ($tempState) { $peerVar = @("-var=gcp_remote_state_path=$($tempState -replace '\\','/')") }

try {
    Write-Step 'terraform init (azure)'
    Invoke-Tf -TfArgs @("-chdir=$AzureDir", 'init', '-input=false')

    # Clear a possibly-orphaned ER connection before destroy so the ER gateway can be deleted.
    Remove-OrphanedErConnection -ResourceGroup $ResourceGroup

    Write-Step 'terraform destroy (azure)'
    # enable_expressroute/enable_er_connection are forced true so that, if an ER circuit
    # and ER gateway connection exist in state, Terraform tears the connection down BEFORE
    # the (always-present) ER gateway. For a destroy this never creates anything: resources
    # absent from state are simply skipped. Without it, the in-state connection references a
    # now-count-0 circuit and the ER gateway delete fails (VirtualNetworkGatewayCannotBeDeleted).
    Invoke-Tf -TfArgs (@(
        "-chdir=$AzureDir", 'destroy', '-input=false',
        "-var=location=$Location",
        "-var=vm_admin_username=$VmUsername",
        '-var=enable_onprem_connection=true',
        '-var=enable_expressroute=true',
        '-var=enable_er_connection=true'
    ) + $peerVar + $tfAutoApprove)
}
finally {
    if ($tempState -and (Test-Path -LiteralPath $tempState)) {
        Remove-Item -LiteralPath $tempState -Force -ErrorAction SilentlyContinue
    }
    Remove-Item Env:TF_VAR_vm_admin_password -ErrorAction SilentlyContinue
}

Write-Banner 'AZURE CLEANUP COMPLETE'
Write-Ok 'Azure lab resources removed.'
Write-Warn 'Run cleanup-gcp.ps1 next to remove the GCP on-prem side.'
Write-Warn 'If ExpressRoute was deployed, cancel Megaport VXCs at https://portal.megaport.com.'
