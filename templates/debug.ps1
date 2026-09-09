[CmdletBinding()]
param(
    [switch]$Apply,
    [string]$ParametersFile = "parameters.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

function Assert-LastExitCode {
    param([string]$Operation)

    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed with exit code $LASTEXITCODE."
    }
}

function Get-RequiredProperty {
    param(
        [object]$Parameters,
        [string]$Name
    )

    $property = $Parameters.PSObject.Properties[$Name]
    if (-not $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        throw "Missing parameter: $Name"
    }
    return [string]$property.Value
}

$parametersPath = if ([IO.Path]::IsPathRooted($ParametersFile)) {
    $ParametersFile
}
else {
    Join-Path $PSScriptRoot $ParametersFile
}
if (-not (Test-Path -LiteralPath $parametersPath -PathType Leaf)) {
    throw "Parameters file not found: $parametersPath"
}

foreach ($commandName in @("az", "ssh")) {
    if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $commandName"
    }
}

$parameters = Get-Content -LiteralPath $parametersPath -Raw | ConvertFrom-Json
$resourceGroup = Get-RequiredProperty $parameters "ResourceGroupName"
$vmName = Get-RequiredProperty $parameters "VmName"
$vmAdminUsername = Get-RequiredProperty $parameters "VmAdminUsername"
$publicIp = Get-RequiredProperty $parameters "PublicIpAddress"
$resourceSuffix = $vmName -replace '^vm', ''
$deploymentNsg = "ng$resourceSuffix"

Write-Host "== Azure account =="
az account show --query '{subscription:name,tenantId:tenantId}' --output table --only-show-errors
Assert-LastExitCode "Azure account lookup"

Write-Host "== VM state =="
$powerState = az vm get-instance-view `
    --resource-group $resourceGroup `
    --name $vmName `
    --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus | [0]" `
    --output tsv `
    --only-show-errors
Assert-LastExitCode "VM state lookup"
$powerState = $powerState.Trim()
Write-Host $powerState
if ($powerState -ne "VM running") {
    throw "VM is not running. Start it with: az vm start --resource-group $resourceGroup --name $vmName"
}

$nicId = az vm show `
    --resource-group $resourceGroup `
    --name $vmName `
    --query 'networkProfile.networkInterfaces[0].id' `
    --output tsv `
    --only-show-errors
Assert-LastExitCode "VM NIC lookup"
$nicId = $nicId.Trim()
$nicName = Split-Path $nicId -Leaf

$subnetId = az network nic show `
    --ids $nicId `
    --query 'ipConfigurations[0].subnet.id' `
    --output tsv `
    --only-show-errors
Assert-LastExitCode "NIC subnet lookup"
$subnetId = $subnetId.Trim()
$subnetName = Split-Path $subnetId -Leaf
$vnetId = $subnetId -replace '/subnets/[^/]+$', ''
$vnetName = Split-Path $vnetId -Leaf

$privateIp = az network nic show `
    --ids $nicId `
    --query 'ipConfigurations[0].privateIPAddress' `
    --output tsv `
    --only-show-errors
Assert-LastExitCode "NIC private IP lookup"
$privateIp = $privateIp.Trim()

try {
    $publicSourceIp = ([string](Invoke-RestMethod -Uri "https://api.ipify.org" -TimeoutSec 10)).Trim()
}
catch {
    $publicSourceIp = "0.0.0.0"
    Write-Warning "Unable to determine this client's public IPv4 address."
}

Write-Host "== Network resources =="
Write-Host "VM: $vmName"
Write-Host "NIC: $nicName"
Write-Host "VNet: $vnetName"
Write-Host "Subnet: $subnetName"
Write-Host "Deployment NSG: $deploymentNsg"
Write-Host "Public IP: $publicIp"
Write-Host "Client public IP: $publicSourceIp"

Write-Host "== Effective SSH and MongoDB security rules =="
az network nic list-effective-nsg `
    --resource-group $resourceGroup `
    --name $nicName `
    --query "value[].{association:association,networkSecurityGroup:networkSecurityGroup.id,rules:effectiveSecurityRules[?contains(name, 'SSH') || contains(name, 'Mongo') || contains(name, 'DenyAllInBound')].{name:name,priority:priority,access:access,destinationPorts:destinationPortRange}}" `
    --output json `
    --only-show-errors
Assert-LastExitCode "Effective NSG lookup"

Write-Host "== Services and listeners inside VM =="
az vm run-command invoke `
    --resource-group $resourceGroup `
    --name $vmName `
    --command-id RunShellScript `
    --scripts `
        "systemctl is-active ssh" `
        "systemctl is-active mongod" `
        "ss -lntp | grep -E ':(22|27017) ' || true" `
    --query 'value[].message' `
    --output tsv `
    --only-show-errors
Assert-LastExitCode "VM service diagnostics"

if ($Apply) {
    Write-Host "== Associate deployment NSG with subnet =="
    az network vnet subnet update `
        --resource-group $resourceGroup `
        --vnet-name $vnetName `
        --name $subnetName `
        --network-security-group $deploymentNsg `
        --output none `
        --only-show-errors
    Assert-LastExitCode "Subnet NSG association"
}

Write-Host "== Azure packet-flow checks =="
foreach ($port in @(22, 27017)) {
    $result = az network watcher test-ip-flow `
        --resource-group $resourceGroup `
        --vm $vmName `
        --nic $nicName `
        --direction Inbound `
        --protocol TCP `
        --local "${privateIp}:$port" `
        --remote "${publicSourceIp}:50000" `
        --query '{access:access,rule:ruleName}' `
        --output json `
        --only-show-errors
    Assert-LastExitCode "Packet-flow check for port $port"
    Write-Host "Port ${port}: $($result -join [Environment]::NewLine)"
}

Write-Host "== SSH negotiation =="
$sshOutput = & ssh -vv `
    -o BatchMode=yes `
    -o ConnectTimeout=8 `
    -o StrictHostKeyChecking=no `
    -o UserKnownHostsFile=/dev/null `
    "${vmAdminUsername}@${publicIp}" 2>&1
$sshExitCode = $LASTEXITCODE
$sshOutput | Select-Object -Last 15
if ($sshExitCode -eq 0) {
    Write-Host "SSH key authentication succeeded."
}
elseif (($sshOutput | Out-String) -match 'Permission denied \(publickey,password\)') {
    Write-Host "SSH reached authentication; password login can be tested interactively with:"
    Write-Host "ssh ${vmAdminUsername}@${publicIp}"
}
else {
    throw "SSH negotiation failed with exit code $sshExitCode."
}

if ($Apply) {
    $python = if ($IsWindows) {
        Join-Path $PSScriptRoot ".venv/Scripts/python.exe"
    }
    else {
        Join-Path $PSScriptRoot ".venv/bin/python"
    }
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
        throw "Python virtual environment not found at $python"
    }

    Write-Host "== Reseed MongoDB =="
    $seedOutput = & $python (Join-Path $PSScriptRoot "seed_mongo.py") 2>&1
    $seedExitCode = $LASTEXITCODE
    $seedOutput | ForEach-Object { [string]$_ -replace "at '.*'", "at '<redacted MongoDB URI>'" }
    if ($seedExitCode -ne 0) {
        throw "MongoDB seed failed with exit code $seedExitCode."
    }

    Write-Host "== MongoDB collection counts =="
    @'
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
'@ | & $python -
    Assert-LastExitCode "MongoDB count verification"
}
else {
    Write-Host ""
    Write-Host "Diagnostics complete. Run './debug.ps1 -Apply -ParametersFile $ParametersFile' to apply the NSG association and reseed MongoDB."
}
