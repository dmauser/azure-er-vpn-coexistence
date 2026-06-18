# Niobe — History

## Seed
- **Project:** azure-er-vpn-coexistence2 — Azure ER/VPN coexistence lab, GCP as on-prem.
- **User:** dmauser
- **Stack:** Terraform `google` provider. Porting the gcloud steps in `deploy.azcli` to HCL.
- **Mission:** Own `terraform/gcp/` — VPC/VM/Classic VPN/tunnel/route, flagged Cloud Router + Partner Interconnect.

## Learnings

### 2026-06-17 — GCP route-dump scripts

- **Resource-name defaults used:** project is user-supplied from `var.project`; region defaults to `us-central1`; VPC network is `vpnlab-vpc`; subnet is `vpnlab-subnet`; Classic VPN gateway is `onpremvpn`; VPN static IP is `onpremvpn-pip`; forwarding rules are `onpremvpn-rule-esp`, `onpremvpn-rule-udp500`, and `onpremvpn-rule-udp4500`; VPN tunnel is `vpn-to-azure`; VPN route is `vpn-to-azure-route-1`; Cloud Router is `vpnlab-router`; Partner Interconnect attachment is `vpnlab-vlan`; Cloud Router ASN is `16550`.
- **gcloud route-dump commands captured:** `gcloud compute routes list --project <project> --filter "network:vpnlab-vpc" --format table`; `gcloud compute routers get-status vpnlab-router --region us-central1 --project <project>`; `gcloud compute routers describe vpnlab-router --region us-central1 --project <project>`; `gcloud compute vpn-tunnels describe vpn-to-azure --region us-central1 --project <project>`; `gcloud compute vpn-tunnels list --project <project> --regions us-central1 --format table`; `gcloud compute target-vpn-gateways describe onpremvpn --region us-central1 --project <project>`; `gcloud compute forwarding-rules list --project <project> --regions us-central1 --filter "target:targetVpnGateways/onpremvpn" --format table`; `gcloud compute routes describe vpn-to-azure-route-1 --project <project>`.
- **GCP VM net-tools startup:** `google_compute_instance.vm1` (`vpnlab-vm1` by default) now uses `metadata_startup_script = local.nettools_startup` to install `net-tools`, `traceroute`, `tcptraceroute`, `nmap`, `hping3`, `iperf3`, `nginx`, `speedtest-cli`, and `moreutils`, then writes `hostname` to `/var/www/html/index.html`.

### 2026-06-17 — Initial terraform/gcp/ creation

- **terraform_remote_state during validate:** `terraform validate` does NOT resolve `data "terraform_remote_state"` — it only checks syntax/types. The data source is intentionally correct and will only fail at plan/apply if the Azure state file is absent. This is expected per the documented 3-apply order.
- **`terraform fmt` on Windows:** `fmt -check -diff` fails if `diff` is not in PATH (not standard on Windows). Use plain `fmt` to apply formatting in-place; two files (`main.tf`, `vpn.tf`) had minor whitespace issues fixed.
- **Classic VPN forwarding rule for ESP:** `ip_protocol = "ESP"` requires NO `port_range` attribute — omit it or Terraform errors. UDP rules use `port_range = "500"` / `"4500"` (string, not list).
- **`google_compute_forwarding_rule` target for Classic VPN:** use `.self_link` (not `.id`) on `google_compute_vpn_gateway` — the forwarding rule `target` field requires a self-link URL.
- **`google_compute_instance` image family shorthand:** `"ubuntu-os-cloud/ubuntu-2204-lts"` resolves to the latest image in that family; accepted by the google provider v5 without specifying `image_project` separately.
- **Interconnect `edge_availability_domain`:** Terraform resource uses `"AVAILABILITY_DOMAIN_1"` (uppercase, underscore) — differs from gcloud CLI `availability-domain-1` (lowercase, hyphen).
- **shared_secret is sensitive in the Azure state:** `data.terraform_remote_state.azure.outputs.vpn_shared_key` inherits sensitivity from the Azure side; no explicit `sensitive = true` needed on the data reference itself, but users should not print it.
- **Provider version pinned to `~> 5.0`:** google provider 5.x is the current stable series (5.45.2 installed). Lock file committed to VCS for reproducible installs.

### 2026-06-17 — Session finalization (Scribe: decisions merged, orchestration logs)

- Terraform revamp finalized and validated by Morpheus (all gates passed)
- GCP route dumps committed as per Scribe orchestration log
- All 14 decisions merged into `.squad/decisions.md` from inbox; inbox files deleted
- Orchestration log written: 2026-06-17T20_47_00-niobe.md
