# Route validation helpers (PowerShell). Bash/Linux equivalent: routes.azcli
# Run after the lab is up to inspect the control plane.

#Define Variables
$rg = "lab-er-vpn-coexistence"  # Define your resource group
$location = az group show -g $rg --query location -o tsv
#Define parameters for Azure Hub and Spokes:
$AzurehubName = "Az-Hub"     # Azure Hub Name
$Azurespoke1Name = "Az-Spk1" # Azure Spoke 1 name
$Azurespoke2Name = "Az-Spk2" # Azure Spoke 2 name

# VMs IP and Effective Routes
# Azure Hub VM
az network nic show --resource-group $rg -n "$AzurehubName-lxvm-nic" --query "ipConfigurations[].privateIPAddress" -o tsv
az network nic show-effective-route-table --resource-group $rg -n "$AzurehubName-lxvm-nic" -o table

# Azure Spoke1 VM
az network nic show --resource-group $rg -n "$Azurespoke1Name-lxvm-nic" --query "ipConfigurations[].privateIPAddress" -o tsv
az network nic show-effective-route-table --resource-group $rg -n "$Azurespoke1Name-lxvm-nic" -o table

# Azure Spoke2 VM
az network nic show --resource-group $rg -n "$Azurespoke2Name-lxvm-nic" --query "ipConfigurations[].privateIPAddress" -o tsv
az network nic show-effective-route-table --resource-group $rg -n "$Azurespoke2Name-lxvm-nic" -o table

# Check ER/VPN GW learned / advertised routes
# 1) Azure Hub VPN Gateway
## BGP Peer Status
az network vnet-gateway list-bgp-peer-status -g $rg -n "$AzurehubName-vpngw" -o table
## Advertised BGP Routes = Use Portal
## Learned BGP Routes
az network vnet-gateway list-learned-routes -g $rg -n "$AzurehubName-vpngw" -o table

# 2) Azure Hub ER-GW
## BGP Peer Status
az network vnet-gateway list-bgp-peer-status -g $rg -n "$AzurehubName-ergw" -o table
## Get advertised BGP Routes to each neighbor
$neighbors = az network vnet-gateway list-bgp-peer-status -g $rg -n "$AzurehubName-ergw" --query "value[].neighbor" -o tsv
foreach ($neighbor in $neighbors) {
  az network vnet-gateway list-advertised-routes -g $rg -n "$AzurehubName-ergw" --peer $neighbor -o table
}
## Learned BGP Routes
az network vnet-gateway list-learned-routes -g $rg -n "$AzurehubName-ergw" -o table

# 3) Route Server (only if you deployed one separately — not part of the trimmed lab)
$rsname = az network routeserver list --resource-group $rg --query "[?contains(name, 'az')].name | [0]" -o tsv
if ($rsname) {
  Write-Host "Route Server name: $rsname"
  Write-Host "Route Server IPs:"
  az network routeserver show --name $rsname --resource-group $rg --query 'virtualRouterIps[]' -o tsv
}
