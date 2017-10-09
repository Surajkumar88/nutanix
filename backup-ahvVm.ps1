<#
.SYNOPSIS
  This script can be used to export/backup AHV vms while they are running to an external storage using a proxy VM. It can also restore vms based on backed up data.
.DESCRIPTION
  The script uses v3 and v2 REST API in Prism to snapshot running VMs and attach disks to a proxy VM. The Proxy VM must be running Linux, already have external storage attached (such as an NFS or CIFS network share) and have qemu-utils installed.  The proxy vm converts the attached disks to qcow2 images and exports the vm and AHV cluster network information to json files. It can also read from a specified location backed up data and restore them to the AHV cluster by importing each disk into the image library and re-creating the VM based on json information.
.PARAMETER help
  Displays a help message (seriously, what did you think this was?)
.PARAMETER history
  Displays a release history for this script (provided the editors were smart enough to document this...)
.PARAMETER log
  Specifies that you want the output messages to be written in a log file as well as on the screen.
.PARAMETER debugme
  Turns off SilentlyContinue on unexpected error messages.
.PARAMETER cluster
  Nutanix cluster fully qualified domain name or IP address.
.PARAMETER username
  Username used to connect to the Nutanix cluster.
.PARAMETER password
  Password used to connect to the Nutanix cluster.
.PARAMETER backupPath
  Path where you want to export VM disks and configuration files.
.PARAMETER proxy
  Name of the VM you want to use as a backup proxy for hotadd. Note that if you use a proxy, you will have to trigger backup inside that proxy manually for now.
.PARAMETER vm
  Name of the vm you want to back up/export.
.PARAMETER snapDeleteAll
  Deletes all existing snapshots for the vm specified with -vm.
.PARAMETER diskDetachAll
  Detaches all scsi disks devices (except for the scsi 0 device) from the proxy vm specified with -proxy.
.PARAMETER restore
  Restores the specified vm to the specified AHV cluster.

.EXAMPLE
.\backup-ahvVm.ps1 -cluster ntnxc1.local -username admin -password admin -vm vm2backup -proxy vmproxy -backupPath /media/backup/
Backup vm "vm2backup" using proxy "vmproxy" to /media/backup/ on cluster "ntnxc1.local"

.EXAMPLE
.\backup-ahvVm.ps1 -cluster ntnxc1.local -username admin -password admin -vm vm2backup -backupPath /media/backup/ -restore
Restore vm "vm2backup" to clusyer "ntnxc1.local" from /media/backup/

.LINK
  http://www.nutanix.com/services
.LINK
  https://github.com/sbourdeaud/nutanix
.NOTES
  Author: Stephane Bourdeaud (sbourdeaud@nutanix.com)
  Revision: Oct 3rd 2017
#>

#region parameters
######################################
##   parameters and initial setup   ##
######################################
#let's start with some command line parsing
Param
(
    #[parameter(valuefrompipeline = $true, mandatory = $true)] [PSObject]$myParam1,
    [parameter(mandatory = $false)] [switch]$help,
    [parameter(mandatory = $false)] [switch]$history,
    [parameter(mandatory = $false)] [switch]$log,
    [parameter(mandatory = $false)] [switch]$debugme,
    [parameter(mandatory = $true)] [string]$cluster,
    [parameter(mandatory = $false)] [string]$username,
    [parameter(mandatory = $false)] [string]$password,
    [parameter(mandatory = $false)] [string]$vm,
    [parameter(mandatory = $false)] [string]$proxy,
    [parameter(mandatory = $false)] [string]$backupPath,
    [parameter(mandatory = $false)] [switch]$snapDeleteAll,
    [parameter(mandatory = $false)] [switch]$diskDetachAll,
    [parameter(mandatory = $false)] [switch]$restore
)
#endregion

#region functions
########################
##   main functions   ##
########################
function detach-disks
{
<#
.SYNOPSIS
  Detaches all scsi disk devices (except for scsi 0) from the specified AHV vm.
.DESCRIPTION
  Detaches all scsi disk devices (except for scsi 0) from the specified AHV vm.
.NOTES
  Author: Stephane Bourdeaud
.PARAMETER vm
  Specifies the vm name to process.
.PARAMETER uuid
  Specifies the uuid of the vm to process.
.PARAMETER username
  Specifies the Prism username.
.PARAMETER password
  Specifies the Prism password.
.PARAMETER prism
  Specifies the Prism IP or FQDN.
.EXAMPLE
  detach-disks -username admin -password admin -prism 10.10.10.10 -vm vmproxy
#>
param
	(
		[string] 
        $username,
		
        [SecureString] 
        $password,
        
        [string] 
        $prism,

        [string] 
        $vm,

        [string] 
        $uuid
	)

    begin {}

    process 
    {

    #retrieve details about the proxy vm and its currently attached disks
    Write-Host "$(get-date) [INFO] Retrieving list of attached disks on $vm..." -ForegroundColor Green
    $url = "https://$($prism):9440/PrismGateway/services/rest/v2.0/vms/$($uuid)?include_vm_disk_config=true"
    $method = "GET"
    $vmDetails = Get-PrismRESTCall -method $method -username $username -password ([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($password))) -url $url
    Write-Host "$(get-date) [SUCCESS] Successfully retrieved list of attached disks on $vm!" -ForegroundColor Cyan
    #determine which disks need to be detached
    $diskToDetach_uuids = @()
    foreach ($disk in ($vmDetails.vm_disk_info | where {$_.disk_address.device_index -ne 0})) {
        $diskToDetach_uuids += $disk.disk_address.vmdisk_uuid
    }
    if (!$diskToDetach_uuids)
    {
        Write-Host "$(get-date) [WARN] There is no disk to detach from $vm..." -ForegroundColor Yellow
    } else {
        #detach the disks
        Write-Host "$(get-date) [INFO] Detaching disks from $vm..." -ForegroundColor Green
        $content = @{
            uuid = "$uuid"
            vm_disks = @(foreach ($disk in $diskToDetach_uuids) {
                        @{
                    disk_address = @{
                        vmdisk_uuid = "$disk"
                    }
                        }
            }
            )
        }
        $body = (ConvertTo-Json $content -Depth 4)
        $url = "https://$($cluster):9440/PrismGateway/services/rest/v2.0/vms/$($uuid)/disks/detach"
        $method = "POST"
        $diskDetachTaskUuid = Get-PrismRESTCall -method $method -username $username -password ([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($password))) -url $url -body $body

        Write-Host "$(get-date) [INFO] Checking status of the disk detach task $($diskDetachTaskUuid.task_uuid)..." -ForegroundColor Green
        Do {
            $url = "https://$($prism):9440/PrismGateway/services/rest/v2.0/tasks/$($diskDetachTaskUuid.task_uuid)"
            $method = "GET"
            $diskDetachTaskStatus = Get-PrismRESTCall -method $method -username $username -password ([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($password))) -url $url
            if ($diskDetachTaskStatus.progress_status -ne "Succeeded") {
                Write-Host "$(get-date) [WARNING] Disk detach task status is $($diskDetachTaskStatus.progress_status), waiting 5 seconds..." -ForegroundColor Yellow
                Start-Sleep -Seconds 5
            } else {
                Write-Host "$(get-date) [SUCCESS] Disk detach task status has $($diskDetachTaskStatus.progress_status)!" -ForegroundColor Cyan
            }
        } While ($diskDetachTaskStatus.progress_status -ne "Succeeded")
    }

    }

    end {}
}
#endregion

#region prepwork
# get rid of annoying error messages
if (!$debugme) {$ErrorActionPreference = "SilentlyContinue"}
#check if we need to display help and/or history
$HistoryText = @'
 Maintenance Log
 Date       By   Updates (newest updates at the top)
 ---------- ---- ---------------------------------------------------------------
 06/19/2015 sb   Initial release.
################################################################################
'@
$myvarScriptName = ".\template_prism_rest.ps1"
 
if ($help) {get-help $myvarScriptName; exit}
if ($History) {$HistoryText; exit}


#process requirements (PoSH version and modules)
    Write-Host "$(get-date) [INFO] Checking the Powershell version..." -ForegroundColor Green
    if ($PSVersionTable.PSVersion.Major -lt 5) {
        Write-Host "$(get-date) [WARNING] Powershell version is less than 5. Trying to upgrade from the web..." -ForegroundColor Yellow
        if (!$IsLinux) {
            $ChocoVersion = choco
            if (!$ChocoVersion) {
                Write-Host "$(get-date) [WARNING] Chocolatey is not installed!" -ForegroundColor Yellow
                [ValidateSet('y','n')]$ChocoInstall = Read-Host "Do you want to install the chocolatey package manager? (y/n)"
                if ($ChocoInstall -eq "y") {
                    Write-Host "$(get-date) [INFO] Downloading and running chocolatey installation script from chocolatey.org..." -ForegroundColor Green
                    iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
                    Write-Host "$(get-date) [INFO] Downloading and installing the latest Powershell version from chocolatey.org..." -ForegroundColor Green
                    choco install -y powershell
                } else {
                    Write-Host "$(get-date) [ERROR] Please upgrade to Powershell v5 or above manually (https://www.microsoft.com/en-us/download/details.aspx?id=54616)" -ForegroundColor Red
                    Exit
                }#endif choco install
            }#endif not choco
        } else {
            Write-Host "$(get-date) [ERROR] Please upgrade to Powershell v5 or above manually by running sudo apt-get upgrade powershell" -ForegroundColor Red
            Exit
        } #endif not Linux
    }#endif PoSH version
    Write-Host "$(get-date) [INFO] Checking for required Powershell modules..." -ForegroundColor Green
    if (!(Get-Module -Name sbourdeaud)) {
        Write-Host "$(get-date) [INFO] Importing module 'sbourdeaud'..." -ForegroundColor Green
        try
        {
            Import-Module -Name sbourdeaud -ErrorAction Stop
            Write-Host "$(get-date) [SUCCESS] Imported module 'sbourdeaud'!" -ForegroundColor Cyan
        }#end try
        catch #we couldn't import the module, so let's download it
        {
            Write-Host "$(get-date) [INFO] Downloading module 'sbourdeaud' from github..." -ForegroundColor Green
            if (!$IsLinux) {
                $ModulesPath = ($env:PsModulePath -split ";")[0]
                $MyModulePath = "$ModulesPath\sbourdeaud"
            } else {
                $ModulesPath = "~/.local/share/powershell/Modules"
                $MyModulePath = "$ModulesPath/bourdeaud"
            }
            New-Item -Type Container -Force -path $MyModulePath | out-null
            (New-Object net.webclient).DownloadString("https://raw.github.com/sbourdeaud/modules/master/sbourdeaud.psm1") | Out-File "$MyModulePath\sbourdeaud.psm1" -ErrorAction Continue
            (New-Object net.webclient).DownloadString("https://raw.github.com/sbourdeaud/modules/master/sbourdeaud.psd1") | Out-File "$MyModulePath\sbourdeaud.psd1" -ErrorAction Continue

            try
            {
                Import-Module -Name sbourdeaud -ErrorAction Stop
                Write-Host "$(get-date) [SUCCESS] Imported module 'sbourdeaud'!" -ForegroundColor Cyan
            }#end try
            catch #we couldn't import the module
            {
                Write-Host "$(get-date) [ERROR] Unable to import the module sbourdeaud.psm1 : $($_.Exception.Message)" -ForegroundColor Red
                Write-Host "$(get-date) [WARNING] Please download and install from https://github.com/sbourdeaud/modules" -ForegroundColor Yellow
                Exit
            }#end catch
        }#end catch
    }#endif module sbourdeaud

    #let's get ready to use the Nutanix REST API
    #Accept self signed certs
if (!$IsLinux) {
add-type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
}#endif not Linux

#endregion

#region variables
#initialize variables
	#misc variables
	$ElapsedTime = [System.Diagnostics.Stopwatch]::StartNew() #used to store script begin timestamp


    #let's deal with the password
    if (!$password) #if it was not passed as an argument, let's prompt for it
    {
        $PrismSecurePassword = Read-Host "Enter the Prism admin user password" -AsSecureString
    }
    else #if it was passed as an argument, let's convert the string to a secure string and flush the memory
    {
        $PrismSecurePassword = ConvertTo-SecureString $password –asplaintext –force
        Remove-Variable password
    }
    if (!$username) {
        $username = "admin"
    }#endif not username
#endregion

#region parameters validation
	############################################################################
	# command line arguments initialization
	############################################################################	
    if (!$diskDetachAll -and !$snapDeleteAll) {
        if (!(Test-Path $backupPath)) {
            Write-Host "$(get-date) [ERROR] The backup path $backupPath cannot be accessed." -ForegroundColor Red
            Exit
        }
        if (!$vm)
        {
            $vm = Read-Host "Enter the name of the vm to backup"
        }
    }

    if ($diskDetachAll -and !$proxy)
    {
        $proxy = Read-Host "Enter the name of the proxy vm from which disks must be detached"
    }

    if ($snapDeleteAll -and !$vm)
    {
        $vm = Read-Host "Enter the name of the vm to backup"
    }
    
#endregion

#region processing	
	################################
	##  Main execution here       ##
	################################
    
    #retrieving all AHV vm information
    Write-Host "$(get-date) [INFO] Retrieving list of VMs..." -ForegroundColor Green
    $url = "https://$($cluster):9440/PrismGateway/services/rest/v2.0/vms/"
    $method = "GET"
    $vmList = Get-PrismRESTCall -method $method -url $url -username $username -password ([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($PrismSecurePassword)))

    #figuring out the uuid for the vm and the proxy
    $vmUuid = ($vmList.entities | where {$_.name -eq $vm}).uuid
    if ($proxy) {$proxyUuid = ($vmList.entities | where {$_.name -eq $proxy}).uuid}
    
    #detach all disks from the proxy if this is what was asked
    if ($diskDetachAll) {
        detach-disks -username $username -password $PrismSecurePassword -vm $proxy -uuid $proxyUuid -prism $cluster
    #otherwise start normal processing
    } ElseIf ($restore) {
        #read vm info from json export
        #(Get-Content $backupPath/$vm.json) -replace "`0", "" | Set-Content $backupPath/$vm.json
        $vmInfo = Get-Content -Raw -Path $backupPath/$vm.json | ConvertFrom-Json
        #import disks into image library
            #foreach disk listed in vmInfo and which is scsi, find the corresponding qcow2 object in backupPath
            #check to see if the image already exists
            #do the import
            #$source = "nfs://127.0.0.1/"+$container+"/"+$myvarDiskName+".qcow2"
            #$body = @{annotation=$myvarAnnotation;image_type="disk_image";imageImportSpec=@{containerName=$container;url=$myvarSource};name=$myvarImageName}
            #check on task status and proceed to next disk
        #create vm (POST v2 /vms/)
            #check on task status
        #attach disks (POST v2 /vms/{uuid}/disks/attach)
            #check on task status
        #attach cdrom
            #check on task status
        #attach network (POST v2 /vms/{uuid}/nics/)
            #check on task status
        #remove disks from image library
            #get image uuid (GET v2 /images/)
            #delete image uuid (DELETE v2 /images/{uuid}/)
            #check on task status
    } Else {
        
        #getting info about the source vm
        Write-Host "$(get-date) [INFO] Retrieving the configuration of $vm..." -ForegroundColor Green
        $url = "https://$($cluster):9440/PrismGateway/services/rest/v2.0/vms/$($vmUuid)?include_vm_disk_config=true&include_vm_nic_config=true"
        $method = "GET"
        $vmConfig = Get-PrismRESTCall -method $method -url $url -username $username -password ([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($PrismSecurePassword)))
        Write-Host "$(get-date) [SUCCESS] Successfully retrieved the configuration of $vm..." -ForegroundColor Cyan
        
        #getting info about the cluster networks
        Write-Host "$(get-date) [INFO] Retrieving the list of networks on $cluster..." -ForegroundColor Green
        $url = "https://$($cluster):9440/PrismGateway/services/rest/v2.0/networks/"
        $method = "GET"
        $clusterNetworks = Get-PrismRESTCall -method $method -url $url -username $username -password ([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($PrismSecurePassword)))
        Write-Host "$(get-date) [SUCCESS] Successfully retrieved the configuration of $vm..." -ForegroundColor Cyan

        #saving the source vm configuration information
        Write-Host "$(get-date) [INFO] Saving $vm configuration to $($backupPath)$($vm).json..." -ForegroundColor Green
        $vmConfig | ConvertTo-Json | Out-File -FilePath "$($backupPath)$($vm).json"

        #saving the cluster networks information
        Write-Host "$(get-date) [INFO] Saving $cluster networks information to $($backupPath)$($cluster)_networks.json..." -ForegroundColor Green
        $clusterNetworks | ConvertTo-Json | Out-File -FilePath "$($backupPath)$($cluster)_networks.json"
        
        #getting identifier (required for api v3)
        #$deleteIdentifiers = Get-PrismRESTCall -method DELETE -username $username -password $password -url "https://$($cluster):9440/api/nutanix/v3/idempotence_identifiers/$($env:COMPUTERNAME)"
        if ($IsLinux) {$client_identifier = hostname} else {$client_identifier = "$env:COMPUTERNAME"}
        Write-Host "$(get-date) [INFO] Asking for snapshot id allocation for $($client_identifier)..." -ForegroundColor Green
        $content = @{
                client_identifier = "$($client_identifier)"
                count = 1
            }
        $body = (ConvertTo-Json $content)
        $url = "https://$($cluster):9440/api/nutanix/v3/idempotence_identifiers"
        $method = "POST"
        $snapshotAllocatedId = Get-PrismRESTCall -method $method -username $username -password ([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($PrismSecurePassword))) -url $url -body $body
        Write-Host "$(get-date) [SUCCESS] Successfully obtained a snapshot id allocation!" -ForegroundColor Cyan

        #figure out if we are just deleting all snapshots
        if ($snapDeleteAll) {
            Write-Host "$(get-date) [INFO] Deleting all snapshots for vm $vm..." -ForegroundColor Green
            $content =@{
                filter = "entity_uuid==$vmUuid"
                kind = "vm_snapshot"
            }
            $body = (ConvertTo-Json $content)
            $url = "https://$($cluster):9440/api/nutanix/v3/vm_snapshots/list"
            $method = "POST"
            Write-Host "$(get-date) [INFO] Retrieving snapshot list..." -ForegroundColor Green
            $backupSnapshots = Get-PrismRESTCall -method $method -username $username -password ([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($PrismSecurePassword))) -url $url -body $body
            Write-Host "$(get-date) [SUCCESS] Successfully retrieved the snapshot list..." -ForegroundColor Cyan
            
            ForEach ($snapshot in $backupSnapshots.entities) {
                Write-Host "$(get-date) [INFO] Deleting snapshot $($snapshot.metadata.uuid)..." -ForegroundColor Green
                $url = "https://$($cluster):9440/api/nutanix/v3/vm_snapshots/$($snapshot.metadata.uuid)"
                $method = "DELETE"
                Get-PrismRESTCall -method $method -username $username -password ([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($PrismSecurePassword))) -url $url                
                Write-Host "$(get-date) [SUCCESS] Successfully deleted snapshot $($snapshot.metadata.uuid)!" -ForegroundColor Cyan
            }

        #otherwise continue with normal processing
        } else {
            #snapshot the vm                                                                                                                                                            #region creating a snapshot
            Write-Host "$(get-date) [INFO] Creating a crash consistent snapshot of vm $vm..." -ForegroundColor Green
            $snapshotName = "backup.snapshot.$(Get-Date -UFormat "%Y_%m_%d_%H_%M_")$vm"
            $content = @{
                    spec = @{
                        resources = @{
                            entity_uuid = "$vmUuid"
                        }
                        snapshot_type = "CRASH_CONSISTENT"
                        name = $snapshotName
                    }
                    api_version = "3.0"
                    metadata = @{
                        kind = "vm_snapshot"
                        uuid = $snapshotAllocatedId.uuid_list[0]
                    }
                }
            $body = (ConvertTo-Json $content)
            $url = "https://$($cluster):9440/api/nutanix/v3/vm_snapshots"
            $method = "POST"
            $snapshotTask = Get-PrismRESTCall -method $method -username $username -password ([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($PrismSecurePassword))) -url $url -body $body
            Write-Host "$(get-date) [INFO] Retrieving status of snapshot $snapshotName ..." -ForegroundColor Green
            Do {
                $url = "https://$($cluster):9440/api/nutanix/v3/vm_snapshots/$($snapshotAllocatedId.uuid_list[0])"
                $method = "GET"
                $snapshotStatus = Get-PrismRESTCall -method $method -username $username -password ([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($PrismSecurePassword))) -url $url
                if ($snapshotStatus.status.state -eq "kError") {
                    Write-Host "$(get-date) [ERROR] $($snapshotStatus.status.message_list.message)" -ForegroundColor Red
                    Exit
                } elseIf ($snapshotStatus.status.state -eq "COMPLETE") {
                    Write-Host "$(get-date) [SUCCESS] $snapshotName status is $($snapshotStatus.status.state)!" -ForegroundColor Cyan
                } else {
                    Write-Host "$(get-date) [WARNING] $snapshotName status is $($snapshotStatus.status.state), waiting 5 seconds..." -ForegroundColor Yellow
                    Start-Sleep -Seconds 5
                }
            } While ($snapshotStatus.status.state -ne "COMPLETE")

            #process with a proxy
            if ($proxy) {
                Write-Host "$(get-date) [INFO] Mounting the $vm snapshots on $proxy..." -ForegroundColor Green
                #$snapshotFilePath = $snapshotStatus.status.snapshot_file_list.snapshot_file_path
                #building our reference variable to map disks/snapshots/scsi_index
                [System.Collections.ArrayList]$diskToAttachRefArray = New-Object System.Collections.ArrayList($null)
                foreach ($snapshotFile in $snapshotStatus.status.snapshot_file_list) {
                    foreach ($disk in ($vmConfig.vm_disk_info | where {$_.is_cdrom -eq $false})) {
                        if ($snapshotFile.file_path -like "*$($disk.disk_address.vmdisk_uuid)") {
                            $diskToAttachRef = @{"source_device_bus"=$disk.disk_address.device_bus;"source_device_index"=$disk.disk_address.device_index;"source_vmdisk_uuid"=$disk.disk_address.vmdisk_uuid;"snapshot_file_path"=$snapshotFile.snapshot_file_path}
                            $diskToAttachRefArray.Add((New-Object PSObject -Property $diskToAttachRef)) | Out-Null
                        }
                    }
                }
                
                #attaching disks in order of scsi device index
                $content = @{
                    uuid = "$proxyUuid"
                    vm_disks = @(foreach ($disk in ($diskToAttachRefArray | Sort-Object -Property source_device_index)) {
                                @{
                        vm_disk_clone = @{
                            disk_address = @{
                                device_bus = "SCSI"
                                ndfs_filepath = "$($disk.snapshot_file_path)"
                            }
                        }
                                }
                    }
                    )
                }
                $body = (ConvertTo-Json $content -Depth 4)
                $url = "https://$($cluster):9440/PrismGateway/services/rest/v2.0/vms/$($proxyUuid)/disks/attach"
                $method = "POST"
                $diskAttachTaskUuid = Get-PrismRESTCall -method $method -username $username -password ([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($PrismSecurePassword))) -url $url -body $body

                Write-Host "$(get-date) [INFO] Checking status of the disk attach task $($diskAttachTaskUuid.task_uuid)..." -ForegroundColor Green
                Do {
                    $url = "https://$($cluster):9440/PrismGateway/services/rest/v2.0/tasks/$($diskAttachTaskUuid.task_uuid)"
                    $method = "GET"
                    $diskAttachTaskStatus = Get-PrismRESTCall -method $method -username $username -password ([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($PrismSecurePassword))) -url $url
                    if ($diskAttachTaskStatus.progress_status -ne "Succeeded") {
                        Write-Host "$(get-date) [WARNING] Disk attach task status is $($diskAttachTaskStatus.progress_status), waiting 5 seconds..." -ForegroundColor Yellow
                        Start-Sleep -Seconds 5
                    } else {
                        Write-Host "$(get-date) [SUCCESS] Disk attach task status has $($diskAttachTaskStatus.progress_status)!" -ForegroundColor Cyan
                    }
                } While ($diskAttachTaskStatus.progress_status -ne "Succeeded")
                
                if ($IsLinux) {
                    if ($(hostname) -ne $proxy) {
                        Write-Host "$(get-date) [ERROR] $(hostname) is not the backup proxy $proxy. You must run this script on the proxy vm!" -ForegroundColor Red
                    } else {
                        #retrieve details about the proxy vm and its currently attached disks
                        Write-Host "$(get-date) [INFO] Retrieving list of attached disks on $proxy..." -ForegroundColor Green
                        $url = "https://$($cluster):9440/PrismGateway/services/rest/v2.0/vms/$($proxyUuid)?include_vm_disk_config=true"
                        $method = "GET"
                        $proxyVmDetails = Get-PrismRESTCall -method $method -username $username -password ([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($PrismSecurePassword))) -url $url
                        Write-Host "$(get-date) [SUCCESS] Successfully retrieved list of attached disks on $proxy!" -ForegroundColor Cyan
                        $proxyVmDisksAttached = $proxyVmDetails.vm_disk_info | where {$_.disk_address.device_index -ne 0}

                        Write-Host "$(get-date) [INFO] Starting backup tasks..." -ForegroundColor Green
                        #getting Linux disk device information
                        $disks = sudo parted -l | Select-String "Disk /dev/sd*" -Context 1,0
                        $diskinfo = @()
                        foreach ($disk in $disks) {
                            $diskline1 = $disk.ToString().Split("`n")[0].ToString().Replace('  Model: ','')
                            $diskline2 = $disk.ToString().Split("`n")[1].ToString().Replace('> Disk ','')
                            $i = New-Object psobject -Property @{'Friendly Name' = $diskline1; Device=$diskline2.Split(': ')[0]; 'Total Size'=$diskline2.Split(':')[1]}
                            $diskinfo += $i
                        }
                        
                        $devicesToBackup = $diskinfo | where {$_.Device -ne "/dev/sda"} | select -Property Device | Sort-Object -Property Device

                        if ($proxyVmDisksAttached.Count -ne $devicesToBackup.Count) {
                            Write-Host "$(get-date) [WARNING] The number of attached disks does not match the number of visible devices in-guest!" -ForegroundColor Yellow
                        }

                        $indexCounter = 0
                        ForEach ($device in $devicesToBackup) {
                            Write-Host "$(get-date) [INFO] Backing up $($device.device) to $backupPath$($vm+"_"+$diskToAttachRefArray[$indexCounter].source_device_bus+"_"+$diskToAttachRefArray[$indexCounter].source_device_index+"_"+$diskToAttachRefArray[$indexCounter].source_vmdisk_uuid)" -ForegroundColor Green
                            sudo qemu-img convert -p -f raw -O qcow2 $($device.device) $backupPath$($vm+"_"+$diskToAttachRefArray[$indexCounter].source_device_bus+"_"+$diskToAttachRefArray[$indexCounter].source_device_index+"_"+$diskToAttachRefArray[$indexCounter].source_vmdisk_uuid)
                            ++$indexCounter
                        }
                        
                        if (!$devicesToBackup) {
                            Write-Host "$(get-date) [WARNING] There is no disk device to backup!" -ForegroundColor Green
                        } else {
                            
                        }
                                            
                        #process each disk
                        foreach ($disk in ($proxyVmDetails.vm_disk_info | where {$_.disk_address.device_index -ne 0})) {
                            #map disk scsi to device name in-guest
                        }
                    }
                } else {
                    if ($env:COMPUTERNAME -ne $proxy) 
                    {
                        Write-Host "$(get-date) [ERROR] $($env:COMPUTERNAME) is not the backup proxy $proxy. You must run this script on the proxy vm!" -ForegroundColor Red
                    } else {
                        Write-Host "$(get-date) [ERROR] $($env:COMPUTERNAME) is not running Linux: proxy operations are only possible on a Linux vm for now." -ForegroundColor Red
                    }
                    foreach ($disk in ($diskToAttachRefArray | sort -Property source_device_index)) {
                        Write-Host "$(get-date) [INFO] I would have otherwise backed up $($vm+"_"+$disk.source_device_bus+"_"+$disk.source_device_index+"_"+$disk.source_vmdisk_uuid)" -ForegroundColor DarkGreen
                    }
                }

                detach-disks -username $username -password $PrismSecurePassword -vm $proxy -uuid $proxyUuid -prism $cluster
                
            }#endif proxy

            #process without a proxy
            if (!$proxy) {
                #region restore disks
                #we only waant to restore disk objects from the snapshot, so let's examine the snapshot and determine which objects are attached disks
                ForEach ($file in $snapshotStatus.status.snapshot_file_list) {
                    #create a volume group cloning the disk
                }#end foreach file in snapshot
                #now restore those objects on the container in the restore folder
                #endregion
                #region copy data
                #for each restored disk, copy the data to the backup path
                #endregion
                #region delete restored disks
                #delete each restored disk in the restore folder from the container
                #endregion
            }#endif not proxy
        
        #now that we are done processing, delete the vm snapshot we created earlier
        Write-Host "$(get-date) [INFO] Deleting snapshot $snapshotName..." -ForegroundColor Green
        $url = "https://$($cluster):9440/api/nutanix/v3/vm_snapshots/$($snapshotAllocatedId.uuid_list[0])"
        $method = "DELETE"
        $snapshotDeletionStatus = Get-PrismRESTCall -method $method -username $username -password ([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($PrismSecurePassword))) -url $url
        Write-Host "$(get-date) [SUCCESS] Successfully deleted snapshot $snapshotName!" -ForegroundColor Cyan

        #and release the snapshot identifiers we previously requested
        Write-Host "$(get-date) [INFO] Deleting snapshot identifiers for $($client_identifier)..." -ForegroundColor Green
        $url = "https://$($cluster):9440/api/nutanix/v3/idempotence_identifiers/$($client_identifier)"
        $method = "DELETE"
        $deleteIdentifiers = Get-PrismRESTCall -method $method -username $username -password ([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($PrismSecurePassword))) -url $url
        Write-Host "$(get-date) [SUCCESS] Successfully deleted snapshot identifiers for $($client_identifier)!" -ForegroundColor Cyan

        }
    }#endif else diskDetachAll
#endregion

#region cleanup
#########################
##       cleanup       ##
#########################

	#let's figure out how much time this all took
    Write-Host "$(get-date) [SUM] total processing time: $($ElapsedTime.Elapsed.ToString())" -ForegroundColor Magenta
	
#endregion