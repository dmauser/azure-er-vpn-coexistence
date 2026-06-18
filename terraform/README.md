# Azure ER/VPN Coexistence Lab — Terraform Runbook

**Two independent local-state configs wired via `terraform_remote_state`.**

```
terraform/
  azure/   ← Trinity's config  (azurerm + random providers)
  gcp/     ← Niobe's config    (google provider)
```

---

## Why a 3-apply order?

Azure must generate the VPN gateway public IP and the pre-shared key **before** GCP can create its tunnel.  
GCP must expose its own gateway public IP **before** Azure can create the Local Network Gateway.  
These circular dependencies are broken by splitting the work into three sequential applies:

1. **Azure base** — builds the VPN gateway (IP known after apply).
2. **GCP full** — reads Azure IP + shared key from Azure state, creates tunnel.
3. **Azure connection** — reads GCP IP from GCP state, creates LNG + VPN connection.

---

## Prerequisites

| Requirement | Minimum |
|---|---|
| Terraform | ≥ 1.5 |
| Azure CLI | logged in (`az login`) with Contributor on the target subscription |
| gcloud CLI | Application Default Credentials configured (`gcloud auth application-default login`) |
| GCP project | existing project ID with billing enabled |
| Megaport account | **only needed for Step 4 (ExpressRoute/Interconnect)** — optional |

---

## Step 1 — Azure base apply

```bash
cd terraform/azure
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` and set the **three required values**:

```hcl
vm_admin_username          = "azureuser"
vm_admin_password          = "YourStr0ngP@ssword!"   # min 12 chars
restrict_ssh_source_prefix = "203.0.113.5/32"        # your public IP + /32
```

Leave `enable_onprem_connection = false` (the default). Do **not** set it yet — GCP state doesn't exist yet.

```bash
terraform init
terraform apply
```

After apply, two outputs are relevant to GCP:

| Output | Sensitive | Purpose |
|---|---|---|
| `vpn_gateway_public_ip` | no | GCP VPN tunnel peer address |
| `vpn_shared_key` | **yes** | IKEv2 pre-shared key (never printed by default) |

> The shared key is stored only in `terraform.tfstate`. Protect this file.

---

## Step 2 — GCP apply

```bash
cd ../gcp
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` and set the **two required values**:

```hcl
project          = "your-gcp-project-id"
caller_source_ip = "203.0.113.5"   # your public IP, no mask
```

Optional overrides (defaults shown):

```hcl
# region                  = "us-central1"
# zone                    = "us-central1-c"
# vpc_range               = "192.168.0.0/24"
# envname                 = "vpnlab"
# azure_remote_state_path = "../azure/terraform.tfstate"   # default
```

`azure_remote_state_path` must point to the state file written by Step 1. The default `../azure/terraform.tfstate` works when both modules are in this repo at their standard paths.

```bash
terraform init
terraform apply
```

GCP reads `vpn_gateway_public_ip` and `vpn_shared_key` automatically from Azure state. After apply:

| Output | Purpose |
|---|---|
| `gcp_vpn_public_ip` | Azure Local Network Gateway peer address (used in Step 3) |
| `gcp_vpc_cidr` | GCP subnet CIDR advertised to Azure (default `192.168.0.0/24`) |

---

## Step 3 — Azure connection apply

Return to the Azure module and enable the on-premises connection:

```bash
cd ../azure
```

In `terraform.tfvars`, add or uncomment:

```hcl
enable_onprem_connection = true
# gcp_remote_state_path = "../gcp/terraform.tfstate"   # default — adjust only if needed
```

```bash
terraform apply
```

This creates:
- **Local Network Gateway** `lng-onprem-gcp` — GCP's public IP as the on-prem endpoint.
- **VPN Connection** `Azure-to-OnpremGCP` — IPsec IKEv2, using the same pre-shared key generated in Step 1.

**At this point the Site-to-Site VPN should come up.** Both sides now have each other's IPs and share the same pre-shared key.

---

## VPN Verification

**Azure — check connection status:**

```bash
az network vpn-connection show \
  --name Azure-to-OnpremGCP \
  --resource-group lab-er-vpn-coexistence \
  --query connectionStatus
```

Expected: `"Connected"`

**GCP — check tunnel status:**

```bash
gcloud compute vpn-tunnels describe vpn-to-azure \
  --region us-central1
```

Look for `status: ESTABLISHED`.

**End-to-end — ping from GCP VM to Azure VMs:**

```bash
# SSH into the GCP VM (use IAP or the external IP from GCP console)
ping 10.0.10.4   # Az-Hub VM
ping 10.0.11.4   # Az-Spk1 VM
ping 10.0.12.4   # Az-Spk2 VM
```

All three should reply within the tunnel.

---

## Step 4 — ExpressRoute + Interconnect (optional, billable)

> ⚠️ This step provisions **billable** cloud resources and requires a **Megaport** account.

### 4a — Deploy ER circuit (Azure) and Interconnect attachment (GCP)

In `terraform/gcp/terraform.tfvars`:

```hcl
enable_interconnect = true
```

In `terraform/azure/terraform.tfvars`:

```hcl
enable_expressroute = true
# express_route_peering_location = "Chicago"   # default
# express_route_provider         = "Megaport"  # default
# express_route_bandwidth_mbps   = 50          # default
```

Apply GCP first (Cloud Router + VLAN attachment), then Azure (ER circuit):

```bash
terraform -chdir=terraform/gcp apply
terraform -chdir=terraform/azure apply
```

### 4b — Retrieve the pairing keys

```bash
# GCP Partner Interconnect pairing key → give to Megaport for the GCP VXC
terraform -chdir=terraform/gcp output -raw interconnect_pairing_key

# Azure ExpressRoute service key → give to Megaport for the Azure VXC
terraform -chdir=terraform/azure output -raw expressroute_service_key
```

### 4c — Order VXCs in Megaport

1. Log in to the [Megaport portal](https://portal.megaport.com/).
2. Create a **VXC to Google Cloud** — paste the **GCP pairing key** when prompted.
3. Create a **VXC to Azure ExpressRoute** — paste the **Azure service key** when prompted.
4. Wait for both VXCs to show **Active** and the Azure ER circuit to show **Provisioned** in the Azure portal.

### 4d — Attach the ER circuit to the ER gateway

Once the circuit is provisioned, re-run the Azure apply to create the ER gateway connection:

```bash
terraform -chdir=terraform/azure apply
```

This attaches circuit `az-hub-er-circuit` to the ER gateway via connection `ER-Connection-to-Onprem` (routing weight 0).

---

## Coexistence / Failover Test

With both VPN and ExpressRoute up, Azure's route table will prefer ExpressRoute (BGP routes from ER have lower effective metric than the static VPN route).

**To test VPN failover:**

1. In the Azure portal, navigate to the ExpressRoute circuit `az-hub-er-circuit`.
2. Disable **Private Peering** on the circuit.
3. Wait ~60 seconds. Azure route table falls back to the VPN connection.
4. Re-verify pings from the GCP VM to the Azure VMs — traffic should still flow over the VPN tunnel.
5. Re-enable Private Peering to restore ER.

---

## Cleanup (reverse order)

> Destroy Azure first — its VPN connection references GCP state. Destroying GCP first would leave Azure with a dangling LNG reference.

**1. Destroy Azure resources:**

```bash
terraform -chdir=terraform/azure destroy
```

**2. Destroy GCP resources:**

```bash
terraform -chdir=terraform/gcp destroy
```

**3. Cancel Megaport VXCs** (if Step 4 was run) via the Megaport portal to stop billing.

---

## Cross-State Contract Reference

| Producer | Output name | Sensitive | Consumer | Consumed as |
|---|---|---|---|---|
| `terraform/azure` | `vpn_gateway_public_ip` | no | `terraform/gcp` | `data.terraform_remote_state.azure.outputs.vpn_gateway_public_ip` |
| `terraform/azure` | `vpn_shared_key` | **yes** | `terraform/gcp` | `data.terraform_remote_state.azure.outputs.vpn_shared_key` |
| `terraform/gcp` | `gcp_vpn_public_ip` | no | `terraform/azure` | `data.terraform_remote_state.gcp[0].outputs.gcp_vpn_public_ip` |
| `terraform/gcp` | `gcp_vpc_cidr` | no | `terraform/azure` | `data.terraform_remote_state.gcp[0].outputs.gcp_vpc_cidr` |

**Gating:** The Azure `terraform_remote_state.gcp` data source (and all resources that consume it) carry `count = var.enable_onprem_connection ? 1 : 0`. Set `enable_onprem_connection = false` for Step 1; `true` for Step 3 onward.
