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

## Related Issues

- Azure deprecated non-AZ VPN gateway SKUs
- DMAUSER-FDPO subscription requires Standard PIP feature registration
- Both issues documented and mitigated in deploy guidance
