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

**2026-06-17 · Housekeeping Pass 3 — Requirements & Setup Expansion**

Expanded `terraform/README.md` **Prerequisites** section with detailed **Requirements & Setup**:
- **Tool installation** (Terraform, Azure CLI, gcloud) with commands for Windows (winget), Linux (apt/curl), macOS (Homebrew).
- **Verification blocks** for each tool (`terraform -version`, `az version`, `gcloud --version`).
- **Azure authentication** (az login, subscription listing/selection, confirmation; note on ARM_SUBSCRIPTION_ID env var override).
- **GCP authentication** (gcloud auth login, gcloud auth application-default-login, project selection; note on ADC path and project variable match).
- **Required GCP APIs** (gcloud services enable compute.googleapis.com).
- **Permissions verification** (az role assignment checks, gcloud projects get-iam-policy).
- **Megaport note** for Step 4 (VXC creation, no additional perms needed).

Updated root `README.md` Prerequisites to keep the 5-row summary table and add a single line pointing to the detailed runbook section `#requirements--setup`.

Root README now has **one sentence:** "For detailed install commands ... see Requirements & Setup in terraform/README.md."

**2026-06-17 · Consistency Pass 4 — Quick Start Timing & Plan Recommendation**

Updated root `README.md` **Quick Start** section for consistency with Tank's expanded runbook:
- Added **⏱ timing note** on Step 1 Azure apply: gateways take ~30–45 minutes to provision; Terraform appearing to hang is normal, do not cancel.
- Added **`terraform plan` recommendation** before each `terraform apply` in all steps (best practice).
- Expanded Step 1 description from "VPN gateway" to "VPN + ExpressRoute gateways" for accuracy.
- Updated the **"For full details"** section to explicitly list: pre-flight checklist, requirements & setup, detailed step-by-step, **troubleshooting**, VPN verification, ER/Interconnect, coexistence/failover.
- Kept concise; root README is overview; Tank's runbook holds the detail and checklist/troubleshooting.

**2026-06-17 - Network Test Tools Docs**

Documented that network test tools are auto-installed on all Linux VMs at first boot:
- **Azure**: all three VMs install via cloud-init `custom_data`.
- **GCP**: the on-prem VM installs via `metadata_startup_script`.
- Canonical user-facing section now lives in `terraform/README.md#network-test-tools`, with a pointer from root `README.md`.


**2026-06-17 - Scripted Deploy, Serial Console, and Route Inspection Docs**

Updated the canonical runbook and root README for the new root deployment wrappers and route diagnostics:
- Added `terraform/README.md#scripted-deployment-recommended` for `deploy.sh` / `deploy.ps1`, including check/deploy/destroy, ExpressRoute, non-interactive usage, secure password handling, and Megaport stop/re-run behavior.
- Added Azure Serial Console access guidance for VMs with no public IPs and documented that outbound internet is still available for first-boot `apt` installs.
- Added `terraform/README.md#route-inspection` for the Azure and GCP route dump scripts.
- Removed `restrict_ssh_source_prefix` from user-facing docs; public IP now applies only to GCP `caller_source_ip`.

### 2026-06-17 — Session finalization (Scribe: decisions merged, orchestration logs)

- Terraform revamp finalized and validated by Morpheus (all gates passed)
- Documentation updates committed as per Scribe orchestration log
- All 14 decisions merged into `.squad/decisions.md` from inbox; inbox files deleted
- Orchestration log written: 2026-06-17T20_47_00-switch.md
