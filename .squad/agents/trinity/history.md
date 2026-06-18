# Trinity — History

## Seed
- **Project:** azure-er-vpn-coexistence2 — Azure ER/VPN coexistence lab, GCP as on-prem.
- **User:** dmauser
- **Stack:** Terraform `azurerm`. Porting `bicep/main.bicep` + `deploy.azcli` Azure steps to native HCL.
- **Mission:** Own `terraform/azure/` — hub/spokes, VPN GW, ER GW, LNG+connection, flagged ER circuit.

## Learnings

### 2026-06-17 — Initial terraform/azure/ scaffold

- **File split that works:** `providers.tf`, `variables.tf`, `main.tf`, `gateways.tf`, `vm.tf`, `vpn.tf`, `expressroute.tf`, `outputs.tf`. Cross-file resource references work because all files compile as one module.
- **Subnet strategy:** Do NOT mix inline subnet blocks on `azurerm_virtual_network` with separate `azurerm_subnet` resources — causes perpetual drift. Use separate resources exclusively; define non-gateway subnets in `main.tf` and GatewaySubnet in `gateways.tf`.
- **GatewaySubnet NSG:** Azure forbids an NSG on GatewaySubnet. Omit `azurerm_subnet_network_security_group_association` for it.
- **use_remote_gateways peering:** Spoke-side peerings with `use_remote_gateways = true` require both the VPN GW and ER GW to exist; add `depends_on = [azurerm_virtual_network_gateway.vpn, azurerm_virtual_network_gateway.er]` even when both are always created.
- **Active-active VPN GW:** Both `ip_configuration` blocks reference the same `azurerm_subnet.gateway.id`; each gets its own `azurerm_public_ip`. `active_active = true` requires `enable_bgp = true`.
- **ER GW vs VPN GW:** Do NOT set `generation` on the ExpressRoute gateway — that attribute is VPN-only. `type = "ExpressRoute"` is sufficient with `sku = "Standard"`.
- **Gated resource pattern:** `count = var.enable_X ? 1 : 0` on both the data source and dependent resources. Reference with `[0]` index. Use `one(resource[*].attr)` in outputs for null-safe access.
- **random_password PSK:** `length = 24, special = false` produces a clean ASCII key safe for IKEv2 PSK; stored in local state; shared key is `sensitive` in outputs.
- **terraform validate:** Passes without real variable values; does not resolve remote-state output keys at validate time — safe.
- **azurerm version pinned:** `~> 3.100` (resolved to 3.117.1). Avoids azurerm 4.x breaking `subscription_id` requirement.
