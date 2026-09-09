[CmdletBinding()]
param(
    [string]$ParametersFile = (Join-Path $PSScriptRoot "parameters.json")
)

# Run from Windows PowerShell or PowerShell 7 with Azure CLI installed.
# The script reuses an Azure CLI session for the requested tenant when possible,
# prompts for a subscription, provisions a private MongoDB VM, and waits for cloud-init.
$ErrorActionPreference = "Continue"
$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$temporaryFiles = [System.Collections.Generic.List[string]]::new()

if (-not (Test-Path -LiteralPath $ParametersFile -PathType Leaf)) {
    throw "Parameters file not found: $ParametersFile"
}
$deploymentParameters = Get-Content -LiteralPath $ParametersFile -Raw | ConvertFrom-Json
$requiredParameters = @(
    "TenantId", "ResourceToken", "Location", "FallbackLocations", "VmSize",
    "VmAdminUsername", "VmAdminPassword", "VmImage", "DataDiskSizeGB",
    "OsDiskStorageSku", "SecurityType", "PublicIpSku", "VnetAddressPrefix",
    "SubnetAddressPrefix", "AutoShutdownTimeUtc", "SshSourceAddressPrefix",
    "MongoUsername", "MongoPassword", "MongoDatabase", "MongoPort",
    "DocumentDbServerVersion", "DocumentDbTier", "DocumentDbStorageSizeGB",
    "DocumentDbStorageType", "DocumentDbShardCount", "DocumentDbHighAvailability"
)
foreach ($requiredParameter in $requiredParameters) {
    if ($null -eq $deploymentParameters.$requiredParameter) {
        throw "$requiredParameter is missing from $ParametersFile."
    }
}
$tenantId = $deploymentParameters.TenantId
if ($tenantId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
    throw "TenantId in $ParametersFile must be a valid GUID."
}
$mongoDatabase = $deploymentParameters.MongoDatabase
$mongoPort = [int]$deploymentParameters.MongoPort
$ResourceToken = [string]$deploymentParameters.ResourceToken
$Location = [string]$deploymentParameters.Location
$fallbackLocations = @($deploymentParameters.FallbackLocations)
$VmSize = [string]$deploymentParameters.VmSize
$vmAdminUsername = [string]$deploymentParameters.VmAdminUsername
$plainPassword = [string]$deploymentParameters.VmAdminPassword
$vmImage = [string]$deploymentParameters.VmImage
$DataDiskSizeGB = [int]$deploymentParameters.DataDiskSizeGB
$osDiskStorageSku = [string]$deploymentParameters.OsDiskStorageSku
$securityType = [string]$deploymentParameters.SecurityType
$publicIpSku = [string]$deploymentParameters.PublicIpSku
$vnetAddressPrefix = [string]$deploymentParameters.VnetAddressPrefix
$subnetAddressPrefix = [string]$deploymentParameters.SubnetAddressPrefix
$autoShutdownTimeUtc = [string]$deploymentParameters.AutoShutdownTimeUtc
$SshSourceAddressPrefix = [string]$deploymentParameters.SshSourceAddressPrefix
$mongoUsername = [string]$deploymentParameters.MongoUsername
$mongoPassword = [string]$deploymentParameters.MongoPassword
$documentDbServerVersion = [string]$deploymentParameters.DocumentDbServerVersion
$documentDbTier = [string]$deploymentParameters.DocumentDbTier
$documentDbStorageSizeGB = [int]$deploymentParameters.DocumentDbStorageSizeGB
$documentDbStorageType = [string]$deploymentParameters.DocumentDbStorageType
$documentDbShardCount = [int]$deploymentParameters.DocumentDbShardCount
$documentDbHighAvailability = [string]$deploymentParameters.DocumentDbHighAvailability
if ($mongoDatabase -notmatch '^[a-zA-Z0-9_-]+$') {
    throw "MongoDatabase must contain only letters, numbers, underscores, or hyphens."
}
if ($mongoPort -lt 1024 -or $mongoPort -gt 65535) {
    throw "MongoPort must be between 1024 and 65535."
}
if ($DataDiskSizeGB -lt 8 -or $DataDiskSizeGB -gt 1024) {
    throw "DataDiskSizeGB must be between 8 and 1024."
}
if ($plainPassword.Length -lt 12 -or $plainPassword -notmatch '[A-Z]' -or
    $plainPassword -notmatch '[a-z]' -or $plainPassword -notmatch '\d' -or
    $plainPassword -notmatch '[^a-zA-Z0-9]') {
    throw "VmAdminPassword must be at least 12 characters with uppercase, lowercase, numeric, and special characters."
}

function Assert-LastExitCode {
    param([string]$Action)
    if ($LASTEXITCODE -ne 0) {
        throw "$Action failed with exit code $LASTEXITCODE."
    }
}

function Set-ParameterValue {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Parameters,

        [Parameter(Mandatory)]
        [string]$Name,

        [AllowNull()]
        [object]$Value
    )

    $Parameters | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force
}

function New-LowercaseToken {
    -join (1..5 | ForEach-Object { [char](Get-Random -Minimum 97 -Maximum 123) })
}

function Test-AzureSession {
    param(
        [Parameter(Mandatory)]
        [string]$TenantId
    )

    az account get-access-token --tenant $TenantId --output none 2>$null
    return $LASTEXITCODE -eq 0
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI was not found. Install it from https://aka.ms/installazurecliwindows."
}

if (Test-AzureSession -TenantId $tenantId) {
    Write-Host "Reusing the existing Azure CLI session for tenant $tenantId."
}
else {
    Write-Host "No valid Azure CLI session was found for tenant $tenantId. Signing in using device-code authentication."
    Write-Host "Open the URL shown by Azure CLI in an InPrivate or Incognito browser window, then enter the displayed code."
    az login --tenant $tenantId --use-device-code --output none
    Assert-LastExitCode "Azure login"
}

$subscriptions = @(az account list --all --query "[?state=='Enabled' && tenantId=='$tenantId'].{Name:name,Id:id}" --output json | ConvertFrom-Json)
Assert-LastExitCode "Subscription lookup"
if ($subscriptions.Count -eq 0) {
    throw "No enabled subscriptions are available in tenant $tenantId."
}

Write-Host "`nAvailable subscriptions:"
for ($index = 0; $index -lt $subscriptions.Count; $index++) {
    Write-Host ("[{0}] {1} ({2})" -f ($index + 1), $subscriptions[$index].Name, $subscriptions[$index].Id)
}
do {
    $selection = Read-Host "Choose a subscription number (1-$($subscriptions.Count))"
    $selectionNumber = 0
    $validSelection = [int]::TryParse($selection, [ref]$selectionNumber) -and
        $selectionNumber -ge 1 -and $selectionNumber -le $subscriptions.Count
} until ($validSelection)

$subscription = $subscriptions[$selectionNumber - 1]
az account set --subscription $subscription.Id
Assert-LastExitCode "Subscription selection"
Write-Host "Using subscription: $($subscription.Name)"

Write-Host "Installing or updating the Azure DocumentDB CLI extension..."
az extension add --name documentdb --upgrade --yes --output none
Assert-LastExitCode "Azure DocumentDB CLI extension installation"

if ([string]::IsNullOrWhiteSpace($ResourceToken)) {
    $ResourceToken = New-LowercaseToken
}
if ($ResourceToken -notmatch '^[a-z]{1,5}$') {
    throw "ResourceToken must contain one to five lowercase letters."
}

$candidateLocations = @($Location) + $fallbackLocations |
    Select-Object -Unique
$selectedLocation = $null
$instance = 1
foreach ($candidate in $candidateLocations) {
    Write-Host "Checking availability of $VmSize in $candidate..."
    $skuRecords = @(az vm list-skus --location $candidate --size $VmSize --resource-type virtualMachines --output json 2>$null | ConvertFrom-Json)
    if ($LASTEXITCODE -eq 0 -and @($skuRecords | Where-Object { $_.name -eq $VmSize -and @($_.restrictions).Count -eq 0 }).Count -gt 0) {
        $selectedLocation = $candidate
        if ($candidate -ne $Location) { $instance = 2 }
        break
    }
}
if (-not $selectedLocation) {
    throw "VM size $VmSize is unavailable in the requested and fallback regions. Choose another -VmSize or -Location."
}
if ($selectedLocation -ne $Location) {
    Write-Warning "$VmSize is unavailable in $Location. Using $selectedLocation and resource instance suffix 2."
}

$resourceGroupName = "rg$ResourceToken$instance"
$vmName = "vm$ResourceToken$instance"
$vnetName = "vn$ResourceToken$instance"
$subnetName = "sn$ResourceToken$instance"
$nsgName = "ng$ResourceToken$instance"
$publicIpName = "ip$ResourceToken$instance"
$nicName = "ni$ResourceToken$instance"
$dataDiskName = "dd$ResourceToken$instance"
$subscriptionToken = $subscription.Id.Replace("-", "").Substring(0, 8).ToLowerInvariant()
$documentDbClusterName = "docdb-$ResourceToken-$instance-$subscriptionToken"

if ([string]::IsNullOrWhiteSpace($SshSourceAddressPrefix)) {
    try {
        $callerIp = (Invoke-RestMethod -Uri "https://api.ipify.org" -TimeoutSec 10).Trim()
        $SshSourceAddressPrefix = "$callerIp/32"
    }
    catch {
        $SshSourceAddressPrefix = Read-Host "Enter the public CIDR allowed to SSH (for example, 203.0.113.10/32)"
    }
}
if ($SshSourceAddressPrefix -notmatch '^(\d{1,3}\.){3}\d{1,3}/([0-9]|[12][0-9]|3[0-2])$') {
    throw "SshSourceAddressPrefix must be an IPv4 CIDR such as 203.0.113.10/32."
}

try {
    $cloudInitPath = Join-Path ([System.IO.Path]::GetTempPath()) "cloud-init-$ResourceToken.yaml"
    $temporaryFiles.Add($cloudInitPath)
    $cloudInit = Get-Content (Join-Path $projectRoot "cloud-init.yaml") -Raw
    $cloudInit = $cloudInit.Replace("__MONGO_APP_USERNAME__", $mongoUsername)
    $cloudInit = $cloudInit.Replace("__MONGO_APP_PASSWORD__", $mongoPassword)
    $cloudInit = $cloudInit.Replace("__MONGO_DATABASE__", $mongoDatabase)
    Set-Content -Path $cloudInitPath -Value $cloudInit -Encoding utf8

    Write-Warning "Resource group $resourceGroupName will be deleted and recreated. This permanently removes its VM, disks, IPs, NSG, network, MongoDB data, and Azure DocumentDB cluster."
    $resourceGroupExist = az group show --name $resourceGroupName 2>$null
    if ($resourceGroupExist) {
        Write-Host "Deleting existing resource group $resourceGroupName..."
        az group delete --name $resourceGroupName --yes --no-wait
        Assert-LastExitCode "Resource group deletion request"
        az group wait --deleted --name $resourceGroupName
        Assert-LastExitCode "Resource group deletion"
    }
    Write-Host "Creating resource group $resourceGroupName in $selectedLocation..."
    az group create --name $resourceGroupName --location $selectedLocation --output none
    Assert-LastExitCode "Resource group creation"

    Write-Host "Creating Azure DocumentDB cluster $documentDbClusterName..."
    az documentdb mongocluster create --name $documentDbClusterName --resource-group $resourceGroupName `
        --location $selectedLocation --admin-user $mongoUsername --admin-password $mongoPassword `
        --server-version $documentDbServerVersion --tier $documentDbTier `
        --storage-size $documentDbStorageSizeGB --storage-type $documentDbStorageType `
        --shard-count $documentDbShardCount --high-availability $documentDbHighAvailability `
        --auth-allowed-modes NativeAuth --public-network-access Enabled --no-wait --output none
    Assert-LastExitCode "Azure DocumentDB cluster creation"
    az documentdb mongocluster wait --name $documentDbClusterName --resource-group $resourceGroupName --created
    Assert-LastExitCode "Azure DocumentDB cluster provisioning"

    az documentdb mongocluster firewall-rule create --name AllowAllExternal `
        --cluster-name $documentDbClusterName --resource-group $resourceGroupName `
        --start-ip-address "0.0.0.0" --end-ip-address "255.255.255.255" --output none
    Assert-LastExitCode "Azure DocumentDB firewall rule creation"

    $vnetExist = az network vnet show --resource-group $resourceGroupName --name $vnetName 2>$null
    if (-not $vnetExist) {
        az network vnet create --resource-group $resourceGroupName --name $vnetName --location $selectedLocation `
            --address-prefixes $vnetAddressPrefix --subnet-name $subnetName --subnet-prefixes $subnetAddressPrefix --output none
        Assert-LastExitCode "Virtual network creation"
    }

    $nsgExist = az network nsg show --resource-group $resourceGroupName --name $nsgName 2>$null
    if (-not $nsgExist) {
        az network nsg create --resource-group $resourceGroupName --name $nsgName --location $selectedLocation --output none
        Assert-LastExitCode "Network security group creation"
    }
    $sshRuleExist = az network nsg rule show --resource-group $resourceGroupName --nsg-name $nsgName --name AllowSsh 2>$null
    if (-not $sshRuleExist) {
        az network nsg rule create --resource-group $resourceGroupName --nsg-name $nsgName --name AllowSsh `
            --priority 100 --direction Inbound --access Allow --protocol Tcp --source-address-prefixes $SshSourceAddressPrefix `
            --destination-port-ranges 22 --output none
        Assert-LastExitCode "SSH rule creation"
    }
    az network nsg rule create --resource-group $resourceGroupName --nsg-name $nsgName --name AllowMongoDb `
        --priority 120 --direction Inbound --access Allow --protocol Tcp --source-address-prefixes "*" `
        --source-port-ranges "*" --destination-address-prefixes "*" --destination-port-ranges $mongoPort --output none
    Assert-LastExitCode "MongoDB inbound rule creation"
    az network nsg rule create --resource-group $resourceGroupName --nsg-name $nsgName --name AllowMongoDbOutbound `
        --priority 120 --direction Outbound --access Allow --protocol Tcp --source-address-prefixes "*" `
        --source-port-ranges "*" --destination-address-prefixes "*" --destination-port-ranges $mongoPort --output none
    Assert-LastExitCode "MongoDB outbound rule creation"
    az network vnet subnet update --resource-group $resourceGroupName --vnet-name $vnetName --name $subnetName `
        --network-security-group $nsgName --output none
    Assert-LastExitCode "Subnet network security group association"
    $appRuleExist = az network nsg rule show --resource-group $resourceGroupName --nsg-name $nsgName --name AllowFlask 2>$null
    if ($appRuleExist) {
        az network nsg rule delete --resource-group $resourceGroupName --nsg-name $nsgName --name AllowFlask --output none
        Assert-LastExitCode "Obsolete Flask rule removal"
    }

    $publicIpExist = az network public-ip show --resource-group $resourceGroupName --name $publicIpName 2>$null
    if (-not $publicIpExist) {
        az network public-ip create --resource-group $resourceGroupName --name $publicIpName --location $selectedLocation `
            --sku $publicIpSku --allocation-method Static --zone 1 2 3 --output none
        Assert-LastExitCode "Public IP creation"
    }

    $nicExist = az network nic show --resource-group $resourceGroupName --name $nicName 2>$null
    if (-not $nicExist) {
        az network nic create --resource-group $resourceGroupName --name $nicName --location $selectedLocation `
            --vnet-name $vnetName --subnet $subnetName --network-security-group $nsgName `
            --public-ip-address $publicIpName --accelerated-networking false --output none
        Assert-LastExitCode "Network interface creation"
    }

    $vmExist = az vm show --resource-group $resourceGroupName --name $vmName 2>$null
    if (-not $vmExist) {
        az vm create --resource-group $resourceGroupName --name $vmName --location $selectedLocation `
            --nics $nicName --image $vmImage --size $VmSize --admin-username $vmAdminUsername `
            --authentication-type password --admin-password $plainPassword --custom-data $cloudInitPath `
            --storage-sku "os=$osDiskStorageSku" --security-type $securityType --enable-secure-boot true `
            --enable-vtpm true --assign-identity --data-disk-sizes-gb $DataDiskSizeGB `
            --tags "CostControl=ignore" --output none
        Assert-LastExitCode "Virtual machine creation"
        az vm auto-shutdown --resource-group $resourceGroupName --name $vmName --time $autoShutdownTimeUtc --output none
        Assert-LastExitCode "Auto-shutdown configuration"

        Write-Host "Waiting for cloud-init to install and secure MongoDB..."
        az vm run-command invoke --resource-group $resourceGroupName --name $vmName `
            --command-id RunShellScript --scripts "cloud-init status --wait" --output none
        Assert-LastExitCode "Cloud-init"
    }
    else {
        Write-Host "MongoDB VM already exists; applying MongoDB network configuration for direct client access."
        $encodedMongoPassword = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($mongoPassword))
                $mongoNetworkScript = @"
set -e
sudo sed -i -E 's/^([[:space:]]*)bindIp:.*/\\1bindIp: 0.0.0.0/' /etc/mongod.conf
sudo sed -i '/^security:$/,+1d' /etc/mongod.conf
sudo systemctl restart mongod
mongo_password=`$(echo '$encodedMongoPassword' | base64 -d)
MONGO_USER='$mongoUsername' MONGO_PASSWORD="`$mongo_password" MONGO_DATABASE='$mongoDatabase' mongosh --quiet --host 127.0.0.1 admin --eval '
if (db.getUser(process.env.MONGO_USER)) {
    db.updateUser(process.env.MONGO_USER, { pwd: process.env.MONGO_PASSWORD, roles: [
        { role: "readWrite", db: process.env.MONGO_DATABASE },
        { role: "clusterMonitor", db: "admin" }
    ] });
} else {
    db.createUser({ user: process.env.MONGO_USER, pwd: process.env.MONGO_PASSWORD, roles: [
        { role: "readWrite", db: process.env.MONGO_DATABASE },
        { role: "clusterMonitor", db: "admin" }
    ] });
}'
printf '\nsecurity:\n  authorization: enabled\n' | sudo tee -a /etc/mongod.conf >/dev/null
sudo systemctl restart mongod
"@
        az vm run-command invoke --resource-group $resourceGroupName --name $vmName `
            --command-id RunShellScript --scripts $mongoNetworkScript --output none
        Assert-LastExitCode "MongoDB network reconfiguration"
        $existingDataDisks = @(
            az vm show --resource-group $resourceGroupName --name $vmName --query "storageProfile.dataDisks[].name" --output tsv
        )
        if ($existingDataDisks.Count -eq 0) {
            Write-Host "Attaching a ${DataDiskSizeGB}GB data disk to existing VM..."
            az vm disk attach --resource-group $resourceGroupName --vm-name $vmName --name $dataDiskName --new --size-gb $DataDiskSizeGB --output none
            Assert-LastExitCode "Data disk attachment"
            Write-Warning "A new data disk was attached to an existing VM. Run cloud-init disk steps manually if MongoDB was already initialized."
        }
    }

    $publicIp = az network public-ip show --resource-group $resourceGroupName --name $publicIpName `
        --query ipAddress --output tsv
    Assert-LastExitCode "Public IP lookup"
    $encodedUsername = [Uri]::EscapeDataString($mongoUsername)
    $encodedPassword = [Uri]::EscapeDataString($mongoPassword)
    $mongoUri = "mongodb://${encodedUsername}:${encodedPassword}@${publicIp}:${mongoPort}/${mongoDatabase}?authSource=admin"
    $documentDbConnectionString = az documentdb mongocluster list-connection-strings `
        --cluster-name $documentDbClusterName --resource-group $resourceGroupName `
        --query "connectionStrings[0].connectionString" --output tsv
    Assert-LastExitCode "Azure DocumentDB connection string lookup"
    if ([string]::IsNullOrWhiteSpace($documentDbConnectionString)) {
        throw "Azure DocumentDB did not return a connection string."
    }
    $documentDbConnectionString = $documentDbConnectionString.Replace("<username>", $encodedUsername)
    $documentDbConnectionString = $documentDbConnectionString.Replace("<user>", $encodedUsername)
    $documentDbConnectionString = $documentDbConnectionString.Replace("<password>", $encodedPassword)

    $generatedParameters = [ordered]@{
        ResourceToken = $ResourceToken
        SshSourceAddressPrefix = $SshSourceAddressPrefix
        MongoUri = $mongoUri
        PublicIpAddress = $publicIp
        DeploymentLocation = $selectedLocation
        ResourceGroupName = $resourceGroupName
        VmName = $vmName
        DocumentDbClusterName = $documentDbClusterName
    }
    foreach ($generatedParameter in $generatedParameters.GetEnumerator()) {
        Set-ParameterValue -Parameters $deploymentParameters `
            -Name $generatedParameter.Key -Value $generatedParameter.Value
    }

    $parameterContent = $deploymentParameters | ConvertTo-Json -Depth 10
    Set-Content -LiteralPath $ParametersFile -Value $parameterContent -Encoding utf8
    Write-Host "`nDeployment complete."
    Write-Host "SSH: ssh $vmAdminUsername@$publicIp"
    Write-Host "MongoUri: $mongoUri"
    Write-Host "DocumentDbConnectionString: $documentDbConnectionString"
    Write-Host "Seed locally:  python ./seed_mongo.py"
    Write-Host "Run app local: python ./app.py"
    Write-Host "Open app:      http://127.0.0.1:5000"
    Write-Warning "MongoDB ($mongoPort) is exposed to all IP addresses by inbound and outbound NSG rules."
    Write-Warning "Azure DocumentDB allows external access from 0.0.0.0 through 255.255.255.255. Use this firewall rule only for testing and development."
    Write-Host "Resource group: $resourceGroupName"
    Write-Host "Cleanup: az group delete --name $resourceGroupName --yes --no-wait"
}
finally {
    $plainPassword = $null
    foreach ($file in $temporaryFiles) {
        Remove-Item $file -Force -ErrorAction SilentlyContinue
    }
}
