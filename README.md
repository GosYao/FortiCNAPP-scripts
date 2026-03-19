# FortiCNAPP Azure vCPU Inventory Scripts

Scripts for scanning Azure environments to count vCPUs across Virtual Machines (VMs) and VM Scale Sets (VMSS), used for FortiCNAPP/Lacework license sizing.

---

## Scripts Overview

| Script | Shell | Best for |
|---|---|---|
| `lw_azure_inventory_202603.sh` | Bash | Local machine or Linux/Mac |
| `lw_azure_inventory_cloudshell_202603.sh` | Bash | Azure Cloud Shell (Bash mode) |
| `lw_azure_inventory_local_202603.ps1` | PowerShell | Local Windows/Mac/Linux |
| `lw_azure_inventory_cloudshell_202603.ps1` | PowerShell | Azure Cloud Shell (PowerShell mode) |

**Cloud Shell variants** are memory-optimised: they fetch VM SKU data only for regions that actually have resources, rather than pulling all global regions upfront.

---

## Output

All scripts produce the same output:

- **CSV rows** — one row per subscription, written to stdout (Bash) or the output pipeline (PowerShell)
- **Summary** — printed at the end showing VM, VMSS, and total vCPU counts

**CSV columns:**
```
Subscription ID, Subscription Name, VM Instances, VM vCPUs, VM Scale Sets, VM Scale Set Instances, VM Scale Set vCPUs, Total Subscription vCPUs
```

**Counting rules:**
- VMs: only **running** instances are counted (`PowerState/running`)
- VMSS: **all** instances are counted regardless of power state

---

## Bash Scripts

### Prerequisites

- Azure CLI (`az`) — [install guide](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
- `jq` — [install guide](https://jqlang.github.io/jq/download/)
- Authenticated Azure session

The scripts auto-install the required `resource-graph` and `account` Azure CLI extensions on first run.

---

### Local Machine (`lw_azure_inventory_202603.sh`)

**Authenticate first:**
```bash
az login
```

**Run:**
```bash
# Scan all accessible subscriptions
./lw_azure_inventory_202603.sh

# Scan specific subscriptions
./lw_azure_inventory_202603.sh -s "sub-id-1,sub-id-2"

# Scan a management group (includes all child subscriptions)
./lw_azure_inventory_202603.sh -m "management-group-id"

# Save CSV output to a file
./lw_azure_inventory_202603.sh > report.csv
```

> **Note:** Must be run with `bash` directly. `sh ./script.sh` will not work.

---

### Azure Cloud Shell — Bash mode (`lw_azure_inventory_cloudshell_202603.sh`)

**Download the script:**

In Cloud Shell, click the **Upload/Download** button in the toolbar, select **Upload**, and upload the script. Or use the editor:
```bash
curl -O https://raw.githubusercontent.com/GosYao/FortiCNAPP-scripts/main/lw_azure_inventory_cloudshell_202603.sh
chmod +x lw_azure_inventory_cloudshell_202603.sh
```

**Run** (no login needed — Cloud Shell is pre-authenticated):
```bash
# Scan all accessible subscriptions
./lw_azure_inventory_cloudshell_202603.sh

# Scan specific subscriptions
./lw_azure_inventory_cloudshell_202603.sh -s "sub-id-1,sub-id-2"

# Scan a management group
./lw_azure_inventory_cloudshell_202603.sh -m "management-group-id"

# Limit to specific Azure regions (reduces scan time and memory usage)
./lw_azure_inventory_cloudshell_202603.sh -r "eastus,westeurope"

# Combine filters
./lw_azure_inventory_cloudshell_202603.sh -m "management-group-id" -r "eastus"

# Save CSV output to a file
./lw_azure_inventory_cloudshell_202603.sh > report.csv

# Download the output file to your browser
download report.csv
```

**Available flags:**

| Flag | Description |
|---|---|
| `-s` | Comma-separated subscription IDs to scan |
| `-m` | Comma-separated management group IDs (takes precedence over `-s`) |
| `-r` | Comma-separated Azure region names to include (e.g. `eastus,westeurope`) |
| `-h` | Show help |

---

## PowerShell Scripts

### Prerequisites

- PowerShell 7.0 or later — [install guide](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell)
- Required Az modules: `Az.Accounts`, `Az.Compute`, `Az.ResourceGraph`
  - The **local script** installs these automatically if missing
  - The **Cloud Shell script** uses modules pre-installed in Cloud Shell

---

### Local Machine (`lw_azure_inventory_local_202603.ps1`)

**Authenticate first:**
```powershell
Connect-AzAccount
```

**Allow the script to run** (first time only, if execution policy blocks it):
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

**Run:**
```powershell
# Scan all accessible subscriptions
.\lw_azure_inventory_local_202603.ps1

# Scan specific subscriptions
.\lw_azure_inventory_local_202603.ps1 -Subscription "sub-id-1,sub-id-2"

# Scan a management group (includes all child subscriptions)
.\lw_azure_inventory_local_202603.ps1 -ManagementGroup "management-group-id"

# Save CSV output to a file (status and summary still appear on screen)
.\lw_azure_inventory_local_202603.ps1 | Out-File report.csv

# Save CSV as a proper CSV file with UTF-8 encoding
.\lw_azure_inventory_local_202603.ps1 | Out-File report.csv -Encoding utf8
```

**Available parameters:**

| Parameter | Description |
|---|---|
| `-Subscription` | Comma-separated subscription IDs to scan |
| `-ManagementGroup` | Comma-separated management group IDs (takes precedence over `-Subscription`) |

---

### Azure Cloud Shell — PowerShell mode (`lw_azure_inventory_cloudshell_202603.ps1`)

**Download the script:**
```powershell
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/GosYao/FortiCNAPP-scripts/main/lw_azure_inventory_cloudshell_202603.ps1" -OutFile lw_azure_inventory_cloudshell_202603.ps1
```

Or use the Cloud Shell toolbar: click **Upload/Download** → **Upload**.

**Run** (no login needed — Cloud Shell is pre-authenticated):
```powershell
# Scan all accessible subscriptions
./lw_azure_inventory_cloudshell_202603.ps1

# Scan specific subscriptions
./lw_azure_inventory_cloudshell_202603.ps1 -Subscription "sub-id-1,sub-id-2"

# Scan a management group
./lw_azure_inventory_cloudshell_202603.ps1 -ManagementGroup "management-group-id"

# Limit to specific Azure regions (reduces scan time and memory usage)
./lw_azure_inventory_cloudshell_202603.ps1 -Region "eastus,westeurope"

# Combine filters
./lw_azure_inventory_cloudshell_202603.ps1 -ManagementGroup "management-group-id" -Region "eastus"

# Save CSV output to a file (status and summary still appear on screen)
./lw_azure_inventory_cloudshell_202603.ps1 | Out-File report.csv

# Download the output file to your browser
download report.csv
```

**Available parameters:**

| Parameter | Description |
|---|---|
| `-Subscription` | Comma-separated subscription IDs to scan |
| `-ManagementGroup` | Comma-separated management group IDs (takes precedence over `-Subscription`) |
| `-Region` | Comma-separated Azure region names to include (e.g. `eastus,westeurope`) |

---

## Choosing the Right Script

```
Are you in Azure Cloud Shell?
├── Yes → Use the cloudshell variant for your shell mode
│         Bash mode    → lw_azure_inventory_cloudshell_202603.sh
│         PowerShell   → lw_azure_inventory_cloudshell_202603.ps1
│
└── No  → Use the local variant for your preferred shell
          Bash (Mac/Linux/WSL) → lw_azure_inventory_202603.sh
          PowerShell (any OS)  → lw_azure_inventory_local_202603.ps1
```

## Required Azure Permissions

The account used to run the scripts must have at least **Reader** access on the subscriptions or management groups being scanned. This is required for:
- Azure Resource Graph queries (VMs, VMSSes, subscriptions)
- VM SKU data (`Microsoft.Compute/skus/read`)
