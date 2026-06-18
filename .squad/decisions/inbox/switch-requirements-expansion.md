# Decision: Requirements & Setup Section Expansion

**Date:** 2026-06-17  
**Decided by:** Switch (Docs/DevRel)  
**Status:** COMPLETED

## Rationale

The `terraform/README.md` Prerequisites section was minimal (5-row table only), forcing users to guess at install commands and auth steps. This created friction for onboarding, especially for first-time Terraform/Azure/GCP users.

## What changed

### terraform/README.md

Expanded the **Prerequisites** section with a new **Requirements & Setup** subsection that covers:

1. **Tool Installation** — Terraform, Azure CLI, gcloud — with platform-specific commands:
   - **Windows (winget):** `winget install --id Hashicorp.Terraform`, `winget install --id Microsoft.AzureCLI`, `winget install --id Google.CloudSDK`
   - **Linux (apt):** HashiCorp apt repo + `apt install terraform`; Azure CLI via curl; gcloud via official installer.
   - **macOS (Homebrew):** `brew install`, with HashiCorp tap for Terraform.
   - **Verify blocks** for each tool.

2. **Azure Authentication** — Step-by-step:
   - `az login` (with `--use-device-code` for headless).
   - List subscriptions: `az account list --output table`.
   - Set subscription: `az account set --subscription "<Name or ID>"`.
   - Confirm: `az account show --output table`.
   - Note: Terraform's `azurerm` provider auto-uses CLI context; optional `ARM_SUBSCRIPTION_ID` env var override.

3. **GCP Authentication** — Step-by-step:
   - User auth: `gcloud auth login`.
   - **ADC setup** (required for Terraform's `google` provider): `gcloud auth application-default login`.
   - Project listing: `gcloud projects list`.
   - Project selection: `gcloud config set project <PROJECT_ID>` + confirm.
   - Note: `project` variable in `terraform/gcp/terraform.tfvars` must match; ADC path shown.

4. **Required GCP APIs** — enable upfront:
   - `gcloud services enable compute.googleapis.com`.
   - Note on servicenetworking.googleapis.com for Interconnect.

5. **Permissions & Service Accounts**:
   - Azure: Contributor role required; verification via `az role assignment list`.
   - GCP: Compute Network Admin required; verification via `gcloud projects get-iam-policy`.
   - Megaport: only for Step 4; no additional GCP/Azure perms needed.

### root README.md

Kept the **Prerequisites** table (5 rows, unchanged) and added a single pointer line:

> For **detailed install commands** (Windows/Linux/macOS), **auth steps**, and **permission verification**, see **[Requirements & Setup in `terraform/README.md`](./terraform/README.md#requirements--setup)**.

This maintains the quick-reference table at the root while delegating detailed setup to the runbook.

## Accuracy notes

- All install commands verified against official docs (HashiCorp, Microsoft, Google).
- Azure CLI: uses `az login` context (no hardcoded subscription_id in config); ARM_SUBSCRIPTION_ID env var is optional override.
- GCP: uses Application Default Credentials (ADC) — required for Terraform's `google` provider; the `project` variable in `terraform/gcp/terraform.tfvars` is explicitly a required input.
- GCP APIs: `compute.googleapis.com` is required for all steps; `servicenetworking.googleapis.com` is noted for Interconnect (Step 4) only.
- Permissions: aligned with actual Terraform resource scopes (VNet/VM creation = Contributor/Network Admin; Interconnect = no additional perms beyond Compute Network Admin).

## Testing

- Tested install commands structure against official installers.
- Auth flows verified against Azure/GCP Terraform provider docs.
- Anchor link `#requirements--setup` in root README points to the h2 heading in terraform/README.md.

## Cross-references

- Root `README.md` Prerequisites now has a clear link to the expanded section.
- terraform/README.md Prerequisites table moved above the new Requirements & Setup section (natural reading order).

## Post-decision actions

- Both README files staged.
- Learnings appended to `.squad/agents/switch/history.md`.
- No further expansions planned for prerequisites (this is the comprehensive version).
