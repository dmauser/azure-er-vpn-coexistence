locals {
  vpn_bgp_asn = 65515
  tags = {
    Project   = "azure-er-vpn-coexistence"
    ManagedBy = "Terraform"
  }
  nettools_cloud_init = <<-CLOUD_INIT
#cloud-config
package_update: true
package_upgrade: true
packages:
  - net-tools
  - traceroute
  - tcptraceroute
  - nmap
  - hping3
  - iperf3
  - nginx
  - speedtest-cli
  - moreutils
runcmd:
  - [ bash, -lc, "hostname > /var/www/html/index.html" ]
  CLOUD_INIT
}

# ---------------------------------------------------------------------------
# Resource Group
# ---------------------------------------------------------------------------
resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.tags
}

# ---------------------------------------------------------------------------
# NSG — VMs are reached via Serial Console only; there is no inbound SSH from
# the internet and VM NICs have no public IPs. Intra-VNet / gateway traffic is
# still covered by the default AllowVnetInBound rule (VirtualNetwork tag).
# ---------------------------------------------------------------------------
resource "azurerm_network_security_group" "default" {
  name                = "Default-NSG"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

# ---------------------------------------------------------------------------
# Hub VNet
# ---------------------------------------------------------------------------
resource "azurerm_virtual_network" "hub" {
  name                = "${var.hub_name}-vnet"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = [var.hub_address_space]
  tags                = local.tags
}

resource "azurerm_subnet" "hub_subnet1" {
  name                 = "subnet1"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [var.hub_subnet_prefix]
}

resource "azurerm_subnet_network_security_group_association" "hub_subnet1" {
  subnet_id                 = azurerm_subnet.hub_subnet1.id
  network_security_group_id = azurerm_network_security_group.default.id
}

# ---------------------------------------------------------------------------
# Spoke 1 VNet
# ---------------------------------------------------------------------------
resource "azurerm_virtual_network" "spoke1" {
  name                = "${var.spoke1_name}-vnet"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = [var.spoke1_address_space]
  tags                = local.tags
}

resource "azurerm_subnet" "spoke1_subnet1" {
  name                 = "subnet1"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.spoke1.name
  address_prefixes     = [var.spoke1_subnet_prefix]
}

resource "azurerm_subnet_network_security_group_association" "spoke1_subnet1" {
  subnet_id                 = azurerm_subnet.spoke1_subnet1.id
  network_security_group_id = azurerm_network_security_group.default.id
}

# ---------------------------------------------------------------------------
# Spoke 2 VNet
# ---------------------------------------------------------------------------
resource "azurerm_virtual_network" "spoke2" {
  name                = "${var.spoke2_name}-vnet"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = [var.spoke2_address_space]
  tags                = local.tags
}

resource "azurerm_subnet" "spoke2_subnet1" {
  name                 = "subnet1"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.spoke2.name
  address_prefixes     = [var.spoke2_subnet_prefix]
}

resource "azurerm_subnet_network_security_group_association" "spoke2_subnet1" {
  subnet_id                 = azurerm_subnet.spoke2_subnet1.id
  network_security_group_id = azurerm_network_security_group.default.id
}

# ---------------------------------------------------------------------------
# Peerings — hub allows gateway transit; spokes use remote gateways.
# Spoke-side use_remote_gateways requires both gateways to exist first.
# ---------------------------------------------------------------------------
resource "azurerm_virtual_network_peering" "hub_to_spoke1" {
  name                         = "Hub-to-Spoke1"
  resource_group_name          = azurerm_resource_group.this.name
  virtual_network_name         = azurerm_virtual_network.hub.name
  remote_virtual_network_id    = azurerm_virtual_network.spoke1.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = true
  use_remote_gateways          = false
}

resource "azurerm_virtual_network_peering" "spoke1_to_hub" {
  name                         = "Spoke1-to-Hub"
  resource_group_name          = azurerm_resource_group.this.name
  virtual_network_name         = azurerm_virtual_network.spoke1.name
  remote_virtual_network_id    = azurerm_virtual_network.hub.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = true

  depends_on = [
    azurerm_virtual_network_gateway.vpn,
    azurerm_virtual_network_gateway.er,
  ]
}

resource "azurerm_virtual_network_peering" "hub_to_spoke2" {
  name                         = "Hub-to-Spoke2"
  resource_group_name          = azurerm_resource_group.this.name
  virtual_network_name         = azurerm_virtual_network.hub.name
  remote_virtual_network_id    = azurerm_virtual_network.spoke2.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = true
  use_remote_gateways          = false
}

resource "azurerm_virtual_network_peering" "spoke2_to_hub" {
  name                         = "Spoke2-to-Hub"
  resource_group_name          = azurerm_resource_group.this.name
  virtual_network_name         = azurerm_virtual_network.spoke2.name
  remote_virtual_network_id    = azurerm_virtual_network.hub.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = true

  depends_on = [
    azurerm_virtual_network_gateway.vpn,
    azurerm_virtual_network_gateway.er,
  ]
}
