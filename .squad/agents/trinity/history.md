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

### 2026-06-17 — Standard public IP pre-flight probe

- **Standard vs Basic PIP requirement:** Active-active VPN gateways with BGP require Standard SKU public IPs. Azure retired Basic SKU public IPs on 2025-09-30; they never supported active-active or BGP. `gateways.tf` must keep `sku = "Standard"` + `allocation_method = "Static"` on vpn_gw_pip1, vpn_gw_pip2, and er_gw_pip.
- **FDPO subscription Standard-PIP gate:** The DMAUSER-FDPO subscription gates allocation of ALL Standard SKU public IPs behind the provider feature `Microsoft.Network/AllowBringYourOwnPublicIpAddress`. The feature name is misleading — it is NOT "bring your own IP prefix". Registering it simply unlocks normal Azure-allocated Standard public IPs. Most subscriptions have this unlocked by default; FDPO/restricted subs do not.
- **Failure mode:** `terraform apply` creates the VM successfully, then fails ~20 min in at `azurerm_public_ip.vpn_gw_pip1` with `SubscriptionNotRegisteredForFeature ... Microsoft.Network/AllowBringYourOwnPublicIpAddress`.
- **Pre-flight probe added:** Both `deploy.ps1` (`Test-Prereqs`) and `deploy.sh` (`check_prereqs`) now include a "Azure Standard public IP capability" step immediately after Azure subscription confirmation. The probe creates a temp RG and attempts `az network public-ip create --sku Standard`, cleans up the RG regardless, and exits with full fix instructions if the gated error is detected.
- **No auto-registration:** Per user preference, the scripts detect and explain only; they hand the user the exact three `az` commands to run once.
- **Bypass:** Set `SKIP_PIP_PRECHECK=1` to skip the probe (e.g., when subscription is known-good and you want to skip the ~30s probe).
- **Docs:** Added "Restricted subscriptions: Standard public IP gate" subsection to `terraform/README.md` Troubleshooting section.


- **Root cause:** Active `vm_admin_password` placeholder in `terraform/azure/terraform.tfvars` silently overrode strong password collected by `deploy.sh`/`deploy.ps1` due to Terraform variable precedence (tfvars > env var).
- **Guard implemented:** Both deploy wrappers now fail during prerequisite validation if `terraform/azure/terraform.tfvars` contains uncommented `vm_admin_password`.
- **Example file updated:** `terraform/azure/terraform.tfvars.example` keeps credentials commented with note explaining script supply behavior.
- **Decision #16 merged:** Trinity inbox decision merged into decisions.md; inbox file deleted.
- **Orchestration log:** 2026-06-18T02-30-trinity.md

### 2026-06-17 — Azure VPN Gateway AZ SKU Consolidation

- **Issue:** Live deployment failed with `400 NonAzSkusNotAllowedForVPNGateway: VpnGw1-5 non-AZ SKUs are no longer supported for VPN gateways. Only VpnGw1-5AZ SKUs can be created going forward.`
- **Root cause:** Azure has consolidated VPN gateway SKUs and now rejects legacy non-AZ variants (VpnGw1–VpnGw5).
- **Fix applied:** `terraform/azure/variables.tf` gateway_sku default changed to `VpnGw1AZ` with validation regex `^VpnGw[1-5]AZ$`; `terraform/azure/gateways.tf` vpn_gw_pip1/pip2 now set `zones = ["1","2","3"]` for zone-redundant Standard PIPs (required by AZ SKUs); `terraform.tfvars.example` example updated to VpnGw1AZ. Verified live — Azure accepted the VpnGw1AZ create.
- **Documentation added:** New troubleshooting subsection "VPN gateway SKU: AZ SKUs required (NonAzSkusNotAllowedForVPNGateway)" in `terraform/README.md` near the "Restricted subscriptions: Standard public IP gate" section documents the error, the AZ-only requirement, zone-redundant PIP configuration, and validation rules.

### 2026-06-19 — Standard public IP pre-check opt-in

- **Deploy pre-flight behavior:** `scripts/deploy.ps1` and `scripts/deploy.sh` now skip the Azure Standard public IP capability probe by default and print an ok/info line explaining `RUN_PIP_PRECHECK=1` enables it.
- **Opt-in env var:** Use `RUN_PIP_PRECHECK=1` to run the temp-RG Standard PIP probe before Terraform apply; `SKIP_PIP_PRECHECK` is retired.
- **User-facing guidance:** The failure message no longer suggests bypassing the check because the user explicitly opted in when it runs.

### 2026-06-19 — Import recovery after mid-apply machine reboot

**Trigger:** Machine rebooted mid `terraform apply`; Azure resources were created but state file was NOT written (OneDrive may have locked it during the write). Re-running `apply` failed with:
> `Error: A resource with the ID ".../virtualNetworkGateways/Az-Hub-ergw" already exists`

**Diagnosis steps:**
1. `terraform -chdir=terraform/azure state list` — verified what IS tracked.
2. Cross-referenced with `az network vnet-gateway show` and `az network vnet peering show` to find what existed in Azure but not in state.

**Resources missing from state (orphaned in Azure):**
- `azurerm_virtual_network_gateway.er` — `/subscriptions/78216abe-8139-4b45-8715-6bab2010101e/resourceGroups/lab-er-vpn-coexistence/providers/Microsoft.Network/virtualNetworkGateways/Az-Hub-ergw`

**Resources that did NOT exist in Azure yet (genuinely missing — need create):**
- `azurerm_virtual_network_peering.spoke1_to_hub`
- `azurerm_virtual_network_peering.spoke2_to_hub`

**Import command run:**
```powershell
$env:TF_VAR_vm_admin_password = 'Resume!Plan#2026Strong'
terraform -chdir=terraform/azure import `
  -var="vm_admin_username=azureuser" `
  'azurerm_virtual_network_gateway.er' `
  '/subscriptions/78216abe-8139-4b45-8715-6bab2010101e/resourceGroups/lab-er-vpn-coexistence/providers/Microsoft.Network/virtualNetworkGateways/Az-Hub-ergw'
```

**Post-import plan result (clean — no "already exists" conflicts):**
- `azurerm_virtual_network_gateway.er` — update in-place (add `public_ip_address_id` to ip_configuration)
- `azurerm_virtual_network_peering.spoke1_to_hub` — create
- `azurerm_virtual_network_peering.spoke2_to_hub` — create
- 3 VMs showed `-/+` ONLY because of the placeholder password used for planning — **NOT a real replacement issue**; when `deploy.ps1` is re-run with the original password, the VMs match state and are not touched.

**Password artifact warning:** Using a placeholder `TF_VAR_vm_admin_password` during `terraform plan`/`import` will show VM force-replacement in the plan diff (admin_password forces replacement). This is harmless for import; the actual apply via `deploy.ps1` with the real password will not replace the VMs.

**Resume command for the user:**
```powershell
./scripts/deploy.ps1 -AutoApprove
```
(Re-run will detect existing GCP state, keep `enable_onprem_connection=true`, apply only what is missing.)


### 2026-06-19 — Default RG rename + interactive prompt

- **New default RG name:** `lab-ervpn-coexist` (was `lab-er-vpn-coexistence`). Changed everywhere a hardcoded default existed: `terraform/azure/variables.tf`, `scripts/deploy.ps1`, `scripts/deploy.sh`, `scripts/cleanup-azure.ps1`, `scripts/cleanup-azure.sh`, `scripts/dump-routes-azure.ps1`, `scripts/dump-routes-azure.sh`, `terraform/azure/terraform.tfvars` (comment), `terraform/azure/terraform.tfvars.example` (comment), `terraform/README.md`, `README.md`, `archive/bicep/README.md`.
- **Interactive RG prompt (deploy.ps1):** `$DefaultAzureRG = 'lab-ervpn-coexist'` is the constant. `$script:AzureRG = ''` is initialized in the mutable state section. In `Get-RequiredInputs`, after the GCP zone block, an interactive-guarded prompt sets `$script:AzureRG` from user input or falls back to `$DefaultAzureRG` when empty or non-interactive.
- **Interactive RG prompt (deploy.sh):** `readonly DEFAULT_RG="lab-ervpn-coexist"` is the constant. `AZURE_RG=""` is in the mutable state section (NOT readonly). In `collect_inputs`, after the GCP zone block, `read -r -p "  Azure resource group [${DEFAULT_RG}]: "` sets `AZURE_RG` with `${in:-${DEFAULT_RG}}` fallback.
- **How the value flows to terraform:** Every `tf_apply`/`tf_destroy` call for `${AZURE_DIR}` (and `Invoke-Tf -Chdir $AzureDir`) now includes `-var resource_group_name=${AZURE_RG}` (bash) or `-var=resource_group_name=$($script:AzureRG)` (PowerShell). This overrides the default in `variables.tf` so the prompted RG name is what Terraform provisions. The `az` CLI calls in VPN verification and ExpressRoute status checks also use `$script:AzureRG` / `${AZURE_RG}`, keeping az and Terraform perfectly in sync.
- **Non-interactive / -AutoApprove path:** Both scripts silently fall back to `$DefaultAzureRG` / `${DEFAULT_RG}` when not interactive, so existing automation / CI is unaffected.

