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

### 2026-06-17 — Azure VM hardening + route dumps

- **VM hardening:** Removed VM public IP resources and NIC public IP bindings for `hub`, `spoke1`, and `spoke2`. Removed `restrict_ssh_source_prefix` and the custom `Allow-SSH-Inbound` NSG rule; VM access is now through Azure Serial Console, with default NSG platform rules only.
- **Serial Console enablement:** Added empty `boot_diagnostics {}` blocks to all three `azurerm_linux_virtual_machine` resources. Empty boot diagnostics uses managed platform storage and enables Serial Console access (`az serialconsole` / portal).
- **Route-dump approach:** Added root scripts `dump-routes-azure.sh` and `dump-routes-azure.ps1`. They verify `az`, show the active subscription, prompt for defaults while accepting flags/env for automation, auto-discover NICs in the RG, and gracefully continue when ExpressRoute resources are disabled or unprovisioned.
- **VM nettools cloud-init:** Added shared `local.nettools_cloud_init` and assigned it to all three Linux VMs via `custom_data = base64encode(local.nettools_cloud_init)`. It installs `net-tools`, `traceroute`, `tcptraceroute`, `nmap`, `hping3`, `iperf3`, `nginx`, `speedtest-cli`, and `moreutils`, then writes `hostname` to `/var/www/html/index.html`; apt relies on Azure default outbound access because the VMs have no public IP.
- **deploy.sh secret cleanup:** Added an `EXIT` trap immediately after exporting `TF_VAR_vm_admin_password` so the Terraform VM password is cleared even if `set -e` aborts on apply failure.
- **deploy password handling:** `deploy.sh` and `deploy.ps1` now enforce Azure's 12-72 character / 3-of-4 complexity rule for interactive, parameter, and environment passwords; interactive entry also requires confirmation.
- **terraform.tfvars precedence guard:** `deploy.sh` and `deploy.ps1` now fail during prerequisite checks if `terraform/azure/terraform.tfvars` actively sets `vm_admin_password`, because Terraform tfvars values override `TF_VAR_vm_admin_password` from the secure prompt.
- **Exact az commands used by the scripts:**
  - `az network express-route list-route-table --resource-group <rg> --name <circuit> --peering-name AzurePrivatePeering --path primary -o table`
  - `az network express-route list-route-table --resource-group <rg> --name <circuit> --peering-name AzurePrivatePeering --path secondary -o table`
  - `az network nic list -g <rg> --query "[].name" -o tsv`
  - `az network nic show-effective-route-table --resource-group <rg> --name <nic> -o table`
  - `az network vnet-gateway list-learned-routes --resource-group <rg> --name <er-gw> -o table`
  - Optional: `az network vnet-gateway list-advertised-routes --resource-group <rg> --name <er-gw> -o table`

### 2026-06-17 — Session finalization (Scribe: decisions merged, orchestration logs)

- Terraform revamp finalized and validated by Morpheus (all gates passed: Secrets/State/Cross-State/Billing/Fidelity/Docs)
- VM hardening + route dumps committed as per Scribe orchestration log
- Coordinator applied critical trap fix to deploy.sh (TF_VAR_vm_admin_password cleanup on EXIT) — High-severity finding from Morpheus resolved
- All 14 decisions merged into `.squad/decisions.md` from inbox; inbox files deleted
- Orchestration log written: 2026-06-17T20_47_00-trinity.md

### 2026-06-18T02:30:00Z — tfvars Precedence Guard (Scribe decision merge)

- **Root cause:** Active `vm_admin_password` placeholder in `terraform/azure/terraform.tfvars` silently overrode strong password collected by `deploy.sh`/`deploy.ps1` due to Terraform variable precedence (tfvars > env var).
- **Guard implemented:** Both deploy wrappers now fail during prerequisite validation if `terraform/azure/terraform.tfvars` contains uncommented `vm_admin_password`.
- **Example file updated:** `terraform/azure/terraform.tfvars.example` keeps credentials commented with note explaining script supply behavior.
- **Decision #16 merged:** Trinity inbox decision merged into decisions.md; inbox file deleted.
- **Orchestration log:** 2026-06-18T02-30-trinity.md
