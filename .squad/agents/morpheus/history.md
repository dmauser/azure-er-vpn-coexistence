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
