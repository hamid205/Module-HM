function ConvertFrom-SecureStringToPlainText($secureString) {
    $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureString)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
  }
  
  # Admin-Passwort abfragen und prüfen (einmalig)
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
  $csvPath = ".\HM-Data.csv"
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
    $port = $vm.public_inbound_port
    $disksize = $vm.os_disk_size
    $os_type = $vm.os_type
    $shutdown  = $vm.'auto_shutdown'
    $createPublicIp = -not [string]::IsNullOrWhiteSpace($vm.public_ip_name)
    $securitytype = $vm.security_type
  
    # Virtuelles Netzwerk + Subnetz
    az network vnet create `
      --resource-group $resourceGroup `
      --name $vnetName `
      --location $location `
      --address-prefix $network `
      --subnet-name $subnetName `
      --subnet-prefix $subnetPrefix
  
    # Öffentliche IP
    if ($createPublicIp) {
        az network public-ip create `
            --resource-group $resourceGroup `
            --name $ipName `
            --location $location
    } 
  
    # NSG + Regel
    az network nsg create `
      --resource-group $resourceGroup `
      --location $location `
      --name $nsgName
  
    if($os_type -like "*windows*"){
        az network nsg rule create `
          --resource-group $resourceGroup `
          --nsg-name $nsgName `
          --name allow-rdp `
          --priority 1000 `
          --destination-port-ranges $port `
          --protocol Tcp `
          --access Allow `
          --direction Inbound
    }
  
    if($os_type -like "*linux*"){
        az network nsg rule create `
          --resource-group $resourceGroup `
          --nsg-name $nsgName `
          --name allow-ssh `
          --priority 1000 `
          --destination-port-ranges $port `
          --protocol Tcp `
          --access Allow `
          --direction Inbound
    }
  
    # Netzwerkkarte
    az network nic create `
      --resource-group $resourceGroup `
      --name $nicName `
      --vnet-name $vnetName `
      --subnet $subnetName `
      --location $location `
      --network-security-group $nsgName `
      $(if ($createPublicIp) { @("--public-ip-address", $ipName) } else { @() })
  
    # VM erstellen
    if($os_type -like "*windows*"){
        az vm create `
          --resource-group $resourceGroup `
          --location $location `
          --name $vmName `
          --image $image `
          --size $vmSize `
          --admin-username $adminUser `
          --admin-password (ConvertFrom-SecureStringToPlainText $admin_password) `
          --nics $nicName `
          --storage-sku $diskType `
          --os-disk-size-gb $disksize `
          --security-type $securitytype `
          $(if ($spot) { "--priority"; "Spot"; "--eviction-policy"; "Deallocate" }) `
          --enable-agent true `
          --license-type Windows_Client
    }
  
    if($os_type -like "*linux*"){
        az vm create `
          --resource-group $resourceGroup `
          --name $vmName `
          --image $image `
          --size $vmSize `
          --admin-username $adminUser `
          --admin-password (ConvertFrom-SecureStringToPlainText $admin_password) `
          --location $location `
          --nics $nicName `
          --storage-sku $diskType `
          --os-disk-size-gb $disksize `
          $(if ($spot) { "--priority"; "Spot"; "--eviction-policy"; "Deallocate" }) `
          --enable-agent true
    }
  
    if ($shutdown -eq "True"){
        az vm auto-shutdown `
          --resource-group $resourceGroup `
          --name $vmName `
          --time 1900 `
          --location $location `
          --email "hamidullah.jalali@schule-zukunftsmotor.org"
    }
  }
   