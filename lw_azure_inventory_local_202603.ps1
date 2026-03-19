#Requires -Version 7.0

<#
.SYNOPSIS
    FortiCNAPP/Lacework Azure license vCPU estimator — local PowerShell version.
.DESCRIPTION
    Scans Azure VMs and VM Scale Sets to estimate vCPU counts for FortiCNAPP licensing.
    Builds a comprehensive global VM SKU map covering all Azure regions.
    Required modules (Az.Accounts, Az.Compute, Az.ResourceGraph) are auto-installed if missing.
.PARAMETER Subscription
    Comma-separated list of subscription IDs to scan.
.PARAMETER ManagementGroup
    Comma-separated list of management group IDs (takes precedence over -Subscription).
.EXAMPLE
    .\lw_azure_inventory_local_202603.ps1
.EXAMPLE
    .\lw_azure_inventory_local_202603.ps1 -Subscription "sub-id-1,sub-id-2"
.EXAMPLE
    .\lw_azure_inventory_local_202603.ps1 -ManagementGroup "mg-root"
.NOTES
    CSV rows go to the output pipeline; status messages and summary go to the host.
    To capture CSV only:  .\lw_azure_inventory_local_202603.ps1 | Out-File report.csv
#>

[CmdletBinding()]
param(
    [string]$Subscription    = "",
    [string]$ManagementGroup = ""
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Ensure required Az modules are available
# ---------------------------------------------------------------------------
function Install-RequiredModules {
    foreach ($mod in @("Az.Accounts", "Az.Compute", "Az.ResourceGraph")) {
        if (-not (Get-Module -ListAvailable -Name $mod -ErrorAction SilentlyContinue)) {
            Write-Host "Installing module $mod ..."
            Install-Module $mod -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        }
        Import-Module $mod -ErrorAction Stop
    }
}

# ---------------------------------------------------------------------------
# Paginate through all Resource Graph results (page size 1000)
# ---------------------------------------------------------------------------
function Invoke-GraphQuery {
    param(
        [string]   $Query,
        [string[]] $Subscriptions,
        [string[]] $ManagementGroups
    )
    $all      = [System.Collections.Generic.List[object]]::new()
    $skip     = 0
    $pageSize = 1000

    do {
        $p = @{ Query = $Query; First = $pageSize }
        if ($skip -gt 0)         { $p.Skip          = $skip }
        if ($ManagementGroups) { $p.ManagementGroup = $ManagementGroups }
        elseif ($Subscriptions)  { $p.Subscription  = $Subscriptions }

        $raw  = Search-AzGraph @p
        if ($null -eq $raw) { break }
        # Normalise: newer Az.ResourceGraph versions return a PSResourceGraphResponse
        # wrapper with a .Data property; older versions return PSObject[] directly.
        $page = if ($raw.PSObject.Properties.Name -contains 'Data') { @($raw.Data) } else { @($raw) }
        $count = $page.Count
        if ($count -gt 0) { $all.AddRange($page) }
        $skip += $pageSize
    } while ($count -eq $pageSize)

    return $all.ToArray()
}

# ---------------------------------------------------------------------------
# Build a global SKU map: hashtable of SKU name -> vCPU count
# Fetches all regions globally — comprehensive but slower than location-scoped.
# ---------------------------------------------------------------------------
function Build-SkuMap {
    Write-Host "Fetching VM SKU vCPU data globally (this may take a few minutes)..."
    $map  = @{}
    $skus = Get-AzComputeResourceSku | Where-Object { $_.ResourceType -eq "virtualMachines" }
    foreach ($sku in $skus) {
        if ($map.ContainsKey($sku.Name)) { continue }
        $cap = $sku.Capabilities | Where-Object { $_.Name -eq "vCPUs" } | Select-Object -First 1
        if ($cap) { $map[$sku.Name] = [int]$cap.Value }
    }
    Write-Host "SKU map built: $($map.Count) unique SKUs loaded."
    return $map
}

# ---------------------------------------------------------------------------
# Per-subscription tally
# $Totals is a hashtable passed by reference (hashtables are reference types).
# ---------------------------------------------------------------------------
function Invoke-SubscriptionAnalysis {
    param(
        [string]    $SubId,
        [string]    $SubName,
        [object[]]  $Vms,
        [object[]]  $Vmss,
        [hashtable] $SkuMap,
        [hashtable] $Totals
    )
    $vmCount = 0; $vmVcpu = 0
    $vsCount = 0; $vsVmCount = 0; $vsVcpu = 0

    # Running VMs only
    foreach ($vm in @($Vms | Where-Object { $_.subscriptionId -eq $SubId -and $_.powerState -eq "PowerState/running" })) {
        $sku = [string]$vm.sku
        if (-not $sku -or $sku -eq "null") { continue }
        if ($SkuMap.ContainsKey($sku)) { $vmCount++; $vmVcpu += $SkuMap[$sku] }
    }

    # All VMSS instances regardless of power state
    foreach ($vs in @($Vmss | Where-Object { $_.subscriptionId -eq $SubId })) {
        $sku = [string]$vs.sku
        $cap = if ($null -ne $vs.capacity) { [int]$vs.capacity } else { 0 }
        if (-not $sku -or $sku -eq "null" -or $cap -le 0) { continue }
        if ($SkuMap.ContainsKey($sku)) {
            $vsCount++
            $vsVmCount += $cap
            $vsVcpu    += $SkuMap[$sku] * $cap
        }
    }

    $Totals.VmCount   += $vmCount
    $Totals.VmVcpu    += $vmVcpu
    $Totals.VsCount   += $vsCount
    $Totals.VsVmCount += $vsVmCount
    $Totals.VsVcpu    += $vsVcpu

    Write-Output "`"$SubId`", `"$SubName`", $vmCount, $vmVcpu, $vsCount, $vsVmCount, $vsVcpu, $($vmVcpu + $vsVcpu)"
}

# ---------------------------------------------------------------------------
# Main analysis
# ---------------------------------------------------------------------------
function Invoke-Analysis {
    param([string[]]$Subscriptions, [string[]]$ManagementGroups)

    $skuMap = Build-SkuMap
    $qp     = @{ Subscriptions = $Subscriptions; ManagementGroups = $ManagementGroups }

    Write-Host "Loading subscriptions..."
    $subs = @(Invoke-GraphQuery -Query "resourcecontainers | where type == 'microsoft.resources/subscriptions' | project name, subscriptionId" @qp)
    Write-Host "Loading VMs..."
    $vms  = @(Invoke-GraphQuery -Query "Resources | where type=~'microsoft.compute/virtualmachines' | project subscriptionId, name, sku=properties.hardwareProfile.vmSize, powerState=properties.extended.instanceView.powerState.code" @qp)
    Write-Host "Loading VMSSes..."
    $vmss = @(Invoke-GraphQuery -Query "Resources | where type=~'microsoft.compute/virtualmachinescalesets' | project subscriptionId, name, sku=sku.name, capacity=toint(sku.capacity)" @qp)
    Write-Host "Found $($vms.Count) VMs and $($vmss.Count) VMSSes across $($subs.Count) subscriptions."

    $totals = @{ VmCount = 0; VmVcpu = 0; VsCount = 0; VsVmCount = 0; VsVcpu = 0 }
    $ap     = @{ Vms = $vms; Vmss = $vmss; SkuMap = $skuMap; Totals = $totals }

    Write-Output '"Subscription ID", "Subscription Name", "VM Instances", "VM vCPUs", "VM Scale Sets", "VM Scale Set Instances", "VM Scale Set vCPUs", "Total Subscription vCPUs"'

    # Handle subscriptions present in VM data but absent from the expected list
    $expectedIds = @($subs | Select-Object -ExpandProperty subscriptionId)
    foreach ($id in @($vms | Select-Object -ExpandProperty subscriptionId -Unique)) {
        if ($id -notin $expectedIds) {
            Invoke-SubscriptionAnalysis -SubId $id -SubName "" @ap
        }
    }

    # Process all expected subscriptions
    foreach ($sub in $subs) {
        Invoke-SubscriptionAnalysis -SubId $sub.subscriptionId -SubName $sub.name @ap
    }

    Write-Host "##########################################"
    Write-Host "FortiCNAPP inventory collection complete."
    Write-Host ""
    Write-Host "VM Summary:"
    Write-Host "==============================="
    Write-Host "VM Instances:     $($totals.VmCount)"
    Write-Host "VM vCPUs:         $($totals.VmVcpu)"
    Write-Host ""
    Write-Host "VM Scale Set Summary:"
    Write-Host "==============================="
    Write-Host "VM Scale Sets:          $($totals.VsCount)"
    Write-Host "VM Scale Set Instances: $($totals.VsVmCount)"
    Write-Host "VM Scale Set vCPUs:     $($totals.VsVcpu)"
    Write-Host ""
    Write-Host "License Summary"
    Write-Host "==============================="
    Write-Host "  VM vCPUs:             $($totals.VmVcpu)"
    Write-Host "+ VM Scale Set vCPUs:   $($totals.VsVcpu)"
    Write-Host "-------------------------------"
    Write-Host "Total vCPUs:            $($totals.VmVcpu + $totals.VsVcpu)"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
Install-RequiredModules

if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
    Write-Error "Not authenticated. Run Connect-AzAccount first."
    exit 1
}

if ($ManagementGroup) {
    Invoke-Analysis -ManagementGroups ($ManagementGroup -split ",") -Subscriptions @()
} elseif ($Subscription) {
    Invoke-Analysis -Subscriptions ($Subscription -split ",") -ManagementGroups @()
} else {
    Write-Host "Discovering accessible subscriptions..."
    $enabledSubs = @(Get-AzSubscription | Where-Object { $_.State -eq "Enabled" })
    if ($enabledSubs.Count -eq 0) {
        Write-Error "No enabled subscriptions found. Run Connect-AzAccount first."
        exit 1
    }
    Invoke-Analysis -Subscriptions ($enabledSubs | Select-Object -ExpandProperty Id) -ManagementGroups @()
}
