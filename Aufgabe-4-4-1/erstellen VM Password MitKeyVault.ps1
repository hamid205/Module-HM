# Funktion: SecureString in Klartext umwandeln
function Convert-SecureStringToPlainText {
    param ([System.Security.SecureString]$secureString)
    $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureString)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

# CSV einlesen
$csvPath = ".\Konfig.csv"
if (-not (Test-Path $csvPath)) {
    Write-Host "CSV-Datei '$csvPath' nicht gefunden. Skript wird abgebrochen!"
    exit
}
$csvContent = Get-Content -Path $csvPath -Encoding UTF8
$vms = $csvContent | ConvertFrom-Csv -Delimiter ';'

# Richtiger Key Vault Name
$keyVaultName = "keyVault-hh"

foreach ($vm in $vms) {
    if ($vm.os_type -notlike "windows") {
        Write-Host "Überspringe VM '$($vm.virtual_machine_name)', da sie kein Windows-Betriebssystem ist."
        continue
    }

    # Variablen aus CSV
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
    $image = $vm.image
    $adminUser = $vm.admin_username
    $diskType = $vm.os_disk_type
    $vmSize = $vm.size
    $spot = $vm.azure_spot_discount -eq "true"
    $port = $vm.public_inbound_port
    $disksize = $vm.os_disk_size
    $securitytype = $vm.security_type
    $createPublicIp = -not [string]::IsNullOrWhiteSpace($vm.public_ip_name)
    $shutdown = $vm.auto_shutdown -eq "true"
    $keyVaultSecretName = $vm.KeyVaultSecretName

    # Passwort aus Key Vault abrufen
    if ([string]::IsNullOrWhiteSpace($keyVaultSecretName)) {
        Write-Host "Kein KeyVaultSecretName für VM '$vmName' angegeben. VM wird übersprungen."
        continue
    }
    try {
        Write-Host "Rufe Passwort für '$vmName' aus Key Vault ab..."
        $vmPassword = az keyvault secret show --name $keyVaultSecretName --vault-name $keyVaultName --query value -o tsv | ConvertTo-SecureString -AsPlainText -Force
        if (-not $vmPassword) {
            Write-Host "Fehler: Kein Passwort für '$vmName' im Key Vault gefunden. VM wird übersprungen."
            continue
        }
    }
    catch {
        Write-Host "Fehler beim Abrufen des Passworts für '$vmName' aus Key Vault: $_"
        continue
    }

    # VNet & Subnetz erstellen
    try {
        Write-Host "Erstelle VNet und Subnetz für '$vmName'..."
        az network vnet create `
            --resource-group $resourceGroup `
            --name $vnetName `
            --location $location `
            --address-prefix $network `
            --subnet-name $subnetName `
            --subnet-prefix $subnetPrefix `
            --only-show-errors
    }
    catch {
        Write-Host "Fehler beim Erstellen von VNet/Subnets für '$vmName': $_"
        continue
    }

    # Öffentliche IP
    if ($createPublicIp) {
        try {
            Write-Host "Erstelle öffentliche IP für '$vmName'..."
            az network public-ip create `
                --resource-group $resourceGroup `
                --name $ipName `
                --location $location `
                --sku Standard `
                --allocation-method Static `
                --only-show-errors
        }
        catch {
            Write-Host "Fehler beim Erstellen der öffentlichen IP für '$vmName': $_"
            continue
        }
    }

    # NSG + Regel für RDP
    try {
        Write-Host "Erstelle NSG und RDP-Regel für '$vmName'..."
        az network nsg create `
            --resource-group $resourceGroup `
            --location $location `
            --name $nsgName `
            --only-show-errors

        az network nsg rule create `
            --resource-group $resourceGroup `
            --nsg-name $nsgName `
            --name allow-rdp `
            --priority 1000 `
            --destination-port-ranges $port `
            --protocol Tcp `
            --access Allow `
            --direction Inbound `
            --only-show-errors
    }
    catch {
        Write-Host "Fehler beim Erstellen von NSG/Regel für '$vmName': $_"
        continue
    }

    # Netzwerkkarte
    try {
        Write-Host "Erstelle Netzwerkkarte für '$vmName'..."
        az network nic create `
            --resource-group $resourceGroup `
            --name $nicName `
            --vnet-name $vnetName `
            --subnet $subnetName `
            --location $location `
            --network-security-group $nsgName `
            $(if ($createPublicIp) { @("--public-ip-address", $ipName) } else { @() }) `
            --only-show-errors
    }
    catch {
        Write-Host "Fehler beim Erstellen der Netzwerkkarte für '$vmName': $_"
        continue
    }

    # Spot-Parameter vorbereiten
    $spotParams = @()
    if ($spot) {
        $spotParams += @("--priority", "Spot", "--eviction-policy", "Deallocate")
    }

    # Windows-VM erstellen
    try {
        Write-Host "Erstelle VM '$vmName'..."
        az vm create `
            --resource-group $resourceGroup `
            --location $location `
            --name $vmName `
            --image $image `
            --size $vmSize `
            --admin-username $adminUser `
            --admin-password (Convert-SecureStringToPlainText $vmPassword) `
            --nics $nicName `
            --storage-sku $diskType `
            --os-disk-size-gb $disksize `
            --security-type $securitytype `
            @spotParams `
            --enable-agent true `
            --license-type Windows_Client `
            --only-show-errors
    }
    catch {
        Write-Host "Fehler beim Erstellen der VM '$vmName': $_"
        continue
    }

    # Auto-Shutdown aktivieren
    if ($shutdown) {
        try {
            Write-Host "Konfiguriere Auto-Shutdown für '$vmName'..."
            az vm auto-shutdown `
                --resource-group $resourceGroup `
                --name $vmName `
                --time 1900 `
                --location $location `
                --email "hamidullah.jalali@schule-zukunftsmotor.org" `
                --only-show-errors
        }
        catch {
            Write-Host "Fehler beim Aktivieren von Auto-Shutdown für '$vmName': $_"
        }
    }

    Write-Host "VM '$vmName' erfolgreich erstellt."
}

Write-Host "Skriptausführung abgeschlossen."