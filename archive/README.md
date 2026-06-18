# Archive: Legacy Lab Automation

This folder contains the **original lab automation scripts**, now superseded by the Terraform configurations under `terraform/azure/` and `terraform/gcp/`.

## Archived Files

- **`deploy.azcli`** — Original Azure CLI deployment script for the main lab environment.
- **`deploy.ps1`** — Original PowerShell deployment script for the main lab environment.
- **`routes.azcli`** — Azure CLI script for route validation and inspection helpers.
- **`routes.ps1`** — PowerShell script for route validation and inspection helpers.
- **`vpnsite2.azcli`** — Azure CLI script to configure and deploy the second on-premises site simulation.
- **`vpnsite2.ps1`** — PowerShell script to configure and deploy the second on-premises site simulation.
- **`customer-demo-migration.azcli`** — Variant of the main deployment used for customer demonstrations.
- **`azuredeploy.json`** — Legacy Azure Resource Manager (ARM) template.
- **`bicep/`** — Local Bicep template used by the original `deploy.azcli` script.

## Migration Status

All functionality has been migrated to **Infrastructure as Code via Terraform**:
- Azure resources → `terraform/azure/`
- Google Cloud resources → `terraform/gcp/`

**Kept for reference only.** Use the Terraform flow documented in the root `README.md`.
