# Adds a SECOND on-premises GCP site (vpnsite2) connected to the same Azure Hub VPN Gateway.
# Bash/Linux equivalent: vpnsite2.azcli
#
# PREREQUISITE: run deploy.ps1 first in the SAME PowerShell session. This script reuses the
# variables $rg (resource group) and $sharedkey (S2S shared key) defined there.
# If running in a new shell, set them first:
#   $rg = "lab-er-vpn-coexistence"
#   $sharedkey = "<the same key generated/used by deploy.ps1>"

# ===== Prerequisite check (run this first) =====
function Test-Prereqs {
  $ok = $true
  foreach ($tool in 'az','gcloud') {
    if (Get-Command $tool -ErrorAction SilentlyContinue) { Write-Host "OK  : $tool found" }
    else { Write-Host "FAIL: $tool not found in PATH" -ForegroundColor Red; $ok = $false }
  }
  if (az account show 2>$null) {
    Write-Host "OK  : Azure subscription -> $(az account show --query name -o tsv) ($(az account show --query id -o tsv))"
  } else {
    Write-Host "FAIL: not logged in to Azure. Run: az login" -ForegroundColor Red; $ok = $false
  }
  $gcpAccount = gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>$null
  if ($gcpAccount) { Write-Host "OK  : gcloud account -> $gcpAccount" }
  else { Write-Host "FAIL: no active gcloud account. Run: gcloud auth login" -ForegroundColor Red; $ok = $false }
  if ($rg) { Write-Host "OK  : `$rg = $rg" }
  else { Write-Host "FAIL: `$rg not set. Run deploy.ps1 first, or set: `$rg = 'lab-er-vpn-coexistence'" -ForegroundColor Red; $ok = $false }
  if ($sharedkey) { Write-Host "OK  : `$sharedkey is set" }
  else { Write-Host "FAIL: `$sharedkey not set. Reuse the key from deploy.ps1." -ForegroundColor Red; $ok = $false }
  if (-not $ok) { Write-Host ">>> Prerequisites NOT met. Fix the FAIL items above before continuing." -ForegroundColor Red; return $false }
  Write-Host ">>> All prerequisites satisfied." -ForegroundColor Green
  return $true
}
Test-Prereqs
# ===============================================

# Define GCP variables (Mandatory: Define your GCP project)
$region = "us-central1"   # (OPTIONAL) Set your region. List zones: gcloud compute zones list
$zone = "$region-c"       # Set availability zone: a, b or c.
$vpcrange = "192.168.100.0/24"
$envname = "vpnsite2"
$vmname = "vm1"
$mypip = (Invoke-RestMethod -Uri "https://api.ipify.org").Trim()
$project = Read-Host "Enter your GCP Project ID"

#Set default project
gcloud config set project $project

#Create VPC
gcloud compute networks create $envname-vpc --subnet-mode=custom --mtu=1460 --bgp-routing-mode=regional
gcloud compute networks subnets create $envname-subnet --range=$vpcrange --network=$envname-vpc --region=$region

#Create Firewall Rule
gcloud compute firewall-rules create $envname-allow-traffic-from-azure --network $envname-vpc --allow tcp,udp,icmp --source-ranges "192.168.0.0/16,10.0.0.0/8,172.16.0.0/12,35.235.240.0/20,$mypip/32"

#Create Ubuntu VM:
gcloud compute instances create $envname-vm1 --zone=$zone --machine-type=e2-micro --network-interface=subnet=$envname-subnet,network-tier=PREMIUM --image-family=ubuntu-2204-lts --image-project=ubuntu-os-cloud --boot-disk-size=10GB --boot-disk-type=pd-balanced --boot-disk-device-name=$envname-vm1

# *** Setup VPN tunnels ***
# GCP side
#GCP VPN
gcloud compute target-vpn-gateways create $envname-vpn --region=$region --network=$envname-vpc
gcloud compute addresses create $envname-vpn-pip --region=$region
$gcpvpnpip = gcloud compute addresses describe $envname-vpn-pip --region=$region --format='value(address)'
gcloud compute forwarding-rules create $envname-vpn-rule-esp --region=$region --address=$gcpvpnpip --ip-protocol=ESP --target-vpn-gateway=$envname-vpn
gcloud compute forwarding-rules create $envname-vpn-rule-udp500 --region=$region --address=$gcpvpnpip --ip-protocol=UDP --ports=500 --target-vpn-gateway=$envname-vpn
gcloud compute forwarding-rules create $envname-vpn-rule-udp4500 --region=$region --address=$gcpvpnpip --ip-protocol=UDP --ports=4500 --target-vpn-gateway=$envname-vpn

#Azure Local Network Gateway
az network local-gateway create --gateway-ip-address $gcpvpnpip `
  --name "lng-$envname-gcp" `
  --resource-group $rg `
  --local-address-prefixes 192.168.100.0/24 `
  --output none

#GCP VPN Tunnel to Azure
$azgwnamepip = az network public-ip show -g $rg -n az-hub-vpngw-pip1 --query ipAddress -o tsv
gcloud compute vpn-tunnels create $envname-vpn-to-azure --region=$region --peer-address=$azgwnamepip --shared-secret=$sharedkey --ike-version=2 --local-traffic-selector=0.0.0.0/0 --remote-traffic-selector=0.0.0.0/0 --target-vpn-gateway=$envname-vpn
gcloud compute routes create $envname-vpn-to-azure-route-1 --network=$envname-vpc --priority=1000 --destination-range=10.0.0.0/8 --next-hop-vpn-tunnel=$envname-vpn-to-azure --next-hop-vpn-tunnel-region=$region

# Loop to check az-hub-vpngw provisioning state
while ((az network vnet-gateway show -g $rg -n az-hub-vpngw --query provisioningState -o tsv) -ne "Succeeded") {
  Write-Host "Waiting for az-hub-vpngw to be provisioned..."
  Start-Sleep -Seconds 10
}

#Azure VPN tunnel to GCP
$gwname = "Az-Hub-vpngw"
az network vpn-connection create --name "Azure-to-$envname-vpn" `
  --resource-group $rg `
  --vnet-gateway1 $gwname `
  --location (az group show -n $rg --query location -o tsv) `
  --shared-key $sharedkey `
  --local-gateway2 "lng-$envname-gcp"

#Check VPN Status on Azure side
# a) Check Connection Status (Note: you may get Unknown but wait a minute and issue the command again)
az network vpn-connection show -g $rg -n "Azure-to-$envname-vpn" --query connectionStatus -o tsv

# b) Check vpn connection IKE/SAs details
az network vpn-connection list-ike-sas -g $rg -n "Azure-to-$envname-vpn"

#GCP VPN Status on GCP Side
#More info: https://cloud.google.com/network-connectivity/docs/vpn/how-to/checking-vpn-status
gcloud compute vpn-tunnels describe $envname-vpn-to-azure --region=$region --format='flattened(status,detailedStatus)'

### Clean up ###
# GCP
gcloud compute vpn-tunnels delete $envname-vpn-to-azure --region $region --quiet
gcloud compute routes delete $envname-vpn-to-azure-route-1 --quiet
gcloud compute forwarding-rules delete $envname-vpn-rule-esp --region $region --quiet
gcloud compute forwarding-rules delete $envname-vpn-rule-udp500 --region $region --quiet
gcloud compute forwarding-rules delete $envname-vpn-rule-udp4500 --region $region --quiet
gcloud compute target-vpn-gateways delete $envname-vpn --region $region --quiet
gcloud compute addresses delete $envname-vpn-pip --region $region --quiet
gcloud compute instances delete $envname-vm1 --zone=$zone --quiet
gcloud compute firewall-rules delete $envname-allow-traffic-from-azure --quiet
gcloud compute networks subnets delete $envname-subnet --region=$region --quiet
gcloud compute networks delete $envname-vpc --quiet

# Azure side: remove just this site's VPN connection + local gateway (keep the hub)
az network vpn-connection delete -g $rg -n "Azure-to-$envname-vpn"
az network local-gateway delete -g $rg -n "lng-$envname-gcp"
