<#
.SYNOPSIS
Dump the GCP Partner Interconnect VLAN attachment pairing key for the
azure-er-vpn-coexistence2 lab.

.USAGE
.\dump-keys-gcp.ps1 [-Project <id>] [-Region <region>] [-Attachment <name>] [-NoPrompt]

.PARAMETER Project
GCP project ID. Defaults from $env:GCP_PROJECT, $env:GOOGLE_CLOUD_PROJECT, then gcloud config.

.PARAMETER Region
GCP region. Defaults from $env:GCP_REGION, then us-central1.

.PARAMETER Attachment
Partner Interconnect VLAN attachment name. Defaults from $env:GCP_INTERCONNECT_ATTACHMENT,
terraform output -raw interconnect_attachment_name when available, or vpnlab-vlan.

.PARAMETER NoPrompt
Do not prompt; use parameters, environment, and defaults.

.NOTES
The pairing key is what you hand to the connectivity provider to provision the
VXC against your VLAN attachment. It is read from the GCP module's Terraform
output (interconnect_pairing_key) when available, otherwise from
`gcloud compute interconnects attachments partner describe`. The key is
sensitive; do not capture this output into logs. Requires enable_interconnect=true.
#>

[CmdletBinding()]
param(
    [string]$Project = $(if ($env:GCP_PROJECT) { $env:GCP_PROJECT } elseif ($env:GOOGLE_CLOUD_PROJECT) { $env:GOOGLE_CLOUD_PROJECT } else { "" }),
    [string]$Region = $(if ($env:GCP_REGION) { $env:GCP_REGION } else { "us-central1" }),
    [string]$Attachment = $(if ($env:GCP_INTERCONNECT_ATTACHMENT) { $env:GCP_INTERCONNECT_ATTACHMENT } else { "vpnlab-vlan" }),
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

function Get-GcpTfOutput {
    param([Parameter(Mandatory = $true)][string]$Name)
    $gcpTfDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'terraform\gcp'
    if ((Get-Command terraform -ErrorAction SilentlyContinue) -and (Test-Path -Path $gcpTfDir -PathType Container)) {
        $value = & terraform -chdir=$gcpTfDir output -raw $Name 2>$null
        if ($LASTEXITCODE -eq 0 -and $value -and $value -ne "null") {
            return $value.Trim()
        }
    }
    return ""
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

# Resolve the attachment name from Terraform when not overridden.
$tfAttachment = Get-GcpTfOutput -Name "interconnect_attachment_name"
if ($tfAttachment -and -not $env:GCP_INTERCONNECT_ATTACHMENT) { $Attachment = $tfAttachment }

$Project = Confirm-Value "GCP project" $Project
$Region = Confirm-Value "GCP region" $Region
$Attachment = Confirm-Value "Interconnect VLAN attachment" $Attachment

if ([string]::IsNullOrWhiteSpace($Project) -or $Project -eq "YOUR_GCP_PROJECT_ID") {
    throw "Set a valid project with -Project, GCP_PROJECT, GOOGLE_CLOUD_PROJECT, or the prompt."
}

Write-Banner "GCP INTERCONNECT PAIRING KEY DUMP"
Write-Kv "Account" $activeAccount
Write-Kv "Project" $Project
Write-Kv "Region" $Region
Write-Kv "VLAN attachment" $Attachment

# ---------------------------------------------------------------------------
# Pairing key — prefer the GCP module's Terraform output; fall back to gcloud.
# ---------------------------------------------------------------------------
Write-Sub "Partner Interconnect pairing key"
$pairingKey = Get-GcpTfOutput -Name "interconnect_pairing_key"
$source = "terraform output (gcp: interconnect_pairing_key)"

if (-not $pairingKey) {
    $pairingKey = (& gcloud compute interconnects attachments describe $Attachment --region $Region --project $Project --format="value(pairingKey)" 2>$null | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($pairingKey)) { $pairingKey = "" }
    $source = "gcloud compute interconnects attachments describe"
}

if ($pairingKey) {
    Write-Kv "Pairing key" $pairingKey
    Write-Kv "Source" $source
}
else {
    Write-Note "Pairing key unavailable. Interconnect may be disabled (enable_interconnect=false) or the attachment '$Attachment' is not provisioned in region '$Region'. Continuing."
}

Write-Banner "DONE"
