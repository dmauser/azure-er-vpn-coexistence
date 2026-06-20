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
> a real provider order. Always run the **Cleanup** section when finished.

## Contents

- [Architecture diagram](#architecture-diagram)
- [Address plan](#address-plan)
- [Pre-flight Checklist](#pre-flight-checklist)
- [How this lab works (3-apply flow)](#how-this-lab-works-3-apply-flow)
- [Quick Start (experienced users)](#quick-start-experienced-users)
- [First-time guided deployment](#first-time-guided-deployment)
- [Success checkpoints](#success-checkpoints)
- [Optional ExpressRoute + Megaport](#optional-expressroute--megaport)
- [Cleanup (destroy resources)](#cleanup-destroy-resources)
- [Troubleshooting jumpstart](#troubleshooting-jumpstart)
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

## Pre-flight Checklist

Verify these before starting. A missed item is the #1 cause of failed first runs.

**Tools & CLIs:**
- [ ] **Terraform ≥ 1.5** — run `terraform -version`
- [ ] **Azure CLI installed** — run `az version`
- [ ] **gcloud CLI installed** — run `gcloud --version`

**Authentication & credentials:**
- [ ] **Azure login done** — run `az login` (or `az login --use-device-code` for headless shells)
- [ ] **Correct Azure subscription set** — run `az account show --output table` and verify
- [ ] **GCP user login done** — run `gcloud auth login`
- [ ] **GCP Application Default Credentials set** — run `gcloud auth application-default login`
- [ ] **GCP project configured** — run `gcloud config set project <PROJECT_ID>` with your project
- [ ] **Compute Engine API enabled in GCP** — run `gcloud services enable compute.googleapis.com`

**Configuration:**
- [ ] **Your public IP captured** (needed for GCP firewall allow-list):
  ```bash
  # Linux/macOS
  curl -4 ifconfig.io
  # Windows PowerShell
  (Invoke-RestMethod -Uri 'https://ifconfig.io')
  ```
  Note: If your ISP/VPN reassigns IPs between sessions, you will need to update GCP `caller_source_ip` and re-apply.

- [ ] **Strong VM password chosen** — Azure requires ≥ 12 characters with at least 3 of: uppercase, lowercase, digit, special character.

For detailed install steps (Windows/Linux/macOS) and permission checks, see **[Requirements & Setup in `terraform/README.md`](./terraform/README.md#requirements--setup)**.

## How this lab works (3-apply flow)

The deployment uses a **3-step Terraform apply** to break circular dependencies between Azure and GCP:

1. **Azure base** (Step 1)  
   - Creates Azure VNets, VPN Gateway, ExpressRoute Gateway, and test VMs.
   - After apply, the VPN Gateway has a public IP and a pre-shared key. ✅
   
2. **GCP full** (Step 2)  
   - Reads the Azure VPN Gateway public IP and pre-shared key from Azure state.
   - Creates GCP VPC, Classic VPN gateway, VPN tunnel (now has its own public IP), and test VMs.
   - After apply, GCP gateway public IP is ready. ✅
   
3. **Azure connection** (Step 3)  
   - Reads the GCP gateway public IP from GCP state.
   - Creates the Azure Local Network Gateway and VPN connection.
   - Tunnel comes up. VPN verified. ✅

**Why this order?** Azure needs its IP to seed GCP's tunnel config. GCP needs to output its IP so Azure can build the connection. A single apply would deadlock; three sequential applies resolve it.

The deployment scripts handle this automatically. For manual Terraform, see **[Manual 3-Apply Walkthrough in `terraform/README.md`](./terraform/README.md#manual--advanced-3-apply-walkthrough)**.

---

## Quick Start (experienced users)

If you have already completed the pre-flight checklist and are comfortable with Terraform:

**Linux / macOS:**
```bash
./scripts/deploy.sh check           # Validate prerequisites
./scripts/deploy.sh deploy --project my-gcp-project --location eastus2
```

**Windows PowerShell:**
```powershell
.\scripts\deploy.ps1 -Check
.\scripts\deploy.ps1 -Project my-gcp-project -Location eastus2
```

For destroy (reverse order: Azure first, then GCP):
```bash
./scripts/deploy.sh destroy --auto-approve --project my-gcp-project
```

```powershell
.\scripts\deploy.ps1 -Destroy -AutoApprove -Project my-gcp-project
```

---

## First-time guided deployment

Follow these steps in order if this is your first time, or if you want to understand the process.

### Step 1: Clone the repository and navigate to it

```bash
git clone https://github.com/dmauser/azure-er-vpn-coexistence2.git
cd azure-er-vpn-coexistence2
```

### Step 2: Verify the pre-flight checklist

Go back to the **[Pre-flight Checklist](#pre-flight-checklist)** above and tick every box. Open a terminal and run the commands listed. If any command fails, stop and fix it before proceeding.

### Step 3: Decide on location and credentials

Decide on:
- **Azure location** (e.g., `eastus2`, `westeurope`, `centralus`) — defaults to `centralus`
- **GCP region** (e.g., `us-central1`, `europe-west1`) — defaults to `us-central1`
- **VM admin username** (e.g., `azureuser`) — used for RDP/Serial Console access
- **VM admin password** — must be ≥ 12 characters with uppercase, lowercase, digit, and special character

### Step 4: Run the deployment script with your values

**Linux / macOS:**
```bash
./scripts/deploy.sh deploy \
  --project my-gcp-project \
  --location eastus2 \
  --region us-central1 \
  --vm-username azureuser \
  --vm-password 'YourP@ss123!'
```

**Windows PowerShell:**
```powershell
.\scripts\deploy.ps1 `
  -Project my-gcp-project `
  -Location eastus2 `
  -Region us-central1 `
  -VmUsername azureuser `
  -VmPassword 'YourP@ss123!'
```

> **Note:** If you don't provide `--vm-password` / `-VmPassword`, the script will prompt you to enter it securely. The same applies for other unspecified arguments.

### Step 5: Watch the deployment

The script will:
1. Validate all prerequisites and print a summary.
2. Run the **Azure base** apply (creates VPN Gateway).
3. Run the **GCP full** apply (creates tunnel with Azure's IP).
4. Run the **Azure connection** apply (completes the VPN).
5. Print success messages and next steps.

The first run typically takes **10–15 minutes** depending on region and Terraform state initialization.

### Step 6: Verify the VPN is up

Once deployment finishes, the script prints verification commands. To manually verify:

**From the GCP side:**
```bash
gcloud compute vpn-tunnels describe vpn-to-azure --project my-gcp-project --region us-central1
```

Look for `status: ESTABLISHED`.

**From the Azure side** (requires Azure CLI and Serial Console access to the Hub VM):
```bash
az network vpn-connection list \
  --resource-group lab-ervpn-coexist \
  --output table
```

Look for `ConnectionStatus: Connected`.

---

## Success checkpoints

Your deployment is **complete and working** when:

✅ **Terraform apply(s) complete** with no errors.

✅ **GCP VPN tunnel status is `ESTABLISHED`:**
```bash
gcloud compute vpn-tunnels describe vpn-to-azure --project my-gcp-project --region us-central1 | grep status
```

✅ **Azure VPN connection status is `Connected`:**
```bash
az network vpn-connection show \
  --name Azure-to-OnpremGCP \
  --resource-group lab-ervpn-coexist \
  --output table
```

✅ **End-to-end ping works** (from GCP to Azure VM across the tunnel):
```bash
# SSH into GCP test VM, then ping the Azure Hub VM
# GCP VM IP: 192.168.0.10 → Azure Hub VM IP: 10.0.10.10
gcloud compute ssh vm-onprem --project my-gcp-project --zone us-central1-c
# Inside GCP VM:
ping 10.0.10.10 -c 4
```

✅ **Route entries exist** in both clouds:
```bash
# Azure: check route table for 192.168.0.0/24 via VPN Gateway
az network route-table route list \
  --resource-group lab-ervpn-coexist \
  --route-table-name hub-rt \
  --output table

# GCP: check route for 10.0.10.0/24 via VPN tunnel
gcloud compute routes list --project my-gcp-project --filter="name:vpn*"
```

If any checkpoint fails, see **[Troubleshooting jumpstart](#troubleshooting-jumpstart)** below.

---

## Optional ExpressRoute + Megaport

Once the VPN is working, you can add **ExpressRoute + Partner Interconnect** to test coexistence and failover.

> 🔔 **Important:** ExpressRoute and Megaport provisioning involves **third-party ordering and billing**. Read the section below before proceeding.

### What it requires

- **Megaport account** — free to sign up at https://www.megaport.com. You control and pay for the service.
- **Megaport service setup** — Megaport hosts the cross-connect between you and GCP. This is a **real service** — it is billable and requires manual provisioning steps.
- **ExpressRoute service key** — Azure generates this; Megaport uses it to create the service.
- **GCP Partner Interconnect pairing key** — GCP generates this; Megaport uses it to create the connection.

### Cost note

- **ExpressRoute circuit** (Azure): billable from the moment it is created, even if not yet connected.
- **Megaport service** (third-party): typically $25–50 USD/month for a lab-scale 1 Gbps port.
- **GCP Partner Interconnect**: free (you pay Megaport for the cross-connect).

Once provisioned, the VPN stays active as a **backup path**. Azure will prefer ExpressRoute (lower BGP metric) over VPN for normal operations.

### Provisioning steps

1. **Deploy ExpressRoute circuit and Megaport service:**
   ```bash
   ./scripts/deploy.sh deploy --expressroute --project my-gcp-project
   ```
   ```powershell
   .\scripts\deploy.ps1 -EnableExpressRoute -Project my-gcp-project
   ```

2. **Script output will print:**
   - **ExpressRoute service key** — copy this
   - **GCP Partner Interconnect pairing key** — copy this
   - **Megaport deployment name** (e.g., `Megaport-ER-GCP-2024-06-19...`)

3. **In Megaport portal:**
   - Log in to https://portal.megaport.com
   - Create a new **Port** (1 Gbps, select Azure region matching your ExpressRoute circuit location)
   - Create a **Virtual Cross Connect** from the Port to Azure (paste the service key you copied)
   - Create another **Virtual Cross Connect** to GCP Partner Interconnect (paste the GCP pairing key)
   - Wait for status to change to `UP` (typically 5–15 minutes)

4. **Verify circuit is provisioned:**
   ```bash
   az network express-route show \
     --name az-hub-er-circuit \
     --resource-group lab-ervpn-coexist \
     --output table
   ```
   Look for `provisioningState: Succeeded` and `circuitProvisioningState: Provisioned`.

5. **Verify GCP Interconnect is up:**
   ```bash
   gcloud compute interconnects attachments describe er-to-onprem-vlan \
     --project my-gcp-project \
     --region us-central1
   ```
   Look for `state: ACTIVE`.

For a deeper walkthrough, see **[ExpressRoute + Interconnect in `terraform/README.md`](./terraform/README.md#expressroute--interconnect)**.

---

## Cleanup (destroy resources)

Always clean up when you are finished to avoid ongoing charges.

> ⚠️ **Order matters:** Destroy **Azure first**, then **GCP**.  
> Why? The Azure VPN connection references the GCP Gateway IP in the Local Network Gateway. If GCP is destroyed first, Azure's state refers to a non-existent resource. The cleanup scripts use state fallbacks to handle either order, but Azure-first is recommended and cleaner.

### Option A: Full destroy (recommended)

Destroys both Azure and GCP in the correct order:

**Linux / macOS:**
```bash
./scripts/deploy.sh destroy --auto-approve --project my-gcp-project
```

**Windows PowerShell:**
```powershell
.\scripts\deploy.ps1 -Destroy -AutoApprove -Project my-gcp-project
```

### Option B: Cloud-by-cloud cleanup

For granular control, clean each cloud separately. Always do **Azure first**:

**Azure cleanup (always first):**
```bash
./scripts/cleanup-azure.sh --auto-approve
```
```powershell
.\scripts\cleanup-azure.ps1 -AutoApprove
```

Then **GCP cleanup:**
```bash
./scripts/cleanup-gcp.sh --project my-gcp-project --auto-approve
```
```powershell
.\scripts\cleanup-gcp.ps1 -Project my-gcp-project -AutoApprove
```

### Cleanup details

- **`cleanup-azure.sh/ps1`** removes the Azure Hub and Spoke VNets, VPN Gateway, ExpressRoute Gateway, and test VMs. It also attempts to clean up any orphaned `ER-Connection-to-Onprem` (failover artifact). Requires `az login`.
- **`cleanup-gcp.sh/ps1`** removes the GCP VPC, Classic VPN gateway, test VM, and optionally the Partner Interconnect if it was created.

### Verify deletion

Check that resources are gone:

**Azure:**
```bash
az network vnet list --resource-group lab-ervpn-coexist --output table
```
Should be empty.

**GCP:**
```bash
gcloud compute networks list --project my-gcp-project --filter="name:vpnlab"
```
Should be empty.

---

## Troubleshooting jumpstart

### Issue: Terraform plan/apply fails with "subscription not found"

**Cause:** Azure CLI is not authenticated or the subscription is not set.

**Fix:**
```bash
az login
az account show --output table
az account set --subscription <SUBSCRIPTION_ID>
```

### Issue: "gcloud" not in PATH or command not found

**Cause:** gcloud SDK is not installed or not in your shell's PATH.

**Fix:**
- **Windows:** Install via `winget install Google.CloudSDK` and restart your terminal.
- **Linux/macOS:** Run `curl https://sdk.cloud.google.com | bash`, then restart your terminal.
- Verify: `gcloud --version`

### Issue: GCP VPN tunnel status is `DOWN` or `UNKNOWN`

**Cause:** IKE/IPsec negotiation is failing (usually bad pre-shared key, wrong public IPs, firewall blocking).

**Check:**
```bash
# View tunnel detail
gcloud compute vpn-tunnels describe vpn-to-azure --project my-gcp-project --region us-central1

# View tunnel error logs
gcloud compute vpn-tunnels describe vpn-to-azure --project my-gcp-project --region us-central1 | grep -i error
```

**Common fixes:**
- Verify the Azure VPN Gateway public IP matches what GCP tunnel is configured to reach. Check Terraform outputs:
  ```bash
  cd terraform/azure && terraform output vpn_gateway_public_ip
  cd ../gcp && terraform output gcp_vpn_public_ip
  ```
- Verify the pre-shared key matches in both clouds. Regenerate if needed and run the 3-apply cycle again.

### Issue: Azure VPN connection shows `Unknown` or `Disconnected`

**Cause:** Azure hasn't picked up the GCP gateway IP, or the connection resource is misconfigured.

**Check:**
```bash
az network vpn-connection show \
  --name Azure-to-OnpremGCP \
  --resource-group lab-ervpn-coexist \
  --output json | jq '.connectionStatus, .connectionProtocol'
```

**Fix:** Re-run the Azure connection apply (Step 3 of the 3-apply):
```bash
cd terraform/azure
terraform apply -auto-approve
```

### Issue: Ping test fails between VMs

**Cause:** NSG firewall rules are blocking traffic, or routes are missing.

**Check routes:**
```bash
# Azure: does hub route table have a route to 192.168.0.0/24?
az network route-table route list \
  --resource-group lab-ervpn-coexist \
  --route-table-name hub-rt \
  --output table

# GCP: does VPC have a route to 10.0.10.0/24?
gcloud compute routes list --project my-gcp-project --filter="network:vpnlab"
```

**Check NSGs:**
```bash
# Azure: is there an inbound NSG rule allowing ICMP from 192.168.0.0/24?
az network nsg rule list \
  --resource-group lab-ervpn-coexist \
  --nsg-name hub-nsg \
  --output table
```

**Check firewall rules:**
```bash
# GCP: is there an ingress firewall rule allowing ICMP from 10.0.10.0/24?
gcloud compute firewall-rules list --project my-gcp-project --filter="network:vpnlab"
```

### Issue: ExpressRoute circuit stays in `ProvisioningState: NotProvisioned`

**Cause:** Megaport hasn't created and activated the service yet, or the service key wasn't used correctly.

**Check:**
```bash
az network express-route show \
  --name az-hub-er-circuit \
  --resource-group lab-ervpn-coexist
```

**Fix:**
1. Log in to Megaport portal.
2. Verify the Virtual Cross Connect exists and status is `UP`.
3. Check that the service key was correctly entered in Megaport.
4. Wait 10–15 minutes and re-check. Megaport provisioning can be slow.
5. If still stuck, contact Megaport support.

### Issue: I want to destroy ExpressRoute but keep VPN

**Cause:** You want to test failover or reduce costs temporarily.

**Fix:** Run `terraform destroy` on just the ExpressRoute resources in the Terraform state, or delete the ExpressRoute circuit in the Azure portal. The VPN will remain active.

---

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
| `--resource-group` | `-ResourceGroup` | `AZURE_ROUTE_RG` | `lab-ervpn-coexist` |
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

## Key / secret dump helpers

Use these to print the connection secrets to the console (for pasting into a provider portal or the peer cloud). Each verifies its CLI is authenticated and continues gracefully when a resource is disabled or unprovisioned. **The values are sensitive — do not capture this output into logs.**

### Azure — `dump-keys-azure.sh` / `dump-keys-azure.ps1`

Prints the **ExpressRoute circuit service key** (the key you give the connectivity provider). Reads it from `terraform output -raw expressroute_service_key` when available, otherwise falls back to `az network express-route show --query serviceKey`.

```bash
./scripts/dump-keys-azure.sh
./scripts/dump-keys-azure.sh --resource-group lab-ervpn-coexist --circuit-name az-hub-er-circuit --yes
```

```powershell
.\scripts\dump-keys-azure.ps1
.\scripts\dump-keys-azure.ps1 -ResourceGroup lab-ervpn-coexist -CircuitName az-hub-er-circuit -Yes
```

| Flag (bash) | Param (PowerShell) | Environment | Default |
|---|---|---|---|
| `--resource-group` | `-ResourceGroup` | `AZURE_KEYS_RG` | `lab-ervpn-coexist` |
| `--circuit-name` | `-CircuitName` | `AZURE_KEYS_CIRCUIT` | terraform output or `az-hub-er-circuit` |
| `--yes` | `-Yes` | `AZURE_KEYS_YES` | off (interactive) |

### GCP — `dump-keys-gcp.sh` / `dump-keys-gcp.ps1`

Prints the **Partner Interconnect VLAN attachment pairing key** (the key you hand to the connectivity provider to provision the VXC). Reads it from the GCP module's `terraform output -raw interconnect_pairing_key` when available, otherwise falls back to `gcloud compute interconnects attachments describe --format="value(pairingKey)"`. Requires `enable_interconnect = true`.

```bash
./scripts/dump-keys-gcp.sh --project my-gcp-project --region us-central1
```

```powershell
.\scripts\dump-keys-gcp.ps1 -Project my-gcp-project -Region us-central1
```

| Flag (bash) | Param (PowerShell) | Environment | Default |
|---|---|---|---|
| `--project` | `-Project` | `GCP_PROJECT` / `GOOGLE_CLOUD_PROJECT` | gcloud config |
| `--region` | `-Region` | `GCP_REGION` | `us-central1` |
| `--attachment` | `-Attachment` | `GCP_INTERCONNECT_ATTACHMENT` | terraform output or `vpnlab-vlan` |
| `--no-prompt` | `-NoPrompt` | — | off (interactive) |

---

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
| [`scripts/dump-keys-azure.sh`](./scripts/dump-keys-azure.sh), [`scripts/dump-keys-azure.ps1`](./scripts/dump-keys-azure.ps1) | Print the ExpressRoute circuit **service key** (from terraform output or `az network express-route show`). Sensitive output. |
| [`scripts/dump-keys-gcp.sh`](./scripts/dump-keys-gcp.sh), [`scripts/dump-keys-gcp.ps1`](./scripts/dump-keys-gcp.ps1) | Print the Partner Interconnect VLAN attachment **pairing key** — from the GCP `interconnect_pairing_key` output or `gcloud compute interconnects attachments describe`. Sensitive output. Requires `enable_interconnect = true`. |
| [`terraform/README.md`](./terraform/README.md) | **Terraform runbook** — scripted deployment, manual 3-apply order, VPN verification, ExpressRoute provisioning, route inspection, coexistence testing, and cleanup. **Start here.** |
| [`archive/`](./archive/) | **Legacy lab automation** — original bash/PowerShell scripts and ARM/Bicep templates now superseded by Terraform. See [`archive/README.md`](./archive/README.md). Kept for reference only. |
| [`media/`](./media/) | Architecture diagrams (Mermaid/SVG). |

## License

See [LICENSE](./LICENSE).
