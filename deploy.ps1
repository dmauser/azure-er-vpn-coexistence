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
    [string]$CallerIp     = '',
    [string]$VmUsername   = '',
    [securestring]$VmPassword
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- constants ---------------------------------------------------------------
$ScriptRoot       = $PSScriptRoot
$AzureRG          = 'lab-er-vpn-coexistence'
$AzureVpnConn     = 'Azure-to-OnpremGCP'
$GcpTunnel        = 'vpn-to-azure'
$AzureDir         = 'terraform/azure'
$GcpDir           = 'terraform/gcp'
$DefaultUsername  = 'azureuser'
$DefaultLocation  = 'centralus'
$DefaultRegion    = 'us-central1'

# --- mutable script-scope state (functions read/write via $script:) ----------
$script:Project  = $Project
$script:CallerIp = $CallerIp
$script:Username = $VmUsername
$script:Location = $Location
$script:Region   = $Region
$script:Zone     = $Zone

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

    Write-Ok "VM admin username: $($script:Username)"
    Write-Ok "Azure location:    $($script:Location)"
    Write-Ok "GCP region / zone: $($script:Region) / $($script:Zone)"

    # VM admin password - stored in TF_VAR_vm_admin_password env var so Terraform
    # reads it automatically and it never appears on a command line.
    if ($env:TF_VAR_vm_admin_password) {
        # Already provided via environment (CI / non-interactive) - leave as-is.
        return
    }

    if ($null -ne $VmPassword) {
        $bstr  = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($VmPassword)
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        if ($plain.Length -lt 12) { Write-Fail 'Password must be at least 12 characters.' }
        $env:TF_VAR_vm_admin_password = $plain
        $plain = $null
        return
    }

    if (-not $interactive) {
        Write-Fail 'No password supplied. For non-interactive runs set $env:TF_VAR_vm_admin_password or pass -VmPassword.'
    }

    do {
        $secPwd = Read-Host '  VM admin password (min 12 chars, upper+lower+digit+special)' -AsSecureString
        $bstr   = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPwd)
        $plain  = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        if ($plain.Length -lt 12) {
            Write-Warn "Password is $($plain.Length) chars - Azure requires at least 12."
            $plain = $null
        }
    } while (-not $plain -or $plain.Length -lt 12)
    $env:TF_VAR_vm_admin_password = $plain
    $plain = $null
}

# --- VPN verification --------------------------------------------------------
function Invoke-VpnVerify {
    Write-Banner 'VPN VERIFICATION'

    Write-Step 'Azure - VPN connection status'
    $connStatus = & az network vpn-connection show `
        --name $AzureVpnConn `
        --resource-group $AzureRG `
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
    Write-Ok "  az serialconsole connect --name Az-Hub-lxvm --resource-group $AzureRG"
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
    Invoke-Tf -Chdir $AzureDir -TfArgs (@(
        'apply', '-input=false',
        "-var=location=$($script:Location)",
        "-var=vm_admin_username=$($script:Username)",
        '-var=enable_onprem_connection=false'
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
        "-var=caller_source_ip=$($script:CallerIp)"
    ) + $tfAutoApprove)

    # -- Step 3: Azure connection ---------------------------------------------
    Write-Step 'Step 3 - Azure connection (Local Network Gateway + VPN connection)'
    Invoke-Tf -Chdir $AzureDir -TfArgs (@(
        'apply', '-input=false',
        "-var=location=$($script:Location)",
        "-var=vm_admin_username=$($script:Username)",
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
        "-var=caller_source_ip=$($script:CallerIp)",
        '-var=enable_interconnect=true'
    ) + $tfAutoApprove)

    Write-Step 'Step 4b - Azure: ExpressRoute circuit + ER gateway connection'
    # enable_expressroute=true creates az-hub-er-circuit AND the ER gateway connection.
    # If the circuit is not yet Provisioned (Megaport VXC not active), the gateway
    # connection may remain non-functional until Megaport activates. Re-run with
    # -EnableExpressRoute after the circuit reaches 'Provisioned' to retry attachment.
    Invoke-Tf -Chdir $AzureDir -TfArgs (@(
        'apply', '-input=false',
        "-var=location=$($script:Location)",
        "-var=vm_admin_username=$($script:Username)",
        '-var=enable_onprem_connection=true',
        '-var=enable_expressroute=true'
    ) + $tfAutoApprove)

    Write-Step 'Step 4c - Retrieve pairing keys for Megaport'
    Write-Host ''
    Write-Host "  GCP Partner Interconnect pairing key  ->  paste into Megaport 'Google Cloud' VXC:" `
        -ForegroundColor Cyan
    & terraform -chdir=$GcpDir output -raw interconnect_pairing_key 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Warn 'Pairing key not yet available - the VLAN attachment may still be provisioning.'
    }
    Write-Host ''

    Write-Host "  Azure ExpressRoute service key  ->  paste into Megaport 'Azure ExpressRoute' VXC:" `
        -ForegroundColor Cyan
    & terraform -chdir=$AzureDir output -raw expressroute_service_key 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Warn 'Service key not yet available.'
    }
    Write-Host ''

    Write-Warn ('=' * 60)
    Write-Warn '  STOP - MANUAL MEGAPORT ACTION REQUIRED BEFORE CONTINUING'
    Write-Warn ('=' * 60)
    Write-Warn '1. Log in to https://portal.megaport.com'
    Write-Warn '2. Create a VXC to Google Cloud  ->  paste the GCP pairing key above.'
    Write-Warn '3. Create a VXC to Azure ExpressRoute  ->  paste the Azure service key above.'
    Write-Warn "4. Wait for BOTH VXCs to show 'Active' in Megaport AND for the Azure ER"
    Write-Warn "   circuit 'az-hub-er-circuit' to show 'Provisioned' in the Azure portal."
    Write-Warn '5. Once the circuit is Provisioned, re-run this script with -EnableExpressRoute'
    Write-Warn '   to attach the ER circuit to the ER gateway (the apply is idempotent):'
    Write-Warn '       .\deploy.ps1 -EnableExpressRoute [same options as before]'
    Write-Host ''
    Write-Ok 'Script stopping here intentionally. Save the keys above - you need them in Megaport.'

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
    Invoke-Tf -Chdir $AzureDir -TfArgs (@(
        'destroy', '-input=false',
        "-var=location=$($script:Location)",
        "-var=vm_admin_username=$($script:Username)",
        '-var=enable_onprem_connection=true'
    ) + $tfAutoApprove)

    Write-Step '2 - Destroy GCP resources (VPN tunnel, VM, VPC, firewall)'
    Invoke-Tf -Chdir $GcpDir -TfArgs (@(
        'destroy', '-input=false',
        "-var=project=$($script:Project)",
        "-var=region=$($script:Region)",
        "-var=zone=$($script:Zone)",
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
