# Session Log — AZ VPN SKU Fix

**Date:** 2026-06-18  
**Session:** az-vpn-sku-fix  
**Status:** Complete

## Summary

Live incident: Azure VPN gateway deployment failed with `NonAzSkusNotAllowedForVPNGateway` error. Azure has consolidated gateway SKUs — only AZ variants (VpnGw1AZ-VpnGw5AZ) are now supported. 

**Fix applied:**
- Updated `gateway_sku` default to `VpnGw1AZ` in variables.tf
- Added validation regex to enforce AZ-only selection
- Configured zone-redundant Standard PIPs on both VPN gateway public IPs
- Updated example tfvars
- Added troubleshooting documentation to README

**Incidents handled:**
1. NonAzSkusNotAllowedForVPNGateway — Fixed by default + validation
2. Standard PIP gate for restricted subscriptions — Documented with pre-flight detection guidance

**Team contributions:**
- Trinity: Terraform config fixes + decisions
- Morpheus: Reviewer gate (APPROVED)
- Scribe: Decisions merge, documentation coordination

## Outcomes

- Live deployment verified with VpnGw1AZ SKU
- terraform validate passes
- All documentation updated
- Decisions committed to decisions.md
- Ready for deployment

## Post-Deployment: IP Tags Idempotency Fix

**2026-06-18:** VPN gateway deployment reached `Succeeded` state.
- **Gateway:** VpnGw1AZ (VpnGw1AZ)
- **Public IP:** 20.236.226.149

**Issue discovered:** Azure auto-injects `ip_tags` value (FirstPartyUsage=/Unprivileged) on gateway public IPs, causing Terraform to detect drift and perpetually plan PIP destruction/recreation on every `terraform apply`.

**Resolution applied:**
- Added `lifecycle { ignore_changes = [ip_tags] }` to all three gateway public IPs:
  - vpn_gw_pip1
  - vpn_gw_pip2
  - er_gw_pip
- Verified with `terraform validate` (success) and `terraform plan` (no changes needed — drift eliminated)

**Commit:** c113ddd (fix: ip_tags lifecycle ignore_changes for Azure-injected PIP attributes)

## Related Issues

- Azure deprecated non-AZ VPN gateway SKUs
- DMAUSER-FDPO subscription requires Standard PIP feature registration
- Azure auto-injects ip_tags on gateway PIPs (now mitigated with lifecycle rules)
- All issues documented and mitigated in deploy guidance
