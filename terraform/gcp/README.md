# terraform/gcp — GCP "on-premises" Terraform module

Ports the GCP steps from [`deploy.azcli`](../../deploy.azcli) to native `google` provider HCL.

## What this creates

| Resource | Name (default) | Purpose |
|----------|---------------|---------|
| VPC (custom-mode) | `vpnlab-vpc` | Isolated on-prem network |
| Subnet | `vpnlab-subnet` | `192.168.0.0/24` |
| Firewall rule | `vpnlab-allow-traffic-from-azure` | TCP/UDP/ICMP from RFC1918 + IAP + caller IP |
| Ubuntu 22.04 VM | `vpnlab-vm1` | e2-micro test VM |
| Classic VPN gateway | `onpremvpn` | Target VPN gateway |
| Static IP | `onpremvpn-pip` | Public IP for VPN (→ Azure LNG) |
| Forwarding rules | `onpremvpn-rule-{esp,udp500,udp4500}` | ESP + IKE + NAT-T |
| VPN tunnel | `vpn-to-azure` | IKEv2, static 0.0.0.0/0 selectors |
| Route | `vpn-to-azure-route-1` | `10.0.0.0/8` → tunnel |
| Cloud Router *(flag)* | `vpnlab-router` | BGP ASN 16550 for Interconnect |
| Partner Interconnect *(flag)* | `vpnlab-vlan` | VLAN attachment, `AVAILABILITY_DOMAIN_1` |

> ⚠️ **Classic VPN deprecation:** GCP deprecated BGP on Classic VPN (2025-08-01). This lab uses
> **static routing** on Classic VPN, which remains supported. See the [GCP deprecation notice](https://cloud.google.com/network-connectivity/docs/vpn/deprecations/classic-vpn-deprecation).

## Prerequisites

1. [Terraform ≥ 1.5](https://developer.hashicorp.com/terraform/install)
2. GCP Application Default Credentials: `gcloud auth application-default login`
3. The Azure module (`terraform/azure/`) must be applied first so its state file exists at
   `../azure/terraform.tfstate` (or override `azure_remote_state_path`).

## Quick start

```bash
cd terraform/gcp

# Copy and edit variables
cp terraform.tfvars.example terraform.tfvars
# Set: project, caller_source_ip

terraform init
terraform plan
terraform apply
```

## Deployment order (3-apply sequence)

1. `terraform/azure/` — provisions Azure resources and writes `vpn_gateway_public_ip` + `vpn_shared_key` to its state.
2. **`terraform/gcp/`** (this module) — reads Azure state, builds GCP VPC/VM/VPN.
3. `terraform/azure/` again — Local Network Gateway + VPN Connection (reads `gcp_vpn_public_ip` from GCP state).

## Enabling Partner Interconnect

```hcl
# terraform.tfvars
enable_interconnect = true
```

After `apply`, retrieve the pairing key and provide it to your connectivity provider:

```bash
terraform output -raw interconnect_pairing_key
```

## Outputs

| Output | Description |
|--------|-------------|
| `gcp_vpn_public_ip` | VPN gateway public IP — used as Azure LNG gateway IP |
| `gcp_vpc_cidr` | GCP subnet CIDR — used as Azure LNG address prefix |
| `interconnect_pairing_key` *(sensitive)* | Pairing key for provider VXC order |
| `interconnect_attachment_name` | VLAN attachment name |
