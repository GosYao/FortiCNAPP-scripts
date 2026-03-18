#!/bin/bash

# Script to fetch Azure inventory for Lacework sizing.
# Requirements: az cli, jq, cut, grep

# This script can be run from Azure Cloud Shell.
# Run ./lw_azure_inventory.sh -h for help on how to run the script.
# Or just read the text in showHelp below.

function showHelp {
  echo "lw_azure_inventory.sh is a tool for estimating license vCPUs in an Azure environment, based on"
  echo "subscription or management group level. It leverages the az CLI and by default analyzes all"
  echo "subscriptions a user has access to. The script provides output in a CSV format to be imported"
  echo "into a spreadsheet, as well as an easy-to-read summary."
  echo ""
  echo "By default, the script will scan all subscriptions returned by the following command:"
  echo "az account subscription list"
  echo ""
  echo "Note the following about the script:"
  echo "* Works great in a cloud shell"
  echo "* It has been verified to work on Mac and Linux based systems"
  echo "* Has been observed to work with Windows Subsystem for Linux to run on Windows"
  echo "* Run using the following syntax: ./lw_azure_inventory.sh, sh lw_azure_inventory.sh will not work"
  echo ""
  echo "Available flags:"
  echo " -s       Comma separated list of Azure subscriptions to scan."
  echo "          ./lw_azure_inventory.sh -s subscription-1,subscription-2"
  echo " -m       Comma separated list of Azure management groups to scan."
  echo "          ./lw_azure_inventory.sh -m 1234,456"
}

#Ensure the script runs with the BASH shell
echo $BASH | grep -q "bash"
if [ $? -ne 0 ]; then
  echo "The script is running using the incorrect shell."
  echo "Use ./lw_azure_inventory.sh to run the script using the required shell, bash."
  exit
fi

set -o errexit
set -o pipefail

while getopts ":m:s:" opt; do
  case ${opt} in
    s ) SUBSCRIPTION=$OPTARG ;;
    m ) MANAGEMENT_GROUP=$OPTARG ;;
    \? ) showHelp; exit 1 ;;
    : ) showHelp; exit 1 ;;
  esac
done
shift $((OPTIND -1))

function removeTmp {
  rm -f ./tmp_map
}

function installExtensions {
  resourceGraphPresent=$(az extension list -o json --query "contains([].name, \`resource-graph\`)")
  if [ "$resourceGraphPresent" != true ]; then
    echo "Resource-graph extension not present in Az CLI installation. Enabling..."
    az extension add --name "resource-graph"
  else
    echo "Resource-graph extension already present..."
  fi
  accountPresent=$(az extension list -o json --query "contains([].name, \`account\`)")
  if [ "$accountPresent" != true ]; then
    echo "Account extension not present in Az CLI installation. Enabling..."
    az extension add --name "account"
  else
    echo "Account extension already present..."
  fi
}

# Paginate through all Resource Graph results (default page size is 1000)
function graphQuery {
  local query=$1
  local scope=$2
  local skip=0
  local pageSize=1000
  local allData='{"data":[]}'

  while true; do
    local result
    # shellcheck disable=SC2086
    result=$(az graph query -q "$query" $scope --first $pageSize --skip $skip -o json)
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

trap removeTmp EXIT

# Set the initial counts to zero.
AZURE_VMS_VCPU=0
AZURE_VMS_COUNT=0
AZURE_VMSS_VCPU=0
AZURE_VMSS_VM_COUNT=0
AZURE_VMSS_COUNT=0

installExtensions

function buildSkuMap {
  echo "Fetching VM SKU vCPU data (this may take a minute)..."
  az vm list-skus --resource-type virtualmachines -o json \
    | jq -r '.[] | .name as $n | select(.capabilities != null) | .capabilities[] | select(.name == "vCPUs") | $n+":"+.value' \
    | sort -u > ./tmp_map

  local mapSize
  mapSize=$(wc -l < ./tmp_map)
  echo "Map built: $mapSize unique SKUs loaded."
}

###################################

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

  # Tally up VM vCPU (running only)
  local VM_LINES
  VM_LINES=$(echo "$vms" | jq -r --arg sid "$subscriptionId" \
    '.data[] | select(.subscriptionId==$sid) | select(.powerState=="PowerState/running") | .sku')
  if [[ -n "$VM_LINES" ]]; then
    while read -r sku; do
      local vCPU
      vCPU=$(grep -m1 "^${sku}:" ./tmp_map | cut -d: -f2) || true
      if [[ -n "$vCPU" ]]; then
        subscriptionVmCount=$((subscriptionVmCount + 1))
        subscriptionVmVcpu=$((subscriptionVmVcpu + vCPU))
      fi
    done <<< "$VM_LINES"
  fi

  # Tally up VMSS vCPU
  local VMSS_LINES
  VMSS_LINES=$(echo "$vmss" | jq -r --arg sid "$subscriptionId" \
    '.data[] | select(.subscriptionId==$sid) | .sku+":"+(.capacity // 0 | tostring)')
  if [[ -n "$VMSS_LINES" ]]; then
    while read -r line; do
      local sku="${line%%:*}"
      local capacity="${line##*:}"
      local vCPU
      vCPU=$(grep -m1 "^${sku}:" ./tmp_map | cut -d: -f2) || true
      if [[ -n "$vCPU" ]]; then
        local total_vCPU=$((vCPU * capacity))
        subscriptionVmssVcpu=$((subscriptionVmssVcpu + total_vCPU))
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

function runAnalysis {
  local scope=$1

  buildSkuMap

  echo "Load subscriptions"
  local expectedSubscriptions
  # shellcheck disable=SC2086
  expectedSubscriptions=$(graphQuery "resourcecontainers | where type == 'microsoft.resources/subscriptions' | project name, subscriptionId" "$scope")
  local expectedSubscriptionIds
  expectedSubscriptionIds=$(echo "$expectedSubscriptions" | jq -r '.data[] | .subscriptionId' | sort)

  echo "Load VMs"
  local vms
  vms=$(graphQuery "Resources | where type=~'microsoft.compute/virtualmachines' | project subscriptionId, name, sku=properties.hardwareProfile.vmSize, powerState=properties.extended.instanceView.powerState.code" "$scope")

  echo "Load VMSS"
  local vmss
  vmss=$(graphQuery "Resources | where type=~ 'microsoft.compute/virtualmachinescalesets' | project subscriptionId, name, sku=sku.name, capacity = toint(sku.capacity)" "$scope")

  local actualSubscriptionIds
  actualSubscriptionIds=$(echo "$vms" | jq -r '.data[] | .subscriptionId' | sort -u)

  echo '"Subscription ID", "Subscription Name", "VM Instances", "VM vCPUs", "VM Scale Sets", "VM Scale Set Instances", "VM Scale Set vCPUs", "Total Subscription vCPUs"'

  # First analyze subscriptions found in VM data but not in the expected list
  for actualSubscriptionId in $actualSubscriptionIds; do
    local foundSubscriptionId
    foundSubscriptionId=$(echo "$expectedSubscriptions" | jq -r --arg sid "$actualSubscriptionId" \
      '.data[] | select(.subscriptionId==$sid) | .subscriptionId')
    if [ "$actualSubscriptionId" != "$foundSubscriptionId" ]; then
      runSubscriptionAnalysis "$actualSubscriptionId" "" "$vms" "$vmss"
    fi
  done

  # Go through all expected subscriptions
  for expectedSubscriptionId in $expectedSubscriptionIds; do
    local subscriptionName
    subscriptionName=$(echo "$expectedSubscriptions" | jq -r --arg sid "$expectedSubscriptionId" \
      '.data[] | select(.subscriptionId==$sid) | .name')
    runSubscriptionAnalysis "$expectedSubscriptionId" "$subscriptionName" "$vms" "$vmss"
  done
}


# Management group takes precedence...partial scopes ALLOWED
if [[ -n "$MANAGEMENT_GROUP" ]]; then
  runAnalysis "--management-groups ${MANAGEMENT_GROUP//,/ }"
elif [[ -n "$SUBSCRIPTION" ]]; then
  runAnalysis "--subscriptions ${SUBSCRIPTION//,/ }"
else
  echo "Load all subscriptions available to user"
  subscriptions=$(az account subscription list -o json | jq -r '[.[] | .subscriptionId] | join(" ")')
  runAnalysis "--subscriptions $subscriptions"
fi

echo "##########################################"
echo "Lacework inventory collection complete."
echo ""
echo "VM Summary:"
echo "==============================="
echo "VM Instances:     $AZURE_VMS_COUNT"
echo "VM vCPUS:         $AZURE_VMS_VCPU"
echo ""
echo "VM Scale Set Summary:"
echo "==============================="
echo "VM Scale Sets:          $AZURE_VMSS_COUNT"
echo "VM Scale Set Instances: $AZURE_VMSS_VM_COUNT"
echo "VM Scale Set vCPUs:     $AZURE_VMSS_VCPU"
echo ""
echo "License Summary"
echo "==============================="
echo "  VM vCPUS:             $AZURE_VMS_VCPU"
echo "+ VM Scale Set vCPUs:   $AZURE_VMSS_VCPU"
echo "-------------------------------"
echo "Total vCPUs:            $((AZURE_VMS_VCPU + AZURE_VMSS_VCPU))"
