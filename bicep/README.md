# Trimmed Bicep template for the ER/VPN coexistence lab

This folder contains a **local Bicep** version of the Azure side of the lab. It replaces the
external `azure-hub-spoke-base-lab` ARM template and deploys **only what this lab needs**.

## What it deploys

| Resource | Notes |
|----------|-------|
| Hub VNet (`Az-Hub-vnet`) | `subnet1` (VM) + `GatewaySubnet` only |
| Spoke VNets (`Az-Spk1-vnet`, `Az-Spk2-vnet`) | `subnet1` each, peered to the hub with gateway transit |
| VPN Gateway (`Az-Hub-vpngw`) | Active-active, BGP (ASN 65515), two PIPs (`-pip1`, `-pip2`) |
| ExpressRoute Gateway (`Az-Hub-ergw`) | Shares the `GatewaySubnet` with the VPN gateway |
| NSG (`Default-NSG`) | Allows SSH only from `restrictSshSourcePrefix` |
| 3 × Ubuntu 22.04 VMs | `Az-Hub-lxvm`, `Az-Spk1-lxvm`, `Az-Spk2-lxvm` (validation only) |

## What was removed vs. the original

- **`AzureFirewallSubnet`** — empty; no Azure Firewall was ever deployed.
- **`RouteServerSubnet`** + Route Server — the subnet existed but **no Route Server resource**
  was deployed, and it isn't required for native VPN/ExpressRoute coexistence.

## Deploy

```bash
rg=lab-er-vpn-coexistence
az group create -n $rg -l centralus

# Preview (recommended)
az deployment group what-if -g $rg --template-file ./main.bicep \
  --parameters vmAdminUsername=azureuser vmAdminPassword='<StrongP@ssw0rd>' restrictSshSourcePrefix=$(curl -4 ifconfig.io -s)/32

# Deploy
az deployment group create -g $rg --template-file ./main.bicep \
  --parameters vmAdminUsername=azureuser vmAdminPassword='<StrongP@ssw0rd>' restrictSshSourcePrefix=$(curl -4 ifconfig.io -s)/32
```

`deploy.azcli` already calls this template (`--template-file ./bicep/main.bicep`) and prompts for
the VM credentials, so normally you just run that script.

## Validate locally

```bash
az bicep build --file ./main.bicep   # syntax
az bicep lint  --file ./main.bicep   # best-practice lint
```

> Analysis only — verify against vendor documentation before applying.
