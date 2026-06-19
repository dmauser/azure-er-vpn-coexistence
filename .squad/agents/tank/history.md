# Tank — History

## Seed
- **Project:** azure-er-vpn-coexistence2 — Azure ER/VPN coexistence lab, GCP as on-prem.
- **User:** dmauser
- **Stack:** Terraform across two configs; `terraform_remote_state` cross-wiring; Megaport handoff.
- **Mission:** Own the cross-state contract, shared-key flow, 3-apply order, key outputs, and validation.

## Learnings

### 2026-06-17 — Deploy wrapper scripts (task: deploy-scripts)

**Scope:** Built `deploy.sh` (bash) and `deploy.ps1` (PowerShell) at repo root. Both scripts validate prerequisites, orchestrate the 3-apply Terraform deployment, support an optional ER stage, and handle destroy in reverse order.

**Variable names verified against actual `.tf` files before coding:**
- Azure required: `vm_admin_username`, `vm_admin_password`, `restrict_ssh_source_prefix` (with `/32` suffix appended by script)
- Azure booleans: `enable_onprem_connection` (false→Step1, true→Step3), `enable_expressroute` (ER stage only)
- GCP required: `project`, `caller_source_ip` (no mask)
- GCP boolean: `enable_interconnect` (ER stage only)
- Resource/output names: `Azure-to-OnpremGCP` (VPN connection), `vpn-to-azure` (GCP tunnel), `lab-er-vpn-coexistence` (RG), `vpnlab-vm1` (GCP VM default), `interconnect_pairing_key` / `expressroute_service_key` (ER keys)

**Security design:**
- Password is collected via `read -s` (bash) / `Read-Host -AsSecureString` (PowerShell), then exported to `TF_VAR_vm_admin_password` environment variable. This keeps the secret out of the process list (`ps aux`). The shell variable is cleared immediately after export.
- `TF_VAR_vm_admin_password` is removed from the environment in a `finally` block (PowerShell) and via `unset` (bash) on exit, including the ER-stage early-exit path.

**Key design decisions:**
- `terraform -input=false` prevents interactive prompts during CI/CD usage.
- `enable_onprem_connection=true` is passed during destroy so Terraform can plan the LNG + VPN connection teardown while GCP state still exists (remote_state data source resolves correctly).
- ER stage stops after dumping keys and instructs user to re-run `--expressroute` after circuit reaches Provisioned (Megaport VXC must be active before `ER-Connection-to-Onprem` is functional).

**Bash gotcha fixed:** heredoc delimiter `USAGE` conflicted with the word `USAGE` appearing as a section header inside the heredoc content → renamed delimiter to `HELPTEXT`.

**Line ending issue fixed:** Windows `create` tool writes CRLF by default; bash fails on `\r\n`. Fixed by converting `deploy.sh` to LF with `[System.IO.File]::WriteAllText(...)` using `UTF8` encoding.

**Syntax check results:**
- `bash -n deploy.sh` → exit 0 (no errors)
- PowerShell `Parser::ParseFile` → 0 errors

**Decision written:** `.squad/decisions/inbox/tank-deploy-scripts.md`

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

### 2026-06-19 — Megaport key polling (task: megaport-key-poll)

**Scope:** Replaced single-shot Terraform output reads in Step 4c of both deploy.ps1 and deploy.sh with polling loops that retry until both keys are non-empty or a timeout is reached.

**Output names confirmed:**
- GCP Partner Interconnect pairing key: `interconnect_pairing_key` (in `terraform/gcp`)
- Azure ExpressRoute service key: `expressroute_service_key` (in `terraform/azure`)
Both are `sensitive = true` in their respective `outputs.tf`. `terraform output -raw` returns the raw string value for sensitive outputs without redaction — safe to capture into a variable.

**Polling design:**
- Interval: 30 s; timeout: 1 800 s (30 min). Both stored in tunable constants at script top.
  - PS1: `$KeyPollIntervalSec` / `$KeyPollTimeoutSec` (lines ~98-101)
  - Bash: `KEY_POLL_INTERVAL` / `KEY_POLL_TIMEOUT` (readonly, lines ~28-31)
- Each cycle independently tracks which key is still missing; stops polling a key as soon as it's captured. Prints elapsed time + pending key names between cycles.
- On timeout: falls back to the existing warn-and-continue behavior so the script still exits cleanly. Ctrl-C terminates via the existing `set -euo pipefail` / `$ErrorActionPreference = Stop` paths.
- Polling only runs inside `Invoke-ExpressRoute` / `run_expressroute` — gated by `-EnableExpressRoute` / `--expressroute` flag. Not executed for normal VPN-only deploys.
- Once both keys are captured they are printed with cyan labels and the existing Megaport portal instructions follow naturally.

**Syntax checks passed:**
- `Parser::ParseFile` → 0 errors (deploy.ps1)
- `bash -n deploy.sh` → exit 0

- Terraform revamp finalized and validated by Morpheus (all gates passed)
- Deploy wrapper scripts and success audit work committed as per Scribe orchestration log
- Deploy work SUPERSEDED by Coordinator's clean rewrite of deploy.sh/deploy.ps1
- Coordinator applied critical trap fix to deploy.sh (TF_VAR_vm_admin_password cleanup on EXIT) — High-severity finding from Morpheus resolved
- All 14 decisions merged into `.squad/decisions.md` from inbox; inbox files deleted
- No orchestration log for Tank (work superseded); decisions preserved
