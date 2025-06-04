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
$admin_passwordSecure = Read-Host -AsSecureString "Geben Sie das Admin-Passwort für die VMs ein"
$admin_password = ConvertFrom-SecureStringToPlainText $admin_passwordSecure

if ([string]::IsNullOrWhiteSpace($admin_password)) {
    Write-Host "Kein Passwort angegeben. Skript wird abgebrochen!"
    exit
}

# CSV-Datei laden
$csvPath = ".\HM.csv"
$csvContent = Get-Content -Path $csvPath -Encoding UTF8
$vms = $csvContent | ConvertFrom-Csv -Delimiter ';'

foreach ($vm in $vms) {
    $location = $vm.region
    $resourceGroup = $vm.resource_group
    $vmName = $vm.virtual_machine_name
    $vnetName = $vm.vnet_name
    $subnetName = $vm.subnet_name
    $subnetPrefix = $vm.subnet_cidr
    $ipName = $vm.public_ip_name
    $nsgName = "nsg-$vmName"
    $network = $vm.vnet_cidr
    $nicName = "nic-$vmName"
    $image = $vm.Image
    $adminUser = $vm.admin_username
    $diskType = $vm.os_disk_type
    $vmSize = $vm.size
    $spot = $vm.azure_spot_discount -eq "true"
    $disksize = $vm.os_disk_size
    $os_type = $vm.os_type
    $shutdown  = $vm.'auto-shutdown'
    $securitytype = $vm.security_type
    $bastionName = $vm.bastion_name

    # Warnung bei Bastion und Public IP
    if (![string]::IsNullOrWhiteSpace($bastionName) -and ![string]::IsNullOrWhiteSpace($ipName)) {
        Write-Warning "⚠️ VM '$vmName' hat sowohl eine Public IP als auch eine Bastion! Dies ist nicht empfohlen, wird aber durchgeführt."
    }

    # Virtuelles Netzwerk + Subnetz
    az network vnet create `
      --resource-group $resourceGroup `
      --name $vnetName `
      --location $location `
      --address-prefix $network `
      --subnet-name $subnetName `
      --subnet-prefix $subnetPrefix

    # NSG erstellen
    az network nsg create `
      --resource-group $resourceGroup `
      --location $location `
      --name $nsgName

   # Öffentliche IP erstellen (falls benötigt)
    if ($createPublicIp) {
        az network public-ip create `
            --resource-group $resourceGroup `
            --name $ipName `
            --location $location `
            --sku Basic `
            --allocation-method Static
    }

    # NIC erstellen
    az network nic create `
      --resource-group $resourceGroup `
      --name $nicName `
      --vnet-name $vnetName `
      --subnet $subnetName `
      --location $location

    # Bastion erstellen wenn angegeben
    if (![string]::IsNullOrWhiteSpace($bastionName)) {
        $bastionSubnetName = "AzureBastionSubnet"
        $bastionSubnetPrefix = "10.6.3.0/26"
        $bastionPipName = "$bastionName-pip"

        az network vnet subnet create `
          --resource-group $resourceGroup `
          --vnet-name $vnetName `
          --name $bastionSubnetName `
          --address-prefixes $bastionSubnetPrefix

        az network public-ip create `
          --resource-group $resourceGroup `
          --name $bastionPipName `
          --sku Standard `
          --location $location

        az network bastion create `
          --name $bastionName `
          --public-ip-address $bastionPipName `
          --resource-group $resourceGroup `
          --vnet-name $vnetName `
          --location $location
    }

    # VM erstellen
    if ($os_type -like "*windows*") {
        az vm create `
          --resource-group $resourceGroup `
          --location $location `
          --name $vmName `
          --image $image `
          --size $vmSize `
          --admin-username $adminUser `
          --admin-password $admin_password `
          --nics $nicName `
          --storage-sku $diskType `
          --os-disk-size-gb $disksize `
          --security-type $securitytype `
          $(if ($spot) { "--priority"; "Spot"; "--eviction-policy"; "Deallocate" }) `
          --enable-agent true `
          --license-type Windows_Client
    }

    if ($os_type -like "*linux*") {
        az vm create `
          --resource-group $resourceGroup `
          --name $vmName `
          --image $image `
          --size $vmSize `
          --admin-username $adminUser `
          --admin-password $admin_password `
          --location $location `
          --nics $nicName `
          --storage-sku $diskType `
          --os-disk-size-gb $disksize `
          $(if ($spot) { "--priority"; "Spot"; "--eviction-policy"; "Deallocate" }) `
          --enable-agent true
    }

    # Auto-Shutdown aktivieren
    if ($shutdown -eq "True") {
        az vm auto-shutdown `
          --resource-group $resourceGroup `
          --name $vmName `
          --time 1900 `
          --location $location `
          --email "hamidullah.jalali@schule-zukunftsmotor.org"
    }
}
