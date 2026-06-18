# Switch — History

## Seed
- **Project:** azure-er-vpn-coexistence2 — Azure ER/VPN coexistence lab, GCP as on-prem.
- **User:** dmauser
- **Stack:** Markdown docs for a Terraform lab.
- **Mission:** Rewrite `README.md` around the Terraform flow, add `archive/README.md`, update `.gitignore`.

## Learnings

**2026-06-17 · Housekeeping Pass 1 — Archive & .gitignore**

Moved legacy automation into `archive/`:
- **Bash/PowerShell scripts** (deploy, routes, vpnsite2, customer-demo-migration) → `archive/`
- **ARM template** (azuredeploy.json) → `archive/`
- **Bicep directory** (local template, modules) → `archive/bicep/`
- **Total**: 12 items moved via `git mv` to preserve history.

Created `archive/README.md` explaining each archived file and why (now superseded by Terraform).

Updated root `.gitignore` with Terraform state safety block:
- Ignores `.terraform/`, `*.tfstate`, `*.tfvars` (except `.tfvars.example`), lock files, crash logs, override files.
- Preserved existing Squad runtime ignores.

**2026-06-17 · Housekeeping Pass 2 — README Rewrite**

Rewrote root `README.md` to be **Terraform-centric**:
- Kept: title, intro paragraph, cost warning, architecture diagram/table, Address plan CIDR table.
- Replaced: "Repository layout" with new structure (terraform/azure/, terraform/gcp/, terraform/README.md, archive/, media/).
- Replaced: old "Prerequisites" (bash/PowerShell/gcloud setup) with minimal 5-row table.
- Replaced: old "Step-by-step: what deploy.azcli does" (8 sections) with **Quick Start — Terraform Workflow** (3 applies + 1 optional ER/Interconnect, concise, links to terraform/README.md for details).
- Kept: GCP Classic VPN deprecation note (2025-08-01 BGP cutoff).
- Kept: License section.
- Added: **Legacy routing helpers** section pointing to archived routes.azcli/routes.ps1.
- **No variable/output names invented** — all drawn from terraform/azure/variables.tf, outputs.tf, terraform/gcp/variables.tf, outputs.tf, terraform/README.md.


