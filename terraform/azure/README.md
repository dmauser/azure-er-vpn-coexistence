# terraform/azure — Azure Hub-Spoke Lab (Terraform)

Native `azurerm` Terraform port of `bicep/main.bicep` and the Azure steps of `deploy.azcli`.  
Terraform ≥ 1.5 · provider `azurerm ~> 3.100` · local state (no remote backend).

## Quick start

```bash
cd terraform/azure
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — fill in vm_admin_username, vm_admin_password, restrict_ssh_source_prefix
terraform init
terraform plan
terraform apply
```

## Files

| File | Contents |
|------|----------|
| `providers.tf` | Terraform version constraint + `azurerm` / `random` providers |
| `variables.tf` | All input variables (see table below) |
| `main.tf` | Resource group, NSG, hub VNet, 2 spoke VNets, subnets, NSG associations, bidirectional peerings |
| `gateways.tf` | GatewaySubnet, VPN GW (active-active BGP, 2× public IPs), ExpressRoute GW (Standard) |
| `vm.tf` | 3 Ubuntu 22.04 LTS test VMs — one per VNet; names match `deploy.azcli` NIC refs |
| `vpn.tf` | Random PSK, GCP remote-state read, LNG `lng-onprem-gcp`, connection `Azure-to-OnpremGCP` |
| `expressroute.tf` | ER circuit `az-hub-er-circuit`, connection `ER-Connection-to-Onprem` |
| `outputs.tf` | Outputs consumed by Tank (orchestration) and Niobe (GCP Terraform) |
| `terraform.tfvars.example` | Template for required + optional inputs |

## Deployment phases

| Phase | Toggle | What it creates |
|-------|--------|-----------------|
| 1 — base lab | _(always)_ | RG · VNets · NSG · VPN GW · ER GW · 3 VMs |
| 2 — VPN to GCP | `enable_onprem_connection = true` | LNG `lng-onprem-gcp` · connection `Azure-to-OnpremGCP` |
| 3 — ExpressRoute | `enable_expressroute = true` | Circuit `az-hub-er-circuit` · connection `ER-Connection-to-Onprem` |

> **Phase 2 prerequisite:** GCP Terraform must be applied first so that  
> `gcp_vpn_public_ip` and `gcp_vpc_cidr` are present in `gcp_remote_state_path`.

## Key outputs (Tank / Niobe contract)

| Output | Description |
|--------|-------------|
| `vpn_gateway_public_ip` | VPN GW instance-0 IP — Niobe peers its GCP tunnel here |
| `vpn_shared_key` | Auto-generated PSK (**sensitive**) |
| `expressroute_service_key` | ER circuit service key (**sensitive**, null if disabled) |
| `resource_group_name` | RG name |
| `location` | Azure region |
| `hub_vnet_name` | Hub VNet name |

## Notes

- `terraform.tfvars` and `*.tfstate*` must be added to `.gitignore` (managed by Switch).
- Do **not** run `terraform apply` before reading the ExpressRoute provider's provisioning steps.
- VPN GW and ER GW share the GatewaySubnet — this is standard Azure coexistence topology.
