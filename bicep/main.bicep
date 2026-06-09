// =====================================================================================
// Azure VPN + ExpressRoute coexistence lab — TRIMMED Bicep version
// -------------------------------------------------------------------------------------
// Deploys ONLY what this lab needs:
//   - Hub VNet with subnet1 (VM) + GatewaySubnet   (NO AzureFirewallSubnet / RouteServerSubnet)
//   - Two spoke VNets, each with subnet1 and a VM, bidirectionally peered to the hub
//   - Active-active VPN Gateway (BGP) and an ExpressRoute Gateway in the hub
//   - One Ubuntu test VM per VNet + an NSG restricting SSH to your public IP
//
// Removed vs. the original azure-hub-spoke-base-lab template: the empty AzureFirewallSubnet
// and RouteServerSubnet (and the Route Server, which was never actually deployed).
//
// Names/IPs intentionally match deploy.azcli so the GCP-side scripts keep working
// (e.g. Az-Hub-vpngw-pip1, VM private IPs 10.0.10.4 / 10.0.11.4 / 10.0.12.4).
// =====================================================================================

targetScope = 'resourceGroup'

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Source public IP/CIDR allowed to SSH the VMs (e.g. 1.2.3.4/32). Use * to allow any.')
param restrictSshSourcePrefix string = '*'

@description('Admin username for the Linux test VMs')
param vmAdminUsername string

@description('Admin password for the Linux test VMs')
@secure()
param vmAdminPassword string

@description('Test VM size')
param vmSize string = 'Standard_B1s'

@description('VPN gateway SKU')
@allowed([ 'VpnGw1', 'VpnGw2', 'VpnGw3', 'VpnGw4', 'VpnGw5' ])
param gatewaySku string = 'VpnGw1'

@description('VPN gateway generation')
@allowed([ 'Generation1', 'Generation2' ])
param vpnGatewayGeneration string = 'Generation1'

@description('VPN gateway BGP ASN')
param vpnGatewayAsn int = 65515

@description('ExpressRoute gateway SKU')
@allowed([ 'Standard', 'HighPerformance', 'UltraPerformance', 'ErGw1AZ', 'ErGw2AZ', 'ErGw3AZ' ])
param erGatewaySku string = 'Standard'

@description('Hub VNet name')
param hubName string = 'Az-Hub'

@description('Spoke 1 VNet name')
param spoke1Name string = 'Az-Spk1'

@description('Spoke 2 VNet name')
param spoke2Name string = 'Az-Spk2'

@description('Hub VNet address space')
param hubAddressSpace string = '10.0.10.0/24'

@description('Hub VM subnet prefix')
param hubSubnetPrefix string = '10.0.10.0/27'

@description('GatewaySubnet prefix (shared by VPN + ExpressRoute gateways)')
param gatewaySubnetPrefix string = '10.0.10.32/27'

@description('Spoke 1 address space')
param spoke1AddressSpace string = '10.0.11.0/24'

@description('Spoke 1 subnet prefix')
param spoke1SubnetPrefix string = '10.0.11.0/27'

@description('Spoke 2 address space')
param spoke2AddressSpace string = '10.0.12.0/24'

@description('Spoke 2 subnet prefix')
param spoke2SubnetPrefix string = '10.0.12.0/27'

@description('Tags applied to all resources')
param tags object = {
  Project: 'azure-er-vpn-coexistence'
  ManagedBy: 'Bicep'
}

var subnetName = 'subnet1'
var vpnGatewayName = '${hubName}-vpngw'
var erGatewayName = '${hubName}-ergw'

// ---------------------------------------------------------------------------
// NSG — allow SSH only from the specified source; intra-VNet/VPN traffic is
// covered by the default AllowVnetInBound rule (VirtualNetwork tag includes
// peered spokes and on-premises ranges learned over the gateways).
// ---------------------------------------------------------------------------
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'Default-NSG'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-SSH-Inbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: restrictSshSourcePrefix
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Hub VNet — only subnet1 + GatewaySubnet
// ---------------------------------------------------------------------------
resource hubVnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: '${hubName}-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [ hubAddressSpace ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: hubSubnetPrefix
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
      {
        name: 'GatewaySubnet'
        properties: {
          addressPrefix: gatewaySubnetPrefix
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Spoke VNets
// ---------------------------------------------------------------------------
resource spoke1Vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: '${spoke1Name}-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [ spoke1AddressSpace ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: spoke1SubnetPrefix
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

resource spoke2Vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: '${spoke2Name}-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [ spoke2AddressSpace ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: spoke2SubnetPrefix
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// VPN Gateway (active-active, BGP) — two public IPs (pip1/pip2)
// ---------------------------------------------------------------------------
resource vpnGwPip1 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: '${vpnGatewayName}-pip1'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource vpnGwPip2 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: '${vpnGatewayName}-pip2'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource vpnGateway 'Microsoft.Network/virtualNetworkGateways@2023-11-01' = {
  name: vpnGatewayName
  location: location
  tags: tags
  properties: {
    gatewayType: 'Vpn'
    vpnType: 'RouteBased'
    vpnGatewayGeneration: vpnGatewayGeneration
    sku: {
      name: gatewaySku
      tier: gatewaySku
    }
    activeActive: true
    enableBgp: true
    bgpSettings: {
      asn: vpnGatewayAsn
    }
    ipConfigurations: [
      {
        name: 'vnetGatewayConfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: '${hubVnet.id}/subnets/GatewaySubnet'
          }
          publicIPAddress: {
            id: vpnGwPip1.id
          }
        }
      }
      {
        name: 'vnetGatewayConfig2'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: '${hubVnet.id}/subnets/GatewaySubnet'
          }
          publicIPAddress: {
            id: vpnGwPip2.id
          }
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// ExpressRoute Gateway (shares the GatewaySubnet with the VPN gateway)
// ---------------------------------------------------------------------------
resource erGwPip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: '${erGatewayName}-pip'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource erGateway 'Microsoft.Network/virtualNetworkGateways@2023-11-01' = {
  name: erGatewayName
  location: location
  tags: tags
  properties: {
    gatewayType: 'ExpressRoute'
    sku: {
      name: erGatewaySku
      tier: erGatewaySku
    }
    ipConfigurations: [
      {
        name: 'ergwConfig'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: '${hubVnet.id}/subnets/GatewaySubnet'
          }
          publicIPAddress: {
            id: erGwPip.id
          }
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Peerings — hub<->spoke with gateway transit so spokes use the hub gateways.
// Spoke-side useRemoteGateways requires the gateways to exist first.
// ---------------------------------------------------------------------------
resource hubToSpoke1 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-11-01' = {
  parent: hubVnet
  name: 'Hub-to-Spoke1'
  properties: {
    remoteVirtualNetwork: {
      id: spoke1Vnet.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: true
    useRemoteGateways: false
  }
}

resource spoke1ToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-11-01' = {
  parent: spoke1Vnet
  name: 'Spoke1-to-Hub'
  dependsOn: [ vpnGateway, erGateway ]
  properties: {
    remoteVirtualNetwork: {
      id: hubVnet.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: true
  }
}

resource hubToSpoke2 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-11-01' = {
  parent: hubVnet
  name: 'Hub-to-Spoke2'
  properties: {
    remoteVirtualNetwork: {
      id: spoke2Vnet.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: true
    useRemoteGateways: false
  }
}

resource spoke2ToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-11-01' = {
  parent: spoke2Vnet
  name: 'Spoke2-to-Hub'
  dependsOn: [ vpnGateway, erGateway ]
  properties: {
    remoteVirtualNetwork: {
      id: hubVnet.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: true
  }
}

// ---------------------------------------------------------------------------
// Test VMs (one per VNet)
// ---------------------------------------------------------------------------
module hubVm 'modules/vm.bicep' = {
  name: '${hubName}-vm'
  params: {
    location: location
    vmName: '${hubName}-lxvm'
    subnetId: '${hubVnet.id}/subnets/${subnetName}'
    nsgId: nsg.id
    vmSize: vmSize
    adminUsername: vmAdminUsername
    adminPassword: vmAdminPassword
    tags: tags
  }
}

module spoke1Vm 'modules/vm.bicep' = {
  name: '${spoke1Name}-vm'
  params: {
    location: location
    vmName: '${spoke1Name}-lxvm'
    subnetId: '${spoke1Vnet.id}/subnets/${subnetName}'
    nsgId: nsg.id
    vmSize: vmSize
    adminUsername: vmAdminUsername
    adminPassword: vmAdminPassword
    tags: tags
  }
}

module spoke2Vm 'modules/vm.bicep' = {
  name: '${spoke2Name}-vm'
  params: {
    location: location
    vmName: '${spoke2Name}-lxvm'
    subnetId: '${spoke2Vnet.id}/subnets/${subnetName}'
    nsgId: nsg.id
    vmSize: vmSize
    adminUsername: vmAdminUsername
    adminPassword: vmAdminPassword
    tags: tags
  }
}

// ---------------------------------------------------------------------------
// Outputs (used by deploy.azcli for the VPN/ER steps)
// ---------------------------------------------------------------------------
output vpnGatewayName string = vpnGateway.name
output vpnGatewayPip1 string = vpnGwPip1.properties.ipAddress
output erGatewayName string = erGateway.name
output hubVmPrivateIp string = hubVm.outputs.privateIp
output spoke1VmPrivateIp string = spoke1Vm.outputs.privateIp
output spoke2VmPrivateIp string = spoke2Vm.outputs.privateIp
