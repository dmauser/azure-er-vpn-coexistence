# Session Log — Standard Public IP Gate Probe — 2026-06-17

## Summary

Trinity completed pre-flight detection for the Azure Standard public IP feature gate (`AllowBringYourOwnPublicIpAddress`) on restricted subscriptions. The probe was added to both root deploy scripts (`deploy.sh` and `deploy.ps1`) and documented in `terraform/README.md`. Morpheus reviewed and approved.

## Outcome

- ✅ Pre-flight probe added to `deploy.sh` and `deploy.ps1`
- ✅ Detection logic: temp RG creation with `az network public-ip create --sku Standard`
- ✅ Bypass: `SKIP_PIP_PRECHECK=1` environment variable
- ✅ User-driven registration: probe detects gate and outputs exact three `az` commands for user to run once
- ✅ Documentation: "Restricted subscriptions: Standard public IP gate" section added to Troubleshooting
- ✅ Validation: syntax checks passed; `terraform validate` passes both Azure and GCP configs
- ✅ Morpheus approval: all gates passed

## Rationale

Active-active VPN gateways with BGP require Standard SKU public IPs. Failure occurs ~20 min into `terraform apply` when PIP allocation hits the feature gate. Early detection (pre-flight, ~30 sec) prevents user confusion and provides immediate remediation path.

## Files Changed

- `deploy.sh` — Standard-PIP probe in `check_prereqs()`
- `deploy.ps1` — Standard-PIP probe in `Test-Prereqs()`
- `terraform/README.md` — Troubleshooting subsection added
- `.squad/agents/trinity/history.md` — Session entry appended

## Date

**Session Date:** 2026-06-17  
**Work Completed:** 2026-06-17T21:50:01-05:00  
**Agents:** Trinity (implementation), Morpheus (review)
