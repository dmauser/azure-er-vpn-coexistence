output "resource_group_name" {
  description = "Name of the deployed resource group"
  value       = azurerm_resource_group.this.name
}

output "location" {
  description = "Azure region of the deployment"
  value       = azurerm_resource_group.this.location
}

output "hub_vnet_name" {
  description = "Name of the hub VNet"
  value       = azurerm_virtual_network.hub.name
}

# pip1 = instance-0; this is the address Niobe (GCP Terraform) peers its VPN tunnel to.
output "vpn_gateway_public_ip" {
  description = "Public IP of VPN gateway instance 0 — the address Niobe's GCP tunnel uses as peer"
  value       = azurerm_public_ip.vpn_gw_pip1.ip_address
}

output "vpn_shared_key" {
  description = "Auto-generated VPN pre-shared key (consume via Tank remote-state; never log)"
  value       = random_password.vpn_shared_key.result
  sensitive   = true
}

# one() returns null when count=0, the single value when count=1.
output "expressroute_service_key" {
  description = "ExpressRoute circuit service key (null when enable_expressroute=false)"
  value       = one(azurerm_express_route_circuit.this[*].service_key)
  sensitive   = true
}

output "expressroute_circuit_name" {
  description = "ExpressRoute circuit name (null when enable_expressroute=false)"
  value       = one(azurerm_express_route_circuit.this[*].name)
}
