# Squad Decisions

## Terraform Revamp Session (2026-06-17)

### 1. Morpheus Reviewer Gate — Terraform Revamp Verdict

**Date:** 2026-06-17  
**Reviewer:** Morpheus (Lead / Architect)  
**Scope:** `terraform/azure/`, `terraform/gcp/`, `terraform/README.md`, root `README.md`, `archive/README.md`, `.gitignore`

**Validation:**
```
terraform -chdir="terraform/azure" validate  →  Success! The configuration is valid.
terraform -chdir="terraform/gcp"   validate  →  Success! The configuration is valid.
```

**Assessment Summary:**
1. **Secrets / State Hygiene ✅** — All sensitive outputs marked; `.gitignore` correct; no hardcoded secrets.
2. **Cross-State Correctness ✅** — Azure ↔ GCP output/input names match exactly; gating logic correct.
3. **Billing Safety ✅** — ExpressRoute and Interconnect both default `false` with `count` guards.
4. **Fidelity ✅** — All CIDR blocks, gateway configs, and resource parameters verified against specification.
5. **Docs Accuracy ✅** — `terraform/README.md` and root README verified; 3-apply order documented correctly.

**Minor Fix Applied:** `.gitignore` — removed `.terraform.lock.hcl` from exclusions (lock files should be committed per Terraform best practice).

**Verdict: APPROVED** — Terraform revamp is clean, correct, and safe to ship. All five review criteria pass.

---

### 2. Trinity — Azure Terraform Configuration

**Date:** 2026-06-17  
**Author:** Trinity (Azure TF Engineer)  
**Status:** Validated (`terraform validate` passes)

**Files created:**
- `terraform/azure/` (9 files: providers, variables, main, gateways, vm, vpn, expressroute, outputs, README, tfvars.example)

**Contract compliance:** All items verified ✅
- RG, location, address space, VPN gateway (active-active), ER gateway, peering
- Variables: admin user/pass (sensitive), SSH source restriction, gateway SKU, enable flags
- Outputs: VPN gateway public IP, VPN shared key (sensitive), ER service key (sensitive, null-safe)
- Gating: GCP remote-state read and VPN/ER resources all correctly gated on enable flags

**Notable decisions:**
1. NSG applied at subnet level only (not NIC) — avoids redundancy vs. Bicep equivalent
2. `vpn_bgp_asn = 65515` as local (can promote to variable if needed)
3. Single VPN connection (not dual active-active) — matches deploy.azcli
4. Lock file `.terraform.lock.hcl` generated and should be committed

---

### 3. Niobe — GCP Terraform Configuration

**Date:** 2026-06-17  
**Author:** Niobe (GCP TF Engineer)  
**Status:** Validated (`terraform validate` passes)

**Files created:**
- `terraform/gcp/` (8 files: providers, variables, main, vpn, interconnect, outputs, README, tfvars.example, lock)

**Contract compliance:** All items verified ✅
- `terraform_remote_state` with correct path to Azure state
- Consumes Azure outputs: `vpn_gateway_public_ip`, `vpn_shared_key`
- All 8 variables with correct defaults
- All 4 outputs: `gcp_vpn_public_ip`, `gcp_vpc_cidr`, `interconnect_pairing_key` (sensitive), `interconnect_attachment_name`

**Notable decisions:**
1. All resource names match `deploy.azcli` exactly
2. `terraform fmt` applied in-place during creation
3. `google_compute_forwarding_rule.target` uses `.self_link` (required by GCP API for Classic VPN)
4. Lock file included; provider google 5.45.2 selected

---

### 4. Tank — Cross-State Integration Contract Verification

**Date:** 2026-06-17  
**Author:** Tank (Connectivity / Integration Engineer)  
**Status:** Verified — both configs pass `terraform validate`

**Cross-State Contract:** Exact output/input mapping verified ✅
| Producer | Output | Sensitive | Consumer | Reference |
|---|---|---|---|---|
| `terraform/azure` | `vpn_gateway_public_ip` | no | `terraform/gcp` | `data.terraform_remote_state.azure.outputs.vpn_gateway_public_ip` |
| `terraform/azure` | `vpn_shared_key` | **yes** | `terraform/gcp` | `data.terraform_remote_state.azure.outputs.vpn_shared_key` |
| `terraform/gcp` | `gcp_vpn_public_ip` | no | `terraform/azure` | `data.terraform_remote_state.gcp[0].outputs.gcp_vpn_public_ip` |
| `terraform/gcp` | `gcp_vpc_cidr` | no | `terraform/azure` | `data.terraform_remote_state.gcp[0].outputs.gcp_vpc_cidr` |

**3-Apply Order:**
```
Step 1: terraform/azure apply (enable_onprem_connection=false)
        → emits vpn_gateway_public_ip + vpn_shared_key

Step 2: terraform/gcp apply (always full)
        → reads Azure state
        → emits gcp_vpn_public_ip + gcp_vpc_cidr

Step 3: terraform/azure apply (enable_onprem_connection=true)
        → reads GCP state
        → creates S2S VPN connection
```

**Gating verification:** Azure's GCP remote-state read correctly gated on `enable_onprem_connection`; GCP's Azure read always required (correct per apply order).

**Sensitive flag verification:** All three secrets (`vpn_shared_key`, `expressroute_service_key`, `interconnect_pairing_key`) marked `sensitive = true`.

**Megaport handoff:** ER service key and Interconnect pairing key both available as sensitive outputs for VXC provisioning in Step 4.

**Result:** No mismatches found. Contract fully verified.

---

### 5. Switch — Root README Rewrite for Terraform-First Workflow

**Date:** 2026-06-17  
**Author:** Switch (Docs/DevRel)  
**Status:** COMPLETED

**What changed:**
Rewrote root `README.md` from script-centric (8-step deploy.azcli walkthrough) to Terraform-first:

**Preserved sections:**
- Title, intro, cost warning, architecture diagram + table, address plan CIDR table, license

**Replaced sections:**
1. Repository layout — old: 8 scripts + bicep/. New: terraform/azure/, terraform/gcp/, terraform/README.md, archive/, media/
2. Prerequisites — old: 7-item detailed instructions. New: 5-row table (Terraform ≥1.5, az login, gcloud ADC, GCP project, Megaport)
3. Step-by-step — old: 8 manual sections. New: "Quick Start — Terraform Workflow" with 4 concise steps (Azure base → GCP → Azure connection → optional ER/Interconnect)

**New sections:**
- Legacy routing helpers (archive note for routes.azcli / routes.ps1)
- Notes on GCP Classic VPN deprecation (2025-08-01 BGP cutoff)

**Links:** Clear delegation to `terraform/README.md` for full details, variables, verification, ER provisioning, coexistence tests, cleanup.

**Rationale:**
1. Single source of truth — Terraform runbook in `terraform/README.md` (owned by Tank)
2. Accuracy — All variable/output names sourced directly from Terraform code
3. Progressive disclosure — Root README shows 3-apply workflow at a glance; details link out
4. History preservation — Legacy scripts archived with full git history intact

**Testing:** README verified against Terraform configs, variable/output definitions, CIDRs (all correct), and archive/README.md.

---

### 6. Morpheus — Final Documentation Review — First-Time-User Gate

**Date:** 2026-06-17T20:08:00-05:00  
**Reviewer:** Morpheus (Lead/Architect)  
**Status:** APPROVED

Performed a complete first-time-user walkthrough of lab documentation: root `README.md`, `terraform/README.md`, both `terraform.tfvars.example` files. Spot-checked all `.tf` files to confirm every resource name, output name, variable default, region, and zone referenced in docs matches actual Terraform code.

**Minor fixes applied (in-place):**
- Two missing code-fence closers in `terraform/README.md` — bash blocks for Steps 2 and 3 were missing their closing ` ``` `, causing all subsequent markdown to render as code. Fixed.

**Verified correct:**
- Resource names: `lab-er-vpn-coexistence`, `Azure-to-OnpremGCP`, `lng-onprem-gcp`, `vpn-to-azure`, `vpnlab-vm1`, `az-hub-er-circuit`, `ER-Connection-to-Onprem`, `Az-Hub-vpngw`, `Az-Hub-ergw` — all match `.tf` files.
- Output names: `vpn_gateway_public_ip`, `vpn_shared_key`, `gcp_vpn_public_ip`, `gcp_vpc_cidr`, `expressroute_service_key`, `interconnect_pairing_key` — all match `outputs.tf`.
- Defaults: region `us-central1`, zone `us-central1-c`, envname `vpnlab`, RG `lab-er-vpn-coexistence` — all match `variables.tf`.
- Pre-flight checklist, gateway timing warning, SSH instructions, troubleshooting section, cleanup order all present and correct.
- `terraform validate` passes for both `terraform/azure` and `terraform/gcp`.

**Verdict: APPROVED.** Documentation is complete and correct for a first-time user to deploy this lab end-to-end.

---

### 7. Morpheus — Script Revamp Verdict (Coordinator Trap Fix Applied)

**Date:** 2026-06-17  
**Reviewer:** Morpheus (Lead/Architect)  
**Status:** CHANGES REQUESTED → RESOLVED

**Critical Issue (Severity: High)** — deploy.sh Secret Safety:
- **Problem:** If deploy.sh fails during execution (e.g., terraform apply fails), the `set -e` causes abort. The `unset TF_VAR_vm_admin_password` commands at script end will not execute, leaving password in environment.
- **Solution:** Use bash trap: `trap 'unset TF_VAR_vm_admin_password' EXIT` when exporting the secret to guarantee cleanup on any exit.
- **Status after Coordinator's fix:** ✅ Trap implemented. Issue resolved.

**Other Findings (All None severity):**
- deploy.ps1 — Properly implemented using try/finally. ✅
- Cross-State Correctness & Gating — 3-apply order and reverse destroy order properly gated. ✅
- Billing Safety — ExpressRoute correctly defaulted false and hidden behind explicit flags. ✅
- Route-dump scripts — Correct and fail gracefully when expected resources missing. ✅

---

### 8. Niobe — GCP Route Dump Scripts Decision

**Date:** 2026-06-17  
**Author:** Niobe (GCP Terraform Engineer)  
**Scope:** Root GCP route-dump helper scripts

Create root-level `dump-routes-gcp.sh` and `dump-routes-gcp.ps1` as prompt-driven diagnostics helpers with flag and environment-variable overrides for non-interactive use.

**Rationale:**
- Scripts work on Linux/macOS and Windows from repository root.
- Defaults sourced from `terraform/gcp/` resource names: Region `us-central1`, VPC network `vpnlab-vpc`, Cloud Router `vpnlab-router`, Classic VPN gateway `onpremvpn`, VPN tunnel `vpn-to-azure`, VPN static route `vpn-to-azure-route-1`.
- Cloud Router probing is optional and graceful because `enable_interconnect=false` by default.

**Commands Covered:**
- `gcloud compute routes list` with project/network filtering.
- `gcloud compute routers get-status` and `describe`.
- `gcloud compute vpn-tunnels describe` and `list`.
- `gcloud compute forwarding-rules list` filtered to target VPN gateway.
- `gcloud compute routes describe` for static route inspection.

---

### 9. Switch — Deploy Wrappers and VM Hardening Docs

**Date:** 2026-06-17  
**Author:** Switch (Docs/DevRel)

Updated `terraform/README.md` and root `README.md` to make `deploy.sh` / `deploy.ps1` the recommended deployment path, while keeping the manual 3-apply walkthrough as the advanced path. Docs now reflect Azure VM hardening: no public IPs, Serial Console access, password via `TF_VAR_vm_admin_password`, and no `restrict_ssh_source_prefix`.

Also documented the root route inspection scripts for Azure and GCP diagnostics, plus the ExpressRoute/Interconnect script handoff point where users must order Megaport VXCs and re-run after the Azure circuit is `Provisioned`.

---

### 10. Switch — Network Test Tools Documentation

**Date:** 2026-06-17  
**Author:** Switch (Docs/DevRel)

Documented the first-boot network test toolkit in `terraform/README.md#network-test-tools` and linked it from root README. Section covers Azure cloud-init `custom_data` path, GCP `metadata_startup_script` path, install timing, access constraints, tool purposes, and S2S VPN validation examples.

---

### 11. Switch — Requirements & Setup Section Expansion

**Date:** 2026-06-17  
**Decided by:** Switch (Docs/DevRel)  
**Status:** COMPLETED

Expanded `terraform/README.md` Prerequisites section with new Requirements & Setup subsection covering:

1. **Tool Installation** — Terraform, Azure CLI, gcloud — with platform-specific commands (Windows/Linux/macOS).
2. **Azure Authentication** — `az login`, subscription listing, confirmation.
3. **GCP Authentication** — `gcloud auth login`, ADC setup (`gcloud auth application-default login`), project selection.
4. **Required GCP APIs** — `compute.googleapis.com` (required for all), `servicenetworking.googleapis.com` (Interconnect only).
5. **Permissions & Service Accounts** — Azure: Contributor role; GCP: Compute Network Admin; verification commands.

Root `README.md` maintains quick-reference Prerequisites table and points to `terraform/README.md#requirements--setup` for detailed instructions.

---

### 12. Tank — Deploy Wrapper Scripts Decision

**Date:** 2026-06-17  
**Author:** Tank (Connectivity / Integration Engineer)  
**Task:** deploy-scripts  
**Status:** Done

Authored two wrapper scripts at repo root:
- `deploy.sh` — Bash for Linux/macOS (288 lines, set -euo pipefail).
- `deploy.ps1` — PowerShell for Windows and pwsh on Linux/macOS (332 lines, Set-StrictMode -Version Latest).

**Key Design Decisions:**
- All `-var` flag names cross-checked against actual `variables.tf`.
- Password handled as `TF_VAR_vm_admin_password` env var (not in process list); cleared in finally block (PS) and via trap on EXIT (bash).
- Destroy with `enable_onprem_connection=true` ensures GCP state resolves for proper teardown of LNG + VPN connection.
- ExpressRoute stage creates circuit/gateway connection, then dumps pairing keys and exits (user must order Megaport, wait for Provisioned, then re-run).
- No tfvars file required; all required values passed via `-var` flags.

**Syntax Check Results:**
- `bash -n deploy.sh` → exit 0 (clean).
- PowerShell AST parse → 0 errors.
- Note: `deploy.sh` converted from CRLF to LF line endings.

---

### 13. Tank — First-Time User Success Audit

**Date:** 2026-06-17  
**Author:** Tank (Connectivity / Integration Engineer)  
**Task:** docs-success-audit  
**Status:** Done

Updated `terraform/README.md` with:

1. **Pre-flight Checklist** (12 items) — tools, auth, project, API, IP, password.
2. **Step 1 gateway timing note** — ⏱ 30–45 minute warning added.
3. **Public IP retrieval** — `curl -4 ifconfig.io` (Linux/macOS) + PowerShell equivalent added inline.
4. **`terraform plan` recommendation** — added before each `apply` in Steps 1, 2, 3.
5. **Explicit GCP SSH command** — `gcloud compute ssh vpnlab-vm1 --zone us-central1-c` with envname note and `--tunnel-through-iap` documentation.
6. **Troubleshooting / Common Pitfalls section** (7 entries) — NotConnected, remote_state empty, Compute API missing, password policy, IP change, gateways stuck, ER never Provisioned, destroy order failure.

Updated `terraform/azure/terraform.tfvars.example` and `terraform/gcp/terraform.tfvars.example` with inline IP retrieval commands and dynamic-IP re-apply warnings.

**Verification:** `terraform validate` passes for both `terraform/azure` and `terraform/gcp`. No `.tf` files modified.

---

### 14. Trinity — VM Hardening and Azure Route Dumps

**Date:** 2026-06-17  
**Author:** Trinity (Azure Terraform Engineer)

**VM Hardening Decision:**
Azure lab VMs are now private-only: no VM public IP resources, no NIC public IP bindings, no custom inbound SSH NSG rule, no `restrict_ssh_source_prefix` input. Access is through Azure Serial Console (enabled by managed boot diagnostics on each VM).

All three Linux VMs run shared cloud-init at boot via Terraform `custom_data` to install network tools (`net-tools`, `traceroute`, `tcptraceroute`, `nmap`, `hping3`, `iperf3`, `nginx`, `speedtest-cli`, `moreutils`) and publish VM hostname through nginx. Requires Azure default outbound access for apt (no explicit NAT Gateway/Azure Firewall egress defined).

**Follow-up needed:**
- Tank: Update deployment/orchestration logic that still collects or passes `restrict_ssh_source_prefix`.
- Switch: Update root and Terraform docs that still tell users to collect their public IP or SSH directly to Azure VMs.
- Switch/Tank: Note that first boot depends on Azure default outbound access for apt unless a future explicit egress design replaces it.

**Route verification scripts:**
Root-level Azure route dump helpers added:
- `dump-routes-azure.sh`
- `dump-routes-azure.ps1`

Dump ExpressRoute circuit routes, VM effective routes, and ER gateway learned routes via Azure CLI. Continue gracefully when ExpressRoute disabled or not provisioned.

---

## Governance

- All meaningful changes require team consensus
- Document architectural decisions here
- Keep history focused on work, decisions focused on direction
