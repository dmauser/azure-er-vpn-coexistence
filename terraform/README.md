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
| Terraform | ≥ 1.5 (tested with 1.15.x) |
| Azure CLI | ≥ 2.5x, authenticated (`az login`) with Contributor on the target subscription |
| gcloud CLI | authenticated with Application Default Credentials (`gcloud auth application-default login`) |
| GCP project | existing project ID with billing enabled; Compute Engine API enabled |
| Megaport account | **only needed for Step 4 (ExpressRoute/Interconnect)** — optional |

---

## Pre-flight Checklist

Tick every item before running Step 1. A missed item is the #1 cause of failed first runs.

- [ ] **Terraform ≥ 1.5** installed — `terraform -version`
- [ ] **Azure CLI** installed — `az version`
- [ ] **gcloud CLI** installed — `gcloud --version`
- [ ] **Azure login** done — `az login` (or `az login --use-device-code` for headless shells)
- [ ] **Correct Azure subscription** set — `az account show --output table`
- [ ] **GCP user login** done — `gcloud auth login`
- [ ] **GCP Application Default Credentials** set — `gcloud auth application-default login`
- [ ] **GCP project** set — `gcloud config set project <PROJECT_ID>`
- [ ] **Compute Engine API enabled** — `gcloud services enable compute.googleapis.com`
- [ ] **Your current public IP** known (needed for both tfvars files):
  ```bash
  # Linux / macOS
  curl -4 ifconfig.io
  # Windows PowerShell
  (Invoke-RestMethod -Uri 'https://ifconfig.io')
  # Alternative (PowerShell)
  (Invoke-WebRequest -Uri 'https://api.ipify.org').Content
  ```
- [ ] **Strong VM password chosen** — Azure requires ≥ 12 characters with at least 3 of: uppercase, lowercase, digit, special character.

> ⚠️ If your public IP changes between sessions (dynamic ISP, VPN reconnect, etc.), you must update `restrict_ssh_source_prefix` (Azure) and `caller_source_ip` (GCP) and re-apply both modules — otherwise SSH and ICMP will be blocked by the firewall rules.

---

## Requirements & Setup

### 1. Install Terraform

**Windows (via winget):**
```powershell
winget install --id Hashicorp.Terraform
```

**Linux (via HashiCorp apt repository):**
```bash
wget -O - https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
sudo apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
sudo apt update && sudo apt install terraform
```

**macOS (via Homebrew):**
```bash
brew tap hashicorp/tap
brew install hashicorp/tap/terraform
```

**Verify installation:**
```bash
terraform -version
```

---

### 2. Install Azure CLI

**Windows (via winget):**
```powershell
winget install --id Microsoft.AzureCLI
```

**Linux (via curl):**
```bash
curl -sL https://aka.ms/InstallAzureCLIDeb | bash
```

**macOS (via Homebrew):**
```bash
brew install azure-cli
```

**Verify installation:**
```bash
az version
```

---

### 3. Install Google Cloud SDK (gcloud)

**Windows (via winget):**
```powershell
winget install --id Google.CloudSDK
```

**Linux (via curl and apt):**
```bash
curl https://sdk.cloud.google.com | bash
exec -l $SHELL
```

**macOS (via Homebrew):**
```bash
brew install google-cloud-sdk
```

**Verify installation:**
```bash
gcloud --version
```

---

### 4. Authenticate with Azure

**Step 1: Log in with `az`**
```bash
az login
```

For headless or remote shells (e.g., WSL, cloud shell), use device code flow:
```bash
az login --use-device-code
```

**Step 2: List subscriptions**
```bash
az account list --output table
```

**Step 3: Set the target subscription**
```bash
az account set --subscription "<Name or ID>"
```

**Step 4: Confirm selection**
```bash
az account show --output table
```

> **Note:** Terraform's `azurerm` provider automatically uses the Azure CLI context (the subscription selected above). If you need to pin the subscription in a specific shell session, export:
> ```bash
> export ARM_SUBSCRIPTION_ID="<Subscription-ID>"
> ```

---

### 5. Authenticate with Google Cloud

**Step 1: User authentication (for `gcloud` CLI commands)**
```bash
gcloud auth login
```

**Step 2: Set up Application Default Credentials (required for Terraform's `google` provider)**
```bash
gcloud auth application-default login
```

This writes credentials to `~/.config/gcloud/application_default_credentials.json` (Linux/macOS) or `%APPDATA%\gcloud\application_default_credentials.json` (Windows).

**Step 3: List GCP projects**
```bash
gcloud projects list
```

**Step 4: Set the active project**
```bash
gcloud config set project <PROJECT_ID>
gcloud config get-value project
```

> **Important:** The `project` variable in `terraform/gcp/terraform.tfvars` must match the active GCP project selected here. Terraform's `google` provider uses Application Default Credentials; make sure `gcloud auth application-default login` has been run.

---

### 6. Enable Required GCP APIs

Terraform will fail if required APIs are not enabled in your GCP project. Enable them upfront:

```bash
gcloud services enable compute.googleapis.com
```

For Step 4 (ExpressRoute/Interconnect), also enable:
```bash
gcloud services enable compute.googleapis.com servicenetworking.googleapis.com
```

---

### 7. Permissions & Service Accounts

**Azure:** The identity running `terraform apply` must have **Contributor** role (or equivalent Network Contributor + Compute permissions) on the target subscription.

```bash
az role assignment list --assignee <your-user-principal-name> --output table
```

**GCP:** The identity running `terraform apply` must have **Compute Network Admin** or higher on the GCP project.

```bash
gcloud projects get-iam-policy <PROJECT_ID> --flatten="bindings[].members" --filter="bindings.members:<your-email>"
```

**Megaport (Step 4 only):** If enabling ExpressRoute/Interconnect, you must have a Megaport account and the ability to create Virtual Cross Connects (VXCs). No specific GCP/Azure permissions are needed beyond the above.

## Step 1 — Azure base apply

```bash
cd terraform/azure
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` and set the **three required values**:

```hcl
vm_admin_username          = "azureuser"
vm_admin_password          = "YourStr0ngP@ssword!"   # min 12 chars, upper+lower+digit+special
restrict_ssh_source_prefix = "203.0.113.5/32"        # your public IP + /32  ← see below
```

> **Finding your public IP** (paste as `<IP>/32`):
> ```bash
> # Linux / macOS
> curl -4 ifconfig.io
> # Windows PowerShell
> (Invoke-RestMethod -Uri 'https://ifconfig.io')
> ```

Leave `enable_onprem_connection = false` (the default). Do **not** set it yet — GCP state doesn't exist yet.

```bash
terraform init
terraform plan   # preview what will be created (recommended before every apply)
terraform apply  # type 'yes' when prompted, or add -auto-approve to skip confirmation
```

> ⏱ **Expect 30–45 minutes** for this first apply. Azure provisions both the VPN Gateway (`Az-Hub-vpngw`) and the ExpressRoute Gateway (`Az-Hub-ergw`) in parallel. Terraform will appear to "hang" on the gateway resources — this is **normal**. Do not cancel the apply; wait for it to complete. Progress can be monitored in the Azure portal under **Virtual network gateways**.  
> Subsequent applies (Steps 2 and 3) are much faster (~2–5 min).

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
caller_source_ip = "203.0.113.5"   # your public IP, no mask  ← same IP as Azure Step 1
```

> **Finding your public IP** (paste without a mask):
> ```bash
> # Linux / macOS
> curl -4 ifconfig.io
> # Windows PowerShell
> (Invoke-RestMethod -Uri 'https://ifconfig.io')
> ```

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
terraform plan   # preview — confirms Azure state is readable and tunnel config looks right
terraform apply  # type 'yes' when prompted

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
terraform plan   # should show ~2 new resources: LNG + VPN connection
terraform apply  # type 'yes' when prompted

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
# SSH into the GCP VM
# Default instance name is "<envname>-vm1" (vpnlab-vm1), zone us-central1-c
gcloud compute ssh vpnlab-vm1 --zone us-central1-c

# If you changed envname in terraform.tfvars, substitute it:
# gcloud compute ssh <envname>-vm1 --zone us-central1-c
```

> 📝 **First SSH:** gcloud may generate an SSH key pair and prompt for a passphrase — this is expected.  
> The VM has an external IP, so `gcloud compute ssh` connects directly. If you prefer to force IAP (Cloud Identity-Aware Proxy), append `--tunnel-through-iap`.

Once connected, ping the Azure VMs:

```bash
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

---

## Troubleshooting / Common Pitfalls

### VPN shows `NotConnected` / tunnel not `ESTABLISHED`
- **Most likely cause:** You haven't finished Step 3, or Step 1's gateways haven't finished provisioning yet (gateways take 30–45 min — see Step 1 note).
- Verify that `az network vpn-connection show --name Azure-to-OnpremGCP --resource-group lab-er-vpn-coexistence --query connectionStatus` returns `"Connected"` and not `"NotConnected"`.
- Check that the shared key and peer IPs are sourced automatically from state — no manual entry needed. If you modified either tfvars file after apply, run `terraform apply` again on both modules.
- Verify the GCP firewall rule `vpnlab-allow-traffic-from-azure` was created (it allows `10.0.0.0/8`).

### `Error: Unable to find remote state` / `terraform_remote_state` returns empty outputs
- You ran the applies **out of order**. Run Step 1 (Azure) and confirm `terraform.tfstate` exists at `terraform/azure/terraform.tfstate` before running Step 2 (GCP).
- Check `azure_remote_state_path` in GCP's `terraform.tfvars` and `gcp_remote_state_path` in Azure's `terraform.tfvars` — both must point to the correct relative path from their module root.
- In Step 3, confirm you ran `terraform init` in the Azure directory again after first init (not needed if providers are cached, but won't hurt).

### `Error: Compute Engine API has not been used in project ... before`
```bash
gcloud services enable compute.googleapis.com
```
Wait ~60 seconds, then re-run `terraform apply`.

### Azure password rejected / VM creation fails with password policy error
Azure requires passwords to be **≥ 12 characters** and contain at least **3 of the 4** character categories: uppercase letter, lowercase letter, digit, special character. Example that satisfies all four: `Lab@2024Secure!`.

### SSH blocked / ping fails after VPN is `Connected`
Your public IP has changed (e.g., ISP DHCP renewal, VPN reconnect). Update both values and re-apply:
1. Get your new IP: `curl -4 ifconfig.io` (Linux/macOS) or `(Invoke-RestMethod -Uri 'https://ifconfig.io')` (PowerShell)
2. In `terraform/azure/terraform.tfvars`: update `restrict_ssh_source_prefix = "<new-ip>/32"`
3. In `terraform/gcp/terraform.tfvars`: update `caller_source_ip = "<new-ip>"`
4. `terraform apply` in both directories.

### Gateways appear "stuck" during Step 1 apply
This is **expected behaviour**. Azure VPN Gateway + ExpressRoute Gateway each take 20–30 minutes to provision. Terraform will hold on `azurerm_virtual_network_gateway.vpn: Still creating...` — do not cancel. Total first-apply time is 30–45 minutes. You can monitor progress in the Azure portal under **Virtual network gateways**.

### ExpressRoute circuit never reaches `Provisioned`
The Megaport VXC has not been ordered or has not activated yet. The Azure ER circuit will remain in `NotProvisioned` state until Megaport completes the cross-connect provisioning. Step 4d (`terraform apply` to attach the circuit) will fail until the circuit shows `Provisioned`. See Step 4c for Megaport VXC ordering instructions.

### Destroy fails — resource dependencies or GCP dangling reference
Always destroy in **reverse order**: Azure first, then GCP. If you accidentally destroyed GCP first, the Azure Local Network Gateway and VPN Connection may be orphaned. Import them back with `terraform import` or delete them manually in the Azure portal before re-running `terraform destroy` on Azure.

---

## Cross-State Contract Reference

| Producer | Output name | Sensitive | Consumer | Consumed as |
|---|---|---|---|---|
| `terraform/azure` | `vpn_gateway_public_ip` | no | `terraform/gcp` | `data.terraform_remote_state.azure.outputs.vpn_gateway_public_ip` |
| `terraform/azure` | `vpn_shared_key` | **yes** | `terraform/gcp` | `data.terraform_remote_state.azure.outputs.vpn_shared_key` |
| `terraform/gcp` | `gcp_vpn_public_ip` | no | `terraform/azure` | `data.terraform_remote_state.gcp[0].outputs.gcp_vpn_public_ip` |
| `terraform/gcp` | `gcp_vpc_cidr` | no | `terraform/azure` | `data.terraform_remote_state.gcp[0].outputs.gcp_vpc_cidr` |

**Gating:** The Azure `terraform_remote_state.gcp` data source (and all resources that consume it) carry `count = var.enable_onprem_connection ? 1 : 0`. Set `enable_onprem_connection = false` for Step 1; `true` for Step 3 onward.
