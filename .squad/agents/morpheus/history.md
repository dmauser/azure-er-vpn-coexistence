# Morpheus — History

## Seed
- **Project:** azure-er-vpn-coexistence2 — Azure ExpressRoute + S2S VPN coexistence lab using GCP as on-prem.
- **User:** dmauser
- **Stack:** Terraform (azurerm + google), Azure hub/spoke, GCP Classic VPN, Megaport for ER/Interconnect.
- **Mission:** Lead the Terraform revamp; own architecture, address plan, cross-state design, and the reviewer gate.

## Learnings

### 2026-06-17 — Reviewer Gate: Terraform Revamp

**Verdict: APPROVED.**

Key observations:
1. The 3-apply pattern (Azure base → GCP → Azure connection) cleanly breaks the circular IP dependency. The gating via `count` on `terraform_remote_state` is the correct pattern — validate passes even when the remote state file doesn't exist.
2. `.terraform.lock.hcl` was incorrectly gitignored by Switch. Fixed during review. Lock files must be committed for reproducible provider versions across team members.
3. The GCP `terraform_remote_state.azure` is intentionally ungated (always reads Azure state). This is correct because the 3-apply order guarantees Azure state exists before any GCP operation. Gating it would add complexity for no benefit.
4. Using `one()` for conditional outputs (ER service key, circuit name) is the idiomatic Terraform ≥1.5 approach — produces `null` when count=0, clean single value when count=1.
5. Single VPN connection (not dual) matches the Classic VPN single-IP constraint on the GCP side. If a future revision moves to HA VPN, a second connection resource will be needed.

### 2026-06-17 — Final Docs Review (First-Time-User Walkthrough)

**Verdict: APPROVED** (with two minor fixes applied in-place).

Reviewed root `README.md`, `terraform/README.md`, both `terraform.tfvars.example` files, and spot-checked every `.tf` file for resource/output/variable name alignment.

Findings:
1. **Two missing code-fence closers** in `terraform/README.md` (Steps 2 and 3 bash blocks were unclosed, causing downstream markdown to render as code). Fixed in-place.
2. All resource names in verification commands match the Terraform code: `lab-er-vpn-coexistence`, `Azure-to-OnpremGCP`, `lng-onprem-gcp`, `vpn-to-azure`, `vpnlab-vm1`, `az-hub-er-circuit`, `ER-Connection-to-Onprem`, `Az-Hub-vpngw`, `Az-Hub-ergw`.
3. All output names (`vpn_gateway_public_ip`, `vpn_shared_key`, `gcp_vpn_public_ip`, `gcp_vpc_cidr`, `expressroute_service_key`, `interconnect_pairing_key`) verified against `outputs.tf` in both modules.
4. Pre-flight checklist, gateway-timing warning, SSH instructions, troubleshooting section, and cleanup order are all present and correct.
5. Both configs pass `terraform validate`.
6. The 3-apply walkthrough is complete end-to-end — a first-time user has every command and value needed.

- 2026-06-17: Reviewed deploy.sh/ps1 and route dump scripts. Caught a secret safety gap in bash where TF_VAR_vm_admin_password was unset at the end of the script instead of in an EXIT trap, meaning it would leak if the script failed. Enforced strict trap hygiene for environment variable secrets.

### 2026-06-17 — Session finalization (Scribe: decisions merged, orchestration logs)

- Terraform revamp finalized: all three gates passed (Terraform Revamp Verdict, Documentation Final Review, Script Revamp Verdict)
- High-severity finding (deploy.sh trap) enforced; Coordinator implemented fix — issue RESOLVED
- All 14 decisions merged into `.squad/decisions.md` from inbox; inbox files deleted
- Orchestration log written: 2026-06-17T20_47_00-morpheus.md
- Ready for team commit: Terraform + docs + scripts all validated and secure

### 2026-06-17 — Reviewer Gate: Azure VPN AZ SKU Hotfix

**Verdict: APPROVED.**

Reviewed uncommitted changes for Azure's `NonAzSkusNotAllowedForVPNGateway` enforcement.

Key observations:
1. `gateway_sku` now defaults to `VpnGw1AZ`, and validation `^VpnGw[1-5]AZ$` correctly allows only `VpnGw1AZ` through `VpnGw5AZ`.
2. Zone-redundant PIPs (`zones = ["1", "2", "3"]`) are applied only to `vpn_gw_pip1` and `vpn_gw_pip2`; `er_gw_pip` remains unchanged Standard/Static.
3. Fresh-deploy correctness checks clean: VPN gateway still consumes `var.gateway_sku`; example tfvars and README align with the new default.
4. `terraform -chdir=terraform\azure validate` passes.

APPROVE.
