# Tank — History

## Seed
- **Project:** azure-er-vpn-coexistence2 — Azure ER/VPN coexistence lab, GCP as on-prem.
- **User:** dmauser
- **Stack:** Terraform across two configs; `terraform_remote_state` cross-wiring; Megaport handoff.
- **Mission:** Own the cross-state contract, shared-key flow, 3-apply order, key outputs, and validation.

## Learnings

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
