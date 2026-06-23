#Requires -Version 5.1
<#
.SYNOPSIS
    Azure ER/VPN Coexistence Lab deployment wrapper (Windows / PowerShell).

.DESCRIPTION
    Validates prerequisites and orchestrates the 3-apply Terraform deployment
    for the Azure ER/VPN coexistence lab (GCP as the simulated on-premises site).

    Azure VMs have NO public IP (reached via Serial Console / boot diagnostics).
    The auto-detected public IP is used ONLY for the GCP SSH firewall allow-list
    (caller_source_ip) - it is no longer applied to the Azure side.

    Default mode (no switch) runs the full check + deploy flow.
    Use -Check for prereq validation only, -Destroy to tear down all resources.

.PARAMETER Check
    Validate prerequisites only, then exit.

.PARAMETER Destroy
    Destroy all lab resources in reverse order (Azure first, then GCP).

.PARAMETER AutoApprove
    Skip the interactive 'yes' confirmation for terraform apply/destroy.

.PARAMETER EnableExpressRoute
    Run the optional ExpressRoute/Interconnect stage (Step 4, billable).

.PARAMETER Subscription
    Azure subscription name or ID to set before validating.

.PARAMETER Project
    GCP project ID to set before validating.

.PARAMETER Location
    Azure region (default: centralus). Prompted interactively if not supplied.

.PARAMETER Region
    GCP region (default: us-central1). Prompted interactively if not supplied.

.PARAMETER Zone
    GCP zone (default: <region>-c). Prompted interactively if not supplied.

.PARAMETER MachineType
    GCE machine type for the test VM (default: e2-micro). Verified against
    the configured zone before deploy; alternative zones in the region are
    listed if the SKU isn't offered or if a capacity stockout occurs.

.PARAMETER CallerIp
    Override the auto-detected public IP (GCP SSH firewall; no CIDR mask).

.PARAMETER VmUsername
    VM admin username. Default: azureuser. Prompted interactively if not supplied.

.PARAMETER VmPassword
    VM admin password as a SecureString. Prompted securely if omitted.

.EXAMPLE
    .\deploy.ps1 -Check

.EXAMPLE
    .\deploy.ps1 -Project my-gcp-project

.EXAMPLE
    .\deploy.ps1 -AutoApprove -Project my-gcp-project -Location eastus2

.EXAMPLE
    .\deploy.ps1 -Destroy -AutoApprove -Project my-gcp-project

.EXAMPLE
    .\deploy.ps1 -EnableExpressRoute -Project my-gcp-project
#>
[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$Destroy,
    [switch]$AutoApprove,
    [switch]$EnableExpressRoute,
    [string]$Subscription = '',
    [string]$Project      = '',
    [string]$Location     = '',
    [string]$Region       = '',
    [string]$Zone         = '',
    [string]$MachineType  = '',
    [string]$CallerIp     = '',
    [string]$VmUsername   = '',
    [securestring]$VmPassword
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- constants ---------------------------------------------------------------
# Scripts live in <repo>/scripts; terraform dirs are resolved from the repo root.
$ScriptRoot       = Split-Path -Parent $PSScriptRoot
$DefaultAzureRG   = 'lab-ervpn-coexist'
$AzureVpnConn     = 'Azure-to-OnpremGCP'
$GcpTunnel        = 'vpn-to-azure'
$AzureDir         = 'terraform/azure'
$GcpDir           = 'terraform/gcp'
$DefaultUsername  = 'azureuser'
$DefaultLocation  = 'centralus'
$DefaultRegion    = 'us-central1'
$DefaultMachineType = 'e2-micro'

# --- Megaport key polling tunables -------------------------------------------
# How long to wait between polls (seconds) and when to give up (seconds).
# 1800 s = 30 min; GCP VLAN attachments / Azure ER circuits can take 20+ min.
$KeyPollIntervalSec = 30
$KeyPollTimeoutSec  = 1800

# --- mutable script-scope state (functions read/write via $script:) ----------
$script:Project  = $Project
$script:CallerIp = $CallerIp
$script:Username = $VmUsername
$script:Location = $Location
$script:Region   = $Region
$script:Zone     = $Zone
$script:MachineType = $MachineType
$script:AzureRG  = ''

# --- output helpers ----------------------------------------------------------
function Write-Banner([string]$Text) {
    Write-Host ''
    Write-Host ('=' * 60) -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('=' * 60) -ForegroundColor Cyan
}
function Write-Step([string]$Text)  { Write-Host ''; Write-Host "---- $Text ----" -ForegroundColor Cyan }
function Write-Ok([string]$Text)    { Write-Host "  [ok]  $Text" -ForegroundColor Green }
function Write-Warn([string]$Text)  { Write-Host "  [!]   $Text" -ForegroundColor Yellow }
function Write-Fail([string]$Text)  {
    Write-Host "  [x]   ERROR: $Text" -ForegroundColor Red
    exit 1
}

function Test-Interactive {
    try { return ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) }
    catch { return $true }
}

function Test-PasswordComplexity {
    param([AllowEmptyString()][string]$Password)
    if ($null -eq $Password) { return $false }
    if ($Password.Length -lt 12 -or $Password.Length -gt 72) { return $false }
    $classes = 0
    if ($Password -match '[a-z]') { $classes++ }
    if ($Password -match '[A-Z]') { $classes++ }
    if ($Password -match '[0-9]') { $classes++ }
    if ($Password -match '[^a-zA-Z0-9]') { $classes++ }
    return ($classes -ge 3)
}

function Get-PasswordComplexityMessage {
    param([AllowEmptyString()][string]$Password)
    if ($null -eq $Password) { $Password = '' }
    $issues = @()
    $missing = @()
    if ($Password.Length -lt 12) { $issues += "too short ($($Password.Length)/12)" }
    if ($Password.Length -gt 72) { $issues += "too long ($($Password.Length)/72)" }
    if ($Password -notmatch '[a-z]') { $missing += 'lowercase' }
    if ($Password -notmatch '[A-Z]') { $missing += 'uppercase' }
    if ($Password -notmatch '[0-9]') { $missing += 'digit' }
    if ($Password -notmatch '[^a-zA-Z0-9]') { $missing += 'special' }
    if ($missing.Count -gt 1) {
        $issues += "needs at least 3 of 4 categories; missing: $($missing -join ', ')"
    }
    $message = 'Password must be 12-72 chars and include at least 3 of: lowercase, uppercase, digit, special'
    if ($issues.Count -gt 0) { $message += " ($($issues -join '; '))" }
    return "$message."
}

# --- terraform invocation wrapper --------------------------------------------
function Invoke-Tf {
    param(
        [string]   $Chdir,
        [string[]] $TfArgs
    )
    $allArgs = @("-chdir=$Chdir") + $TfArgs
    & terraform @allArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "terraform exited with code $LASTEXITCODE"
    }
}

# --- prerequisite validation -------------------------------------------------
function Test-Prereqs {
    Write-Banner 'PREREQUISITE CHECK'

    Write-Step 'Tool installations'

    if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
        Write-Fail @"
terraform not found.
  Windows: winget install Hashicorp.Terraform
  macOS:   brew install hashicorp/tap/terraform
  Linux:   https://developer.hashicorp.com/terraform/install
"@
    }
    $tfVerJson = & terraform version -json 2>$null
    $tfVer = ($tfVerJson | ConvertFrom-Json).terraform_version
    Write-Ok "terraform $tfVer"

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        Write-Fail @"
az CLI not found.
  Windows: winget install Microsoft.AzureCLI
  macOS:   brew install azure-cli
  Linux:   https://aka.ms/InstallAzureCLIDeb
"@
    }
    $azVerJson = & az version --output json 2>$null
    $azVer     = ($azVerJson | ConvertFrom-Json).'azure-cli'
    Write-Ok "az CLI $azVer"

    if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) {
        Write-Fail @"
gcloud not found.
  Windows: winget install Google.CloudSDK
  Others:  https://cloud.google.com/sdk/docs/install
"@
    }
    $gcloudVer = (& gcloud --version 2>$null)[0]
    Write-Ok $gcloudVer

    $azTfvars = Join-Path $AzureDir 'terraform.tfvars'
    if ((Test-Path $azTfvars) -and (Select-String -Path $azTfvars -Pattern '^\s*vm_admin_password\s*=' -Quiet)) {
        Write-Fail "terraform/azure/terraform.tfvars sets vm_admin_password, which OVERRIDES the secure password prompt (a terraform.tfvars value beats the TF_VAR_vm_admin_password environment variable). Comment out that line in terraform/azure/terraform.tfvars and re-run."
    }

    # -- Azure auth -----------------------------------------------------------
    Write-Step 'Azure authentication'

    if ($Subscription) {
        & az account set --subscription $Subscription 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "Could not set subscription '$Subscription'. Run: az login"
        }
    }
    $azAcctJson = & az account show --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $azAcctJson) {
        Write-Fail @"
Not logged in to Azure.
  Run: az login
  Then set subscription: az account set --subscription <NAME_OR_ID>
"@
    }
    $azAcct = $azAcctJson | ConvertFrom-Json
    Write-Ok "Azure subscription: $($azAcct.name) ($($azAcct.id))"

    # -- Confirm subscription (skip if -Subscription or -AutoApprove given) ---
    if (-not $Subscription -and -not $AutoApprove) {
        Write-Host ''
        Write-Host "This deployment will create resources in subscription:" -ForegroundColor Yellow
        Write-Host "  Name : $($azAcct.name)" -ForegroundColor Yellow
        Write-Host "  Id   : $($azAcct.id)" -ForegroundColor Yellow
        Write-Host "  Tenant: $($azAcct.tenantId)" -ForegroundColor Yellow
        Write-Host ''
        $reply = Read-Host 'Continue with this subscription? [Y]es / [n]o-pick-another / [q]uit'
        switch -Regex ($reply.Trim().ToLower()) {
            '^(n|no)$' {
                Write-Host ''
                Write-Host 'Available enabled subscriptions:' -ForegroundColor Cyan
                & az account list --query "[?state=='Enabled'].{Name:name,Id:id}" -o table
                Write-Host ''
                $pick = Read-Host 'Enter subscription NAME or ID to switch to'
                if (-not $pick) { Write-Fail 'No subscription provided. Aborting.' }
                & az account set --subscription $pick 2>$null
                if ($LASTEXITCODE -ne 0) { Write-Fail "Could not set subscription '$pick'." }
                $azAcct = (& az account show --output json) | ConvertFrom-Json
                Write-Ok "Switched to: $($azAcct.name) ($($azAcct.id))"
            }
            '^(q|quit)$' { Write-Fail 'Aborted by user.' }
            default { Write-Ok 'Subscription confirmed.' }
        }
    }

    # -- Standard public IP capability ----------------------------------------
    Write-Step 'Azure Standard public IP capability'

    if (-not $env:RUN_PIP_PRECHECK) {
        Write-Ok 'Standard public IP pre-check skipped (set RUN_PIP_PRECHECK=1 to enable)'
    } else {
        $pipRg = "tfpreflight-pip-$(Get-Random)"
        & az group create -n $pipRg -l eastus --output none 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Fail 'Could not create a test resource group in eastus. Ensure this account has Contributor on the subscription to deploy the lab.'
        }
        $probeOut = & az network public-ip create -g $pipRg -n probe-std --sku Standard --allocation-method Static -l eastus 2>&1
        $probeRc  = $LASTEXITCODE
        & az group delete -n $pipRg --yes --no-wait --output none 2>$null
        if ($probeRc -eq 0) {
            Write-Ok 'Standard public IP allocation: available'
        } elseif ($probeOut -match 'AllowBringYourOwnPublicIpAddress|SubscriptionNotRegisteredForFeature') {
            Write-Fail @"
This subscription gates allocation of ALL Standard SKU public IPs behind the
Microsoft.Network/AllowBringYourOwnPublicIpAddress feature.

Despite its name, this is NOT "bring your own IP". Registering it simply unlocks
normal Azure-allocated Standard public IPs, which this lab requires:
  - Active-active + BGP VPN gateways support ONLY Standard public IPs.
  - Basic SKU public IPs were retired on 2025-09-30.

Fix it once on this subscription (then re-run this script):
  az feature register --namespace Microsoft.Network --name AllowBringYourOwnPublicIpAddress
  az feature show --namespace Microsoft.Network --name AllowBringYourOwnPublicIpAddress --query properties.state -o tsv   # wait until: Registered
  az provider register --namespace Microsoft.Network

Or deploy on a subscription that is not restricted (Standard public IPs work with no setup).
"@
        } else {
            Write-Fail "Could not create a test Standard public IP (unexpected error): $probeOut"
        }
    }

    # -- GCP auth -------------------------------------------------------------
    Write-Step 'GCP authentication'

    if ($script:Project) {
        & gcloud config set project $script:Project --quiet 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "Could not set GCP project '$($script:Project)'."
        }
    }

    $activeAcct = (& gcloud auth list --filter='status:ACTIVE' --format='value(account)' 2>$null) -join ''
    if (-not $activeAcct) {
        Write-Fail "No active GCP account.`n  Run: gcloud auth login"
    }
    Write-Ok "GCP account: $activeAcct"

    # Application Default Credentials
    & gcloud auth application-default print-access-token 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Fail @"
GCP Application Default Credentials not set.
  Run: gcloud auth application-default login
"@
    }
    Write-Ok 'GCP Application Default Credentials: present'

    # GCP project
    $gcpProj = ((& gcloud config get-value project 2>$null) -join '').Trim()
    if (-not $gcpProj -or $gcpProj -eq '(unset)') {
        Write-Fail "No GCP project configured.`n  Run: gcloud config set project <PROJECT_ID>"
    }
    if (-not $script:Project) { $script:Project = $gcpProj }
    Write-Ok "GCP project: $($script:Project)"

    # -- Public IP ------------------------------------------------------------
    Write-Step 'Public IP detection (GCP SSH firewall)'

    if (-not $script:CallerIp) {
        try {
            $script:CallerIp = (Invoke-RestMethod -Uri 'https://ifconfig.io' -TimeoutSec 5).Trim()
        }
        catch {
            try {
                $script:CallerIp = (Invoke-WebRequest -Uri 'https://api.ipify.org' `
                    -UseBasicParsing -TimeoutSec 5).Content.Trim()
            }
            catch {
                Write-Fail "Could not auto-detect public IP.`n  Override with: -CallerIp <YOUR_IP>"
            }
        }
    }
    if ($script:CallerIp -notmatch '^\d+\.\d+\.\d+\.\d+$') {
        Write-Fail "Invalid IPv4 address: '$($script:CallerIp)'. Use -CallerIp to override."
    }
    Write-Ok "Public IP: $($script:CallerIp)  (used only for GCP caller_source_ip)"

    Write-Host ''
    Write-Ok 'All prerequisite checks passed.'
}

# --- collect required inputs (region / zone / username / password) -----------
function Get-RequiredInputs {
    Write-Banner 'DEPLOYMENT SETTINGS  (press Enter to accept the [default])'
    $interactive = Test-Interactive

    # VM admin username
    if (-not $script:Username) {
        if ($interactive) {
            $in = Read-Host "  VM admin username [$DefaultUsername]"
            $script:Username = if ($in) { $in } else { $DefaultUsername }
        }
        else { $script:Username = $DefaultUsername }
    }

    # Azure location
    if (-not $script:Location) {
        if ($interactive) {
            $in = Read-Host "  Azure region / location [$DefaultLocation]"
            $script:Location = if ($in) { $in } else { $DefaultLocation }
        }
        else { $script:Location = $DefaultLocation }
    }

    # GCP region
    if (-not $script:Region) {
        if ($interactive) {
            $in = Read-Host "  GCP region [$DefaultRegion]"
            $script:Region = if ($in) { $in } else { $DefaultRegion }
        }
        else { $script:Region = $DefaultRegion }
    }

    # GCP zone (derived default <region>-c, changeable)
    if (-not $script:Zone) {
        $zdefault = "$($script:Region)-c"
        if ($interactive) {
            $in = Read-Host "  GCP zone [$zdefault]"
            $script:Zone = if ($in) { $in } else { $zdefault }
        }
        else { $script:Zone = $zdefault }
    }

    # Azure resource group
    if (-not $script:AzureRG) {
        if ($interactive) {
            $in = Read-Host "  Azure resource group [$DefaultAzureRG]"
            $script:AzureRG = if ($in) { $in } else { $DefaultAzureRG }
        }
        else { $script:AzureRG = $DefaultAzureRG }
    }

    if (-not $script:MachineType) { $script:MachineType = $DefaultMachineType }

    Write-Ok "VM admin username: $($script:Username)"
    Write-Ok "Azure location:    $($script:Location)"
    Write-Ok "GCP region / zone: $($script:Region) / $($script:Zone)"
    Write-Ok "GCP machine type:  $($script:MachineType)"
    Write-Ok "Azure resource group: $($script:AzureRG)"

    # -- GCP machine type availability ----------------------------------------
    # Verifies the requested machine_type is OFFERED in the chosen zone.
    # Capacity (stockouts) cannot be predicted; we list other zones in the
    # region that offer this SKU so the user can re-run with -Zone if needed.
    Write-Step "GCP machine type availability ($($script:MachineType) in $($script:Zone))"
    & gcloud compute machine-types describe $script:MachineType `
        --zone $script:Zone `
        --project $script:Project `
        --format='value(name)' 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $altZones = (& gcloud compute machine-types list `
            --filter="name=$($script:MachineType) AND zone~^$($script:Region)-" `
            --project $script:Project `
            --format='value(zone)' 2>$null) -join ' '
        Write-Fail @"
Machine type '$($script:MachineType)' is NOT offered in zone '$($script:Zone)'.
Zones in '$($script:Region)' that offer it: $(if ($altZones) { $altZones } else { '(none found)' })
Re-run with: -Zone <alt-zone>  or  -MachineType <other-sku>
"@
    }
    $altZones = (& gcloud compute machine-types list `
        --filter="name=$($script:MachineType) AND zone~^$($script:Region)-" `
        --project $script:Project `
        --format='value(zone)' 2>$null) -join ' '
    Write-Ok "Offered in $($script:Zone). Other zones in $($script:Region) with this SKU: $altZones"
    Write-Warn 'Note: GCP cannot pre-check capacity. If apply fails with "does not have enough resources", re-run with -Zone <alt> from above.'

    # VM admin password - stored in TF_VAR_vm_admin_password env var so Terraform
    # reads it automatically and it never appears on a command line.
    if ($env:TF_VAR_vm_admin_password) {
        # Already provided via environment (CI / non-interactive) - leave as-is.
        if (-not (Test-PasswordComplexity -Password $env:TF_VAR_vm_admin_password)) {
            Write-Fail 'Password must be 12-72 chars and include at least 3 of: lowercase, uppercase, digit, special.'
        }
        return
    }

    if ($null -ne $VmPassword) {
        $bstr  = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($VmPassword)
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        if (-not (Test-PasswordComplexity -Password $plain)) {
            $plain = $null
            Write-Fail 'Password must be 12-72 chars and include at least 3 of: lowercase, uppercase, digit, special.'
        }
        $env:TF_VAR_vm_admin_password = $plain
        $plain = $null
        return
    }

    if (-not $interactive) {
        Write-Fail 'No password supplied. For non-interactive runs set $env:TF_VAR_vm_admin_password or pass -VmPassword.'
    }

    while ($true) {
        $secPwd = Read-Host '  VM admin password (12-72 chars, at least 3 of: upper, lower, digit, special)' -AsSecureString
        $bstr   = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPwd)
        $plain  = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        if (-not (Test-PasswordComplexity -Password $plain)) {
            Write-Warn (Get-PasswordComplexityMessage -Password $plain)
            $plain = $null
            continue
        }

        $secConfirm = Read-Host '  Confirm VM admin password' -AsSecureString
        $bstrConfirm = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secConfirm)
        $confirm = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstrConfirm)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstrConfirm)
        if ($plain -ne $confirm) {
            Write-Warn 'Passwords do not match - try again.'
            $plain = $null
            $confirm = $null
            continue
        }
        $confirm = $null
        break
    }
    $env:TF_VAR_vm_admin_password = $plain
    $plain = $null
}

# --- VPN verification --------------------------------------------------------
function Invoke-VpnVerify {
    Write-Banner 'VPN VERIFICATION'

    Write-Step 'Azure - VPN connection status'
    $connStatus = & az network vpn-connection show `
        --name $AzureVpnConn `
        --resource-group $script:AzureRG `
        --query connectionStatus `
        --output tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and $connStatus) {
        Write-Ok "Azure connection status: $connStatus"
    }
    else {
        Write-Warn 'Could not query Azure VPN connection (may not have converged yet).'
    }

    Write-Step 'GCP - VPN tunnel status'
    $tunnelStatus = & gcloud compute vpn-tunnels describe $GcpTunnel `
        --region $script:Region `
        --format='value(status,detailedStatus)' 2>$null
    if ($LASTEXITCODE -eq 0 -and $tunnelStatus) {
        Write-Ok "GCP tunnel status: $tunnelStatus"
    }
    else {
        Write-Warn 'Could not query GCP VPN tunnel (may not have converged yet).'
    }

    Write-Step 'SSH into GCP VM'
    Write-Ok "Command: gcloud compute ssh vpnlab-vm1 --zone $($script:Zone)"
    Write-Ok "  (If envname was changed from default, use: gcloud compute ssh <envname>-vm1 --zone $($script:Zone))"
    Write-Ok '  First SSH generates an SSH key pair and may prompt for a passphrase - this is normal.'
    Write-Ok "  To force Cloud IAP tunnel: gcloud compute ssh vpnlab-vm1 --zone $($script:Zone) --tunnel-through-iap"

    Write-Step 'Azure VMs (no public IP) - use Serial Console'
    Write-Ok "  az serialconsole connect --name Az-Hub-lxvm --resource-group $script:AzureRG"
    Write-Ok '  (or Azure portal > VM > Help > Serial console). Sign in with the VM admin credentials.'
}

# --- deploy ------------------------------------------------------------------
function Invoke-Deploy {
    Write-Banner 'DEPLOY - 3-APPLY ORDER'
    Set-Location $ScriptRoot

    $tfAutoApprove = if ($AutoApprove) { @('-auto-approve') } else { @() }

    # -- Step 1: Azure base ---------------------------------------------------
    Write-Step 'Step 1 - Azure base (VPN gateway + ExpressRoute gateway)'
    Write-Warn 'Azure gateway provisioning takes ~30-45 minutes on first apply.'
    Write-Warn "Terraform will appear to 'hang' on azurerm_virtual_network_gateway - this is NORMAL."
    Write-Warn 'Do NOT cancel. Monitor in the Azure portal: Virtual network gateways.'
    Write-Host ''

    Invoke-Tf -Chdir $AzureDir -TfArgs @('init', '-input=false')

    # Preserve the VPN on re-runs. A fresh deploy has no GCP side yet, so the
    # on-prem VPN connection cannot exist in Step 1 (it needs GCP's public IP
    # from remote state) and must be disabled here. But on a re-run (e.g. adding
    # ExpressRoute) GCP is already deployed, so forcing enable_onprem_connection
    # =false would DESTROY the existing VPN connection + Local Network Gateway.
    # Detect a prior GCP deployment by the presence of its state file (a
    # lock-free check that is safe even when OneDrive locks terraform.tfstate)
    # and keep the connection in place.
    $step1Onprem = 'false'
    if (Test-Path (Join-Path $GcpDir 'terraform.tfstate')) {
        $step1Onprem = 'true'
        Write-Ok 'Existing GCP deployment detected - keeping the VPN connection in place.'
    }

    Invoke-Tf -Chdir $AzureDir -TfArgs (@(
        'apply', '-input=false',
        "-var=location=$($script:Location)",
        "-var=vm_admin_username=$($script:Username)",
        "-var=resource_group_name=$($script:AzureRG)",
        "-var=enable_onprem_connection=$step1Onprem"
    ) + $tfAutoApprove)

    # -- Step 2: GCP ----------------------------------------------------------
    Write-Step 'Step 2 - GCP (Classic VPN gateway + tunnel + firewall + VM)'
    # TF_VAR_vm_admin_password in env is ignored by the GCP google provider - harmless.
    Invoke-Tf -Chdir $GcpDir -TfArgs @('init', '-input=false')
    Invoke-Tf -Chdir $GcpDir -TfArgs (@(
        'apply', '-input=false',
        "-var=project=$($script:Project)",
        "-var=region=$($script:Region)",
        "-var=zone=$($script:Zone)",
        "-var=machine_type=$($script:MachineType)",
        "-var=caller_source_ip=$($script:CallerIp)"
    ) + $tfAutoApprove)

    # -- Step 3: Azure connection ---------------------------------------------
    Write-Step 'Step 3 - Azure connection (Local Network Gateway + VPN connection)'
    Invoke-Tf -Chdir $AzureDir -TfArgs (@(
        'apply', '-input=false',
        "-var=location=$($script:Location)",
        "-var=vm_admin_username=$($script:Username)",
        "-var=resource_group_name=$($script:AzureRG)",
        '-var=enable_onprem_connection=true'
    ) + $tfAutoApprove)

    Invoke-VpnVerify

    if ($EnableExpressRoute) {
        Invoke-ExpressRoute
    }

    Write-Banner 'DEPLOYMENT COMPLETE'
    Write-Ok 'Site-to-Site VPN deployment finished. See verification output above.'
    Write-Ok 'Re-run with -EnableExpressRoute when ready to add the ExpressRoute/Interconnect path.'
}

# --- optional ExpressRoute / Partner Interconnect stage ----------------------
function Invoke-ExpressRoute {
    Write-Banner 'EXPRESSROUTE / INTERCONNECT STAGE  (OPTIONAL - BILLABLE)'
    Write-Warn 'Billable resources: ExpressRoute circuit, Cloud Router, Partner Interconnect VLAN attachment.'
    Write-Host ''

    $tfAutoApprove = if ($AutoApprove) { @('-auto-approve') } else { @() }

    Write-Step 'Step 4a - GCP: Cloud Router + Partner Interconnect VLAN attachment'
    Invoke-Tf -Chdir $GcpDir -TfArgs (@(
        'apply', '-input=false',
        "-var=project=$($script:Project)",
        "-var=region=$($script:Region)",
        "-var=zone=$($script:Zone)",
        "-var=machine_type=$($script:MachineType)",
        "-var=caller_source_ip=$($script:CallerIp)",
        '-var=enable_interconnect=true'
    ) + $tfAutoApprove)

    Write-Step 'Step 4b - Azure: ExpressRoute circuit (gateway connection deferred)'
    # Create the circuit ONLY (enable_er_connection=false). The ER gateway
    # connection is attached later, and only once the provider (Megaport) has
    # provisioned the circuit. Attaching to a circuit that is not yet
    # 'Provisioned' on the provider side fails, so we gate it on the circuit's
    # serviceProviderProvisioningState below.
    Invoke-Tf -Chdir $AzureDir -TfArgs (@(
        'apply', '-input=false',
        "-var=location=$($script:Location)",
        "-var=vm_admin_username=$($script:Username)",
        "-var=resource_group_name=$($script:AzureRG)",
        '-var=enable_onprem_connection=true',
        '-var=enable_expressroute=true',
        '-var=enable_er_connection=false'
    ) + $tfAutoApprove)

    Write-Step 'Step 4c - Wait for Megaport keys (GCP pairing key + Azure service key)'
    Write-Host "  Polling every ${KeyPollIntervalSec}s, timeout ${KeyPollTimeoutSec}s (~$([int]($KeyPollTimeoutSec/60)) min)." -ForegroundColor Cyan
    Write-Host "  Press Ctrl-C at any time to abort (keys will not be displayed)." -ForegroundColor Cyan
    Write-Host ''

    $pairingKey    = ''
    $serviceKey    = ''
    $pollStart     = [System.Diagnostics.Stopwatch]::StartNew()
    $lastLockWarn  = $false

    while ($true) {
        # Try GCP pairing key if not yet captured. Capture stderr so we can
        # distinguish "still provisioning" from "OneDrive state lock" (the
        # latter is a transient OS-level file lock on terraform.tfstate).
        if ([string]::IsNullOrWhiteSpace($pairingKey)) {
            $gcpErr = $null
            $k = (& terraform -chdir=$GcpDir output -raw interconnect_pairing_key 2>&1) -join "`n"
            if ($LASTEXITCODE -eq 0 -and $k -and -not ($k -match 'Error:|locked')) {
                $pairingKey = $k.Trim()
                Write-Ok "GCP pairing key captured."
            }
            elseif ($k -match 'locked|Failed to read state') { $gcpErr = $k }
        }

        # Try Azure service key if not yet captured.
        if ([string]::IsNullOrWhiteSpace($serviceKey)) {
            $azErr = $null
            $k = (& terraform -chdir=$AzureDir output -raw expressroute_service_key 2>&1) -join "`n"
            if ($LASTEXITCODE -eq 0 -and $k -and -not ($k -match 'Error:|locked')) {
                $serviceKey = $k.Trim()
                Write-Ok "Azure service key captured."
            }
            elseif ($k -match 'locked|Failed to read state') { $azErr = $k }
        }

        # Both keys in hand -> exit polling loop.
        if (-not [string]::IsNullOrWhiteSpace($pairingKey) -and `
            -not [string]::IsNullOrWhiteSpace($serviceKey)) {
            break
        }

        # Check timeout.
        $elapsed = [int]$pollStart.Elapsed.TotalSeconds
        if ($elapsed -ge $KeyPollTimeoutSec) {
            Write-Warn "Key polling timed out after ${elapsed}s."
            break
        }

        # Report which keys are still pending; flag transient state locks once.
        $pending = @()
        if ([string]::IsNullOrWhiteSpace($pairingKey)) { $pending += 'GCP pairing key' }
        if ([string]::IsNullOrWhiteSpace($serviceKey))  { $pending += 'Azure service key' }
        $lockNow = ($gcpErr -or $azErr)
        if ($lockNow -and -not $lastLockWarn) {
            Write-Warn 'terraform state file is locked (likely OneDrive sync). Polling will retry; you can also read the keys directly:'
            Write-Warn '  terraform -chdir=terraform/gcp   output -raw interconnect_pairing_key'
            Write-Warn '  terraform -chdir=terraform/azure output -raw expressroute_service_key'
        }
        $lastLockWarn = [bool]$lockNow

        Write-Host "  [${elapsed}s elapsed]  Still waiting for: $($pending -join ', ') $(if ($lockNow) { '(state locked, retrying)' }) ..." -ForegroundColor Yellow

        Start-Sleep -Seconds $KeyPollIntervalSec
    }

    Write-Host ''
    if (-not [string]::IsNullOrWhiteSpace($pairingKey)) {
        Write-Host "  GCP Partner Interconnect pairing key  ->  paste into Megaport 'Google Cloud' VXC:" `
            -ForegroundColor Cyan
        Write-Host "    $pairingKey"
    } else {
        Write-Warn 'GCP pairing key not available - the VLAN attachment may still be provisioning.'
    }
    Write-Host ''

    if (-not [string]::IsNullOrWhiteSpace($serviceKey)) {
        Write-Host "  Azure ExpressRoute service key  ->  paste into Megaport 'Azure ExpressRoute' VXC:" `
            -ForegroundColor Cyan
        Write-Host "    $serviceKey"
    } else {
        Write-Warn 'Azure service key not available - the ER circuit may still be provisioning.'
    }
    Write-Host ''

    # -- Gate the ER gateway connection on the circuit's PROVIDER provisioning state.
    Write-Step 'Step 4d - Check ExpressRoute circuit provisioning state (provider side)'
    $circuitState = (& az network express-route show `
            --resource-group $script:AzureRG `
            --name 'az-hub-er-circuit' `
            --query 'serviceProviderProvisioningState' `
            --output tsv 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($circuitState)) {
        $circuitState = 'Unknown'
    }
    Write-Host "  Circuit 'az-hub-er-circuit' provider provisioning state: $circuitState"
    Write-Host ''

    if ($circuitState -eq 'Provisioned') {
        Write-Ok 'Circuit is Provisioned at the provider - attaching the ER gateway connection.'
        Write-Step 'Step 4e - Azure: attach ER circuit to the ExpressRoute gateway'
        Invoke-Tf -Chdir $AzureDir -TfArgs (@(
            'apply', '-input=false',
            "-var=location=$($script:Location)",
            "-var=vm_admin_username=$($script:Username)",
            "-var=resource_group_name=$($script:AzureRG)",
            '-var=enable_onprem_connection=true',
            '-var=enable_expressroute=true',
            '-var=enable_er_connection=true'
        ) + $tfAutoApprove)

        Write-Banner 'EXPRESSROUTE STAGE COMPLETE'
        Write-Ok "Circuit Provisioned and gateway connection 'ER-Connection-to-Onprem' created."
        Write-Ok 'VPN and ExpressRoute now coexist. Inspect routes with: .\dump-routes-azure.ps1'
        Remove-Item Env:TF_VAR_vm_admin_password -ErrorAction SilentlyContinue
        return
    }

    # Circuit not yet provisioned by the provider -> stop and instruct the user.
    Write-Warn ('=' * 64)
    Write-Warn '  ACTION REQUIRED - PROVISION THE EXPRESSROUTE CIRCUIT WITH YOUR PROVIDER'
    Write-Warn ('=' * 64)
    Write-Warn "The circuit 'az-hub-er-circuit' is NOT 'Provisioned' yet (state: $circuitState)."
    Write-Warn 'The ER gateway connection was deliberately NOT created, because attaching'
    Write-Warn 'to a circuit the provider has not provisioned fails.'
    Write-Host ''
    Write-Warn 'Provision the circuit with your provider using the keys displayed above:'
    Write-Warn '1. Log in to https://portal.megaport.com'
    Write-Warn '2. Create a VXC to Google Cloud  ->  paste the GCP pairing key above.'
    Write-Warn '3. Create a VXC to Azure ExpressRoute  ->  paste the Azure service key above.'
    Write-Warn "4. Wait for BOTH VXCs to show 'Active' in Megaport AND for the circuit"
    Write-Warn "   'az-hub-er-circuit' to show serviceProviderProvisioningState='Provisioned'."
    Write-Warn '   Check it any time with:'
    Write-Warn "       az network express-route show -g $script:AzureRG -n az-hub-er-circuit --query serviceProviderProvisioningState -o tsv"
    Write-Warn '5. Once the circuit is Provisioned, re-run this script with -EnableExpressRoute.'
    Write-Warn '   It will detect the Provisioned state and attach the connection automatically:'
    Write-Warn '       .\deploy.ps1 -EnableExpressRoute [same options as before]'
    Write-Host ''
    Write-Ok 'Stopping here intentionally - the gateway connection will be created on the next run once provisioned.'

    Remove-Item Env:TF_VAR_vm_admin_password -ErrorAction SilentlyContinue
    exit 0
}

# --- destroy -----------------------------------------------------------------
function Invoke-TfDestroy {
    Write-Banner 'DESTROY - REVERSE ORDER  (Azure first, then GCP)'
    Write-Warn 'This permanently destroys ALL lab resources in this deployment.'
    Set-Location $ScriptRoot

    $tfAutoApprove = if ($AutoApprove) { @('-auto-approve') } else { @() }

    Write-Step '1 - Destroy Azure resources (connections, gateways, VMs, VNets, NSGs)'
    # Pass enable_onprem_connection=true so Terraform can plan the LNG + VPN connection
    # teardown while the GCP state file still exists (remote_state data source resolves).
    Write-Warn 'Azure must be destroyed first - LNG and VPN connection reference GCP state.'
    # enable_expressroute/enable_er_connection forced true so an in-state ER connection is
    # torn down BEFORE the always-present ER gateway (destroy never creates missing resources).
    Invoke-Tf -Chdir $AzureDir -TfArgs (@(
        'destroy', '-input=false',
        "-var=location=$($script:Location)",
        "-var=vm_admin_username=$($script:Username)",
        "-var=resource_group_name=$($script:AzureRG)",
        '-var=enable_onprem_connection=true',
        '-var=enable_expressroute=true',
        '-var=enable_er_connection=true'
    ) + $tfAutoApprove)

    Write-Step '2 - Destroy GCP resources (VPN tunnel, VM, VPC, firewall)'
    Invoke-Tf -Chdir $GcpDir -TfArgs (@(
        'destroy', '-input=false',
        "-var=project=$($script:Project)",
        "-var=region=$($script:Region)",
        "-var=zone=$($script:Zone)",
        "-var=machine_type=$($script:MachineType)",
        "-var=caller_source_ip=$($script:CallerIp)"
    ) + $tfAutoApprove)

    Write-Banner 'DESTROY COMPLETE'
    Write-Ok 'All lab resources removed.'
    Write-Warn 'If ExpressRoute (Step 4) was deployed, cancel Megaport VXCs at https://portal.megaport.com.'
}

# --- main --------------------------------------------------------------------
if ($Check -and $Destroy) {
    Write-Fail 'Cannot use -Check and -Destroy together. Choose one subcommand.'
}

Test-Prereqs

if ($Check) {
    # Prerequisites already validated; nothing more to do.
    exit 0
}

Get-RequiredInputs

try {
    if ($Destroy) {
        Invoke-TfDestroy
    }
    else {
        Invoke-Deploy
    }
}
finally {
    # Always remove the secret from the environment, even on error.
    Remove-Item Env:TF_VAR_vm_admin_password -ErrorAction SilentlyContinue
}
