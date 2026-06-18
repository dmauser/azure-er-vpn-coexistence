# Tank — History

## Seed
- **Project:** azure-er-vpn-coexistence2 — Azure ER/VPN coexistence lab, GCP as on-prem.
- **User:** dmauser
- **Stack:** Terraform across two configs; `terraform_remote_state` cross-wiring; Megaport handoff.
- **Mission:** Own the cross-state contract, shared-key flow, 3-apply order, key outputs, and validation.

## Learnings

### 2026-06-17 — First-time user success audit (task: docs-success-audit)

**Scope:** End-to-end audit of `terraform/README.md` and both `terraform.tfvars.example` files against real `.tf` source. Closed 7 first-timer failure points.

**Gaps found and closed:**

1. **Pre-flight checklist** — Added compact checklist after Prerequisites table covering: tools, `az login` + subscription, `gcloud auth login` + ADC, project set, Compute API enabled, public IP known, strong password chosen. Also added warning about dynamic-IP re-apply requirement.

2. **Gateway provisioning time** — Added ⏱ note in Step 1: Azure VPN + ER gateways take 30–45 min on first apply. Terraform appears stuck on `azurerm_virtual_network_gateway` — this is normal. Don't cancel.

3. **Public IP retrieval commands** — Added `curl -4 ifconfig.io` (Linux/macOS) and `(Invoke-RestMethod -Uri 'https://ifconfig.io')` (PowerShell) everywhere an IP is required: Step 1 text, Step 2 text, Azure `terraform.tfvars.example`, GCP `terraform.tfvars.example`. GCP example previously only had Linux command; now has both.

4. **Explicit GCP VM SSH command** — Verified GCP VM (`${var.envname}-vm1`, default `vpnlab-vm1`) has an external IP via `access_config {}` block in `main.tf`. Zone default is `us-central1-c`. Documented `gcloud compute ssh vpnlab-vm1 --zone us-central1-c` with envname substitution note, first-SSH key-gen note, and optional `--tunnel-through-iap` flag.

5. **`terraform plan` recommendation** — Added `terraform plan` before each `terraform apply` in Steps 1, 2, and 3. Added note that `apply` requires typing `yes` or `-auto-approve`.

6. **Troubleshooting / Common Pitfalls section** — Added before Cross-State Contract Reference. Covers: NotConnected/tunnel not ESTABLISHED, remote_state empty, Compute Engine API error, password policy, SSH blocked by IP change, gateways "stuck", ER circuit never Provisioned, destroy order failure.

7. **tfvars.example completeness** — Both files confirmed complete: all required vars uncommented with placeholders, all optional vars shown commented. No missing entries found. Updated `restrict_ssh_source_prefix` comment to add example strong password format.

**Key code facts verified during audit:**
- GCP VM resource: `google_compute_instance.vm1`, name `${var.envname}-vm1` (default `vpnlab-vm1`), has `access_config {}` (external IP), zone `var.zone` (default `us-central1-c`).
- Firewall `${var.envname}-allow-traffic-from-azure` includes `35.235.240.0/20` (IAP range) — IAP SSH works.
- VPN tunnel name: `vpn-to-azure`; Azure connection name: `Azure-to-OnpremGCP`; Azure RG: `lab-er-vpn-coexistence`.
- Both `terraform validate` pass after all edits.

**Decision written:** `.squad/decisions/inbox/tank-success-audit.md`

### 2026-06-17 — Cross-state contract verification + runbook (task: tank-cross-state-contract)

**Contract status:** Fully correct as built. Zero fixes required.

**Key findings:**
- `terraform/azure/outputs.tf` correctly exports `vpn_gateway_public_ip` (non-sensitive) and `vpn_shared_key` (sensitive=true). Both consumed verbatim in `terraform/gcp/vpn.tf` via `data.terraform_remote_state.azure.outputs.*`.
- `terraform/gcp/outputs.tf` correctly exports `gcp_vpn_public_ip` and `gcp_vpc_cidr` (both non-sensitive). Both consumed in `terraform/azure/vpn.tf` via `data.terraform_remote_state.gcp[0].outputs.*`.
- Azure GCP remote-state read gated correctly: `count = var.enable_onprem_connection ? 1 : 0` in `terraform/azure/vpn.tf`. LNG and VPN connection resources also gated identically; both reference `[0]` index safely.
- GCP Azure remote-state read is NOT gated — correct by design; GCP always depends on Azure state existing per the 3-apply order.
- `expressroute_service_key` uses `one()` for null-safe output when ER is disabled — elegant pattern worth reusing.
- `interconnect_pairing_key` is conditional via ternary in value expression (not count); sensitive=true applies regardless.

**Sensitive flag pattern:** Both configs use `sensitive = true` on outputs that contain secrets. The `one()` wrapper on Azure allows a single output block to be null-safe without a count on the output itself.

**Validation commands that work (no backend needed):**
```
terraform -chdir="terraform/azure" validate
terraform -chdir="terraform/gcp"   validate
```
Both return `Success! The configuration is valid.` with providers already initialized from prior `init -backend=false` runs.

**Runbook written:** `terraform/README.md` — canonical 3-apply order with exact variable/output names, verification commands, Megaport handoff instructions, and cleanup order.

**Decision written:** `.squad/decisions/inbox/tank-cross-state-contract.md`
