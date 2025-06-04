function ConvertFrom-SecureStringToPlainText($secureString) {
    $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureString)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

# Admin-Passwort abfragen
$admin_password         = Read-Host -AsSecureString "Geben Sie das Admin-Passwort für die VMs ein"
$admin_passwordConfirm  = Read-Host -AsSecureString "Geben Sie das Admin-Passwort für die VMs NOCHMAL ein"

if ((ConvertFrom-SecureStringToPlainText $admin_password) -ne (ConvertFrom-SecureStringToPlainText $admin_passwordConfirm)) {
    Write-Host "Passwörter unterschiedlich angegeben. Skript wird abgebrochen!"
    exit
}
if ([string]::IsNullOrWhiteSpace((ConvertFrom-SecureStringToPlainText $admin_password))) {
    Write-Host "Kein Passwort angegeben. Skript wird abgebrochen!"
    exit
}

# CSV einlesen
$csvPath = ".\Konfig.csv"
$csvContent = Get-Content -Path $csvPath -Encoding UTF8
$vms = $csvContent | ConvertFrom-Csv -Delimiter ';'

foreach ($vm in $vms) {
    if ($vm.os_type -notlike "*windows*") {
        continue
    }

    $location = $vm.region
    $resourceGroup = $vm.resource_group
    $vmName = $vm.virtual_machine_name
    $vnetName = $vm.vnet_name
    $subnetName = $vm.subnet_name
    $subnetPrefix = $vm.subnet_cidr
    $ipName = $vm.public_ip_name
    $network = $vm.vnet_cidr
    $nicName = "nic-$vmName"

    $image = $vm.image
    $adminUser = $vm.admin_username

    $diskType = $vm.os_disk_type
    $vmSize = "Standard_B2ms"
    $disksize = $vm.os_disk_size
    $createPublicIp = -not [string]::IsNullOrWhiteSpace($ipName)

    # Virtuelles Netzwerk + Subnetz
    az network vnet create `
        --resource-group $resourceGroup `
        --name $vnetName `
        --address-prefix $network `
        --subnet-name $subnetName `
        --subnet-prefixes $subnetPrefix `
        --location $location

    # Öffentliche IP erstellen (falls benötigt)
    if ($createPublicIp) {
        az network public-ip create `
            --resource-group $resourceGroup `
            --name $ipName `
            --location $location `
            --sku Basic `
            --allocation-method Static
    }

    # Netzwerkkarte OHNE NSG erstellen
    $nicArgs = @(
        "network", "nic", "create",
        "--resource-group", $resourceGroup,
        "--name", $nicName,
        "--vnet-name", $vnetName,
        "--subnet", $subnetName,
        "--location", $location
    )

    if ($createPublicIp) {
        $nicArgs += @("--public-ip-address", $ipName)
    }

    az @nicArgs

    # VM erstellen
    az vm create `
        --resource-group $resourceGroup `
        --name $vmName `
        --image $image `
        --admin-username $adminUser `
        --admin-password (ConvertFrom-SecureStringToPlainText $admin_password) `
        --size $vmSize `
        --os-disk-size-gb $disksize `
        --nics $nicName `
        --location $location `
        --no-wait
}
