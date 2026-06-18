using './main.bicep'

// Fill these in (or pass --parameters on the CLI).
param vmAdminUsername = 'azureuser'
param vmAdminPassword = '' // REQUIRED: set a strong password, or pass --parameters vmAdminPassword=... at deploy time

// Lock SSH to your public IP (recommended). Use '*' only for quick throwaway labs.
param restrictSshSourcePrefix = '*'

// Defaults below match deploy.azcli — change only if you also change the scripts.
param location = 'centralus'
param gatewaySku = 'VpnGw1'
param vpnGatewayGeneration = 'Generation1'
param vpnGatewayAsn = 65515
param erGatewaySku = 'Standard'
param vmSize = 'Standard_B1s'

param hubName = 'Az-Hub'
param spoke1Name = 'Az-Spk1'
param spoke2Name = 'Az-Spk2'

param hubAddressSpace = '10.0.10.0/24'
param hubSubnetPrefix = '10.0.10.0/27'
param gatewaySubnetPrefix = '10.0.10.32/27'
param spoke1AddressSpace = '10.0.11.0/24'
param spoke1SubnetPrefix = '10.0.11.0/27'
param spoke2AddressSpace = '10.0.12.0/24'
param spoke2SubnetPrefix = '10.0.12.0/27'
