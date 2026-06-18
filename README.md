# Azure VPN / ExpressRoute Coexistence using GCP as On-Premises

A hands-on lab that demonstrates **Site-to-Site VPN and ExpressRoute coexistence** on a single
Azure Hub-and-Spoke network, using **Google Cloud (GCP)** to simulate the on-premises site.

You first establish encrypted connectivity over an **IPsec S2S VPN** (the internet path), then bring
up an **ExpressRoute** private circuit (via a Megaport/partner cross-connect to a GCP Partner
Interconnect) and observe Azure automatically **prefer ExpressRoute over VPN** — with the VPN acting
as a backup path for failover testing.

This lab is **fully automated via Terraform** — no manual ARM/Bicep deployments needed.

> ⚠️ **Cost warning:** This lab provisions VPN/ExpressRoute gateways, an ExpressRoute circuit, and a
> partner cross-connect (Megaport). These are **billed hourly** and the ExpressRoute portion requires
> a real provider order. Always run the **Clean up** section when finished.

## Architecture diagram

![ExpressRoute VPN Coexistence](./media/er-vpn-coexistence-diagram.svg)

Editable source for this diagram lives in [`media/er-vpn-coexistence.mmd`](./media/er-vpn-coexistence.mmd).

| Side | Components |
|------|-----------|
| **Azure** | Hub VNet (`Az-Hub`) with an **active-active VPN Gateway** (`Az-Hub-vpngw`, BGP) and an **ExpressRoute Gateway** (`Az-Hub-ergw`) sharing the `GatewaySubnet`, plus a private test VM (no public IP). Two spoke VNets (`Az-Spk1`, `Az-Spk2`), each peered to the hub with one VM. |
| **On-prem (GCP)** | Custom-mode VPC + subnet, a **Classic VPN gateway** (IPsec/IKEv2), and an Ubuntu test VM. For ExpressRoute, a **Cloud Router** + **Partner Interconnect** VLAN attachment. |
| **Transport** | S2S VPN over the internet (static routing) **and** ExpressRoute private peering through a partner (Megaport). |

## Address plan

| Resource | CIDR |
|----------|------|
| Azure Hub VNet | `10.0.10.0/24` |
| &nbsp;&nbsp;Hub subnet1 (VM) | `10.0.10.0/27` |
| &nbsp;&nbsp;GatewaySubnet (VPN + ER gateways) | `10.0.10.32/27` |
| Azure Spoke1 VNet | `10.0.11.0/24` (subnet `10.0.11.0/27`) |
| Azure Spoke2 VNet | `10.0.12.0/24` (subnet `10.0.12.0/27`) |
| GCP on-prem (`vpnlab`) VPC | `192.168.0.0/24` |
| GCP second site (`vpnsite2`) VPC | `192.168.100.0/24` |

## Repository layout

| Path | Purpose |
|------|---------|
| [`terraform/azure/`](./terraform/azure/) | **Azure Terraform module** — deploys hub/spoke VNets, VPN gateway, ExpressRoute gateway, NSGs, and test VMs. Outputs: `vpn_gateway_public_ip`, `vpn_shared_key`, `expressroute_service_key`. |
| [`terraform/gcp/`](./terraform/gcp/) | **GCP Terraform module** — deploys on-premises VPC, Classic VPN gateway, Cloud Router (optional), Partner Interconnect (optional), and test VMs. Outputs: `gcp_vpn_public_ip`, `gcp_vpc_cidr`, `interconnect_pairing_key`. |
| [`deploy.sh`](./deploy.sh), [`deploy.ps1`](./deploy.ps1) | **Recommended deployment wrappers** - validate prerequisites, run the 3-apply Terraform flow, support optional ExpressRoute, and destroy in reverse order. |
| [`dump-routes-azure.sh`](./dump-routes-azure.sh), [`dump-routes-azure.ps1`](./dump-routes-azure.ps1) | Azure route inspection helpers for ExpressRoute circuit routes, VM effective routes, and ER gateway learned routes. |
| [`dump-routes-gcp.sh`](./dump-routes-gcp.sh), [`dump-routes-gcp.ps1`](./dump-routes-gcp.ps1) | GCP route inspection helpers for VPC routes, Cloud Router BGP status, VPN tunnel status, and tunnel routes. |
| [`terraform/README.md`](./terraform/README.md) | **Terraform runbook** - scripted deployment, manual 3-apply order, VPN verification, ExpressRoute provisioning, route inspection, coexistence testing, and cleanup. **Start here.** |
| [`archive/`](./archive/) | **Legacy lab automation** — original bash/PowerShell scripts and ARM/Bicep templates now superseded by Terraform. See [`archive/README.md`](./archive/README.md). Kept for reference only. |
| [`media/`](./media/) | Architecture diagrams (Mermaid/SVG). |

## Prerequisites

| Requirement | Minimum |
|---|---|
| Terraform | ≥ 1.5 (tested with 1.15.x) |
| Azure CLI | ≥ 2.5x, authenticated with Contributor on target subscription |
| gcloud CLI | authenticated with Application Default Credentials |
| GCP project | existing project ID with billing enabled |
| Megaport account | **only needed for Step 4 (ExpressRoute/Interconnect)** — optional |

For **detailed install commands** (Windows/Linux/macOS), **auth steps**, and **permission verification**, see **[Requirements & Setup in `terraform/README.md`](./terraform/README.md#requirements--setup)**.

## Quick Start - Scripted Deployment

The recommended path is the root deployment wrapper. It validates prerequisites, prompts for missing inputs, runs the 3-apply Terraform flow, and prints VPN verification commands.

Linux / macOS:

```bash
./deploy.sh check
./deploy.sh deploy --project my-gcp-project --location eastus2
```

Windows PowerShell:

```powershell
.\deploy.ps1 -Check
.\deploy.ps1 -Project my-gcp-project -Location eastus2
```

Optional ExpressRoute / Interconnect is billable and requires Megaport ordering:

```bash
./deploy.sh deploy --expressroute --project my-gcp-project
```

```powershell
.\deploy.ps1 -EnableExpressRoute -Project my-gcp-project
```

Destroy in reverse order with:

```bash
./deploy.sh destroy --auto-approve --project my-gcp-project
```

```powershell
.\deploy.ps1 -Destroy -AutoApprove -Project my-gcp-project
```

Prefer manual Terraform only when you need the advanced 3-apply walkthrough. See **[Scripted Deployment in `terraform/README.md`](./terraform/README.md#scripted-deployment-recommended)** for the full script interface and **[Manual / Advanced 3-Apply Walkthrough](./terraform/README.md#manual--advanced-3-apply-walkthrough)** for raw Terraform commands.

---

## For full details, verification, and cleanup

→ **[See `terraform/README.md`](./terraform/README.md)** for:
- **Pre-flight checklist** — what to verify before applying
- **Requirements & Setup** — install commands, auth steps, permission checks
- **Scripted Deployment** - recommended root wrappers for check, deploy, ExpressRoute, and destroy
- **Detailed step-by-step** with all Terraform variables and examples
- **Troubleshooting** — common issues and solutions
- **VPN verification** — connection status, end-to-end ping tests
- **[Network Test Tools](./terraform/README.md#network-test-tools)** - auto-installed VM utilities for ping, curl, iperf3, traceroute, nmap, and HTTP reachability checks
- **[Route Inspection](./terraform/README.md#route-inspection)** - root scripts for Azure and GCP route diagnostics
- **ExpressRoute + Interconnect** — full Megaport provisioning flow
- **Coexistence & failover testing** — observe Azure preferring ER over VPN

---

## Route inspection helpers

Use the root route dump scripts after deployment to inspect the data-path control plane:

```bash
./dump-routes-azure.sh
./dump-routes-gcp.sh --project my-gcp-project --region us-central1
```

```powershell
.\dump-routes-azure.ps1
.\dump-routes-gcp.ps1 -Project my-gcp-project -Region us-central1
```

The original `routes.azcli` and `routes.ps1` scripts are archived under [`archive/`](./archive/README.md) for reference only.

## Notes on GCP Classic VPN deprecation

> 🛈 **Routing note:** This lab uses **Classic VPN with static routing**, which remains supported.
> GCP has deprecated **BGP (dynamic routing) on Classic VPN** (2025‑08‑01) and recommends **HA VPN**
> for any new dynamic-routing/SLA-backed deployments. See
> [Classic VPN deprecation](https://cloud.google.com/network-connectivity/docs/vpn/deprecations/classic-vpn-deprecation).

## License

See [LICENSE](./LICENSE).

---

> Analysis only — verify against vendor documentation before applying.
