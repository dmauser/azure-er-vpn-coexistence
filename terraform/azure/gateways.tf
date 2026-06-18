# ---------------------------------------------------------------------------
# GatewaySubnet — shared by VPN gateway and ExpressRoute gateway.
# Must be named "GatewaySubnet" (Azure requirement). No NSG allowed.
# ---------------------------------------------------------------------------
resource "azurerm_subnet" "gateway" {
  name                 = "GatewaySubnet"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [var.gateway_subnet_prefix]
}

# ---------------------------------------------------------------------------
# VPN Gateway — active-active, BGP, two public IPs (pip1 / pip2)
# Names match bicep/main.bicep and deploy.azcli (Az-Hub-vpngw-pip1, etc.)
# ---------------------------------------------------------------------------
# Zone-redundant Standard public IPs — required by the AZ VPN gateway SKU (VpnGw1AZ+).
resource "azurerm_public_ip" "vpn_gw_pip1" {
  name                = "${var.hub_name}-vpngw-pip1"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = local.tags
}

resource "azurerm_public_ip" "vpn_gw_pip2" {
  name                = "${var.hub_name}-vpngw-pip2"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = local.tags
}

resource "azurerm_virtual_network_gateway" "vpn" {
  name                = "${var.hub_name}-vpngw"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  type                = "Vpn"
  vpn_type            = "RouteBased"
  sku                 = var.gateway_sku
  generation          = var.vpn_gateway_generation
  active_active       = true
  enable_bgp          = true
  tags                = local.tags

  bgp_settings {
    asn = local.vpn_bgp_asn
  }

  ip_configuration {
    name                          = "vnetGatewayConfig1"
    public_ip_address_id          = azurerm_public_ip.vpn_gw_pip1.id
    subnet_id                     = azurerm_subnet.gateway.id
    private_ip_address_allocation = "Dynamic"
  }

  ip_configuration {
    name                          = "vnetGatewayConfig2"
    public_ip_address_id          = azurerm_public_ip.vpn_gw_pip2.id
    subnet_id                     = azurerm_subnet.gateway.id
    private_ip_address_allocation = "Dynamic"
  }
}

# ---------------------------------------------------------------------------
# ExpressRoute Gateway — Standard SKU, single public IP, same GatewaySubnet
# ---------------------------------------------------------------------------
resource "azurerm_public_ip" "er_gw_pip" {
  name                = "${var.hub_name}-ergw-pip"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_virtual_network_gateway" "er" {
  name                = "${var.hub_name}-ergw"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  type                = "ExpressRoute"
  sku                 = "Standard"
  tags                = local.tags

  ip_configuration {
    name                          = "ergwConfig"
    public_ip_address_id          = azurerm_public_ip.er_gw_pip.id
    subnet_id                     = azurerm_subnet.gateway.id
    private_ip_address_allocation = "Dynamic"
  }
}
