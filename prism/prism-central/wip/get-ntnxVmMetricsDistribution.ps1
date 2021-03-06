<#
.SYNOPSIS
  Extracts data from the VM > Metrics views available in Prism Central.
.DESCRIPTION
  Extracts data from the VM > Metrics views available in Prism Central which show the distribution of VMs in terms of CPU Usage, CPU Ready Time, Memory Usage, Memory Swap, IOPS, IO Latency, IO Bandwidth, Storage Usage, Working Set Size, Network Packets Dropped and Network Bytes.
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
.PARAMETER prismCreds
  Specifies a custom credentials file name (will look for %USERPROFILE\Documents\WindowsPowerShell\CustomCredentials\$prismCreds.txt). These credentials can be created using the Powershell command 'Set-CustomCredentials -credname <credentials name>'. See https://blog.kloud.com.au/2016/04/21/using-saved-credentials-securely-in-powershell-scripts/ for more details.
.EXAMPLE
.\get-ntnxVmMetricsDistribution.ps1 -cluster ntnxc1.local -username admin -password admin
Shows distribution of VMs for various metrics:
.LINK
  http://www.nutanix.com/services
.NOTES
  Author: Stephane Bourdeaud (sbourdeaud@nutanix.com)
  Revision: July 10th 2020
#>

#region parameters
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
    [parameter(mandatory = $false)] $prismCreds
)
#endregion

#region functions

#endregion

#region prepwork
$HistoryText = @'
Maintenance Log
Date       By   Updates (newest updates at the top)
---------- ---- ---------------------------------------------------------------
07/10/2020 sb   Initial release.
################################################################################
'@
$myvarScriptName = ".\get-ntnxVmMetricsDistribution.ps1"

if ($help) {get-help $myvarScriptName; exit}
if ($History) {$HistoryText; exit}

#check PoSH version
if ($PSVersionTable.PSVersion.Major -lt 5) {throw "$(get-date) [ERROR] Please upgrade to Powershell v5 or above (https://www.microsoft.com/en-us/download/details.aspx?id=50395)"}

#check if we have all the required PoSH modules
Write-Host "$(get-date) [INFO] Checking for required Powershell modules..." -ForegroundColor Green

#region module sbourdeaud is used for facilitating Prism REST calls
$required_version = "3.0.8"
if (!(Get-Module -Name sbourdeaud)) {
    Write-Host "$(get-date) [INFO] Importing module 'sbourdeaud'..." -ForegroundColor Green
    try
    {
        Import-Module -Name sbourdeaud -MinimumVersion $required_version -ErrorAction Stop
        Write-Host "$(get-date) [SUCCESS] Imported module 'sbourdeaud'!" -ForegroundColor Cyan
    }#end try
    catch #we couldn't import the module, so let's install it
    {
        Write-Host "$(get-date) [INFO] Installing module 'sbourdeaud' from the Powershell Gallery..." -ForegroundColor Green
        try {Install-Module -Name sbourdeaud -Scope CurrentUser -Force -ErrorAction Stop}
        catch {throw "$(get-date) [ERROR] Could not install module 'sbourdeaud': $($_.Exception.Message)"}

        try
        {
            Import-Module -Name sbourdeaud -MinimumVersion $required_version -ErrorAction Stop
            Write-Host "$(get-date) [SUCCESS] Imported module 'sbourdeaud'!" -ForegroundColor Cyan
        }#end try
        catch #we couldn't import the module
        {
            Write-Host "$(get-date) [ERROR] Unable to import the module sbourdeaud.psm1 : $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "$(get-date) [WARNING] Please download and install from https://www.powershellgallery.com/packages/sbourdeaud/1.1" -ForegroundColor Yellow
            Exit
        }#end catch
    }#end catch
}#endif module sbourdeaud
$MyVarModuleVersion = Get-Module -Name sbourdeaud | Select-Object -Property Version
if (($MyVarModuleVersion.Version.Major -lt $($required_version.split('.')[0])) -or (($MyVarModuleVersion.Version.Major -eq $($required_version.split('.')[0])) -and ($MyVarModuleVersion.Version.Minor -eq $($required_version.split('.')[1])) -and ($MyVarModuleVersion.Version.Build -lt $($required_version.split('.')[2])))) {
    Write-Host "$(get-date) [INFO] Updating module 'sbourdeaud'..." -ForegroundColor Green
    Remove-Module -Name sbourdeaud -ErrorAction SilentlyContinue
    Uninstall-Module -Name sbourdeaud -ErrorAction SilentlyContinue
    try {
        Update-Module -Name sbourdeaud -Scope CurrentUser -ErrorAction Stop
        Import-Module -Name sbourdeaud -ErrorAction Stop
    }
    catch {throw "$(get-date) [ERROR] Could not update module 'sbourdeaud': $($_.Exception.Message)"}
}
#endregion
Set-PoSHSSLCerts
Set-PoshTls
#endregion

#region variables
$myvarElapsedTime = [System.Diagnostics.Stopwatch]::StartNew() #used to store script begin timestamp
#endregion

#region parameters validation
if (!$prismCreds) 
{#we are not using custom credentials, so let's ask for a username and password if they have not already been specified
    if (!$username) 
    {#if Prism username has not been specified ask for it
        $username = Read-Host "Enter the Prism username"
    } 

    if (!$password) 
    {#if password was not passed as an argument, let's prompt for it
        $PrismSecurePassword = Read-Host "Enter the Prism user $username password" -AsSecureString
    }
    else 
    {#if password was passed as an argument, let's convert the string to a secure string and flush the memory
        $PrismSecurePassword = ConvertTo-SecureString $password –asplaintext –force
        Remove-Variable password
    }
    $prismCredentials = New-Object PSCredential $username, $PrismSecurePassword
} 
else 
{ #we are using custom credentials, so let's grab the username and password from that
    try 
    {
        $prismCredentials = Get-CustomCredentials -credname $prismCreds -ErrorAction Stop
        $username = $prismCredentials.UserName
        $PrismSecurePassword = $prismCredentials.Password
    }
    catch 
    {
        $credname = Read-Host "Enter the credentials name"
        Set-CustomCredentials -credname $credname
        $prismCredentials = Get-CustomCredentials -credname $prismCreds -ErrorAction Stop
        $username = $prismCredentials.UserName
        $PrismSecurePassword = $prismCredentials.Password
    }
    $prismCredentials = New-Object PSCredential $username, $PrismSecurePassword
}
#endregion

#region processing
$url = "https://$($cluster):9440/api/nutanix/v3/search"
$method = "POST"

#region CPU Ready Time
    Write-Host "$(get-date) [INFO] Retrieving distribution of VMs in metrics for CPU Ready Time..." -ForegroundColor Green
    # this is used to capture the content of the payload
    $content = @{
        user_query='VMs "VM Type"="User VM" "CPU Ready Time"';
        explicit_query=$false;
        generate_autocompletions_only=$false;
        query_term_list= @(
            @{
                term="VMs";
                token_list= @(
                    @{
                        display_context=@{
                            entity_type="vm"
                        }
                    }
                )
            };
            @{
                term="VMs";
                token_list= @(
                    @{
                        display_context=@{
                            operator="=";
                            property_type="attribute";
                            property_name="is_cvm";
                            value="User VM";
                            entity_type="vm"
                        }
                    }
                )
            };
            @{
                term="demarcation";
                token_list= @(@{})
            };
            @{
                term='"CPU Ready Time"';
                token_list= @(
                    @{
                        display_context=@{
                            property_type="metric";
                            property_name="hypervisor.cpu_ready_time_ppm";
                            entity_type="vm"
                        };
                        match_type="exact";
                        additional_context=@(
                            @{
                                operator="=";
                                property_name="synonym";
                                value="CPU Ready Time"
                            }
                        )
                    }
                )
            }
        );
        timezone="GMT+0200"
    }
    $payload = (ConvertTo-Json $content -Depth 6)
    $distribution_cpu_ready_time = Get-PrismRESTCall -method $method -url $url -credential $prismCredentials -payload $payload
    Write-Host "$(get-date) [SUCCESS] Successfully retrieved distribution of VMs in metrics for CPU Ready Time from $cluster!" -ForegroundColor Cyan
#endregion

#endregion

#region cleanup
#let's figure out how much time this all took
Write-Host "$(get-date) [SUM] total processing time: $($myvarElapsedTime.Elapsed.ToString())" -ForegroundColor Magenta

#cleanup after ourselves and delete all custom variables
Remove-Variable myvar* -ErrorAction SilentlyContinue
Remove-Variable ErrorActionPreference -ErrorAction SilentlyContinue
Remove-Variable help -ErrorAction SilentlyContinue
Remove-Variable history -ErrorAction SilentlyContinue
Remove-Variable log -ErrorAction SilentlyContinue
Remove-Variable cluster -ErrorAction SilentlyContinue
Remove-Variable username -ErrorAction SilentlyContinue
Remove-Variable password -ErrorAction SilentlyContinue
Remove-Variable debugme -ErrorAction SilentlyContinue
#endregion