# Run commands below on Windows (PowerShell) with Azure CLI and gcloud installed.
# Bash/Linux equivalent: deploy.azcli
#
# This script is meant to be run INTERACTIVELY, block by block (copy/paste),
# not as a single ./deploy.ps1 — several steps require manual portal/provider actions.

# Prerequisite - Install AZ and GCP CLI:
# Azure CLI:  https://learn.microsoft.com/cli/azure/install-azure-cli-windows
# GCP CLI:    https://cloud.google.com/sdk/docs/install#windows

# Login/Subscription
az login
# If necessary select your target subscription:
# az account set --subscription "<Name or ID of subscription>"
# GCP CLI
gcloud init

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
    Write-Host "FAIL: not logged in to Azure. Run: az login  (then: az account set --subscription <id>)" -ForegroundColor Red; $ok = $false
  }
  $gcpAccount = gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>$null
  if ($gcpAccount) { Write-Host "OK  : gcloud account -> $gcpAccount" }
  else { Write-Host "FAIL: no active gcloud account. Run: gcloud auth login" -ForegroundColor Red; $ok = $false }
  $proj = gcloud config get-value project 2>$null
  if ($proj -and $proj -ne '(unset)') { Write-Host "OK  : gcloud project -> $proj" }
  else { Write-Host "WARN: no default gcloud project set (set later from `$project, or run: gcloud config set project <id>)" -ForegroundColor Yellow }
  if (-not $ok) { Write-Host ">>> Prerequisites NOT met. Fix the FAIL items above before deploying." -ForegroundColor Red; return $false }
  Write-Host ">>> All prerequisites satisfied." -ForegroundColor Green
  return $true
}
Test-Prereqs
# ===============================================

#Azure Variables
$rg = "lab-er-vpn-coexistence"   # Define your resource group
$location = "centralus"           # Set Region
$mypip = (Invoke-RestMethod -Uri "https://api.ipify.org").Trim()  # Your public IP; used to restrict SSH/firewall access
# Auto-generate a VPN S2S shared key (24 random bytes, base64)
$bytes = [byte[]]::new(24)
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$sharedkey = [Convert]::ToBase64String($bytes)

# Define GCP variables (Mandatory: Define your GCP project)
$region = "us-central1"   # (OPTIONAL) Set your region. List zones: gcloud compute zones list
$zone = "$region-c"       # Set availability zone: a, b or c.
$vpcrange = "192.168.0.0/24"
$envname = "vpnlab"
$vmname = "vm1"
$mypip = (Invoke-RestMethod -Uri "https://api.ipify.org").Trim()
$project = Read-Host "Enter your GCP Project ID"

#Define parameters for Azure Hub and Spokes:
$AzurehubName = "Az-Hub"                       # Azure Hub Name
$AzurehubaddressSpacePrefix = "10.0.10.0/24"   # Azure Hub VNET address space
$Azurehubsubnet1Prefix = "10.0.10.0/27"        # Azure Hub Subnet address prefix
$AzurehubgatewaySubnetPrefix = "10.0.10.32/27" # Azure Hub Gateway Subnet address prefix
$Azurespoke1Name = "Az-Spk1"                   # Azure Spoke 1 name
$Azurespoke1AddressSpacePrefix = "10.0.11.0/24"
$Azurespoke1Subnet1Prefix = "10.0.11.0/27"
$Azurespoke2Name = "Az-Spk2"                   # Azure Spoke 2 name
$Azurespoke2AddressSpacePrefix = "10.0.12.0/24"
$Azurespoke2Subnet1Prefix = "10.0.12.0/27"

#Deploy base lab environment = Hub + VPN Gateway + ER Gateway + VM and two Spokes with one VM on each.
# Uses the local trimmed Bicep template (./bicep/main.bicep) — no empty AzureFirewall/RouteServer subnets.
Write-Host "*** You will be prompted for the Linux VM admin username and password ***"
Write-Host "*** It will take around 30 minutes to finish the deployment ***"
$vmuser = Read-Host "VM admin username"
$securePass = Read-Host "VM admin password" -AsSecureString
$vmpass = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePass))
az group create --name $rg --location $location
# Optional pre-flight: preview changes with what-if (remove --no-wait below to wait for completion)
# az deployment group what-if --resource-group $rg --template-file ./bicep/main.bicep `
#   --parameters vmAdminUsername=$vmuser vmAdminPassword=$vmpass restrictSshSourcePrefix=$mypip/32
az deployment group create --name "VPNERCoexist-$(Get-Random)" --resource-group $rg `
  --template-file ./bicep/main.bicep `
  --parameters vmAdminUsername=$vmuser vmAdminPassword=$vmpass restrictSshSourcePrefix=$mypip/32 `
               location=$location gatewaySku=VpnGw1 vpnGatewayGeneration=Generation1 `
               hubName=$AzurehubName spoke1Name=$Azurespoke1Name spoke2Name=$Azurespoke2Name `
               hubAddressSpace=$AzurehubaddressSpacePrefix hubSubnetPrefix=$Azurehubsubnet1Prefix `
               gatewaySubnetPrefix=$AzurehubgatewaySubnetPrefix `
               spoke1AddressSpace=$Azurespoke1AddressSpacePrefix spoke1SubnetPrefix=$Azurespoke1Subnet1Prefix `
               spoke2AddressSpace=$Azurespoke2AddressSpacePrefix spoke2SubnetPrefix=$Azurespoke2Subnet1Prefix `
  --output none `
  --no-wait

##### GCP Deployment ####

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
gcloud compute target-vpn-gateways create onpremvpn --region=$region --network=$envname-vpc
gcloud compute addresses create onpremvpn-pip --region=$region
$gcpvpnpip = gcloud compute addresses describe onpremvpn-pip --region=$region --format='value(address)'
gcloud compute forwarding-rules create onpremvpn-rule-esp --region=$region --address=$gcpvpnpip --ip-protocol=ESP --target-vpn-gateway=onpremvpn
gcloud compute forwarding-rules create onpremvpn-rule-udp500 --region=$region --address=$gcpvpnpip --ip-protocol=UDP --ports=500 --target-vpn-gateway=onpremvpn
gcloud compute forwarding-rules create onpremvpn-rule-udp4500 --region=$region --address=$gcpvpnpip --ip-protocol=UDP --ports=4500 --target-vpn-gateway=onpremvpn

#Azure Local Network Gateway
az network local-gateway create --gateway-ip-address $gcpvpnpip `
  --name lng-onprem-gcp `
  --resource-group $rg `
  --local-address-prefixes 192.168.0.0/24 `
  --output none

#GCP VPN Tunnel to Azure
$azgwnamepip = az network public-ip show -g $rg -n az-hub-vpngw-pip1 --query ipAddress -o tsv
gcloud compute vpn-tunnels create vpn-to-azure --region=$region --peer-address=$azgwnamepip --shared-secret=$sharedkey --ike-version=2 --local-traffic-selector=0.0.0.0/0 --remote-traffic-selector=0.0.0.0/0 --target-vpn-gateway=onpremvpn
gcloud compute routes create vpn-to-azure-route-1 --network=$envname-vpc --priority=1000 --destination-range=10.0.0.0/8 --next-hop-vpn-tunnel=vpn-to-azure --next-hop-vpn-tunnel-region=$region

# Loop to check az-hub-vpngw provisioning state
while ((az network vnet-gateway show -g $rg -n az-hub-vpngw --query provisioningState -o tsv) -ne "Succeeded") {
  Write-Host "Waiting for az-hub-vpngw to be provisioned..."
  Start-Sleep -Seconds 10
}

#Azure VPN tunnel to GCP
$gwname = "Az-Hub-vpngw"
az network vpn-connection create --name Azure-to-OnpremGCP `
  --resource-group $rg `
  --vnet-gateway1 $gwname `
  --location (az group show -n $rg --query location -o tsv) `
  --shared-key $sharedkey `
  --local-gateway2 lng-onprem-gcp

#Check VPN Status on Azure side
# a) Check Connection Status (Note: you may get Unknown but wait a minute and issue the command again)
az network vpn-connection show -g $rg -n Azure-to-OnpremGCP --query connectionStatus -o tsv

# b) Check vpn connection IKE/SAs details
az network vpn-connection list-ike-sas -g $rg -n Azure-to-OnpremGCP

#GCP VPN Status on GCP Side
#More info: https://cloud.google.com/network-connectivity/docs/vpn/how-to/checking-vpn-status
gcloud compute vpn-tunnels describe vpn-to-azure --region=$region --format='flattened(status,detailedStatus)'

#Test VPN connectivity - SSH Azure VM and ping GCP VM.
#Get Azure Hub and Spoke VMs IPs
Write-Host "$AzurehubName-lxvm";   az network nic show --resource-group $rg -n "$AzurehubName-lxvm-nic"   --query "ipConfigurations[].privateIPAddress" -o tsv
Write-Host "$Azurespoke1Name-lxvm"; az network nic show --resource-group $rg -n "$Azurespoke1Name-lxvm-nic" --query "ipConfigurations[].privateIPAddress" -o tsv
Write-Host "$Azurespoke2Name-lxvm"; az network nic show --resource-group $rg -n "$Azurespoke2Name-lxvm-nic" --query "ipConfigurations[].privateIPAddress" -o tsv

#Log on GCP VM and try to reach all three VMs listed above:
gcloud compute ssh $envname-vm1 --zone=$zone

# Inside the GCP (Linux) VM, run these to ping the Azure VMs:
#   echo Az-Hub-Lxvm  && ping 10.0.10.4 -O -c 5
#   echo Az-Spk1-lxvm && ping 10.0.11.4 -O -c 5
#   echo Az-Spk2-lxvm && ping 10.0.12.4 -O -c 5
#   exit

### Bringing Azure ExpressRoute and Interconnect ###

## GCP
# 1) Deploy Cloud Router:
gcloud compute routers create $envname-router --region=$region --network=$envname-vpc --asn=16550

# 2) Deploy Partner Interconnect attachment:
gcloud compute interconnects attachments partner create $envname-vlan --region $region --edge-availability-domain availability-domain-1 --router $envname-router --admin-enabled
# Note: save the pairing key to provision the GCP connection with your provider.

# 3) Using the provider website, create a VXC (Virtual Cross Connection) to GCP using the pairing key.

## Azure
# 1) Create ExpressRoute Circuit
# In this example ExpressRoute is created using Megaport as provider. Adjust to your needs.
$ername = "az-hub-er-circuit"  # ExpressRoute Circuit Name
$cxlocation = "Chicago"         # Peering Location
$provider = "Megaport"          # Provider
az network express-route create --bandwidth 50 -n $ername --peering-location $cxlocation -g $rg --provider $provider -l $location --sku-family MeteredData --sku-tier Standard

# 2) Using the provider website, create a VXC to Azure using the provided Service Key.

# 3) Connect the ExpressRoute Circuit to the ExpressRoute Gateway. Only continue once the circuit is fully provisioned.
$erid = az network express-route show -n $ername -g $rg --query id -o tsv
az network vpn-connection create --name ER-Connection-to-Onprem `
  --resource-group $rg --vnet-gateway1 "$AzurehubName-ergw" `
  --express-route-circuit2 $erid `
  --routing-weight 0

# When ExpressRoute is up, connectivity switches from VPN to ER. Keep a ping running between an Azure VM and the GCP VM.

# 4) Disable ExpressRoute Private Peering in the portal (Private Peering) and test the failover back to VPN.

### Clean up VPN + ExpressRoute/Interconnect ###
# GCP
gcloud compute vpn-tunnels delete vpn-to-azure --region $region --quiet
gcloud compute routes delete vpn-to-azure-route-1 --quiet
gcloud compute forwarding-rules delete onpremvpn-rule-esp --region $region --quiet
gcloud compute forwarding-rules delete onpremvpn-rule-udp500 --region $region --quiet
gcloud compute forwarding-rules delete onpremvpn-rule-udp4500 --region $region --quiet
gcloud compute target-vpn-gateways delete onpremvpn --region $region --quiet
gcloud compute addresses delete onpremvpn-pip --region $region --quiet
gcloud compute interconnects attachments delete $envname-vlan --region $region --quiet
gcloud compute routers delete $envname-router --region $region --quiet
gcloud compute instances delete $envname-vm1 --zone=$zone --quiet
gcloud compute firewall-rules delete $envname-allow-traffic-from-azure --quiet
gcloud compute networks subnets delete $envname-subnet --region=$region --quiet
gcloud compute networks delete $envname-vpc --quiet

# Azure
az group delete -g $rg --no-wait --yes
