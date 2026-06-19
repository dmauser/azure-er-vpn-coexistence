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

## Contents

- [Architecture diagram](#architecture-diagram)
- [Address plan](#address-plan)
- [Prerequisites](#prerequisites)
- [Quick Start - Scripted Deployment](#quick-start---scripted-deployment)
- [For full details, verification, and cleanup](#for-full-details-verification-and-cleanup)
- [Route inspection helpers](#route-inspection-helpers)
- [Notes on GCP Classic VPN deprecation](#notes-on-gcp-classic-vpn-deprecation)
- [Repository layout](#repository-layout)
- [License](#license)

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

The recommended path is the deployment wrapper in [`scripts/`](./scripts/). It validates prerequisites, prompts for missing inputs, runs the 3-apply Terraform flow, and prints VPN verification commands.

Linux / macOS:

```bash
./scripts/deploy.sh check
./scripts/deploy.sh deploy --project my-gcp-project --location eastus2
```

Windows PowerShell:

```powershell
.\scripts\deploy.ps1 -Check
.\scripts\deploy.ps1 -Project my-gcp-project -Location eastus2
```

Optional ExpressRoute / Interconnect is billable and requires Megaport ordering:

```bash
./scripts/deploy.sh deploy --expressroute --project my-gcp-project
```

```powershell
.\scripts\deploy.ps1 -EnableExpressRoute -Project my-gcp-project
```

> ✅ Re-running with the ExpressRoute flag **keeps the existing VPN connection** in place
> (the wrapper detects the already-deployed GCP side), so VPN and ExpressRoute run side by
> side — the whole point of the coexistence lab.
>
> 🔒 The wrapper creates the ER **circuit**, prints the GCP pairing key and Azure service key,
> then checks the circuit's provisioning state. It attaches the **ER gateway connection only
> once the circuit is `Provisioned`** by the provider. If it isn't, the script stops and tells
> you to provision the circuit in Megaport with the printed keys, then re-run.

Destroy in reverse order with:

```bash
./scripts/deploy.sh destroy --auto-approve --project my-gcp-project
```

```powershell
.\scripts\deploy.ps1 -Destroy -AutoApprove -Project my-gcp-project
```

Or tear down **one cloud at a time** with the dedicated cleanup scripts. Destroy
**Azure first**, then GCP — the Azure VPN connection/Local Network Gateway are
planned from GCP's Terraform state. The scripts use `try()` state fallbacks so
either order works, but Azure-first is recommended:

```bash
./scripts/cleanup-azure.sh --auto-approve
./scripts/cleanup-gcp.sh --project my-gcp-project --auto-approve
```

```powershell
.\scripts\cleanup-azure.ps1 -AutoApprove
.\scripts\cleanup-gcp.ps1 -Project my-gcp-project -AutoApprove
```

> `cleanup-azure` also makes a best-effort `az network vpn-connection delete` of an
> orphaned `ER-Connection-to-Onprem` (requires `az login`; pass `-ResourceGroup` /
> `--resource-group` if your RG isn't `lab-er-vpn-coexistence`) and copies the peer
> state to a temp file to dodge OneDrive locks.

Prefer manual Terraform only when you need the advanced 3-apply walkthrough. See **[Scripted Deployment in `terraform/README.md`](./terraform/README.md#scripted-deployment-recommended)** for the full script interface and **[Manual / Advanced 3-Apply Walkthrough](./terraform/README.md#manual--advanced-3-apply-walkthrough)** for raw Terraform commands.

---

## For full details, verification, and cleanup

→ **[See `terraform/README.md`](./terraform/README.md)** for:
- **Pre-flight checklist** — what to verify before applying
- **Requirements & Setup** — install commands, auth steps, permission checks
- **Scripted Deployment** — recommended root wrappers for check, deploy, ExpressRoute, and destroy
- **Detailed step-by-step** with all Terraform variables and examples
- **Troubleshooting** — common issues and solutions
- **VPN verification** — connection status, end-to-end ping tests
- **[Network Test Tools](./terraform/README.md#network-test-tools)** — auto-installed VM utilities for ping, curl, iperf3, traceroute, nmap, and HTTP reachability checks
- **[Route Inspection](./terraform/README.md#route-inspection)** — `scripts/` helpers for Azure and GCP route diagnostics
- **ExpressRoute + Interconnect** — full Megaport provisioning flow
- **Coexistence & failover testing** — observe Azure preferring ER over VPN

---

## Route inspection helpers

After deployment, use the route-dump scripts in [`scripts/`](./scripts/) to inspect the data-path control plane. Each script verifies its CLI (`az` / `gcloud`) is installed and authenticated, shows the active subscription/project, prompts for defaults (override with flags or environment variables), and continues gracefully when a resource is disabled or not yet provisioned.

### Azure — `dump-routes-azure.sh` / `dump-routes-azure.ps1`

Prompts you to **select which components to dump** — each is independently selectable:

| # | Component | What it shows |
|---|---|---|
| 1 | `nics` | VM **effective routes** for each NIC (auto-discovered, or pass `--nics`) |
| 2 | `circuit` | **ExpressRoute circuit** routes (`AzurePrivatePeering` primary + secondary) |
| 3 | `ergw` | **ExpressRoute gateway** learned routes (and advertised, with `--advertised`) |
| 4 | `vpngw` | **VPN gateway** learned routes (and advertised, with `--advertised`) |

```bash
# Interactive: choose components at the prompt
./scripts/dump-routes-azure.sh

# Non-interactive: dump only the VPN gateway, including advertised routes
./scripts/dump-routes-azure.sh --components vpngw --advertised --yes

# Dump the ER gateway + circuit together
./scripts/dump-routes-azure.sh --components ergw,circuit
```

```powershell
.\scripts\dump-routes-azure.ps1
.\scripts\dump-routes-azure.ps1 -Components vpngw -Advertised -Yes
.\scripts\dump-routes-azure.ps1 -Components ergw,circuit
```

| Flag (bash) | Param (PowerShell) | Environment | Default |
|---|---|---|---|
| `--components` | `-Components` | `AZURE_ROUTE_COMPONENTS` | prompt (all) |
| `--resource-group` | `-ResourceGroup` | `AZURE_ROUTE_RG` | `lab-er-vpn-coexistence` |
| `--circuit-name` | `-CircuitName` | `AZURE_ROUTE_CIRCUIT` | terraform output or `az-hub-er-circuit` |
| `--er-gateway-name` | `-ErGatewayName` | `AZURE_ROUTE_ER_GATEWAY` | `Az-Hub-ergw` |
| `--vpn-gateway-name` | `-VpnGatewayName` | `AZURE_ROUTE_VPN_GATEWAY` | `Az-Hub-vpngw` |
| `--nics` | `-Nics` | `AZURE_ROUTE_NICS` | auto-discovered |
| `--advertised` | `-Advertised` | `AZURE_ROUTE_ADVERTISED` | off |
| `--yes` | `-Yes` | `AZURE_ROUTE_YES` | off (interactive) |

> `--advertised` discovers each BGP peer automatically and lists the routes advertised to every peer.

### GCP — `dump-routes-gcp.sh` / `dump-routes-gcp.ps1`

Prints a **friendly view**: a health summary (VPN tunnel up/down, gateway `READY`, static route present, Cloud Router/BGP state), key/value detail for the VPN tunnel, classic gateway, and tunnel-backed route, and labeled tables for VPC routes, forwarding rules, and firewall rules. Add `--raw` / `-Raw` for the full `gcloud` YAML when troubleshooting.

```bash
./scripts/dump-routes-gcp.sh --project my-gcp-project --region us-central1
./scripts/dump-routes-gcp.sh --project my-gcp-project --raw   # full gcloud detail
```

```powershell
.\scripts\dump-routes-gcp.ps1 -Project my-gcp-project -Region us-central1
.\scripts\dump-routes-gcp.ps1 -Project my-gcp-project -Raw
```

| Flag (bash) | Param (PowerShell) | Environment | Default |
|---|---|---|---|
| `--project` | `-Project` | `GCP_PROJECT` / `GOOGLE_CLOUD_PROJECT` | gcloud config |
| `--region` | `-Region` | `GCP_REGION` | `us-central1` |
| `--network` | `-Network` | `GCP_NETWORK` | `vpnlab-vpc` |
| `--router` | `-Router` | `GCP_ROUTER` | `vpnlab-router` |
| `--tunnel` | `-Tunnel` | `GCP_VPN_TUNNEL` | `vpn-to-azure` |
| `--gateway` | `-Gateway` | `GCP_VPN_GATEWAY` | `onpremvpn` |
| `--route` | `-Route` | `GCP_VPN_ROUTE` | `vpn-to-azure-route-1` |
| `--raw` | `-Raw` | — | off (friendly view) |
| `--no-prompt` | `-NoPrompt` | — | off (interactive) |

The original `routes.azcli` and `routes.ps1` scripts are archived under [`archive/`](./archive/README.md) for reference only.

## Notes on GCP Classic VPN deprecation

> 🛈 **Routing note:** This lab uses **Classic VPN with static routing**, which remains supported.
> GCP has deprecated **BGP (dynamic routing) on Classic VPN** (2025‑08‑01) and recommends **HA VPN**
> for any new dynamic-routing/SLA-backed deployments. See
> [Classic VPN deprecation](https://cloud.google.com/network-connectivity/docs/vpn/deprecations/classic-vpn-deprecation).

## Repository layout

| Path | Purpose |
|------|---------|
| [`terraform/azure/`](./terraform/azure/) | **Azure Terraform module** — deploys hub/spoke VNets, VPN gateway, ExpressRoute gateway, NSGs, and test VMs. Outputs: `vpn_gateway_public_ip`, `vpn_shared_key`, `expressroute_service_key`. |
| [`terraform/gcp/`](./terraform/gcp/) | **GCP Terraform module** — deploys on-premises VPC, Classic VPN gateway, Cloud Router (optional), Partner Interconnect (optional), and test VMs. Outputs: `gcp_vpn_public_ip`, `gcp_vpc_cidr`, `interconnect_pairing_key`. |
| [`scripts/`](./scripts/) | **All automation scripts** — deployment wrappers, per-cloud cleanup, and route-inspection helpers (see rows below). |
| [`scripts/deploy.sh`](./scripts/deploy.sh), [`scripts/deploy.ps1`](./scripts/deploy.ps1) | **Recommended deployment wrappers** — validate prerequisites, run the 3-apply Terraform flow, support optional ExpressRoute, and destroy in reverse order. |
| [`scripts/cleanup-azure.sh`](./scripts/cleanup-azure.sh), [`scripts/cleanup-azure.ps1`](./scripts/cleanup-azure.ps1) | **Azure-only teardown** — `terraform destroy` of the Azure module. Run **before** the GCP cleanup. |
| [`scripts/cleanup-gcp.sh`](./scripts/cleanup-gcp.sh), [`scripts/cleanup-gcp.ps1`](./scripts/cleanup-gcp.ps1) | **GCP-only teardown** — `terraform destroy` of the GCP module. Run **after** the Azure cleanup. |
| [`scripts/dump-routes-azure.sh`](./scripts/dump-routes-azure.sh), [`scripts/dump-routes-azure.ps1`](./scripts/dump-routes-azure.ps1) | Azure route inspection helpers. Prompt to select which components to dump — VMs/NICs effective routes, ExpressRoute circuit routes, ExpressRoute gateway routes, and VPN gateway routes (each independently selectable). |
| [`scripts/dump-routes-gcp.sh`](./scripts/dump-routes-gcp.sh), [`scripts/dump-routes-gcp.ps1`](./scripts/dump-routes-gcp.ps1) | GCP route inspection helpers. Print a friendly health summary (VPN tunnel, gateway, static route, BGP) plus readable VPN tunnel/route detail and labeled tables for VPC routes, forwarding rules, and firewall rules. Add `--raw`/`-Raw` for full gcloud YAML. |
| [`terraform/README.md`](./terraform/README.md) | **Terraform runbook** — scripted deployment, manual 3-apply order, VPN verification, ExpressRoute provisioning, route inspection, coexistence testing, and cleanup. **Start here.** |
| [`archive/`](./archive/) | **Legacy lab automation** — original bash/PowerShell scripts and ARM/Bicep templates now superseded by Terraform. See [`archive/README.md`](./archive/README.md). Kept for reference only. |
| [`media/`](./media/) | Architecture diagrams (Mermaid/SVG). |

## License

See [LICENSE](./LICENSE).
