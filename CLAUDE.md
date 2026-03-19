# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository contains Bash scripts for scanning Azure environments to count vCPUs across VMs and Virtual Machine Scale Sets (VMSS), used for FortiCNAPP/Lacework licensing estimation. There are two complementary scripts:

- **`lw_azure_inventory_202603.sh`** — Original script; builds a global SKU map across all Azure regions.
- **`lw_azure_inventory_cloudshell_202603.sh`** — Cloud Shell-optimized version; fetches SKU data only for regions containing actual resources, uses parallel Resource Graph queries, and adds `-r` region filtering.

## Running the Scripts

### Bash

```bash
# Basic usage (all accessible subscriptions)
bash lw_azure_inventory_202603.sh

# Filter by subscription IDs
bash lw_azure_inventory_cloudshell_202603.sh -s "sub-id-1,sub-id-2"

# Filter by management group
bash lw_azure_inventory_cloudshell_202603.sh -m "mg-id"

# Filter by Azure region(s) — cloudshell version only
bash lw_azure_inventory_cloudshell_202603.sh -r "eastus,westus2"
```

**Prerequisites**: Azure CLI (`az`), `jq`, authenticated Azure session (`az login`). The scripts auto-install the `resource-graph` and `account` CLI extensions.

### PowerShell

```powershell
# Basic usage (all accessible subscriptions) — local version
.\lw_azure_inventory_local_202603.ps1

# Filter by subscription IDs
.\lw_azure_inventory_local_202603.ps1 -Subscription "sub-id-1,sub-id-2"

# Filter by management group
.\lw_azure_inventory_local_202603.ps1 -ManagementGroup "mg-id"

# Cloud Shell version — filter by region(s)
.\lw_azure_inventory_cloudshell_202603.ps1 -Region "eastus,westus2"

# Capture CSV output only (status/summary go to host, not pipeline)
.\lw_azure_inventory_cloudshell_202603.ps1 | Out-File report.csv
```

**Prerequisites (local)**: PowerShell 7+, `Connect-AzAccount` authenticated. Required Az modules (`Az.Accounts`, `Az.Compute`, `Az.ResourceGraph`) are auto-installed if missing.

**Prerequisites (Cloud Shell)**: No setup needed — Az modules and authentication are pre-configured in Cloud Shell.

## Architecture

Both scripts follow the same data flow:

1. **Parse flags** (`-s`, `-m`, `-r`, `-h`)
2. **Install Azure CLI extensions** (`resource-graph`, `account`)
3. **Query resources** via Azure Resource Graph API — subscriptions, running VMs, VMSS instances
4. **Build SKU map** — maps VM SKU names (e.g., `Standard_D4s_v3`) to vCPU counts
   - Original: fetches all regions globally (slow, comprehensive)
   - Cloud Shell: fetches only locations where resources were found (fast, targeted); sequential per location to avoid MSI token contention
5. **Region filter** (cloudshell `-r` flag): uses `jq` to filter VM/VMSS arrays by location before processing
6. **Per-subscription loop** — tallies VM vCPUs (running only) and VMSS vCPUs (all instances × SKU vCPUs)
7. **Output** — CSV rows + summary report to stdout

### CSV Output Format

```
Subscription ID, Subscription Name, VM Instances, VM vCPUs, VM Scale Sets, VM Scale Set Instances, VM Scale Set vCPUs, Total Subscription vCPUs
```

### Key Differences Between Scripts

| Concern | Bash original | Bash Cloud Shell | PS local | PS Cloud Shell |
|---|---|---|---|---|
| SKU data scope | All global regions | Only regions with VMs/VMSS | All global regions | Only regions with VMs/VMSS |
| SKU fetching | Single global call | Sequential per-location | Single global call | Sequential per-location |
| Resource queries | Sequential | Parallel (`&` + `wait`) | Sequential | Sequential |
| Subscription discovery | `az account subscription list` (API) | `az account list` (cached) | `Get-AzSubscription` | `Get-AzSubscription` (cached) |
| Region filter flag | Not available | `-r` | Not available | `-Region` |
| Module/extension install | Auto (`az extension add`) | Auto | Auto (`Install-Module`) | Skipped (pre-installed) |
| CSV output stream | stdout (mixed with status) | stdout (mixed with status) | Output pipeline only | Output pipeline only |

## Development Notes

- Bash scripts require `bash` (checked at startup); not compatible with `sh` or `zsh`.
- The bash cloudshell script uses `mktemp -d` for temp files and cleans up via `trap`.
- Both bash and PowerShell versions paginate Resource Graph results at 1000 per page.
- Power state filtering for VMs: only `PowerState/running` instances are counted.
- VMSS counts all instances regardless of power state.
- Management group scope takes precedence over subscription scope in all versions.
- PowerShell scripts require PS 7.0+ (`#Requires -Version 7.0`).
- In PowerShell, `Write-Output` emits CSV rows (captured by `|` or `>`); `Write-Host` emits status/summary directly to the console (not captured). This separates data from diagnostics cleanly.
- PowerShell hashtables are reference types — `$Totals` is mutated in-place inside `Invoke-SubscriptionAnalysis` without needing `[ref]`.
