#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./debug.sh [--apply] [parameters-file]

Without --apply, run read-only Azure, SSH, and MongoDB diagnostics.
With --apply, associate the deployment NSG with the subnet, verify the
result, reseed MongoDB, and print the resulting collection counts.
EOF
}

APPLY=false
PARAMETERS_FILE="parameters.json"
for argument in "$@"; do
    case "$argument" in
        --apply) APPLY=true ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "Unknown option: $argument" >&2; usage >&2; exit 2 ;;
        *) PARAMETERS_FILE="$argument" ;;
    esac
done

if [[ ! -f "$PARAMETERS_FILE" ]]; then
    echo "Parameters file not found: $PARAMETERS_FILE" >&2
    exit 1
fi

for command_name in az python3 ssh curl; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Required command not found: $command_name" >&2
        exit 1
    fi
done

mapfile -t PARAMETERS < <(python3 - "$PARAMETERS_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as parameters_file:
    parameters = json.load(parameters_file)

for name in ("ResourceGroupName", "VmName", "VmAdminUsername", "PublicIpAddress"):
    value = parameters.get(name)
    if not value:
        raise SystemExit(f"Missing parameter: {name}")
    print(value)
PY
)

RESOURCE_GROUP=${PARAMETERS[0]}
VM_NAME=${PARAMETERS[1]}
VM_ADMIN_USERNAME=${PARAMETERS[2]}
PUBLIC_IP=${PARAMETERS[3]}
RESOURCE_SUFFIX=${VM_NAME#vm}
DEPLOYMENT_NSG="ng${RESOURCE_SUFFIX}"

echo "== Azure account =="
az account show --query '{subscription:name,tenantId:tenantId}' --output table --only-show-errors

echo "== VM state =="
POWER_STATE=$(az vm get-instance-view \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus | [0]" \
    --output tsv \
    --only-show-errors)
echo "$POWER_STATE"
if [[ "$POWER_STATE" != "VM running" ]]; then
    echo "Start it with: az vm start --resource-group $RESOURCE_GROUP --name $VM_NAME" >&2
    exit 1
fi

NIC_ID=$(az vm show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --query 'networkProfile.networkInterfaces[0].id' \
    --output tsv \
    --only-show-errors)
NIC_NAME=${NIC_ID##*/}
SUBNET_ID=$(az network nic show \
    --ids "$NIC_ID" \
    --query 'ipConfigurations[0].subnet.id' \
    --output tsv \
    --only-show-errors)
SUBNET_NAME=${SUBNET_ID##*/}
VNET_ID=${SUBNET_ID%/subnets/*}
VNET_NAME=${VNET_ID##*/}
PRIVATE_IP=$(az network nic show \
    --ids "$NIC_ID" \
    --query 'ipConfigurations[0].privateIPAddress' \
    --output tsv \
    --only-show-errors)

PUBLIC_SOURCE_IP=$(curl -4 -fsS https://api.ipify.org || true)
if [[ -z "$PUBLIC_SOURCE_IP" ]]; then
    PUBLIC_SOURCE_IP="0.0.0.0"
    echo "Warning: unable to determine this client's public IPv4 address." >&2
fi

echo "== Network resources =="
printf 'VM: %s\nNIC: %s\nVNet: %s\nSubnet: %s\nDeployment NSG: %s\nPublic IP: %s\nClient public IP: %s\n' \
    "$VM_NAME" "$NIC_NAME" "$VNET_NAME" "$SUBNET_NAME" "$DEPLOYMENT_NSG" "$PUBLIC_IP" "$PUBLIC_SOURCE_IP"

echo "== Effective SSH and MongoDB security rules =="
az network nic list-effective-nsg \
    --resource-group "$RESOURCE_GROUP" \
    --name "$NIC_NAME" \
    --query "value[].{association:association,networkSecurityGroup:networkSecurityGroup.id,rules:effectiveSecurityRules[?contains(name, 'SSH') || contains(name, 'Mongo') || contains(name, 'DenyAllInBound')].{name:name,priority:priority,access:access,destinationPorts:destinationPortRange}}" \
    --output json \
    --only-show-errors

echo "== Services and listeners inside VM =="
az vm run-command invoke \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --command-id RunShellScript \
    --scripts \
        "systemctl is-active ssh" \
        "systemctl is-active mongod" \
        "ss -lntp | grep -E ':(22|27017) ' || true" \
    --query 'value[].message' \
    --output tsv \
    --only-show-errors

if [[ "$APPLY" == true ]]; then
    echo "== Associate deployment NSG with subnet =="
    az network vnet subnet update \
        --resource-group "$RESOURCE_GROUP" \
        --vnet-name "$VNET_NAME" \
        --name "$SUBNET_NAME" \
        --network-security-group "$DEPLOYMENT_NSG" \
        --output none \
        --only-show-errors
fi

echo "== Azure packet-flow checks =="
for port in 22 27017; do
    result=$(az network watcher test-ip-flow \
        --resource-group "$RESOURCE_GROUP" \
        --vm "$VM_NAME" \
        --nic "$NIC_NAME" \
        --direction Inbound \
        --protocol TCP \
        --local "${PRIVATE_IP}:${port}" \
        --remote "${PUBLIC_SOURCE_IP}:50000" \
        --query '{access:access,rule:ruleName}' \
        --output json \
        --only-show-errors)
    printf 'Port %s: %s\n' "$port" "$result"
done

echo "== SSH negotiation =="
if ssh -vv -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "${VM_ADMIN_USERNAME}@${PUBLIC_IP}" 2>&1 | tail -n 15; then
    echo "SSH key authentication succeeded."
else
    echo "SSH reached authentication; password login can be tested interactively with:"
    echo "ssh ${VM_ADMIN_USERNAME}@${PUBLIC_IP}"
fi

if [[ "$APPLY" == true ]]; then
    PYTHON=.venv/bin/python
    if [[ ! -x "$PYTHON" ]]; then
        echo "Python virtual environment not found at $PYTHON" >&2
        exit 1
    fi

    echo "== Reseed MongoDB =="
    "$PYTHON" seed_mongo.py | sed -E "s#at '.*'#at '<redacted MongoDB URI>'#"

    echo "== MongoDB collection counts =="
    "$PYTHON" - <<'PY'
from pymongo import MongoClient
from seed_mongo import load_parameters

parameters = load_parameters()
client = MongoClient(
    parameters["MongoUri"],
    serverSelectionTimeoutMS=int(parameters["MongoServerSelectionTimeoutMs"]),
)
try:
    database = client[parameters["MongoDatabase"]]
    print(f"users: {database.users.count_documents({})}")
    print(f"projects: {database.projects.count_documents({})}")
    print(f"tasks: {database.tasks.count_documents({})}")
finally:
    client.close()
PY
else
    echo
    echo "Diagnostics complete. Run './debug.sh --apply $PARAMETERS_FILE' to apply the NSG association and reseed MongoDB."
fi
