<#
.SYNOPSIS
  Retrieves access control policies defined in Prism Central (for role based access control/RBAC).
.DESCRIPTION
  Lists and exports to csv a view of roles, associated users & groups and applicable entities using the access_control_policies v3 API endpoint in Prsim Central.
.PARAMETER help
  Displays a help message (seriously, what did you think this was?)
.PARAMETER history
  Displays a release history for this script (provided the editors were smart enough to document this...)
.PARAMETER debugme
  Turns off SilentlyContinue on unexpected error messages.
.PARAMETER prismcentral
  Nutanix Prism Central fully qualified domain name or IP address.
.PARAMETER username
  Username used to connect to the Nutanix cluster.
.PARAMETER password
  Password used to connect to the Nutanix cluster.
.PARAMETER prismCreds
  Specifies a custom credentials file name (will look for %USERPROFILE\Documents\WindowsPowerShell\CustomCredentials\$prismCreds.txt). These credentials can be created using the Powershell command 'Set-CustomCredentials -credname <credentials name>'. See https://blog.kloud.com.au/2016/04/21/using-saved-credentials-securely-in-powershell-scripts/ for more details.
.EXAMPLE
.\get-accessControlPolicies.ps1 -prismcentral pc.local -username admin -password admin
Restrieve access control policies for the given Prism Central:
.LINK
  http://www.nutanix.com/services
.NOTES
  Author: Stephane Bourdeaud (sbourdeaud@nutanix.com)
  Revision: May 5th 2020
#>

#region parameters
    Param
    (
        #[parameter(valuefrompipeline = $true, mandatory = $true)] [PSObject]$myParam1,
        [parameter(mandatory = $false)] [switch]$help,
        [parameter(mandatory = $false)] [switch]$history,
        [parameter(mandatory = $false)] [switch]$log,
        [parameter(mandatory = $false)] [switch]$debugme,
        [parameter(mandatory = $true)] [string]$prismcentral,
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
05/05/2020 sb   Initial release.
################################################################################
'@
    $myvarScriptName = ".\template.ps1"

    if ($help) {get-help $myvarScriptName; exit}
    if ($History) {$HistoryText; exit}

    #check PoSH version
    if ($PSVersionTable.PSVersion.Major -lt 5) {throw "$(get-date) [ERROR] Please upgrade to Powershell v5 or above (https://www.microsoft.com/en-us/download/details.aspx?id=50395)"}

    #check if we have all the required PoSH modules
    Write-LogOutput -Category "INFO" -LogFile $myvarOutputLogFile -Message "Checking for required Powershell modules..."
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
    $api_server_port = "9440"
    $length = 200
    [System.Collections.ArrayList]$myvar_results = New-Object System.Collections.ArrayList($null)
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

    $api_server_endpoint = "/api/nutanix/v3/access_control_policies/list"
    $url = "https://{0}:{1}{2}" -f $prismcentral,$api_server_port, $api_server_endpoint
    $method = "POST"
    $kind = "access_control_policy"

    # this is used to capture the content of the payload
    $content = @{
        kind=$kind;
        offset=0;
        length=$length
    }
    $payload = (ConvertTo-Json $content -Depth 4)
    Write-Host "$(Get-Date) [INFO] Retrieving access control policies from Prism Central $($prismcentral)" -ForegroundColor Green
    Do {
        try {
            #region making the api call
                $resp = Invoke-PrismAPICall -method $method -url $url -payload $payload -credential $prismCredentials
                $listLength = 0
                if ($resp.metadata.offset) {
                    $firstItem = $resp.metadata.offset
                } else {
                    $firstItem = 0
                }
                if (($resp.metadata.length -le $length) -and ($resp.metadata.length -ne 1)) {
                    $listLength = $resp.metadata.length
                } else {
                    $listLength = $resp.metadata.total_matches
                }
                Write-Host "$(Get-Date) [INFO] Processing results from $($firstItem) to $($firstItem + $listLength) out of $($resp.metadata.total_matches)" -ForegroundColor Green
                if ($debugme) {Write-Host "$(Get-Date) [DEBUG] Response Metadata: $($resp.metadata | ConvertTo-Json)" -ForegroundColor White}
            #endregion

            #! grabbing content here
            #grab the information we need in each entity
            ForEach ($entity in $resp.entities) {

                #figure what objects the acl applies to
                [System.Collections.ArrayList]$myvar_entities = New-Object System.Collections.ArrayList($null)
                
                ForEach ($context in $entity.status.resources.filter_list.context_list) {
                    ForEach ($entity_object in $context.entity_filter_expression_list) {
                        $entity_object_property_left = $entity_object.left_hand_side.psobject.properties.name
                        $entity_object_property_right = $entity_object.right_hand_side.psobject.properties.name
                        if ($entity_object_property_left) {
                            $left = $entity_object.left_hand_side.$entity_object_property_left;
                        } else {
                            $left = $entity_object.left_hand_side
                        }
                        $myvar_entity_object = [ordered]@{
                            "left" = $left;
                            "right" = $entity_object.right_hand_side.$entity_object_property_right;
                        }
                        $myvar_entities.Add((New-Object PSObject -Property $myvar_entity_object)) | Out-Null
                        Remove-Variable entity_object_property_left -ErrorAction SilentlyContinue
                        Remove-Variable entity_object_property_right -ErrorAction SilentlyContinue
                    }
                    ForEach ($scope in $context.scope_filter_expression_list) {
                        $scope_property_left = $scope.left_hand_side.psobject.properties.name
                        $scope_property_right = $scope.right_hand_side.psobject.properties.name
                        if ($scope_property_left -ne "Length") {
                            $left = $scope.left_hand_side.$scope_property_left;
                        } else {
                            $left = $scope.left_hand_side
                        }
                        if ($left -eq "CATEGORY") {
                            $myvar_categories = @()
                            ForEach ($category_name in $scope.right_hand_side.$scope_property_right) {
                                $category_pair = $category_name.psobject.properties.name+":"+$category_name.($category_name.psobject.properties.name)
                                $myvar_categories += $category_pair
                            }
                            $right = $myvar_categories -join ";"
                        } else {
                            $right = $scope.right_hand_side.$scope_property_right
                        }
                        $myvar_scope_object = [ordered]@{
                            "left" = $left;
                            "right" = $right;
                        }
                        $myvar_entities.Add((New-Object PSObject -Property $myvar_scope_object)) | Out-Null
                        Remove-Variable entity_object_property_left -ErrorAction SilentlyContinue
                        Remove-Variable entity_object_property_right -ErrorAction SilentlyContinue
                    }
                }

                #grab other information about the acl and who it applies to
                $myvar_entity_info = [ordered]@{
                    #*about the acl
                    "access_control_list_name" = $entity.status.name;
                    "access_control_list_creation_time" = $entity.metadata.creation_time;
                    "access_control_list_last_update_time" = $entity.metadata.last_update_time;
                    "access_control_list_spec_version" = $entity.metadata.spec_version;
                    
                    #*what does it apply to
                    "entities" = ($myvar_entities | %{$_.left+":"+$_.right}) -join ",";
                    #$property = $entity.status.resources.filter_list.context_list.scope_filter_expression_list.right_hand_side.psobject.properties.name
                    #$entity.status.resources.filter_list.context_list.scope_filter_expression_list.right_hand_side.$property
                    #$entity.status.resources.filter_list.context_list.scope_filter_expression_list.left_hand_side

                    #*who does it apply to
                    "roles_name" = $entity.status.resources.role_reference.name;
                    #"roles_uuid" = $entity.spec.resources.role_reference.uuid;
                    "users" = (($entity.status.resources.user_reference_list | Select-Object -Property name).name) -join ',';
                    "groups" = (($entity.status.resources.user_group_reference_list | Select-Object -Property name).name) -join ';';
                }
                #store the results for this entity in our overall result variable
                $myvar_results.Add((New-Object PSObject -Property $myvar_entity_info)) | Out-Null
            }

            #region prepare the json payload for the next batch of entities/response
                $content = @{
                    kind=$kind;
                    offset=($resp.metadata.length + $resp.metadata.offset);
                    length=$length
                }
                $payload = (ConvertTo-Json $content -Depth 4)
            #endregion
        }
        catch {
            $saved_error = $_.Exception.Message
            # Write-Host "$(Get-Date) [INFO] Headers: $($headers | ConvertTo-Json)"
            Write-Host "$(Get-Date) [INFO] Payload: $payload" -ForegroundColor Green
            Throw "$(get-date) [ERROR] $saved_error"
        }
        finally {
            #add any last words here; this gets processed no matter what
        }
    }
    While ($resp.metadata.length -eq $length)

    if ($debugme) {
        Write-Host "$(Get-Date) [DEBUG] Showing results:" -ForegroundColor White
        $myvar_results
    }

    Write-Host "$(Get-Date) [INFO] Writing results to $(Get-Date -UFormat "%Y_%m_%d_%H_%M_")$($prismcentral)_acls.csv" -ForegroundColor Green
    $myvar_results | export-csv -NoTypeInformation $($(Get-Date -UFormat "%Y_%m_%d_%H_%M_")+$prismcentral+"_acls.csv")
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