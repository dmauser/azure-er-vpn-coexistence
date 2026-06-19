# ---------------------------------------------------------------------------
# ExpressRoute Circuit — gated on enable_expressroute.
# Name matches deploy.azcli: az-hub-er-circuit
# Provider / peering location / bandwidth driven by variables.
# ---------------------------------------------------------------------------
resource "azurerm_express_route_circuit" "this" {
  count                 = var.enable_expressroute ? 1 : 0
  name                  = "az-hub-er-circuit"
  resource_group_name   = azurerm_resource_group.this.name
  location              = azurerm_resource_group.this.location
  service_provider_name = var.express_route_provider
  peering_location      = var.express_route_peering_location
  bandwidth_in_mbps     = var.express_route_bandwidth_mbps
  tags                  = local.tags

  sku {
    tier   = "Standard"
    family = "MeteredData"
  }
}

# ---------------------------------------------------------------------------
# ER Gateway Connection → ER Circuit.
# Name matches deploy.azcli: ER-Connection-to-Onprem
# Gated on enable_er_connection (separate from the circuit) because the attach
# only succeeds once the provider has set the circuit to 'Provisioned'. The
# deploy wrappers create the circuit first, wait for provisioning, then enable
# this connection.
# ---------------------------------------------------------------------------
resource "azurerm_virtual_network_gateway_connection" "er_to_onprem" {
  count                      = (var.enable_expressroute && var.enable_er_connection) ? 1 : 0
  name                       = "ER-Connection-to-Onprem"
  location                   = azurerm_resource_group.this.location
  resource_group_name        = azurerm_resource_group.this.name
  type                       = "ExpressRoute"
  virtual_network_gateway_id = azurerm_virtual_network_gateway.er.id
  express_route_circuit_id   = azurerm_express_route_circuit.this[0].id
  routing_weight             = 0
  tags                       = local.tags
}
