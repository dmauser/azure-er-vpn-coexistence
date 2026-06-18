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

## Governance

- All meaningful changes require team consensus
- Document architectural decisions here
- Keep history focused on work, decisions focused on direction
