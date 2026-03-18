#!/bin/bash

# Script to fetch Azure inventory for FortiCNAPP/Lacework sizing.
# Optimized for Azure Cloud Shell.
#
# Key optimizations vs original:
#   1. Fetches VM SKU data only for regions with actual VMs/VMSSes (not all global regions)
#   2. Per-location SKU fetches run sequentially (avoids MSI token contention in Cloud Shell)
#   3. VM and VMSS Resource Graph queries run in parallel
#   4. az account list (cached) replaces az account subscription list
#
# Requirements: az cli, jq
# Run with bash: ./lw_azure_inventory_cloudshell_202603.sh [-s sub1,sub2] [-m mgmt1,mgmt2]

function showHelp {
  echo "lw_azure_inventory_cloudshell_202603.sh — FortiCNAPP license vCPU estimator for Azure"
  echo ""
  echo "Scans Azure VMs and VM Scale Sets to estimate vCPU counts for licensing."
  echo "Optimized for Azure Cloud Shell (fetches SKUs only for regions in use)."
  echo ""
  echo "Usage:"
  echo "  ./lw_azure_inventory_cloudshell_202603.sh              # all accessible subscriptions"
  echo "  ./lw_azure_inventory_cloudshell_202603.sh -s sub1,sub2 # specific subscriptions"
  echo "  ./lw_azure_inventory_cloudshell_202603.sh -m mgmt1     # management group scope"
  echo ""
  echo "Flags:"
  echo "  -s   Comma-separated subscription IDs"
  echo "  -m   Comma-separated management group IDs (takes precedence over -s)"
  echo "  -h   Show this help"
}

echo $BASH | grep -q "bash"
if [ $? -ne 0 ]; then
  echo "ERROR: Must be run with bash, not sh."
  echo "Use: ./lw_azure_inventory_cloudshell_202603.sh"
  exit 1
fi

set -o errexit
set -o pipefail

while getopts ":m:s:h" opt; do
  case ${opt} in
    s ) SUBSCRIPTION=$OPTARG ;;
    m ) MANAGEMENT_GROUP=$OPTARG ;;
    h ) showHelp; exit 0 ;;
    \? ) showHelp; exit 1 ;;
    : ) showHelp; exit 1 ;;
  esac
done
shift $((OPTIND -1))

SKU_MAP_FILE=""   # populated by buildSkuMapForLocations

function removeTmp {
  [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}
trap removeTmp EXIT

function installExtensions {
  for ext in resource-graph account; do
    if ! az extension show --name "$ext" &>/dev/null; then
      echo "Installing az extension: $ext ..."
      az extension add --name "$ext" --only-show-errors
    fi
  done
}

# ---------------------------------------------------------------------------
# Paginate through all Resource Graph results (page size 1000)
# ---------------------------------------------------------------------------
function graphQuery {
  local query=$1
  local scope=$2
  local skip=0
  local pageSize=1000
  local allData='{"data":[]}'

  while true; do
    local result
    # shellcheck disable=SC2086
    result=$(az graph query -q "$query" $scope --first $pageSize --skip $skip -o json 2>/dev/null)
    local count
    count=$(echo "$result" | jq '.data | length')

    if [[ $count -eq 0 ]]; then
      break
    fi

    allData=$(printf '%s\n%s' "$allData" "$result" | jq -s '{"data": ([.[].data] | add)}')
    skip=$((skip + pageSize))

    if [[ $count -lt $pageSize ]]; then
      break
    fi
  done

  echo "$allData"
}

# ---------------------------------------------------------------------------
# Build SKU map only for locations that actually have VMs/VMSSes.
# Runs sequentially to avoid MSI token contention in Cloud Shell.
# Result is a sorted flat file: "SkuName:vCPUcount" (one per line).
# ---------------------------------------------------------------------------
function buildSkuMapForLocations {
  local locations="$1"   # space-separated region names

  if [[ -z "$locations" ]]; then
    echo "No VM/VMSS locations found — skipping SKU map build."
    return
  fi

  TMP_DIR=$(mktemp -d)
  SKU_MAP_FILE="$TMP_DIR/sku_map"

  echo "Fetching VM SKU data for regions: $locations"

  for loc in $locations; do
    echo "  Loading SKUs for $loc ..."
    az vm list-skus \
      --resource-type virtualmachines \
      --location "$loc" \
      --only-show-errors \
      -o json 2>/dev/null \
      | jq -r '.[] | .name as $n
                    | select(.capabilities != null)
                    | .capabilities[]
                    | select(.name == "vCPUs")
                    | $n + ":" + .value' \
      >> "$SKU_MAP_FILE" || echo "  Warning: SKU fetch failed for $loc, skipping."
  done

  # Deduplicate (same SKU may appear across locations with identical vCPU count)
  [[ -f "$SKU_MAP_FILE" ]] && sort -u -o "$SKU_MAP_FILE" "$SKU_MAP_FILE"

  local mapSize=0
  [[ -f "$SKU_MAP_FILE" ]] && mapSize=$(wc -l < "$SKU_MAP_FILE")
  echo "SKU map built: $mapSize unique SKUs loaded."
}

# ---------------------------------------------------------------------------
# Per-subscription tally — uses SKU_MAP associative array
# ---------------------------------------------------------------------------
function runSubscriptionAnalysis {
  local subscriptionId=$1
  local subscriptionName=$2
  local vms=$3
  local vmss=$4

  local subscriptionVmVcpu=0
  local subscriptionVmCount=0
  local subscriptionVmssVcpu=0
  local subscriptionVmssVmCount=0
  local subscriptionVmssCount=0

  # Running VMs
  local VM_LINES
  VM_LINES=$(echo "$vms" | jq -r --arg sid "$subscriptionId" \
    '.data[] | select(.subscriptionId==$sid) | select(.powerState=="PowerState/running") | .sku // empty')

  if [[ -n "$VM_LINES" ]]; then
    while read -r sku; do
      # Guard: skip null/empty SKUs (VMs with no extended instance view data)
      [[ -z "$sku" || "$sku" == "null" ]] && continue
      local vCPU
      vCPU=$(grep -m1 "^${sku}:" "$SKU_MAP_FILE" 2>/dev/null | cut -d: -f2) || true
      if [[ -n "$vCPU" ]]; then
        subscriptionVmCount=$((subscriptionVmCount + 1))
        subscriptionVmVcpu=$((subscriptionVmVcpu + vCPU))
      fi
    done <<< "$VM_LINES"
  fi

  # VMSS (all instances regardless of power state)
  local VMSS_LINES
  VMSS_LINES=$(echo "$vmss" | jq -r --arg sid "$subscriptionId" \
    '.data[] | select(.subscriptionId==$sid) | (.sku // empty) +":"+(.capacity // 0 | tostring)')

  if [[ -n "$VMSS_LINES" ]]; then
    while read -r line; do
      local sku="${line%%:*}"
      local capacity="${line##*:}"
      # Guard: skip null/empty SKUs
      [[ -z "$sku" || "$sku" == "null" ]] && continue
      local vCPU
      vCPU=$(grep -m1 "^${sku}:" "$SKU_MAP_FILE" 2>/dev/null | cut -d: -f2) || true
      if [[ -n "$vCPU" && "$capacity" -gt 0 ]]; then
        subscriptionVmssVcpu=$((subscriptionVmssVcpu + vCPU * capacity))
        subscriptionVmssVmCount=$((subscriptionVmssVmCount + capacity))
        subscriptionVmssCount=$((subscriptionVmssCount + 1))
      fi
    done <<< "$VMSS_LINES"
  fi

  AZURE_VMS_COUNT=$((AZURE_VMS_COUNT + subscriptionVmCount))
  AZURE_VMS_VCPU=$((AZURE_VMS_VCPU + subscriptionVmVcpu))
  AZURE_VMSS_VCPU=$((AZURE_VMSS_VCPU + subscriptionVmssVcpu))
  AZURE_VMSS_VM_COUNT=$((AZURE_VMSS_VM_COUNT + subscriptionVmssVmCount))
  AZURE_VMSS_COUNT=$((AZURE_VMSS_COUNT + subscriptionVmssCount))

  echo "\"$subscriptionId\", \"$subscriptionName\", $subscriptionVmCount, $subscriptionVmVcpu, $subscriptionVmssCount, $subscriptionVmssVmCount, $subscriptionVmssVcpu, $((subscriptionVmVcpu + subscriptionVmssVcpu))"
}

# ---------------------------------------------------------------------------
# Main analysis: parallel graph queries, location-scoped SKU fetch
# ---------------------------------------------------------------------------
function runAnalysis {
  local scope=$1

  echo "Querying subscriptions, VMs, and VMSSes in parallel..."

  # OPTIMIZATION: run all three Resource Graph queries in parallel
  local subs_file vm_file vmss_file
  subs_file=$(mktemp)
  vm_file=$(mktemp)
  vmss_file=$(mktemp)

  graphQuery \
    "resourcecontainers | where type == 'microsoft.resources/subscriptions' | project name, subscriptionId" \
    "$scope" > "$subs_file" &
  local pid_subs=$!

  # Include location so we can scope the SKU fetch
  graphQuery \
    "Resources | where type=~'microsoft.compute/virtualmachines' | project subscriptionId, name, location, sku=properties.hardwareProfile.vmSize, powerState=properties.extended.instanceView.powerState.code" \
    "$scope" > "$vm_file" &
  local pid_vms=$!

  graphQuery \
    "Resources | where type=~'microsoft.compute/virtualmachinescalesets' | project subscriptionId, name, location, sku=sku.name, capacity=toint(sku.capacity)" \
    "$scope" > "$vmss_file" &
  local pid_vmss=$!

  wait $pid_subs $pid_vms $pid_vmss

  local expectedSubscriptions vms vmss
  expectedSubscriptions=$(cat "$subs_file")
  vms=$(cat "$vm_file")
  vmss=$(cat "$vmss_file")
  rm -f "$subs_file" "$vm_file" "$vmss_file"

  # Collect only the regions that have actual VMs or VMSSes
  local vm_locations vmss_locations all_locations
  vm_locations=$(echo "$vms"   | jq -r '.data[] | .location' | sort -u)
  vmss_locations=$(echo "$vmss" | jq -r '.data[] | .location' | sort -u)
  all_locations=$(printf '%s\n%s\n' "$vm_locations" "$vmss_locations" | sort -u | tr '\n' ' ')

  buildSkuMapForLocations "$all_locations"

  local expectedSubscriptionIds
  expectedSubscriptionIds=$(echo "$expectedSubscriptions" | jq -r '.data[] | .subscriptionId' | sort)

  echo '"Subscription ID", "Subscription Name", "VM Instances", "VM vCPUs", "VM Scale Sets", "VM Scale Set Instances", "VM Scale Set vCPUs", "Total Subscription vCPUs"'

  # Subscriptions found in VM data but not in the expected list
  local actualSubscriptionIds
  actualSubscriptionIds=$(echo "$vms" | jq -r '.data[] | .subscriptionId' | sort -u)

  for actualSubscriptionId in $actualSubscriptionIds; do
    local foundSubscriptionId
    foundSubscriptionId=$(echo "$expectedSubscriptions" | jq -r --arg sid "$actualSubscriptionId" \
      '.data[] | select(.subscriptionId==$sid) | .subscriptionId')
    if [[ "$actualSubscriptionId" != "$foundSubscriptionId" ]]; then
      runSubscriptionAnalysis "$actualSubscriptionId" "" "$vms" "$vmss"
    fi
  done

  # All expected subscriptions
  for expectedSubscriptionId in $expectedSubscriptionIds; do
    local subscriptionName
    subscriptionName=$(echo "$expectedSubscriptions" | jq -r --arg sid "$expectedSubscriptionId" \
      '.data[] | select(.subscriptionId==$sid) | .name')
    runSubscriptionAnalysis "$expectedSubscriptionId" "$subscriptionName" "$vms" "$vmss"
  done
}

# ---------------------------------------------------------------------------
# Global counters
# ---------------------------------------------------------------------------
AZURE_VMS_VCPU=0
AZURE_VMS_COUNT=0
AZURE_VMSS_VCPU=0
AZURE_VMSS_VM_COUNT=0
AZURE_VMSS_COUNT=0

installExtensions

# ---------------------------------------------------------------------------
# Scope selection — use az account list (cached, fast) for the default case
# ---------------------------------------------------------------------------
if [[ -n "$MANAGEMENT_GROUP" ]]; then
  runAnalysis "--management-groups ${MANAGEMENT_GROUP//,/ }"
elif [[ -n "$SUBSCRIPTION" ]]; then
  runAnalysis "--subscriptions ${SUBSCRIPTION//,/ }"
else
  echo "Discovering accessible subscriptions..."
  # az account list is cached locally — much faster than az account subscription list
  subscriptions=$(az account list --only-show-errors -o json | jq -r '[.[] | select(.state=="Enabled") | .id] | join(" ")')
  if [[ -z "$subscriptions" ]]; then
    echo "ERROR: No enabled subscriptions found. Run 'az login' first."
    exit 1
  fi
  runAnalysis "--subscriptions $subscriptions"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "##########################################"
echo "FortiCNAPP inventory collection complete."
echo ""
echo "VM Summary:"
echo "==============================="
echo "VM Instances:     $AZURE_VMS_COUNT"
echo "VM vCPUs:         $AZURE_VMS_VCPU"
echo ""
echo "VM Scale Set Summary:"
echo "==============================="
echo "VM Scale Sets:          $AZURE_VMSS_COUNT"
echo "VM Scale Set Instances: $AZURE_VMSS_VM_COUNT"
echo "VM Scale Set vCPUs:     $AZURE_VMSS_VCPU"
echo ""
echo "License Summary"
echo "==============================="
echo "  VM vCPUs:             $AZURE_VMS_VCPU"
echo "+ VM Scale Set vCPUs:   $AZURE_VMSS_VCPU"
echo "-------------------------------"
echo "Total vCPUs:            $((AZURE_VMS_VCPU + AZURE_VMSS_VCPU))"
