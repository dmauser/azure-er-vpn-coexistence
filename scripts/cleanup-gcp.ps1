#Requires -Version 5.1
<#
.SYNOPSIS
    Tear down ONLY the GCP (simulated on-premises) side of the lab (Windows / PowerShell).

.DESCRIPTION
    Runs `terraform destroy` against terraform/gcp only. The Azure side is left
    untouched - use cleanup-azure.ps1 for that.

    ORDER MATTERS: destroy Azure BEFORE GCP. The Azure Local Network Gateway and
    VPN connection are planned from GCP's Terraform remote state, so destroy the
    Azure side first (cleanup-azure.ps1), then run this script.

.PARAMETER Project
    GCP project ID the lab was deployed to (required).

.PARAMETER Region
    GCP region (default: us-central1).

.PARAMETER Zone
    GCP zone (default: <region>-c).

.PARAMETER CallerIp
    Value passed to caller_source_ip. Irrelevant for a destroy; a placeholder is
    used if omitted, since Terraform still requires the variable to be set.

.PARAMETER AutoApprove
    Skip the interactive 'yes' confirmation for terraform destroy.

.EXAMPLE
    .\cleanup-gcp.ps1 -Project my-gcp-project

.EXAMPLE
    .\cleanup-gcp.ps1 -Project my-gcp-project -Region us-central1 -AutoApprove
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Project,
    [string] $Region   = 'us-central1',
    [string] $Zone     = '',
    [string] $CallerIp = '0.0.0.0',
    [switch] $AutoApprove
)

$ErrorActionPreference = 'Stop'

# Scripts live in <repo>/scripts; terraform dirs are resolved from the repo root.
$RepoRoot = Split-Path -Parent $PSScriptRoot
$GcpDir   = 'terraform/gcp'

if (-not $Zone) { $Zone = "$Region-c" }

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

# OneDrive intermittently places a byte-range lock on the .tfstate file, which makes
# Terraform's terraform_remote_state read fail during the (lengthy) refresh phase with
# "another process has locked a portion of the file". Copy the peer state to a temp file
# outside the synced folder and point the data source at that stable copy.
function Copy-PeerStateToTemp {
    param([string] $SourcePath)
    if (-not (Test-Path -LiteralPath $SourcePath)) { return $null }
    $dest = Join-Path ([System.IO.Path]::GetTempPath()) "az-er-vpn-azure-state-$PID.tfstate"
    for ($i = 1; $i -le 5; $i++) {
        try { Copy-Item -LiteralPath $SourcePath -Destination $dest -Force; return $dest }
        catch { Start-Sleep -Seconds 2 }
    }
    Write-Warn "Could not copy Azure state to a temp file (OneDrive lock); using the original path."
    return $null
}

if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
    Write-Fail "terraform is not installed or not on PATH."
}

Set-Location $RepoRoot

Write-Banner 'CLEANUP - GCP resources only'
Write-Warn 'This permanently destroys the GCP on-prem side of the lab (VPN tunnel, VM, VPC, firewall).'
Write-Warn 'Destroy Azure FIRST (cleanup-azure.ps1) - the Azure side references GCP Terraform state.'

$tfAutoApprove = if ($AutoApprove) { @('-auto-approve') } else { @() }

# Avoid OneDrive locking the Azure state during the GCP refresh by reading a temp copy.
$peerVar  = @()
$tempState = Copy-PeerStateToTemp -SourcePath (Join-Path $RepoRoot 'terraform/azure/terraform.tfstate')
if ($tempState) { $peerVar = @("-var=azure_remote_state_path=$($tempState -replace '\\','/')") }

try {
    Write-Step 'terraform init (gcp)'
    Invoke-Tf -TfArgs @("-chdir=$GcpDir", 'init', '-input=false')

    Write-Step 'terraform destroy (gcp)'
    Invoke-Tf -TfArgs (@(
        "-chdir=$GcpDir", 'destroy', '-input=false',
        "-var=project=$Project",
        "-var=region=$Region",
        "-var=zone=$Zone",
        "-var=caller_source_ip=$CallerIp"
    ) + $peerVar + $tfAutoApprove)
}
finally {
    if ($tempState -and (Test-Path -LiteralPath $tempState)) {
        Remove-Item -LiteralPath $tempState -Force -ErrorAction SilentlyContinue
    }
}

Write-Banner 'GCP CLEANUP COMPLETE'
Write-Ok 'GCP lab resources removed.'
