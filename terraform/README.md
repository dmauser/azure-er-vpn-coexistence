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
- [ ] **Your current public IP** known (needed for GCP `caller_source_ip`):
  ```bash
  # Linux / macOS
  curl -4 ifconfig.io
  # Windows PowerShell
  (Invoke-RestMethod -Uri 'https://ifconfig.io')
  # Alternative (PowerShell)
  (Invoke-WebRequest -Uri 'https://api.ipify.org').Content
  ```
- [ ] **Strong VM password chosen** — Azure requires ≥ 12 characters with at least 3 of: uppercase, lowercase, digit, special character.

> Note: If your public IP changes between sessions (dynamic ISP, VPN reconnect, etc.), update GCP `caller_source_ip` and re-apply the GCP module. Azure VMs have no public IP and no source-IP SSH allow-list.

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


## Scripted Deployment (recommended)

Use the root wrapper scripts for the normal lab flow:

| Shell | Script |
|---|---|
| Linux / macOS | `./deploy.sh` |
| Windows PowerShell | `./deploy.ps1` |

The default action is `deploy`, so `./deploy.sh` and `./deploy.sh deploy` are equivalent. The scripts validate prerequisites, collect inputs safely, run the full 3-apply order, and print post-deploy verification commands.

### Subcommands

| Action | Bash | PowerShell | What it does |
|---|---|---|---|
| Check only | `check` | `-Check` | Validate prerequisites only. |
| Deploy | `deploy` | default | Prereqs plus full 3-apply deployment. |
| Destroy | `destroy` | `-Destroy` | Reverse-order teardown: Azure first, then GCP. |

### Flags

| Bash | PowerShell | Purpose |
|---|---|---|
| `--auto-approve` | `-AutoApprove` | Skip Terraform confirmation. |
| `--expressroute` | `-EnableExpressRoute` | Run optional ExpressRoute/Interconnect stage. Billable. |
| `--subscription <id>` | `-Subscription <id>` | Set Azure subscription first. |
| `--project <id>` | `-Project <id>` | Set GCP project first. |
| `--location <r>` | `-Location <r>` | Azure region. Default: `centralus`. |
| `--region <r>` | `-Region <r>` | GCP region. Default: `us-central1`. |
| `--zone <z>` | `-Zone <z>` | GCP zone. Default: `<region>-c`. |
| `--vm-username <n>` | `-VmUsername <n>` | VM admin username. Default: `azureuser`. |
| `--vm-password <p>` | `-VmPassword <secure>` | VM admin password. Prompted securely if omitted. |
| `--caller-ip <ip>` | `-CallerIp <ip>` | Override auto-detected public IP for the GCP SSH firewall. |

### What the scripts do

1. Validate prerequisites:
   - `terraform`, `az`, and `gcloud` are present and versions are printed.
   - Azure CLI is logged in and the active subscription is printed.
   - GCP has an active account, Application Default Credentials, and a project set.
   - The caller public IP is auto-detected for GCP `caller_source_ip`.
2. Prompt for inputs when not supplied by flags or environment:
   - VM admin username, Azure location, GCP region, and GCP zone each show a `[default]`; press Enter to accept.
   - VM password is collected with no echo and must be at least 12 characters.
   - The password is passed to Terraform through `TF_VAR_vm_admin_password`, never on the command line, in shell history, or in `ps`; it is cleared on exit.
3. Run the 3-apply order automatically:
   - Azure base: `enable_onprem_connection=false`
   - GCP: creates VPC, VM, VPN gateway, tunnel, route, and firewall
   - Azure connection: `enable_onprem_connection=true`
4. Print VPN verification:
   - Azure VPN connection status
   - GCP tunnel status
   - GCP SSH command
   - Azure Serial Console command
5. If ExpressRoute is requested, run Step 4:
   - GCP `enable_interconnect=true`
   - Azure `enable_expressroute=true`
   - Print the GCP pairing key and Azure ExpressRoute service key
   - Stop with Megaport ordering instructions. After the circuit is `Provisioned`, re-run with the ExpressRoute flag to attach/retry the ER gateway connection.
6. For `destroy`, tear down Azure first, then GCP.

### Examples

Linux / macOS:

```bash
./deploy.sh check
./deploy.sh deploy --project my-gcp-project --location eastus2
./deploy.sh deploy --expressroute --project my-gcp-project
./deploy.sh destroy --auto-approve --project my-gcp-project
```

Windows PowerShell:

```powershell
.\deploy.ps1 -Check
.\deploy.ps1 -Project my-gcp-project -Location eastus2
.\deploy.ps1 -EnableExpressRoute -Project my-gcp-project
.\deploy.ps1 -Destroy -AutoApprove -Project my-gcp-project
```

Non-interactive / CI usage:

```bash
export TF_VAR_vm_admin_password='Use-A-Strong-Password-Here'
./deploy.sh deploy --auto-approve --project my-gcp-project --location centralus --region us-central1 --zone us-central1-c --vm-username azureuser --caller-ip 203.0.113.5
```

```powershell
$env:TF_VAR_vm_admin_password = 'Use-A-Strong-Password-Here'
.\deploy.ps1 -AutoApprove -Project my-gcp-project -Location centralus -Region us-central1 -Zone us-central1-c -VmUsername azureuser -CallerIp 203.0.113.5
```

---

## Manual / Advanced 3-Apply Walkthrough

## Step 1 — Azure base apply

```bash
cd terraform/azure
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` or pass variables on the command line. Azure now needs only the admin username plus the password; the VMs have no public IP and no source-IP SSH allow-list.

```hcl
vm_admin_username = "azureuser"
# Prefer TF_VAR_vm_admin_password for the password; do not put it in shell history.
```

For manual runs, set the password through the Terraform environment variable:

```bash
export TF_VAR_vm_admin_password='YourStr0ngP@ssword!'
```

```powershell
$env:TF_VAR_vm_admin_password = 'YourStr0ngP@ssword!'
```

Leave `enable_onprem_connection = false` (the default). Do **not** set it yet - GCP state doesn't exist yet.

```bash
terraform init
terraform plan \
  -var location=centralus \
  -var vm_admin_username=azureuser \
  -var enable_onprem_connection=false
terraform apply \
  -var location=centralus \
  -var vm_admin_username=azureuser \
  -var enable_onprem_connection=false
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
terraform plan \
  -var location=centralus \
  -var vm_admin_username=azureuser \
  -var enable_onprem_connection=true
terraform apply \
  -var location=centralus \
  -var vm_admin_username=azureuser \
  -var enable_onprem_connection=true
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


### Accessing the Azure VMs (no public IP)

Azure VMs do not have public IP addresses. Managed boot diagnostics and Serial Console are enabled on all three VMs, so use Azure Serial Console for direct access:

```bash
az serialconsole connect --name Az-Hub-lxvm --resource-group lab-er-vpn-coexistence
```

Other VM names: `Az-Spk1-lxvm`, `Az-Spk2-lxvm`.

You can also use the Azure portal: **VM > Help > Serial console**. After the VPN is up, you can reach the Azure VMs from a peer VM across VNet peering or the VPN tunnel. The Azure VMs still have outbound internet through Azure default outbound access, which is required for first-boot `apt` package installation.

---

## Network Test Tools

Every Linux VM in the lab is provisioned with the same network test toolkit at first boot:
- Azure: the three test VMs receive it through cloud-init `custom_data`.
- GCP: the on-prem test VM receives it through `metadata_startup_script`.

The installer runs automatically from [`nettools.sh`](https://github.com/dmauser/azure-vm-net-tools/blob/main/script/nettools.sh). Allow a few minutes after VM creation before testing; `apt` must finish installing packages and starting services.

| Tool | What it is for |
|---|---|
| `net-tools` | Classic `ifconfig`, `netstat`, and `arp` troubleshooting commands. |
| `traceroute`, `tcptraceroute` | Path tracing with ICMP or TCP probes. |
| `nmap` | Port and host scanning. |
| `hping3` | Crafted TCP, UDP, and ICMP probes. |
| `iperf3` | Throughput testing between VMs. Run `iperf3 -s` on one VM and `iperf3 -c <peer-private-ip>` on another. Ideal for comparing VPN vs ExpressRoute throughput between Azure and GCP. |
| `nginx` | Serves the VM hostname at `http://<vm-private-ip>/`. A quick tunnel test is `curl http://<remote-vm-private-ip>/`; the response should be the remote hostname. |
| `speedtest-cli` | Internet speed test from the VM. |
| `moreutils` | Extra CLI utilities such as `ts` and `sponge`. |

Access notes:
- Azure VMs have no public IP. Reach them through Azure Serial Console (`az serialconsole connect ...` or the portal), or from a peer VM across the VNet/VPN.
- The GCP VM has an external IP, so `gcloud compute ssh vpnlab-vm1 --zone us-central1-c` works directly unless you changed `envname` or `zone`.

End-to-end S2S VPN examples:

```bash
# From the Azure hub VM, validate reachability to the GCP VM private IP.
ping <gcp-vm-private-ip>
curl http://<gcp-vm-private-ip>/
```

```bash
# Throughput test between Azure and GCP.
# On the GCP VM:
iperf3 -s

# On an Azure VM:
iperf3 -c <gcp-vm-private-ip>
```

For the reverse direction, run `iperf3 -s` on an Azure VM and connect from the GCP VM with `iperf3 -c <azure-vm-private-ip>`.

---


## Route Inspection

Four root diagnostic scripts dump control-plane route state after deployment. They verify the relevant CLI is installed and authenticated before running.

| Script | What it dumps |
|---|---|
| `dump-routes-azure.sh` / `dump-routes-azure.ps1` | Prompts for resource group (default `lab-er-vpn-coexistence`) and lets you select which components to dump: VM effective routes (NICs), ExpressRoute circuit routes for `AzurePrivatePeering` primary/secondary paths, ExpressRoute gateway routes, and VPN gateway routes — each independently selectable via the interactive prompt or `--components nics,circuit,ergw,vpngw` (`AZURE_ROUTE_COMPONENTS`). If a resource is disabled or not provisioned, the script reports that and continues. |
| `dump-routes-gcp.sh` / `dump-routes-gcp.ps1` | Prompts for project and region (default `us-central1`) and prints a friendly view: a health summary (VPN tunnel up/down, gateway READY, static route present, Cloud Router/BGP state), key/value detail for the VPN tunnel, classic gateway, and tunnel-backed route, and labeled tables for VPC routes (static + dynamic), forwarding rules, and firewall rules. Add `--raw`/`-Raw` for the full gcloud YAML/describe output. If Interconnect/BGP is disabled or a resource is missing, the script reports it and continues. |

Examples:

```bash
./dump-routes-azure.sh
./dump-routes-gcp.sh --project my-gcp-project --region us-central1
```

```powershell
.\dump-routes-azure.ps1
.\dump-routes-gcp.ps1 -Project my-gcp-project -Region us-central1
```

### Azure script — component selection

The Azure script lets you dump any subset of components, either interactively or via `--components` / `-Components` (comma-separated, or `all`):

| Component | Dumps |
|---|---|
| `nics` | VM effective routes for each NIC (auto-discovered or `--nics`) |
| `circuit` | ExpressRoute circuit routes (`AzurePrivatePeering` primary + secondary) |
| `ergw` | ExpressRoute gateway learned routes (+ advertised with `--advertised`) |
| `vpngw` | VPN gateway learned routes (+ advertised with `--advertised`) |

| Flag (bash) | Param (PowerShell) | Environment | Default |
|---|---|---|---|
| `--components nics,circuit,ergw,vpngw` | `-Components` | `AZURE_ROUTE_COMPONENTS` | prompt (all) |
| `--resource-group` | `-ResourceGroup` | `AZURE_ROUTE_RG` | `lab-er-vpn-coexistence` |
| `--circuit-name` | `-CircuitName` | `AZURE_ROUTE_CIRCUIT` | terraform output or `az-hub-er-circuit` |
| `--er-gateway-name` | `-ErGatewayName` | `AZURE_ROUTE_ER_GATEWAY` | `Az-Hub-ergw` |
| `--vpn-gateway-name` | `-VpnGatewayName` | `AZURE_ROUTE_VPN_GATEWAY` | `Az-Hub-vpngw` |
| `--nics` | `-Nics` | `AZURE_ROUTE_NICS` | auto-discovered |
| `--advertised` | `-Advertised` | `AZURE_ROUTE_ADVERTISED` | off |
| `--yes` | `-Yes` | `AZURE_ROUTE_YES` | off (interactive) |

```bash
# Only the VPN gateway, with advertised routes, non-interactive
./dump-routes-azure.sh --components vpngw --advertised --yes
# ER gateway + circuit together
./dump-routes-azure.sh --components ergw,circuit
```

```powershell
.\dump-routes-azure.ps1 -Components vpngw -Advertised -Yes
.\dump-routes-azure.ps1 -Components ergw,circuit
```

`--advertised` auto-discovers each BGP peer and lists the routes advertised to every peer (both ER and VPN gateways).

### GCP script — friendly view and `--raw`

The GCP script defaults to a friendly summary (tunnel/gateway/route/BGP health, key/value detail, labeled tables). Add `--raw` / `-Raw` for the full `gcloud ... describe` YAML.

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

```bash
./dump-routes-gcp.sh --project my-gcp-project --raw
```

```powershell
.\dump-routes-gcp.ps1 -Project my-gcp-project -Raw
```

---

## Step 4 — ExpressRoute + Interconnect (optional, billable)

> ⚠️ This step provisions **billable** cloud resources and requires a **Megaport** account.

> ✅ **The existing VPN is preserved.** Adding ExpressRoute does **not** tear down the
> Site-to-Site VPN. When you re-run `deploy.sh --expressroute` / `deploy.ps1 -EnableExpressRoute`
> on an already-deployed lab, the wrapper detects the existing GCP deployment and keeps
> `enable_onprem_connection=true` in Step 1, so the VPN connection and Local Network Gateway
> stay in place. The result is true **coexistence** — VPN and ExpressRoute up at the same time.
> (When running Terraform manually, always pass `-var enable_onprem_connection=true` alongside
> `-var enable_expressroute=true`, as shown below.)

> 🔒 **The ER gateway connection waits for the provider.** The wrappers create the ExpressRoute
> circuit, print the GCP pairing key and Azure service key, then check the circuit's
> `serviceProviderProvisioningState`. The connection (`ER-Connection-to-Onprem`) is created
> **only** when the circuit is `Provisioned`. If it is not, the script prints the keys and
> stops with instructions to provision the circuit with your provider (Megaport), then re-run.

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
terraform -chdir=terraform/gcp apply \
  -var project=<PROJECT_ID> \
  -var region=us-central1 \
  -var zone=us-central1-c \
  -var caller_source_ip=<your-public-ip> \
  -var enable_interconnect=true

terraform -chdir=terraform/azure apply \
  -var location=centralus \
  -var vm_admin_username=azureuser \
  -var enable_onprem_connection=true \
  -var enable_expressroute=true \
  -var enable_er_connection=false   # circuit only - attach the connection in step 4d
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

> 🔒 **The gateway connection is gated on circuit provisioning.** The ER gateway
> connection (`ER-Connection-to-Onprem`) is controlled by a separate variable,
> `enable_er_connection`, which defaults to `false`. Step 4a above creates the
> **circuit only**. Do **not** set `enable_er_connection=true` until the circuit
> shows `serviceProviderProvisioningState=Provisioned` — attaching to a circuit
> the provider has not provisioned fails. Check the state with:
>
> ```bash
> az network express-route show -g lab-er-vpn-coexistence -n az-hub-er-circuit \
>   --query serviceProviderProvisioningState -o tsv
> ```
>
> The `deploy.sh`/`deploy.ps1` wrappers do this automatically: they create the
> circuit, print the keys, check the state, and only attach the connection when
> the circuit is `Provisioned` — otherwise they stop and tell you to provision it
> with the provider first.

Once the circuit is provisioned, re-run the Azure apply with `enable_er_connection=true` to create the ER gateway connection:

```bash
terraform -chdir=terraform/azure apply \
  -var location=centralus \
  -var vm_admin_username=azureuser \
  -var enable_onprem_connection=true \
  -var enable_expressroute=true \
  -var enable_er_connection=true
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
terraform -chdir=terraform/azure destroy \
  -var location=centralus \
  -var vm_admin_username=azureuser \
  -var enable_onprem_connection=true
```

**2. Destroy GCP resources:**

```bash
terraform -chdir=terraform/gcp destroy \
  -var project=<PROJECT_ID> \
  -var region=us-central1 \
  -var zone=us-central1-c \
  -var caller_source_ip=<your-public-ip>
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
Your public IP only affects the GCP SSH firewall. Azure VM access uses Serial Console, not public SSH.
1. Get your new IP: `curl -4 ifconfig.io` (Linux/macOS) or `(Invoke-RestMethod -Uri 'https://ifconfig.io')` (PowerShell).
2. In `terraform/gcp/terraform.tfvars`: update `caller_source_ip = "<new-ip>"`.
3. Re-run `terraform apply` in `terraform/gcp`.

### Gateways appear "stuck" during Step 1 apply
This is **expected behaviour**. Azure VPN Gateway + ExpressRoute Gateway each take 20–30 minutes to provision. Terraform will hold on `azurerm_virtual_network_gateway.vpn: Still creating...` — do not cancel. Total first-apply time is 30–45 minutes. You can monitor progress in the Azure portal under **Virtual network gateways**.

### ExpressRoute circuit never reaches `Provisioned`
The Megaport VXC has not been ordered or has not activated yet. The Azure ER circuit will remain in `NotProvisioned` state until Megaport completes the cross-connect provisioning. Step 4d (`terraform apply` to attach the circuit) will fail until the circuit shows `Provisioned`. See Step 4c for Megaport VXC ordering instructions.

### Destroy fails — resource dependencies or GCP dangling reference
Always destroy in **reverse order**: Azure first, then GCP. If you accidentally destroyed GCP first, the Azure Local Network Gateway and VPN Connection may be orphaned. Import them back with `terraform import` or delete them manually in the Azure portal before re-running `terraform destroy` on Azure.

### Restricted subscriptions: Standard public IP gate

**Why Standard PIPs are required:** The lab uses an active-active VPN gateway with BGP, which requires Standard SKU public IPs. Azure retired Basic SKU public IPs on 2025-09-30 and they never supported active-active or BGP anyway.

**Symptom:** `terraform apply` succeeds for the VM and network resources but then fails ~20 minutes in at `azurerm_public_ip.vpn_gw_pip1` with an error like:
```
SubscriptionNotRegisteredForFeature ... Microsoft.Network/AllowBringYourOwnPublicIpAddress
```

**Pre-flight detection:** The `deploy.sh` / `deploy.ps1` scripts now probe for this condition before any `terraform apply` runs. If detected, the script exits immediately with full instructions.

**What the feature actually does:** Despite the misleading name, `Microsoft.Network/AllowBringYourOwnPublicIpAddress` is NOT about bringing your own IP prefix. It is simply a subscription-level gate that Microsoft enables by default on most subscriptions but leaves locked on certain restricted or FDPO subscriptions. Registering it unlocks normal Azure-allocated Standard public IPs — nothing else changes.

**Fix (one-time, per subscription):**
```bash
az feature register --namespace Microsoft.Network --name AllowBringYourOwnPublicIpAddress
az feature show --namespace Microsoft.Network --name AllowBringYourOwnPublicIpAddress --query properties.state -o tsv   # wait until: Registered
az provider register --namespace Microsoft.Network
```
Then re-run the deploy script. Registration typically takes 5-15 minutes.

**Alternative:** Use an unrestricted Azure subscription where Standard public IPs work without any feature registration.

**Bypass the pre-flight check** (if you already know the subscription is unblocked and want to skip the ~30-second probe):
```bash
SKIP_PIP_PRECHECK=1 ./deploy.sh deploy ...
```
```powershell
$env:SKIP_PIP_PRECHECK=1; .\deploy.ps1 ...
```

### VPN gateway SKU: AZ SKUs required (NonAzSkusNotAllowedForVPNGateway)

**Why AZ SKUs are required:** Azure has consolidated VPN gateway SKUs and no longer allows non-AZ SKUs (VpnGw1–VpnGw5). All new VPN gateways must use the AZ-zone-redundant variants: VpnGw1AZ–VpnGw5AZ.

**Symptom:** `terraform apply` fails at `azurerm_virtual_network_gateway.vpn` with:
```
400 NonAzSkusNotAllowedForVPNGateway: VpnGw1-5 non-AZ SKUs are no longer supported for VPN gateways. Only VpnGw1-5AZ SKUs can be created going forward.
```

**Lab default:** This lab defaults to `gateway_sku = "VpnGw1AZ"` in `variables.tf`, and the input validation enforces the AZ pattern: `^VpnGw[1-5]AZ$`. If you change the SKU, it must be one of `VpnGw1AZ`, `VpnGw2AZ`, `VpnGw3AZ`, `VpnGw4AZ`, or `VpnGw5AZ`.

**Zone-redundant PIPs required:** AZ SKUs require zone-redundant Standard public IPs. The lab automatically sets `zones = ["1","2","3"]` on the VPN gateway public IPs (`vpn_gw_pip1` and `vpn_gw_pip2`) in `gateways.tf`. Never omit or reduce the zones list when using AZ gateway SKUs.

---

## Cross-State Contract Reference

| Producer | Output name | Sensitive | Consumer | Consumed as |
|---|---|---|---|---|
| `terraform/azure` | `vpn_gateway_public_ip` | no | `terraform/gcp` | `data.terraform_remote_state.azure.outputs.vpn_gateway_public_ip` |
| `terraform/azure` | `vpn_shared_key` | **yes** | `terraform/gcp` | `data.terraform_remote_state.azure.outputs.vpn_shared_key` |
| `terraform/gcp` | `gcp_vpn_public_ip` | no | `terraform/azure` | `data.terraform_remote_state.gcp[0].outputs.gcp_vpn_public_ip` |
| `terraform/gcp` | `gcp_vpc_cidr` | no | `terraform/azure` | `data.terraform_remote_state.gcp[0].outputs.gcp_vpc_cidr` |

**Gating:** The Azure `terraform_remote_state.gcp` data source (and all resources that consume it) carry `count = var.enable_onprem_connection ? 1 : 0`. Set `enable_onprem_connection = false` for Step 1; `true` for Step 3 onward.
