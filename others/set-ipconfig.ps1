<#
.SYNOPSIS
  This script is used to deal with IP changes in DR scenarios.  It saves static IP configuration (ipconfig.csv and previous_ipconfig.csv), allows for alternative DR IP configuration (dr_ipconfig.csv) and reconfigures an active interface accordingly. The script only works with 2 DNS servers (no suffix or search list). Each configuration file is appended with a numerical index starting at 1 to indicate the number of the interface (sorted using the ifIndex parameter).
.DESCRIPTION
  This script is meant to be run at startup of a Windows machine, at which point it will list all active network interfaces (meaning they are connected).  If it finds no active interface, it will display an error and exit, otherwise it will continue.  If the active interface is using DHCP, it will see if there is a previously saved configuration and what was the last previous state (if any).  If there is a config file and the previous IP state is the same, if there is a DR config, it will apply it, otherwise it will reapply the static config. If the IP is static and there is no previously saved config, it will save the configuration.  It records the status every time it runs so that it can detect regular static to DR changes.  A change is triggered everytime the interface is in DHCP, and there is a saved config.  If the active interface is already using a static IP address and there is a dr_ipconfig.csv file, the script will try to ping the default gateway and apply the dr_ipconfig if it does NOT ping. If the gateway still does not ping, it will revert back to the standard ipconfig.
.PARAMETER help
  Displays a help message (seriously, what did you think this was?)
.PARAMETER history
  Displays a release history for this script (provided the editors were smart enough to document this...)
.PARAMETER log
  Specifies the path where you want log files to ne kept.
.PARAMETER debugme
  Turns off SilentlyContinue on unexpected error messages.
.PARAMETER path
  Specify the path where you want config files and last state to be saved.  By default, this is in c:\
.PARAMETER dhcp
  Use this switch if you want to configure one or more interfaces with dhcp
.PARAMETER interface
  Specify the interface you want to configure with -dhcp using an index number.  Use 1 for the first interface, 2 for the second, etc... or all for all interfaces.
.PARAMETER setprod
  Apply the production ip configuration (in ipconfig.csv) to the specified interface (use with -interface).
.PARAMETER setdr
  Apply the DR ip configuration (in dr_ipconfig.csv) to the specified interface (use with -interface).
.PARAMETER fcs
  Indicates this is a Microsoft Failover Cluster and that you want to reconfigure cluster resources.  You should have a fcs_prod.csv file and a fcs_dr.csv file which contains: resource_name,resource_value,resource_network,resource_subnet_mask. It will check if it owns those resources and if it does, it will update the specified resources with the specified IP and then bring the resource group online.
  Note that the script assumes the production interface has a lower interface index than the heartbeat adapter (which can be checked with Get-NetAdapter).
  In case of a restore of the IP configuration, the cluster IP configuration does not get reset (and may therefore require manual fixing).  This parameter only works with Windows Server 2019, and assumes the PowerShell cmdlets for managing failover clusters have been installed on all nodes (Add-WindowsFeature RSAT-Clustering-PowerShell).
  Failure to reconfigure the cluster resources only prints errors but does not interrupt the script.
.PARAMETER sleep
  Wait time in seconds after interfaces are updated (default is 10 seconds).
.EXAMPLE
.\set-ipconfig.ps1 -path c:\windows\
Simply run the script and save to c:\windows
.EXAMPLE
.\set-ipconfig.ps1 -path c:\scripts\ -setprod -interface all -sleep 5
Apply the production IPv4 configuration to all interfaces. Wait only 5 seconds after updating each interface.
.EXAMPLE
.\set-ipconfig.ps1 -path c:\scripts\ -sleep 15 -fcs
Examine the IPv4 configuration.  If needed, change it from production to dr (based on ability to ping the gateway). Also process Failover Cluster resources. Wait 15 seconds after each NIC update.
.LINK
  http://www.nutanix.com/services
.NOTES
  Author: Stephane Bourdeaud (sbourdeaud@nutanix.com)
  Revision: February 1st 2021
#>

#region Parameters
	Param
	(
		#[parameter(valuefrompipeline = $true, mandatory = $true)] [PSObject]$myParam1,
		[parameter(mandatory = $false)] [switch]$help,
		[parameter(mandatory = $false)] [switch]$history,
		[parameter(mandatory = $false)] [string]$log,
		[parameter(mandatory = $false)] [switch]$debugme,
		[parameter(mandatory = $false)] [string]$path,
		[parameter(mandatory = $false)] [switch]$dhcp,
		[parameter(mandatory = $false)] [string]$interface,
		[parameter(mandatory = $false)] [switch]$setprod,
		[parameter(mandatory = $false)] [switch]$setdr,
		[parameter(mandatory = $false)] [switch]$fcs,
		[parameter(mandatory = $false)] [int]$sleep
	)
#endregion

#region Functions

	#this function is used to output log data
	Function Write-LogOutput
		{
		<#
		.SYNOPSIS
		Outputs color coded messages to the screen and/or log file based on the category.

		.DESCRIPTION
		This function is used to produce screen and log output which is categorized, time stamped and color coded.

		.PARAMETER Category
		This the category of message being outputed. If you want color coding, use either "INFO", "WARNING", "ERROR" or "SUM".

		.PARAMETER Message
		This is the actual message you want to display.

		.PARAMETER LogFile
		If you want to log output to a file as well, use logfile to pass the log file full path name.

		.NOTES
		Author: Stephane Bourdeaud (sbourdeaud@nutanix.com)

		.EXAMPLE
		.\Write-LogOutput -LogFile $myvarOutputLogFile -category "ERROR" -message "You must be kidding!"
		Displays an error message.

		.LINK
		https://github.com/sbourdeaud
		#>
			[CmdletBinding(DefaultParameterSetName = 'None')] #make this function advanced

			param
			(
				[Parameter(Mandatory)]
				[ValidateSet('INFO','WARNING','ERROR','SUM','SUCCESS','STEP','DEBUG')]
				[string]
				$Category,

				[string]
				$Message,

				[string]
				$LogFile
			)

			process
			{
				$Date = get-date #getting the date so we can timestamp the output entry
				$FgColor = "Gray" #resetting the foreground/text color
				switch ($Category) #we'll change the text color depending on the selected category
				{
					"INFO" {$FgColor = "Green"}
					"WARNING" {$FgColor = "Yellow"}
					"ERROR" {$FgColor = "Red"}
					"SUM" {$FgColor = "Magenta"}
					"SUCCESS" {$FgColor = "Cyan"}
					"STEP" {$FgColor = "Magenta"}
					"DEBUG" {$FgColor = "White"}
				}

				Write-Host -ForegroundColor $FgColor "$Date [$category] $Message" #write the entry on the screen
				if ($LogFile) #add the entry to the log file if -LogFile has been specified
				{
					Add-Content -Path $LogFile -Value "$Date [$Category] $Message"
					Write-Verbose -Message "Wrote entry to log file $LogFile" #specifying that we have written to the log file if -verbose has been specified
				}
			}

		}#end function Write-LogOutput -LogFile $myvarOutputLogFile
	
	#this function is used to process cluster resources
	Function ProcessClusterResource
	{
		param 
		(
			[Parameter(Mandatory)]
			[String]
			$resource_name,
			[String]
			$resource_value,
			[String]
			$resource_network,
			[String]
			$resource_subnet_mask
		)
		begin
		{
			if ($resource_value -and (!($resource_network) -or !($resource_subnet_mask)))
			{
				Write-LogOutput -LogFile $myvarOutputLogFile -Category "ERROR" -Message "You must specifiy the cluster resource network and subnet mask when you specify a cluster resource value..."
				Exit
			}
		}
		process
		{
			try 
			{#get the cluster resource
				Write-LogOutput -LogFile $myvarOutputLogFile -Category "INFO" -Message "Getting the cluster resource $($resource_name)..."
				$myvar_cluster_resource = Get-ClusterResource $resource_name -ErrorAction Stop
				$myvar_resource_group = ($myvar_cluster_resource.OwnerGroup).Name
				if ($myvar_cluster_resource.OwnerNode.Name -eq [System.Net.Dns]::GetHostName())
				{#owner node is our current host
					if ($myvar_cluster_resource.State -ne "Online")
					{#resource is not online
						if ($resource_value)
						{#a resource value was specified that needs to be udpated
							try 
							{#update the resource value
								Write-LogOutput -LogFile $myvarOutputLogFile -Category "INFO" -Message "Updating the cluster resource $($resource_name) with value $($resource_value)..."
								$result = $myvar_cluster_resource | Set-ClusterParameter -multiple @{"network"="$((Get-ClusterNetwork | where {$_.ipv4addresses -like $resource_network}).name)";"Address"="$($resource_value)";"SubnetMask"="$($resource_subnet_mask)";"EnableDHCP"=0} -ErrorAction Stop
							}
							catch 
							{#we could not update the resource value
								Write-LogOutput -LogFile $myvarOutputLogFile -Category "ERROR" -Message "Could not update the cluster resource $($resource_name) with the value $($resource_value) : $($_.Exception.Message)"
							}
						}
						else 
						{
							Write-LogOutput -LogFile $myvarOutputLogFile -Category "WARNING" -Message "The cluster resource $($resource_name) has no value specified so we will only try to bring it online..."	
						}
						Write-LogOutput -LogFile $myvarOutputLogFile -Category "INFO" -message "Waiting $($sleep) seconds for interfaces to update..."
						Start-Sleep $sleep
						try 
						{#bring the resource group online
							Write-LogOutput -LogFile $myvarOutputLogFile -Category "INFO" -Message "Bringing the cluster resource group $($myvar_resource_group) online..."
							$result = Start-ClusterGroup -Name $myvar_resource_group -ErrorAction Stop
							Write-LogOutput -LogFile $myvarOutputLogFile -Category "INFO" -Message "Registering network name resources for the cluster resource group $($myvar_resource_group)..."
							$result = Get-ClusterGroup -Name $myvar_resource_group | Get-ClusterResource | where {$_.ResourceType -eq "Network Name"} | Update-ClusterNetworkNameResource -ErrorAction Stop
						}
						catch 
						{#we could not bring the resource online
							Write-LogOutput -LogFile $myvarOutputLogFile -Category "ERROR" -Message "Could not bring the cluster resource group $($myvar_resource_group) online : $($_.Exception.Message)"
						}
					}
					else 
					{#resource is online already
						Write-LogOutput -LogFile $myvarOutputLogFile -Category "INFO" -Message "The cluster resource $($resource_name) is already online, skipping..."
					}
				}
				else 
				{#we do not own the resource
					Write-LogOutput -LogFile $myvarOutputLogFile -Category "WARNING" -Message "Current node does not own this resource, skipping..."
				}
			}
			catch 
			{#we could not get the cluster resource
				Write-LogOutput -LogFile $myvarOutputLogFile -Category "ERROR" -Message "Could not get the cluster resource $($resource_name) : $($_.Exception.Message)"
			}
		}
		end
		{}
	}

	#this function is used to retrieve the IPv4 config of a given network interface
	Function getIPv4 
	{
		#input: interface
		#output: ipv4 configuration
	<#
	.SYNOPSIS
	Retrieves the IPv4 configuration of a given Windows interface.
	.DESCRIPTION
	Retrieves the IPv4 configuration of a given Windows interface.
	.NOTES
	Author: Stephane Bourdeaud
	.PARAMETER interface
	A Windows network interface.
	.EXAMPLE
	PS> getIPv4 -interface Ethernet
	#>
		param 
		(
			[string] $NetworkInterface
		)

		begin
		{
			$myvarIPv4Configuration = "" | Select-Object -Property InterfaceIndex,InterfaceAlias,IPv4Address,PrefixLength,PrefixOrigin,IPv4DefaultGateway,DNSServer
		}

		process
		{
			Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Getting IPv4 information for the active network interface $NetworkInterface ..."
			try
			{#get ip address
				$myvarActiveNetAdapterIP = Get-NetIPAddress -InterfaceAlias $NetworkInterface -ErrorAction Stop | Where-Object {$_.AddressFamily -eq "IPv4"}
			}
			catch
			{#couldn't get ip address
				Write-LogOutput -LogFile $myvarOutputLogFile -Category "ERROR" -Message "Could not get IPv4 information for $NetworkInterface : $($_.Exception.Message)"
				Exit
			}

			try 
			{#get rest of ip config
				$myvarActiveIPConfiguration = Get-NetIPConfiguration -InterfaceAlias $NetworkInterface -ErrorAction Stop	
			}
			catch
			{#couldn't get rest of ip config
				Write-LogOutput -LogFile $myvarOutputLogFile -Category "ERROR" -Message "Could not get IPv4 information for $NetworkInterface : $($_.Exception.Message)"
				Exit
			}
			
			#save the stuff we got
			$myvarIPv4Configuration.InterfaceIndex = $myvarActiveNetAdapterIP.InterfaceIndex
			$myvarIPv4Configuration.InterfaceAlias = $myvarActiveNetAdapterIP.InterfaceAlias
			$myvarIPv4Configuration.IPv4Address = $myvarActiveIPConfiguration.IPv4Address
			$myvarIPv4Configuration.$NetSubnetProperty = $myvarActiveNetAdapterIP.$NetSubnetProperty
			$myvarIPv4Configuration.PrefixOrigin = $myvarActiveNetAdapterIP.PrefixOrigin
			$myvarIPv4Configuration.IPv4DefaultGateway = $myvarActiveIPConfiguration.IPv4DefaultGateway
			$myvarIPv4Configuration.DNSServer = $myvarActiveIPConfiguration.DNSServer
		}

		end
		{
		return $myvarIPv4Configuration
		}
	}#end function getIPv4

	#this function is used to retrieve the IPv4 config of a given network interface
	Function getIPv4_wmi 
	{
		#input: interface
		#output: ipv4 configuration
	<#
	.SYNOPSIS
	Retrieves the IPv4 configuration of a given Windows interface using WMI.
	.DESCRIPTION
	Retrieves the IPv4 configuration of a given Windows interface using WMI.
	.NOTES
	Author: Stephane Bourdeaud
	.PARAMETER interface
	A Windows network interface WMI object.
	.EXAMPLE
	PS> getIPv4 -interface Ethernet
	#>
		param 
		(
			[string] $NetworkInterface
		)

		begin
		{
			$myvarIPv4Configuration = "" | Select-Object -Property InterfaceIndex,InterfaceAlias,IPv4Address,IPSubnet,IPv4DefaultGateway,DNSServer
		}

		process
		{	
			$NetworkInterface_WmiObject = Get-WmiObject -Class Win32_NetworkAdapterConfiguration -Filter IPEnabled=TRUE -ComputerName . | Where-Object {$_.Description -eq $NetworkInterface}
			#save the stuff we got
			$myvarIPv4Configuration.InterfaceIndex = $NetworkInterface_WmiObject.InterfaceIndex
			$myvarIPv4Configuration.InterfaceAlias = $NetworkInterface_WmiObject.Description
			$myvarIPv4Configuration.IPv4Address = $NetworkInterface_WmiObject.IPAddress[0]
			$myvarIPv4Configuration.IPSubnet = $NetworkInterface_WmiObject.IPSubnet[0]
			$myvarIPv4Configuration.IPv4DefaultGateway = $NetworkInterface_WmiObject.DefaultIPGateway[0]
			$myvarIPv4Configuration.DNSServer = $NetworkInterface_WmiObject.DNSServerSearchOrder
		}

		end
		{
		return $myvarIPv4Configuration
		}
	}#end function getIPv4_wmi


	#this function is used to test a given IP address
	Function TestDefaultGw 
	{
		#input: ip
		#output: boolean
	<#
	.SYNOPSIS
	Tries to ping the IP address provided and returns true or false.
	.DESCRIPTION
	Tries to ping the IP address provided and returns true or false.
	.NOTES
	Author: Stephane Bourdeaud
	.PARAMETER ip
	An IP address to test.
	.EXAMPLE
	PS> TestDefaultGw -ip 10.10.1.1
	#>
		param 
		(
			[string] $ip
		)

		begin
		{
			
		}

		process
		{
			Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Trying to ping IP $ip ..."
			#$Timeout = 100
			#$Ping = New-Object System.Net.NetworkInformation.Ping
			#$Response = $Ping.Send($ip,$Timeout)
			#if (($Response.Status -eq "Success"))
			try 
			{
				$myvar_ping_output = Test-Connection $ip -Count 5 -ErrorAction Stop
				$myvarPingTest = $true
				Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Successfully pinged IP $ip ..."
			}
			catch 
			{
				$myvarPingTest = $false
				Write-LogOutput -LogFile $myvarOutputLogFile -category "ERROR" -message "Could not ping IP $ip ..."
			} 
		}

		end
		{
		return $myvarPingTest
		}
	}#end function TestDefaultGw

	#this function is used to test a given IP address
	Function ApplyProductionIPConfig 
	{
		#input: none
		#output: none
	<#
	.SYNOPSIS
	Applies the production IP configuration.
	.DESCRIPTION
	Applies the production IP configuration.
	.NOTES
	Author: Stephane Bourdeaud
	#>
		param 
		(
			
		)

		begin
		{
			
		}

		process
		{
			Write-LogOutput -LogFile $myvarOutputLogFile -category "WARNING" -message "Applying the production IP address to $($myvarNetAdapter.$NetDescriptor)..."
			#apply PROD
			$result = Remove-NetRoute -InterfaceAlias $myvarNetAdapter.$NetDescriptor -Confirm:$false -ErrorAction SilentlyContinue
			$result = Remove-NetIPAddress -InterfaceAlias $myvarNetAdapter.$NetDescriptor -AddressFamily IPv4 -ErrorAction SilentlyContinue -Confirm:$false
			if ($myvarSavedIPConfig.IPv4DefaultGateway) 
			{#this interface has a default gateway
				try 
				{#set ip address
					$result = New-NetIPAddress -InterfaceAlias $myvarNetAdapter.$NetDescriptor -AddressFamily IPv4 -IPAddress $myvarSavedIPConfig.IPAddress -PrefixLength $myvarSavedIPConfig.$NetSubnetProperty -DefaultGateway $myvarSavedIPConfig.IPv4DefaultGateway -ErrorAction Stop	
				}
				catch
				{#couldn't set ip address
					Write-LogOutput -LogFile $myvarOutputLogFile -Category "ERROR" -Message "Could not set IPv4 address for $($myvarNetAdapter.$NetDescriptor) : $($_.Exception.Message)"
					Exit
				}
			}#end if default gw
			else 
			{#this interface has no default gateway
				try 
				{#set ip address
					$result = New-NetIPAddress -InterfaceAlias $myvarNetAdapter.$NetDescriptor -AddressFamily IPv4 -IPAddress $myvarSavedIPConfig.IPAddress -PrefixLength $myvarSavedIPConfig.$NetSubnetProperty -ErrorAction Stop
				}
				catch
				{#couldn't set ip address
					Write-LogOutput -LogFile $myvarOutputLogFile -Category "ERROR" -Message "Could not set IPv4 address for $($myvarNetAdapter.$NetDescriptor) : $($_.Exception.Message)"
					Exit
				}
			}#end else default gw
			try
			{#setting dns
				$result = Set-DnsClientServerAddress -InterfaceAlias $myvarNetAdapter.$NetDescriptor -ServerAddresses ($myvarSavedIPConfig.PrimaryDNSServer, $myvarSavedIPConfig.SecondaryDNSServer) -ErrorAction Stop
			}
			catch
			{#couldn't set dns
				Write-LogOutput -LogFile $myvarOutputLogFile -Category "ERROR" -Message "Could not set DNS for $($myvarNetAdapter.$NetDescriptor) : $($_.Exception.Message)"
				Exit
			}

			Write-LogOutput -LogFile $myvarOutputLogFile -Category "INFO" -message "Waiting $($sleep) seconds for interfaces to update..."
			Start-Sleep $sleep #adding a delay here as in some environments the network card is not immediately available after applying changes
			Write-LogOutput -LogFile $myvarOutputLogFile -Category "INFO" -message "Registering with DNS..."
			Register-DnsClient

			#todo: add -fcs processing here
			if ($fcs)
			{#we're on a failover cluster
				if ($myvarSavedIPConfig.IPv4DefaultGateway) 
				{#this is the production interface (it has a gateway)
					Foreach ($myvar_resource in $myvar_fcs_prod)
					{#process each cluster resource specified in the fcs_prod.csv file
						ProcessClusterResource -resource_name $myvar_resource.resource_name -resource_value $myvar_resource.resource_value -resource_network $myvar_resource.resource_network -resource_subnet_mask $myvar_resource.resource_subnet_mask
					}
				}
			}
		}

		end
		{
		
		}
	}#end function ApplyProductionIpConfig

	#this function is used to test a given IP address
	Function ApplyProductionIPConfig_wmi 
	{
		#input: none
		#output: none
	<#
	.SYNOPSIS
	Applies the production IP configuration using WMI.
	.DESCRIPTION
	Applies the production IP configuration using WMI.
	.NOTES
	Author: Stephane Bourdeaud
	#>
		param 
		(
			
		)

		begin
		{
			
		}

		process
		{
			Write-LogOutput -LogFile $myvarOutputLogFile -category "WARNING" -message "Applying the production IP address to $($myvarNetAdapter.Description)..."
			#apply PROD
			$ip = ($myvarSavedIPConfig.IPAddress) 
			$gateway = $myvarSavedIPConfig.IPv4DefaultGateway 
			$subnet = $myvarSavedIPConfig.IPSubnet 
			$dns = ($myvarSavedIPConfig.PrimaryDNSServer, $myvarSavedIPConfig.SecondaryDNSServer) 
			$result = $myvarNetAdapter.EnableStatic($ip, $subnet) 
			$result = $myvarNetAdapter.SetGateways($gateway) 
			$result = $myvarNetAdapter.SetDNSServerSearchOrder($dns) 
			$result = $myvarNetAdapter.SetDynamicDNSRegistration("TRUE")  

			Write-LogOutput -LogFile $myvarOutputLogFile -Category "INFO" -message "Waiting $($sleep) seconds for interfaces to update..."
			Start-Sleep $sleep #adding a delay here as in some environments the network card is not immediately available after applying changes
		}

		end
		{
		
		}
	}#end function ApplyProductionIpConfig_wmi


	#this function is used to test a given IP address
	Function ApplyDrIPConfig 
	{
		#input: none
		#output: none
	<#
	.SYNOPSIS
	Applies the DR IP configuration.
	.DESCRIPTION
	Applies the DR IP configuration.
	.NOTES
	Author: Stephane Bourdeaud
	#>
		param 
		(
			
		)

		begin
		{
			
		}

		process
		{
			Write-LogOutput -LogFile $myvarOutputLogFile -category "WARNING" -message "Applying the DR IP address to $($myvarNetAdapter.$NetDescriptor)..."
			$result = Remove-NetRoute -InterfaceAlias $myvarNetAdapter.$NetDescriptor -Confirm:$false -ErrorAction SilentlyContinue
			$result = Remove-NetIPAddress -InterfaceAlias $myvarNetAdapter.$NetDescriptor -AddressFamily IPv4 -ErrorAction SilentlyContinue -Confirm:$false
			if ($myvarDrIPConfig.IPv4DefaultGateway) 
			{ #check this interface has a defined default gateway
				try 
				{#set ip
					$result = New-NetIPAddress -InterfaceAlias $myvarNetAdapter.$NetDescriptor -AddressFamily IPv4 -IPAddress $myvarDrIPConfig.IPAddress -PrefixLength $myvarDrIPConfig.$NetSubnetProperty -DefaultGateway $myvarDrIPConfig.IPv4DefaultGateway -ErrorAction Stop
				}
				catch
				{#couldn't set ip address
					Write-LogOutput -LogFile $myvarOutputLogFile -Category "ERROR" -Message "Could not set IPv4 address for $($myvarNetAdapter.$NetDescriptor) : $($_.Exception.Message)"
					Exit
				}
			}#end if default gw
			else 
			{
				try
				{#set ip
					$result = New-NetIPAddress -InterfaceAlias $myvarNetAdapter.$NetDescriptor -AddressFamily IPv4 -IPAddress $myvarDrIPConfig.IPAddress -PrefixLength $myvarDrIPConfig.$NetSubnetProperty -ErrorAction Stop
				}
				catch
				{#couldn't set ip address
					Write-LogOutput -LogFile $myvarOutputLogFile -Category "ERROR" -Message "Could not set IPv4 address for $($myvarNetAdapter.$NetDescriptor) : $($_.Exception.Message)"
					Exit
				}
			}#end else default gw
			try
			{#setting dns
				$result = Set-DnsClientServerAddress -InterfaceAlias $myvarNetAdapter.$NetDescriptor -ServerAddresses ($myvarDrIPConfig.PrimaryDNSServer, $myvarDrIPConfig.SecondaryDNSServer) -ErrorAction Stop
			}
			catch
			{#couldn't set dns
				Write-LogOutput -LogFile $myvarOutputLogFile -Category "ERROR" -Message "Could not set DNS for $($myvarNetAdapter.$NetDescriptor) : $($_.Exception.Message)"
				Exit
			}

			Write-LogOutput -LogFile $myvarOutputLogFile -Category "INFO" -message "Waiting $($sleep) seconds for interfaces to update..."
			Start-Sleep $sleep #adding a delay here as in some environments the network card is not immediately available after applying changes
			Write-LogOutput -LogFile $myvarOutputLogFile -Category "INFO" -message "Registering with DNS..."
			Register-DnsClient

			if ($fcs)
			{#we're on a failover cluster
				if ($myvarDrIPConfig.IPv4DefaultGateway) 
				{#this is the production interface (it has a gateway)
					Foreach ($myvar_resource in $myvar_fcs_dr)
					{#process each cluster resource specified in the fcs_dr.csv file
						ProcessClusterResource -resource_name $myvar_resource.resource_name -resource_value $myvar_resource.resource_value -resource_network $myvar_resource.resource_network -resource_subnet_mask $myvar_resource.resource_subnet_mask
					}
				}
			}
		}

		end
		{
		
		}
	}#end function ApplyDrIPConfig

	#this function is used to test a given IP address
	Function ApplyDrIPConfig_wmi 
	{
		#input: none
		#output: none
	<#
	.SYNOPSIS
	Applies the DR IP configuration.
	.DESCRIPTION
	Applies the DR IP configuration.
	.NOTES
	Author: Stephane Bourdeaud
	#>
		param 
		(
			
		)

		begin
		{
			
		}

		process
		{
			Write-LogOutput -LogFile $myvarOutputLogFile -category "WARNING" -message "Applying the DR IP address to $($myvarNetAdapter.Description)..."
			#apply PROD
			$ip = ($myvarDrIPConfig.IPAddress) 
			$gateway = $myvarDrIPConfig.IPv4DefaultGateway 
			$subnet = $myvarDrIPConfig.IPSubnet 
			$dns = ($myvarDrIPConfig.PrimaryDNSServer, $myvarDrIPConfig.SecondaryDNSServer) 
			$result = $myvarNetAdapter.EnableStatic($ip, $subnet) 
			$result = $myvarNetAdapter.SetGateways($gateway) 
			$result = $myvarNetAdapter.SetDNSServerSearchOrder($dns) 
			$result = $myvarNetAdapter.SetDynamicDNSRegistration("TRUE")

			Write-LogOutput -LogFile $myvarOutputLogFile -Category "INFO" -message "Waiting $($sleep) seconds for interfaces to update..."
			Start-Sleep $sleep #adding a delay here as in some environments the network card is not immediately available after applying changes
		}

		end
		{
		
		}
	}#end function ApplyDrIPConfig_wmi


	#this function is used to test a given IP address
	#TODO: fix when reverting to dhcp
	Function RestoreIPConfig 
	{
		#input: none
		#output: none
	<#
	.SYNOPSIS
	Restores the IP configuration.
	.DESCRIPTION
	Restores the IP configuration.
	.NOTES
	Author: Stephane Bourdeaud
	#>
		param 
		(
			
		)

		begin
		{
			
		}

		process
		{
			Write-LogOutput -LogFile $myvarOutputLogFile -category "WARNING" -message "Restoring the IP configuration on $($myvarNetAdapter.$NetDescriptor)..."
			Remove-NetRoute -InterfaceAlias $myvarNetAdapter.$NetDescriptor -Confirm:$false -ErrorAction SilentlyContinue
			Remove-NetIPAddress -InterfaceAlias $myvarNetAdapter.$NetDescriptor -AddressFamily IPv4 -ErrorAction SilentlyContinue -Confirm:$false
			if ($myvarSavedIPConfig.IPv4DefaultGateway) 
			{ #check this interface has a defined default gateway
				try
				{#set ip
					New-NetIPAddress -InterfaceAlias $myvarNetAdapter.$NetDescriptor -AddressFamily IPv4 -IPAddress $myvarNetAdapterIPv4Configs.IPAddress -PrefixLength $myvarNetAdapterIPv4Configs.$NetSubnetProperty -DefaultGateway $myvarNetAdapterIPv4Configs.IPv4DefaultGateway.NextHop -ErrorAction Stop
				}
				catch
				{#couldn't set ip address
					Write-LogOutput -LogFile $myvarOutputLogFile -Category "ERROR" -Message "Could not set IPv4 address for $($myvarNetAdapter.$NetDescriptor) : $($_.Exception.Message)"
					Exit
				}
			}#end if default gw
			else 
			{#no gateway
				try 
				{#set ip
					New-NetIPAddress -InterfaceAlias $myvarNetAdapter.$NetDescriptor -AddressFamily IPv4 -IPAddress $myvarNetAdapterIPv4Configs.IPAddress -PrefixLength $myvarNetAdapterIPv4Configs.$NetSubnetProperty -ErrorAction Stop
				}
				catch
				{#couldn't set ip address
					Write-LogOutput -LogFile $myvarOutputLogFile -Category "ERROR" -Message "Could not set IPv4 address for $($myvarNetAdapter.$NetDescriptor) : $($_.Exception.Message)"
					Exit
				}
			}#end else default gw
			try
			{#set dns 
				Set-DnsClientServerAddress -InterfaceAlias $myvarNetAdapter.$NetDescriptor -ServerAddresses ($myvarPrimaryDNS, $myvarSecondaryDNS) -ErrorAction Stop
			}
			catch
			{#couldn't set dns
				Write-LogOutput -LogFile $myvarOutputLogFile -Category "ERROR" -Message "Could not set DNS for $($myvarNetAdapter.$NetDescriptor) : $($_.Exception.Message)"
				Exit
			}

			Write-LogOutput -LogFile $myvarOutputLogFile -Category "INFO" -message "Waiting $($sleep) seconds for interfaces to update..."
			Start-Sleep $sleep #adding a delay here as in some environments the network card is not immediately available after applying changes
			Write-LogOutput -LogFile $myvarOutputLogFile -Category "INFO" -message "Registering with DNS..."
			Register-DnsClient
		}

		end
		{
		
		}
	}#end function RestoreIPConfig

	#this function is used to test a given IP address
	Function RestoreIPConfig_wmi 
	{
		#input: none
		#output: none
	<#
	.SYNOPSIS
	Restores the IP configuration using WMI.
	.DESCRIPTION
	Restores the IP configuration using WMI.
	.NOTES
	Author: Stephane Bourdeaud
	#>
		param 
		(
			
		)

		begin
		{
			
		}

		process
		{
			Write-LogOutput -LogFile $myvarOutputLogFile -category "WARNING" -message "Restoring the IP configuration on $($myvarNetAdapter.$NetDescriptor)..."
			#apply PROD
			$ip = $myvarNetAdapter.IPAddress[0]
			$gateway = $myvarNetAdapter.DefaultIPGateway 
			$subnet = $myvarNetAdapter.IPSubnet[0] 
			$dns = $myvarNetAdapter.DNSServerSearchOrder 
			$result = $myvarNetAdapter.EnableStatic($ip, $subnet) 
			$result = $myvarNetAdapter.SetGateways($gateway) 
			$result = $myvarNetAdapter.SetDNSServerSearchOrder($dns) 
			$result = $myvarNetAdapter.SetDynamicDNSRegistration("TRUE")

			Write-LogOutput -LogFile $myvarOutputLogFile -Category "INFO" -message "Waiting $($sleep) seconds for interfaces to update..."
			Start-Sleep $sleep #adding a delay here as in some environments the network card is not immediately available after applying changes
		}

		end
		{
		
		}
	}#end function RestoreIPConfig_wmi

	#this function is used to save the IP configuration
	Function SaveIPConfig 
	{
		#input: type (previous, production or dr)
		#output: csv file
	<#
	.SYNOPSIS
	Saves the IP configuration.
	.DESCRIPTION
	Saves the IP configuration.
	.NOTES
	Author: Stephane Bourdeaud
	#>
		param 
		(
			[Parameter(Mandatory)]
			[ValidateSet('previous','production','dr')]
			[string]
			$type
		)

		begin
		{
			switch ($type) #we'll change the text color depending on the selected category
			{
				"previous" {$csv = $path+"previous_ipconfig-"+$myvarNicCounter+".csv"}
				"production" {$csv = $path+"ipconfig-"+$myvarNicCounter+".csv"}
				"dr" {$csv = $path+"dr_ipconfig-"+$myvarNicCounter+".csv"}
			}
		}

		process
		{
			Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Saving current configuration to previous state ($($path+"previous_ipconfig-"+$myvarNicCounter+".csv")) for $($myvarNetAdapter.$NetDescriptor)..."
			if (([System.Environment]::OSVersion.Version.Major -gt 6) -or (([System.Environment]::OSVersion.Version.Major -ge 6) -and ([System.Environment]::OSVersion.Version.Minor -gt 1)))
			{#this is a Windows Server 2012 or above machine, so we can use the *Net* cmdlets
				$myvarActiveNetAdapterIP = Get-NetIPAddress -InterfaceAlias $myvarNetAdapter.$NetDescriptor | where-object {$_.AddressFamily -eq "IPv4"}
				$myvarActiveIPConfiguration = Get-NetIPConfiguration -InterfaceAlias $myvarNetAdapter.$NetDescriptor
				$myvarDNSServers = (Get-DnsClientServerAddress -AddressFamily IPv4 -InterfaceAlias $myvarNetAdapter.$NetDescriptor).ServerAddresses

				$myvarPrimaryDNS = $myvarDNSServers[0]
				$myvarSecondaryDNS = $myvarDNSServers[1]

				if ($myvarActiveNetAdapterIP.IPAddress -is [array])
				{
					$index = [array]::indexof($myvarActiveNetAdapterIP.IPAddress,$($myvarActiveNetAdapterIP.IPAddress | Sort-Object | Select-Object -First 1))
					$ipAddress = $myvarActiveNetAdapterIP.IPAddress[$index]
					$subnetMask = $myvarActiveNetAdapterIP.PrefixLength[$index]
				}
				else 
				{
					$ipAddress = $myvarActiveNetAdapterIP.IPAddress
					$subnetMask = $myvarActiveNetAdapterIP.PrefixLength
				}
				

				$myvarIPConfig = [psCustomObject][Ordered] @{   IPAddress = $ipAddress;
																PrefixLength = $subnetMask;
																IPv4DefaultGateway = $myvarActiveIPConfiguration.IPv4DefaultGateway.NextHop;
																PrimaryDNSServer = $myvarPrimaryDNS;
																SecondaryDNSServer = $myvarSecondaryDNS
															}
			}
			else
			{#this is a Windows Server 2008 R2 or below, so we have to use wmi
				$NetworkInterface_WmiObject = Get-WmiObject -Class Win32_NetworkAdapterConfiguration -Filter IPEnabled=TRUE -ComputerName . | Where-Object {$_.Description -eq $myvarNetAdapter.$NetDescriptor}
				#save the stuff we got
				$myvarDNSServers = $NetworkInterface_WmiObject.DNSServerSearchOrder

				$myvarPrimaryDNS = $myvarDNSServers[0]
				$myvarSecondaryDNS = $myvarDNSServers[1]

				$myvarIPConfig = [psCustomObject][Ordered] @{   IPAddress = $NetworkInterface_WmiObject.IPAddress[0];
																IPSubnet = $NetworkInterface_WmiObject.IPSubnet[0]
																IPv4DefaultGateway = $NetworkInterface_WmiObject.DefaultIPGateway[0];
																PrimaryDNSServer = $myvarPrimaryDNS;
																SecondaryDNSServer = $myvarSecondaryDNS
															}
			}

			$myvarIPConfig | Export-Csv -NoTypeInformation $csv -ErrorAction Continue
		}

		end
		{
		
		}
	}#end function SaveIPConfig

#endregion

#region Prep-work

	#initialize variables
	$myvarElapsedTime = [System.Diagnostics.Stopwatch]::StartNew() #used to store script begin timestamp
	if ($log)
	{
		if (!$log.EndsWith("\")) 
		{#make sure given log path has a trailing \
			$log += "\"
		}
		if (Test-Path -path $log)
		{
			$myvarOutputLogFile = $log
			$myvarOutputLogFile += (Get-Date -UFormat "%Y_%m_%d_%H_%M_")
			$myvarOutputLogFile += "set-ipconfig_OutputLog.log"
		}
		else 
		{
			Throw "$(get-date) [ERROR] Specified log path $($log) does not exist! Exiting."	
		}
	}
	else 
	{
		$myvarOutputLogFile = (Get-Date -UFormat "%Y_%m_%d_%H_%M_")
		$myvarOutputLogFile += "set-ipconfig_OutputLog.log"
	}
	$myvarChangeOccurred = $false #this is used to determine if interfaces without a gateway need to be updated or not (they will only get updated if a network interface with a defined gateway has been updated already)

	#check if we need to display help and/or history
	$HistoryText = @'
Maintenance Log
Date       By   Updates (newest updates at the top)
---------- ---- ---------------------------------------------------------------
08/24/2016 sb   Initial release.
11/07/2016 sb   Added support for multiple network interfaces.
03/06/2019 sb   Added support for Windows Server 2008 R2 using wmi.
01/29/2021 sb   Added support for Microsoft Failover Clustering Services (with
				-fcs) and ability to specify sleep time (with -sleep).
02/01/2021 sb   Adding resource_network to fix -fcs.
################################################################################
'@

	$myvarScriptName = ".\set-ipconfig.ps1"

	if ($help) 
	{#display help
		get-help $myvarScriptName
		exit
	}
	if ($History) 
	{#display history
		$HistoryText
		exit
	}

	if (!((get-itemproperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name ProductName).ProductName))
	{#we're not running on Windows
		Write-LogOutput -LogFile $myvarOutputLogFile -category "ERROR" -message "This script only works on Windows!"
		Exit
	}

	if ($psversiontable.PSVersion.Major -lt 5)
	{#PoSH version <5
		Write-LogOutput -LogFile $myvarOutputLogFile -Category "ERROR" -Message "Your version of Powershell is too old, please update to version 5 or above!"
		Exit
	}

	if (!$sleep) {$sleep = 10}

#endregion

#region Main Processing

	#region initialize variables
		#let's initialize parameters if they haven't been specified
		if (!$path) 
		{#no path set, default to c:\
			$path = "c:\"
		}
		if (!$path.EndsWith("\")) 
		{#make sure given path has a trailing \
		$path += "\"
		}

		if ($fcs)
		{
			#load configuration files
			try 
			{#reading fcs_prod.csv
				$myvar_fcs_prod = Import-Csv -path ($path+"fcs_prod.csv") -ErrorAction Stop
			}
			catch 
			{#couldn't read fcs_prod.csv
				Write-LogOutput -LogFile $myvarOutputLogFile -Category "ERROR" -Message "Could not import cluster production configuration from $(($path+"fcs_prod.csv")): $($_.Exception.Message)"
				Exit
			}
			try 
			{#reading fcs_dr.csv
				$myvar_fcs_dr = Import-Csv -path ($path+"fcs_dr.csv") -ErrorAction Stop
			}
			catch 
			{#couldn't read fcs_dr.csv
				Write-LogOutput -LogFile $myvarOutputLogFile -Category "ERROR" -Message "Could not import cluster DR configuration from $(($path+"fcs_dr.csv")): $($_.Exception.Message)"
				Exit
			}
		}

		#when looking at network adapters, property names will vary between Windows Server 2008 R2 and Windows Server 2012 and above.
		if (([System.Environment]::OSVersion.Version.Major -gt 6) -or (([System.Environment]::OSVersion.Version.Major -ge 6) -and ([System.Environment]::OSVersion.Version.Minor -gt 1)))
		{#this is a Windows Server 2012 or above machine
			$NetDescriptor = "Name"
			$NetSubnetProperty = "PrefixLength"
		}
		else
		{#this is a Windows Server 2008 R2 or below
			$NetDescriptor = "Description"
			$NetSubnetProperty = "IPSubnet"
		}
	#endregion

	#region Get Interfaces
		#get the network interface which is connected
		Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Retrieving the active network interface..."
		try 
		{#get adapters
			if (([System.Environment]::OSVersion.Version.Major -gt 6) -or (([System.Environment]::OSVersion.Version.Major -ge 6) -and ([System.Environment]::OSVersion.Version.Minor -gt 1)))
			{#this is a Windows Server 2012 or above machine, so we can use the *Net* cmdlets
				$myvarActiveNetAdapter = Get-NetAdapter -ErrorAction Stop | Where-Object {$_.status -eq "up"} | Sort-Object -Property ifIndex #we use ifIndex to determine the order of the interfaces
			}
			else 
			{#this is a Windows Server 2008 R2 or below, so we have to use wmi
				$myvarActiveNetAdapter = Get-WmiObject -Class Win32_NetworkAdapterConfiguration -Filter IPEnabled=TRUE -ComputerName . -ErrorAction Stop
			}
		}
		catch
		{#couldn't get adapters
			Write-LogOutput -LogFile $myvarOutputLogFile -Category "ERROR" -Message "Could not get network adapters : $($_.Exception.Message)"
			Exit
		}
		#also do something if none of the interfaces are up
		if (!$myvarActiveNetAdapter) 
		{#no active adapter
			Write-LogOutput -LogFile $myvarOutputLogFile -category "ERROR" -message "There is no active network interface: cannot continue!"
			exit
		}#endif no active network adapter
		if ($debugme) {Write-Host "$(get-date) [DEBUG] Active Network Adpaters: $($myvarActiveNetAdapter)" -ForegroundColor Cyan}
	#endregion

	#region Look at IPv4 Configuration
		#get the basic IPv4 information
		#$myvarNetAdapterIPv4Configs = @() #we'll keep all configs in this array
		$myvarNetAdapterIPv4Configs = @()

		ForEach ($myvarNetAdapter in $myvarActiveNetAdapter) 
		{#loop active adapters to get ipv4
			if (([System.Environment]::OSVersion.Version.Major -gt 6) -or (([System.Environment]::OSVersion.Version.Major -ge 6) -and ([System.Environment]::OSVersion.Version.Minor -gt 1)))
			{#this is a Windows Server 2012 or above machine, so we can use the *Net* cmdlets		
				$myvarNetAdapterIPv4Configs += getIPv4 -NetworkInterface $myvarNetAdapter.$NetDescriptor
			}
			else 
			{#this is a Windows Server 2008 R2 or below, so we have to use wmi
				$myvarNetAdapterIPv4Configs += getIPv4_wmi -NetworkInterface $myvarNetAdapter.description
			}
			if ($debugme) {Write-Host "$(get-date) [DEBUG] IPv4 information: $($myvarNetAdapterIPv4Configs)" -ForegroundColor Cyan}
		}#end foreach NetAdapter
	#endregion

	#region Process Each Network Adapter	
		$myvarNicCounter = 1 #we use this to keep track of the network adapter number we are processing
		
		ForEach ($myvarNetAdapter in $myvarActiveNetAdapter) 
		{#loop active adapters to configure
			
			Write-LogOutput -LogFile $myvarOutputLogFile -category "STEP" -message "Processing interface $($myvarNetAdapter.$NetDescriptor) with index $($myvarNetAdapter.InterfaceIndex)..."

			#region -dhcp
				if ($dhcp) 
				{#user specified the -dhcp parameter
					if (($interface -eq $myvarNicCounter) -or ($interface -eq "all")) 
					{#we have a match on the interface to configure
						if (([System.Environment]::OSVersion.Version.Major -gt 6) -or (([System.Environment]::OSVersion.Version.Major -ge 6) -and ([System.Environment]::OSVersion.Version.Minor -gt 1)))
						{#this is a Windows Server 2012 or above machine, so we can use the *Net* cmdlets
							Write-LogOutput -LogFile $myvarOutputLogFile -category "WARNING" -message "Configuring $($myvarNetAdapter.$NetDescriptor) with DHCP..."
							Remove-NetRoute -InterfaceAlias $myvarNetAdapter.$NetDescriptor -Confirm:$false -ErrorAction SilentlyContinue
							try 
							{#configure dhcp
								Set-NetIPInterface -InterfaceAlias $myvarNetAdapter.$NetDescriptor -AddressFamily IPv4 -DHCP Enabled -ErrorAction Stop
								Set-DnsClientServerAddress -InterfaceAlias $myvarNetAdapter.$NetDescriptor -ResetServerAddresses -ErrorAction Stop
							}
							catch
							{#couldn't configure dhcp
								Write-LogOutput -LogFile $myvarOutputLogFile -Category "ERROR" -Message "Could not enable DHCP for $($myvarNetAdapter.$NetDescriptor) : $($_.Exception.Message)"
								Exit
							}
						}
						else
						{#this is a Windows Server 2008 R2 or below, so we have to use wmi
							Write-LogOutput -LogFile $myvarOutputLogFile -category "WARNING" -message "Configuring $($myvarNetAdapter.Description) with DHCP..."
							$myvarNetAdapter.EnableDHCP() 
							$myvarNetAdapter.SetDNSServerSearchOrder() 
						}
					}#endif match interface to configure with dhcp
					else 
					{#no interface specified
						Write-LogOutput -LogFile $myvarOutputLogFile -category "ERROR" -message "You must specify an interface number or use all"	
					}
					#TODO: add default gateway ping test here
				}#endif -dhcp
			#endregion	
			
			#region -setprod
				elseif ($setprod) 
				{#user specified the -dhcp parameter
					if (!$interface)
					{#no interface was specified, so let's assume the current interface
						$interface = $myvarNicCounter
					}
					if (($interface -eq $myvarNicCounter) -or ($interface -eq "all")) 
					{#we have a match on the interface to configure						
						try 
						{#reading ipconfig.csv
							$myvarSavedIPConfig = Import-Csv -path ($path+"ipconfig-"+$myvarNicCounter+".csv") -ErrorAction Stop
						}
						catch 
						{#couldn't read ipconfig.csv
							Write-LogOutput -LogFile $myvarOutputLogFile -Category "ERROR" -Message "Could not import production configuration from $(($path+"ipconfig-"+$myvarNicCounter+".csv")): $($_.Exception.Message)"
							Exit
						}
						
						if (([System.Environment]::OSVersion.Version.Major -gt 6) -or (([System.Environment]::OSVersion.Version.Major -ge 6) -and ([System.Environment]::OSVersion.Version.Minor -gt 1)))
						{#this is a Windows Server 2012 or above machine, so we can use the *Net* cmdlets
							ApplyProductionIPConfig
						}
						else
						{#this is a Windows Server 2008 R2 or below, so we have to use wmi
							ApplyProductionIPConfig_wmi
						}	
					}
				}#endif -setprod
			#endregion
			
			#region -setdr
				elseif ($setdr) {#user specified the -dhcp parameter
					if (!$interface)
					{#no interface was specified, so let's assume the current interface
						$interface = $myvarNicCounter
					}
					if (($interface -eq $myvarNicCounter) -or ($interface -eq "all")) 
					{#we have a match on the interface to configure
						try 
						{#reading dr_ipconfig.csv
							$myvarDrIPConfig = Import-Csv -path ($path+"dr_ipconfig-"+$myvarNicCounter+".csv") -ErrorAction Stop
						}
						catch 
						{#couldn't read dr_ipconfig.csv
							Write-LogOutput -LogFile $myvarOutputLogFile -Category "ERROR" -Message "Could not import dr configuration from $(($path+"dr_ipconfig-"+$myvarNicCounter+".csv")): $($_.Exception.Message)"
							Exit
						}
						
						if (([System.Environment]::OSVersion.Version.Major -gt 6) -or (([System.Environment]::OSVersion.Version.Major -ge 6) -and ([System.Environment]::OSVersion.Version.Minor -gt 1)))
						{#this is a Windows Server 2012 or above machine, so we can use the *Net* cmdlets
							ApplyDrIPConfig
						}
						else
						{#this is a Windows Server 2008 R2 or below, so we have to use wmi
							ApplyDrIPConfig_wmi
						}
					}
				}#endif -setprod
			#endregion
			
			#region no specific command

				else {#no specific action was specified
					
					#saving the DNS config in case we need to restore
					if (([System.Environment]::OSVersion.Version.Major -gt 6) -or (([System.Environment]::OSVersion.Version.Major -ge 6) -and ([System.Environment]::OSVersion.Version.Minor -gt 1)))
					{#this is a Windows Server 2012 or above machine, so we can use the *Net* cmdlets
						$myvarDNSServers = (Get-DnsClientServerAddress -AddressFamily IPv4 -InterfaceAlias $myvarNetAdapter.$NetDescriptor).ServerAddresses
					}
					else
					{#this is a Windows Server 2008 R2 or below, so we have to use wmi
						$myvarDNSServers = $myvarNetAdapter.DNSServerSearchOrder
					}
					$myvarPrimaryDNS = $myvarDNSServers[0]
					$myvarSecondaryDNS = $myvarDNSServers[1]
					
					#region dhcp nic
					
						#determine if the IP configuration is obtained from DHCP or not
						if (([System.Environment]::OSVersion.Version.Major -gt 6) -or (([System.Environment]::OSVersion.Version.Major -ge 6) -and ([System.Environment]::OSVersion.Version.Minor -gt 1)))
						{#this is a Windows Server 2012 or above machine, so we can use the *Net* cmdlets
							Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Checking if the active network interface $($myvarNetAdapter.$NetDescriptor) has DHCP enabled..."
							try 
							{#determine if dhcp
								$myvarDHCPAdapter = Get-NetIPInterface -InterfaceAlias $myvarNetAdapter.$NetDescriptor -AddressFamily IPv4 -ErrorAction Stop
							}
							catch
							{#couldn't determine if dhcp
								Write-LogOutput -LogFile $myvarOutputLogFile -Category "ERROR" -Message "Could not determine if DHCP is enabled for $($myvarNetAdapter.$NetDescriptor) : $($_.Exception.Message)"
								Exit
							}
							if ($myvarDHCPAdapter.Dhcp -eq "Enabled") 
							{#dhcp is enabled
								$isDhcp = $true
							}
							else
							{#dhcp is not enabled
								$isDhcp = $false
							}
						}
						else
						{#this is a Windows Server 2008 R2 or below, so we have to use wmi
							if ($myvarNetAdapter.DHCPEnabled) 
							{#dhcp is enabled
								$isDhcp = $true
							}
							else
							{#dhcp is not enabled
								$isDhcp = $false
							}
						}
						
						
						if ($isDhcp) 
						{#!the active interface is configured with dhcp
							Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Determined the active network interface index $($myvarNetAdapter.InterfaceIndex) has DHCP enabled!"

							#region dhcp + dr_ipconfig

								#do we have a DR configuration?
								Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Checking for the presence of a $($path+"dr_ipconfig-"+$myvarNicCounter+".csv") file for interface index $($myvarNetAdapter.InterfaceIndex)..."
								if (Test-Path -path ($path+"dr_ipconfig-"+$myvarNicCounter+".csv")) 
								{#!we have a dr_ipconfig.csv file
									Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Determined we have a $($path+"dr_ipconfig-"+$myvarNicCounter+".csv") file for interface index $($myvarNetAdapter.InterfaceIndex)!"

									#region dhcp, dr_config, previous state

										#do we have a previous state?
										Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Checking if we have a $($path+"previous_ipconfig-"+$myvarNicCounter+".csv") file for interface index $($myvarNetAdapter.InterfaceIndex)..."
										if (Test-Path -path ($path+"previous_ipconfig-"+$myvarNicCounter+".csv")) 
										{#!we do have a previous state
											Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Determined we have a $($path+"previous_ipconfig-"+$myvarNicCounter+".csv") file for interface index index $($myvarNetAdapter.InterfaceIndex)!"

											#region dhcp, dr_config, previous state, ipconfig
												if (Test-Path -path ($path+"ipconfig-"+$myvarNicCounter+".csv")) 
												{#!we have an ipconfig.csv file
													#compare the actual ip with the previous ip
													Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Comparing current state with previous state for interface index $($myvarNetAdapter.InterfaceIndex)..."
												
													#reading ipconfig.csv
													$myvarSavedIPConfig = Import-Csv -path ($path+"ipconfig-"+$myvarNicCounter+".csv")
													#reading previous state
													$myvarPreviousState = Import-Csv -path ($path+"previous_ipconfig-"+$myvarNicCounter+".csv")
													#reading dr ipconfig
													$myvarDrIPConfig = Import-Csv -path ($path+"dr_ipconfig-"+$myvarNicCounter+".csv")
													
													#region dhcp, dr_config, ipconfig, previous state was PROD

														#!option 1: previous state was normal, we now have dhcp, so most likely, we've been moved to DR. Let's apply that and test GW ping.
														if ($myvarPreviousState.IPAddress -eq $myvarSavedIPConfig.IPAddress) 
														{
															Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Previous state was normal/production, so applying DR configuration for interface index $($myvarNetAdapter.InterfaceIndex)..."
															if (([System.Environment]::OSVersion.Version.Major -gt 6) -or (([System.Environment]::OSVersion.Version.Major -ge 6) -and ([System.Environment]::OSVersion.Version.Minor -gt 1)))
															{#this is a Windows Server 2012 or above machine, so we can use the *Net* cmdlets
																ApplyDrIPConfig
															}
															else
															{#this is a Windows Server 2008 R2 or below, so we have to use wmi
																ApplyDrIPConfig_wmi
															}

															if (!(TestDefaultGw -ip $myvarDrIPConfig.IPv4DefaultGateway)) 
															{#!DR default gateway does not ping
																#apply DR if no ping
																if (([System.Environment]::OSVersion.Version.Major -gt 6) -or (([System.Environment]::OSVersion.Version.Major -ge 6) -and ([System.Environment]::OSVersion.Version.Minor -gt 1)))
																{#this is a Windows Server 2012 or above machine, so we can use the *Net* cmdlets
																	ApplyProductionIPConfig
																}
																else
																{#this is a Windows Server 2008 R2 or below, so we have to use wmi
																	ApplyProductionIPConfig_wmi
																}
																
																#test ping DR gateway
																Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Waiting for $($sleep) seconds..."
																Start-Sleep -Seconds $sleep
																
																if (!(TestDefaultGw -ip $myvarSavedIPConfig.IPv4DefaultGateway)) 
																{#!PROD default gateway does not ping
																	#re-apply ipconfig if still no ping
																	if (([System.Environment]::OSVersion.Version.Major -gt 6) -or (([System.Environment]::OSVersion.Version.Major -ge 6) -and ([System.Environment]::OSVersion.Version.Minor -gt 1)))
																	{#this is a Windows Server 2012 or above machine, so we can use the *Net* cmdlets
																		RestoreIPConfig
																	}
																	else
																	{#this is a Windows Server 2008 R2 or below, so we have to use wmi
																		RestoreIPConfig_wmi
																	}
																}
															}

														}#endif previous was normal

													#endregion
																										
													#region dhcp, dr_config, ipconfig, previous state was DR

														#!option 2: previous state was DR and we now have DHCP, so we have probably been moved to PROD. Let's apply that and test GW ping.
														ElseIf ($myvarPreviousState.IPAddress -eq $myvarDrIPConfig.IPAddress) 
														{
															Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Previous state was DR, so applying normal/production configuration for interface index $($myvarNetAdapter.InterfaceIndex)..."
															if (([System.Environment]::OSVersion.Version.Major -gt 6) -or (([System.Environment]::OSVersion.Version.Major -ge 6) -and ([System.Environment]::OSVersion.Version.Minor -gt 1)))
															{#this is a Windows Server 2012 or above machine, so we can use the *Net* cmdlets
																ApplyProductionIPConfig
															}
															else
															{#this is a Windows Server 2008 R2 or below, so we have to use wmi
																ApplyProductionIPConfig_wmi
															}
															
															if (!(TestDefaultGw -ip $myvarSavedIPConfig.IPv4DefaultGateway)) 
															{#!PROD default gateway does not ping
																#apply DR if no ping
																if (([System.Environment]::OSVersion.Version.Major -gt 6) -or (([System.Environment]::OSVersion.Version.Major -ge 6) -and ([System.Environment]::OSVersion.Version.Minor -gt 1)))
																{#this is a Windows Server 2012 or above machine, so we can use the *Net* cmdlets
																	ApplyDrIPConfig
																}
																else
																{#this is a Windows Server 2008 R2 or below, so we have to use wmi
																	ApplyDrIPConfig_wmi
																}
																
																#test ping DR gateway
																Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Waiting for $($sleep) seconds..."
																Start-Sleep -Seconds $sleep
																
																if (!(TestDefaultGw -ip $myvarDrIPConfig.IPv4DefaultGateway)) 
																{#!DR default gateway does not ping
																	#re-apply ipconfig if still no ping
																	if (([System.Environment]::OSVersion.Version.Major -gt 6) -or (([System.Environment]::OSVersion.Version.Major -ge 6) -and ([System.Environment]::OSVersion.Version.Minor -gt 1)))
																	{#this is a Windows Server 2012 or above machine, so we can use the *Net* cmdlets
																		RestoreIPConfig
																	}
																	else
																	{#this is a Windows Server 2008 R2 or below, so we have to use wmi
																		RestoreIPConfig_wmi
																	}
																}
															}

														}#endElseIf previous was dr

													#endregion
																										
													#region dhcp, dr_config, ipconfig, previous state is UNKNOWN

														Else 
														{#!previous state is unknown, in which case we start by applying prod, try default gw ping, if no response, we apply dr
															Write-LogOutput -LogFile $myvarOutputLogFile -category "WARNING" -message "Previous state does not match normal/production or DR and is therefore unknown for interface index $($myvarNetAdapter.InterfaceIndex)..."
																														
															#region previous state UNKNOWN, apply DR
																Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Applying DR configuration for interface index $($myvarNetAdapter.InterfaceIndex)..."
																if (([System.Environment]::OSVersion.Version.Major -gt 6) -or (([System.Environment]::OSVersion.Version.Major -ge 6) -and ([System.Environment]::OSVersion.Version.Minor -gt 1)))
																{#this is a Windows Server 2012 or above machine, so we can use the *Net* cmdlets
																	ApplyDrIPConfig
																}
																else
																{#this is a Windows Server 2008 R2 or below, so we have to use wmi
																	ApplyDrIPConfig_wmi
																}
																
															#endregion

															#test new GW
															Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Waiting for $($sleep) seconds..."
															Start-Sleep -Seconds $sleep

															if (!(TestDefaultGw -ip $myvarDrIPConfig.IPv4DefaultGateway)) 
															{#!we applied DR but default gateway does not ping, so apply production	
																#region previous state UNKNOWN, DR GW NO ping, apply PROD
																	Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "DR gateway does not ping, so applying production..."
																	if (([System.Environment]::OSVersion.Version.Major -gt 6) -or (([System.Environment]::OSVersion.Version.Major -ge 6) -and ([System.Environment]::OSVersion.Version.Minor -gt 1)))
																	{#this is a Windows Server 2012 or above machine, so we can use the *Net* cmdlets
																		ApplyProductionIPConfig
																	}
																	else
																	{#this is a Windows Server 2008 R2 or below, so we have to use wmi
																		ApplyProductionIPConfig_wmi
																	}
																	
																#endregion
															}#endif test DR default gateway

														}#endelse (previous state is unknown)

													#endregion

												}#endif ipconfig.csv?

											#endregion
											
											#region dhcp, dr_config, previous state, NO ipconfig

												else 
												{#!dhcp, dr_config, previous state, NO ipconfig
													Write-LogOutput -LogFile $myvarOutputLogFile -category "ERROR" -message "The active network interface index $($myvarNetAdapter.InterfaceIndex) is using DHCP, we have a dr_config.csv and a previous_ipconfig.csv file but we don't have an ipconfig.csv file in $path. Cannot continue!"
													continue
												}#endelse we have dhcp, dr config, previous state and NO ipconfig.csv

											#endregion

										}#endif do we have a previous state?
									
									#endregion

									#region dhcp, dr_config, NO previous state, ipconfig
										else 
										{
											if (Test-Path -path ($path+"ipconfig-"+$myvarNicCounter+".csv")) 
											{#!we have an ipconfig.csv file
												#reading ipconfig.csv
												$myvarSavedIPConfig = Import-Csv -path ($path+"ipconfig-"+$myvarNicCounter+".csv")
												#reading dr ipconfig
												$myvarDrIPConfig = Import-Csv -path ($path+"dr_ipconfig-"+$myvarNicCounter+".csv")

												Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "The active network interface index $($myvarNetAdapter.InterfaceIndex) is using DHCP, we have a dr_config.csv, NO previous state and we have an ipconfig.csv.  Applying production configuration (ipconfig.csv)..."
												if (([System.Environment]::OSVersion.Version.Major -gt 6) -or (([System.Environment]::OSVersion.Version.Major -ge 6) -and ([System.Environment]::OSVersion.Version.Minor -gt 1)))
												{#this is a Windows Server 2012 or above machine, so we can use the *Net* cmdlets
													ApplyProductionIPConfig
												}
												else
												{#this is a Windows Server 2008 R2 or below, so we have to use wmi
													ApplyProductionIPConfig_wmi
												}
												
												if (!(TestDefaultGw -ip $myvarSavedIPConfig.IPv4DefaultGateway)) 
												{#!Production default gateway does not ping
													Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Default gateway does not ping, so applying DR configuration for interface index $($myvarNetAdapter.InterfaceIndex)..."
													if (([System.Environment]::OSVersion.Version.Major -gt 6) -or (([System.Environment]::OSVersion.Version.Major -ge 6) -and ([System.Environment]::OSVersion.Version.Minor -gt 1)))
													{#this is a Windows Server 2012 or above machine, so we can use the *Net* cmdlets
														ApplyDrIPConfig
													}
													else
													{#this is a Windows Server 2008 R2 or below, so we have to use wmi
														ApplyDrIPConfig_wmi
													}

													#test new GW
													Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Waiting for $($sleep) seconds..."
													Start-Sleep -Seconds $sleep

													if (!(TestDefaultGw -ip $myvarDrIPConfig.IPv4DefaultGateway)) 
													{#!set default gateway still does not ping...	
														Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Default gateway does not ping, so reverting to production configuration for interface index $($myvarNetAdapter.InterfaceIndex)..."
														if (([System.Environment]::OSVersion.Version.Major -gt 6) -or (([System.Environment]::OSVersion.Version.Major -ge 6) -and ([System.Environment]::OSVersion.Version.Minor -gt 1)))
														{#this is a Windows Server 2012 or above machine, so we can use the *Net* cmdlets
															ApplyProductionIPConfig
														}
														else
														{#this is a Windows Server 2008 R2 or below, so we have to use wmi
															ApplyProductionIPConfig_wmi
														}
													}#endif test DR default gateway

												}


											}
											
											#region dhcp, dr_config, NO previous state, NO ipconfig
												else
												{#!we don't have an ipconfig.csv file
													Write-LogOutput -LogFile $myvarOutputLogFile -category "ERROR" -message "The active network interface index $($myvarNetAdapter.InterfaceIndex) is using DHCP, we have a dr_config.csv, no previous_ipconfig.csv file and we don't have an ipconfig.csv file in $path. Cannot continue!"
													continue
												}
											#endregion
											}

									#endregion

									

								}#endif dr_ipconfig.csv
								
							#endregion							
							
							#region dhcp but NO dr_ipconfig

								else 
								{#!we don't have a dr_ipconfig.csv file
									#do we have a saved config?
									Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "There is no $($path+"dr_ipconfig-"+$myvarNicCounter+".csv") for interface index $($myvarNetAdapter.InterfaceIndex). Checking now if we have a $($path+"ipconfig-"+$myvarNicCounter+".csv") file..."

									#region dhcp, NO dr_ipconfig, ipconfig

										if (Test-Path -path ($path+"ipconfig-"+$myvarNicCounter+".csv")) 
										{#!we have a ipconfig.csv file
											#apply the saved config
											Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Applying the static IP configuration from $($path+"ipconfig-"+$myvarNicCounter+".csv") for interface index $($myvarNetAdapter.InterfaceIndex)..."
											#read ipconfig.csv
											$myvarSavedIPConfig = Import-Csv ($path+"ipconfig-"+$myvarNicCounter+".csv")
											#apply PROD
											if (([System.Environment]::OSVersion.Version.Major -gt 6) -or (([System.Environment]::OSVersion.Version.Major -ge 6) -and ([System.Environment]::OSVersion.Version.Minor -gt 1)))
											{#this is a Windows Server 2012 or above machine, so we can use the *Net* cmdlets
												ApplyProductionIPConfig
											}
											else
											{#this is a Windows Server 2008 R2 or below, so we have to use wmi
												ApplyProductionIPConfig_wmi
											}

										}#endif ipconfig.csv?

									#endregion

									#region dhcp, NO dr_ipconfig, NO ipconfig

										else 
										{#!dhcp, NO dr_ipconfig, NO ipconfig
											Write-LogOutput -LogFile $myvarOutputLogFile -category "ERROR" -message "The active network interface index $($myvarNetAdapter.InterfaceIndex) is using DHCP but we don't have a $($path+"ipconfig-"+$myvarNicCounter+".csv"). Cannot continue!"
											break
										}#endelse we have dhcp and NO ipconfig.csv

									#endregion

								}#endelse we don't have a dr_ipconfig.csv file
							
							#endregion

						}#endif active dhcp interface
						
					#endregion

					#region NOT dhcp nic
						
						else 
						{#!ip config is already static
							#do we have a saved dr_config?
							Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Active network interface index $($myvarNetAdapter.InterfaceIndex) already has a static IP.  Checking if we already have a $($path+"dr_ipconfig-"+$myvarNicCounter+".csv") file..."
							
							
							#region NO dhcp, dr_ipconfig
								if ((Test-Path -path ($path+"dr_ipconfig-"+$myvarNicCounter+".csv")) -and (Test-Path -path ($path+"ipconfig-"+$myvarNicCounter+".csv"))) 
								{#!we have a saved dr_config
									Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Determined we have a $($path+"dr_ipconfig-"+$myvarNicCounter+".csv") file for interface index $($myvarNetAdapter.InterfaceIndex)!"
									#compare the actual ip with the previous ip
									Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Comparing current state with previous state for interface index $($myvarNetAdapter.InterfaceIndex)..."
								
									#reading ipconfig.csv
									$myvarSavedIPConfig = Import-Csv -path ($path+"ipconfig-"+$myvarNicCounter+".csv")
									#reading previous state
									$myvarPreviousState = Import-Csv -path ($path+"previous_ipconfig-"+$myvarNicCounter+".csv")
									#reading dr ipconfig
									$myvarDrIPConfig = Import-Csv -path ($path+"dr_ipconfig-"+$myvarNicCounter+".csv")
									
									
									#region NO dhcp, dr_ipconfig, previous state was PROD
										#!option 1: previous state was normal and we cannot ping the default gw, so we use DR
										if ($myvarPreviousState.IPAddress -eq $myvarSavedIPConfig.IPAddress) {
											Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Previous state was normal/production for interface index $($myvarNetAdapter.InterfaceIndex)..."
											
											#testing default-gw connectivity
											if (([System.Environment]::OSVersion.Version.Major -gt 6) -or (([System.Environment]::OSVersion.Version.Major -ge 6) -and ([System.Environment]::OSVersion.Version.Minor -gt 1)))
											{#this is a Windows Server 2012 or above machine
												if (($myvarNetAdapterIPv4Configs | Where-Object {$_.InterfaceAlias -eq $myvarNetAdapter.$NetDescriptor}).IPv4DefaultGateway.NextHop) 
												{#we have a gw
													$myvarGWPing = TestDefaultGw -ip ($myvarNetAdapterIPv4Configs | Where-Object {$_.InterfaceAlias -eq $myvarNetAdapter.$NetDescriptor}).IPv4DefaultGateway.NextHop
												}#end if default gw
												else 
												{ #if there is no gw for this interface, we assume it needs a change only if another interface was changed, otherwise we leave it untouched
													if ($myvarChangeOccurred -eq $true) 
													{#another interface was changed
														$myvarGWPing = $false
													}
													else 
													{#no other interface was changed, so this one won't either
														$myvarGWPing = $true
													}
												}#end else default gw
											}
											else
											{#this is a Windows Server 2008 R2 or below
												if (($myvarNetAdapterIPv4Configs | Where-Object {$_.InterfaceAlias -eq $myvarNetAdapter.$NetDescriptor}).IPv4DefaultGateway) 
												{#we have a gw
													$myvarGWPing = TestDefaultGw -ip ($myvarNetAdapterIPv4Configs | Where-Object {$_.InterfaceAlias -eq $myvarNetAdapter.$NetDescriptor}).IPv4DefaultGateway
												}#end if default gw
												else 
												{ #if there is no gw for this interface, we assume it needs a change only if another interface was changed, otherwise we leave it untouched
													if ($myvarChangeOccurred -eq $true) 
													{#another interface was changed
														$myvarGWPing = $false
													}
													else 
													{#no other interface was changed, so this one won't either
														$myvarGWPing = $true
													}
												}#end else default gw
											}
											
											if ($myvarGWPing -eq $false) 
											{#!couldn't test gw ping or it failed
												Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Previous state was normal/production, so applying DR configuration for $($myvarNetAdapter.$NetDescriptor)..."
												if (([System.Environment]::OSVersion.Version.Major -gt 6) -or (([System.Environment]::OSVersion.Version.Major -ge 6) -and ([System.Environment]::OSVersion.Version.Minor -gt 1)))
												{#this is a Windows Server 2012 or above machine, so we can use the *Net* cmdlets
													ApplyDrIPConfig
													$myvarChangeOccurred = $true
												}
												else
												{#this is a Windows Server 2008 R2 or below, so we have to use wmi
													ApplyDrIPConfig_wmi
													$myvarChangeOccurred = $true
												}
												if ($myvarDrIPConfig.IPv4DefaultGateway) 
												{#we have a gw
													if (!(TestDefaultGw -ip $myvarDrIPConfig.IPv4DefaultGateway)) 
													{#!DR default gateway does not ping
														#apply Production if no ping
														if (([System.Environment]::OSVersion.Version.Major -gt 6) -or (([System.Environment]::OSVersion.Version.Major -ge 6) -and ([System.Environment]::OSVersion.Version.Minor -gt 1)))
														{#this is a Windows Server 2012 or above machine, so we can use the *Net* cmdlets
															ApplyProductionIPConfig
														}
														else
														{#this is a Windows Server 2008 R2 or below, so we have to use wmi
															ApplyProductionIPConfig_wmi
														}
														#test ping Production gateway
														Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Waiting for $($sleep) seconds..."
														Start-Sleep -Seconds $sleep
														if ($myvarSavedIPConfig.IPv4DefaultGateway)
														{
															if (!(TestDefaultGw -ip $myvarSavedIPConfig.IPv4DefaultGateway)) 
															{#!PROD default gateway does not ping
																#re-apply ipconfig if still no ping
																if (([System.Environment]::OSVersion.Version.Major -gt 6) -or (([System.Environment]::OSVersion.Version.Major -ge 6) -and ([System.Environment]::OSVersion.Version.Minor -gt 1)))
																{#this is a Windows Server 2012 or above machine, so we can use the *Net* cmdlets
																	RestoreIPConfig
																}
																else
																{#this is a Windows Server 2008 R2 or below, so we have to use wmi
																	RestoreIPConfig_wmi
																}
															}
														}
													}
												}

											}#end if gw does not ping
											else 
											{
												Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Gateway pings for interface index $($myvarNetAdapter.InterfaceIndex) so no further changes are required..."
											}

											
										}#endif previous was normal
									#endregion
									
									
									#region NO dhcp, dr_ipconfig, previous state was DR
										#!option 2: previous state was DR and we cannot ping the default gw, so we use normal
										ElseIf ($myvarPreviousState.IPAddress -eq $myvarDrIPConfig.IPAddress) 
										{
											Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Previous state was DR for interface index $($myvarNetAdapter.InterfaceIndex)..."
											#testing default-gw connectivity
											if (([System.Environment]::OSVersion.Version.Major -gt 6) -or (([System.Environment]::OSVersion.Version.Major -ge 6) -and ([System.Environment]::OSVersion.Version.Minor -gt 1)))
											{#this is a Windows Server 2012 or above machine
												if (($myvarNetAdapterIPv4Configs | Where-Object {$_.InterfaceAlias -eq $myvarNetAdapter.$NetDescriptor}).IPv4DefaultGateway.NextHop) 
												{#we have a gw
													$myvarGWPing = TestDefaultGw -ip ($myvarNetAdapterIPv4Configs | Where-Object {$_.InterfaceAlias -eq $myvarNetAdapter.$NetDescriptor}).IPv4DefaultGateway.NextHop
												}#end if default gw
												else 
												{ #if there is no gw for this interface, we assume it needs a change only if another interface was changed, otherwise we leave it untouched
													if ($myvarChangeOccurred -eq $true) 
													{#another interface was changed
														$myvarGWPing = $false
													}
													else 
													{#no other interface was changed, so this one won't either
														$myvarGWPing = $true
													}
												}#end else default gw
											}
											else
											{#this is a Windows Server 2008 R2 or below
												if (($myvarNetAdapterIPv4Configs | Where-Object {$_.InterfaceAlias -eq $myvarNetAdapter.$NetDescriptor}).IPv4DefaultGateway) 
												{#we have a gw
													$myvarGWPing = TestDefaultGw -ip ($myvarNetAdapterIPv4Configs | Where-Object {$_.InterfaceAlias -eq $myvarNetAdapter.$NetDescriptor}).IPv4DefaultGateway
												}#end if default gw
												else 
												{ #if there is no gw for this interface, we assume it needs a change only if another interface was changed, otherwise we leave it untouched
													if ($myvarChangeOccurred -eq $true) 
													{#another interface was changed
														$myvarGWPing = $false
													}
													else 
													{#no other interface was changed, so this one won't either
														$myvarGWPing = $true
													}
												}#end else default gw
											}
											if ($myvarGWPing -eq $false) 
											{
												Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Previous state was DR, so applying normal/production configuration for interface index $($myvarNetAdapter.InterfaceIndex)..."
												#apply Normal
												if (([System.Environment]::OSVersion.Version.Major -gt 6) -or (([System.Environment]::OSVersion.Version.Major -ge 6) -and ([System.Environment]::OSVersion.Version.Minor -gt 1)))
												{#this is a Windows Server 2012 or above machine, so we can use the *Net* cmdlets
													ApplyProductionIPConfig
													$myvarChangeOccurred = $true
												}
												else
												{#this is a Windows Server 2008 R2 or below, so we have to use wmi
													ApplyProductionIPConfig_wmi
													$myvarChangeOccurred = $true
												}

												if ($myvarSavedIPConfig.IPv4DefaultGateway)
												{
													if (!(TestDefaultGw -ip $myvarSavedIPConfig.IPv4DefaultGateway)) 
													{#!PROD default gateway does not ping
														#apply DR if no ping
														if (([System.Environment]::OSVersion.Version.Major -gt 6) -or (([System.Environment]::OSVersion.Version.Major -ge 6) -and ([System.Environment]::OSVersion.Version.Minor -gt 1)))
														{#this is a Windows Server 2012 or above machine, so we can use the *Net* cmdlets
															ApplyDrIPConfig
														}
														else
														{#this is a Windows Server 2008 R2 or below, so we have to use wmi
															ApplyDrIPConfig_wmi
														}
														#test ping DR gateway
														Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Waiting for $($sleep) seconds..."
														Start-Sleep -Seconds $sleep
														if ($myvarDrIPConfig.IPv4DefaultGateway) 
														{
															if (!(TestDefaultGw -ip $myvarDrIPConfig.IPv4DefaultGateway)) 
															{#!DR default gateway does not ping
																#re-apply ipconfig if still no ping
																if (([System.Environment]::OSVersion.Version.Major -gt 6) -or (([System.Environment]::OSVersion.Version.Major -ge 6) -and ([System.Environment]::OSVersion.Version.Minor -gt 1)))
																{#this is a Windows Server 2012 or above machine, so we can use the *Net* cmdlets
																	RestoreIPConfig
																}
																else
																{#this is a Windows Server 2008 R2 or below, so we have to use wmi
																	RestoreIPConfig_wmi
																}
															}
														}
													}
												}
											}
											else 
											{
												Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Gateway pings for interface index $($myvarNetAdapter.InterfaceIndex) so no further changes are required..."
											}


										}#endElseIf previous was dr
									#endregion
									
									#region NO dhcp, dr_ipconfig, previous state was UNKNOWN
										Else 
										{#previous state is unknown, in which case we start by applying prod, try default gw ping, if no response, we apply dr
											Write-LogOutput -LogFile $myvarOutputLogFile -category "WARNING" -message "Previous state does not match normal/production or DR and is therefore unknown for interface index $($myvarNetAdapter.InterfaceIndex): testing default gateway..."
											if (([System.Environment]::OSVersion.Version.Major -gt 6) -or (([System.Environment]::OSVersion.Version.Major -ge 6) -and ([System.Environment]::OSVersion.Version.Minor -gt 1)))
											{#this is a Windows Server 2012 or above machine
												if (($myvarNetAdapterIPv4Configs | Where-Object {$_.InterfaceAlias -eq $myvarNetAdapter.$NetDescriptor}).IPv4DefaultGateway.NextHop) 
												{#we have a gw
													$myvarGWPing = TestDefaultGw -ip ($myvarNetAdapterIPv4Configs | Where-Object {$_.InterfaceAlias -eq $myvarNetAdapter.$NetDescriptor}).IPv4DefaultGateway.NextHop
												}#end if default gw
												else 
												{ #if there is no gw for this interface, we assume it needs a change only if another interface was changed, otherwise we leave it untouched
													if ($myvarChangeOccurred -eq $true) 
													{#another interface was changed
														$myvarGWPing = $false
													}
													else 
													{#no other interface was changed, so this one won't either
														$myvarGWPing = $true
													}
												}#end else default gw
											}
											else
											{#this is a Windows Server 2008 R2 or below
												if (($myvarNetAdapterIPv4Configs | Where-Object {$_.InterfaceAlias -eq $myvarNetAdapter.$NetDescriptor}).IPv4DefaultGateway) 
												{#we have a gw
													$myvarGWPing = TestDefaultGw -ip ($myvarNetAdapterIPv4Configs | Where-Object {$_.InterfaceAlias -eq $myvarNetAdapter.$NetDescriptor}).IPv4DefaultGateway
												}#end if default gw
												else 
												{ #if there is no gw for this interface, we assume it needs a change only if another interface was changed, otherwise we leave it untouched
													if ($myvarChangeOccurred -eq $true) 
													{#another interface was changed
														$myvarGWPing = $false
													}
													else 
													{#no other interface was changed, so this one won't either
														$myvarGWPing = $true
													}
												}#end else default gw
											}
											if ($myvarGWPing -eq $false) 
											{#default gateway does not ping...
												#start by applying PROD
												if (([System.Environment]::OSVersion.Version.Major -gt 6) -or (([System.Environment]::OSVersion.Version.Major -ge 6) -and ([System.Environment]::OSVersion.Version.Minor -gt 1)))
												{#this is a Windows Server 2012 or above machine, so we can use the *Net* cmdlets
													ApplyProductionIPConfig
													$myvarChangeOccurred = $true
												}
												else
												{#this is a Windows Server 2008 R2 or below, so we have to use wmi
													ApplyProductionIPConfig_wmi
													$myvarChangeOccurred = $true
												}
												#then test ping on PROD gateway
												Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Waiting for $($sleep) seconds..."
												Start-Sleep -Seconds $sleep
												
												if ($myvarSavedIPConfig.IPv4DefaultGateway)
												{
													if (!(TestDefaultGw -ip $myvarSavedIPConfig.IPv4DefaultGateway)) 
													{#!PROD default gateway does not ping
														#apply DR if no ping
														if (([System.Environment]::OSVersion.Version.Major -gt 6) -or (([System.Environment]::OSVersion.Version.Major -ge 6) -and ([System.Environment]::OSVersion.Version.Minor -gt 1)))
														{#this is a Windows Server 2012 or above machine, so we can use the *Net* cmdlets
															ApplyDrIPConfig
														}
														else
														{#this is a Windows Server 2008 R2 or below, so we have to use wmi
															ApplyDrIPConfig_wmi
														}
														#test ping DR gateway
														Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Waiting for $($sleep) seconds..."
														Start-Sleep -Seconds $sleep
														
														if ($myvarDrIPConfig.IPv4DefaultGateway)
														{
															if (!(TestDefaultGw -ip $myvarDrIPConfig.IPv4DefaultGateway)) 
															{#!DR default gateway does not ping
																#re-apply ipconfig if still no ping
																if (([System.Environment]::OSVersion.Version.Major -gt 6) -or (([System.Environment]::OSVersion.Version.Major -ge 6) -and ([System.Environment]::OSVersion.Version.Minor -gt 1)))
																{#this is a Windows Server 2012 or above machine, so we can use the *Net* cmdlets
																	RestoreIPConfig
																}
																else
																{#this is a Windows Server 2008 R2 or below, so we have to use wmi
																	RestoreIPConfig_wmi
																}
															}
														}
													}
												}

															
											}#endif test DR default gateway
										}#endelse (previous state is unknown)
									#endregion
									
								}#end dr_config?
							#endregion
							
							
							#region NO dhcp, NO dr_ipconfig
								else 
								{#!we have no dr_config
									#do we have a saved config?
									Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Active network interface index $($myvarNetAdapter.InterfaceIndex) already has a static IP.  Checking if we already have a $($path+"ipconfig-"+$myvarNicCounter+".csv") file..."
									
									
									#region NO dhcp, NO dr_ipconfig, ipconfig
										if (Test-Path -path ($path+"ipconfig-"+$myvarNicCounter+".csv")) 
										{#!we have a saved config
											Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Determined we already have an ipconfig.csv file in $path for interface index $($myvarNetAdapter.InterfaceIndex)!"
											
											#reading previous state
											$myvarSavedIPConfig = Import-Csv -path ($path+"ipconfig-"+$myvarNicCounter+".csv")
											
											#is it the same as current config? Also we must not have a dr file.
											Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Has the static IP address changed for interface index $($myvarNetAdapter.InterfaceIndex)?"
											
											if (([System.Environment]::OSVersion.Version.Major -gt 6) -or (([System.Environment]::OSVersion.Version.Major -ge 6) -and ([System.Environment]::OSVersion.Version.Minor -gt 1)))
											{#this is a Windows Server 2012 or above machine
												if ((($myvarNetAdapterIPv4Configs | Where-Object {$_.InterfaceAlias -eq $myvarNetAdapter.$NetDescriptor}).IPv4Address.IPAddress -ne $myvarSavedIPConfig.IPAddress) -and !(Test-Path -path ($path+"dr_ipconfig-"+$myvarNicCounter+".csv"))) 
												{
													Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Static IP address has changed for interface index $($myvarNetAdapter.InterfaceIndex).  Updating the $($path+"ipconfig-"+$myvarNicCounter+".csv") file..."
													SaveIPConfig -type "production"
												}
											}
											else
											{#this is a Windows Server 2008 R2 or below
												if ((($myvarNetAdapterIPv4Configs | Where-Object {$_.InterfaceAlias -eq $myvarNetAdapter.$NetDescriptor}).IPv4Address -ne $myvarSavedIPConfig.IPAddress) -and !(Test-Path -path ($path+"dr_ipconfig-"+$myvarNicCounter+".csv"))) 
												{
													Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Static IP address has changed for interface index $($myvarNetAdapter.InterfaceIndex).  Updating the $($path+"ipconfig-"+$myvarNicCounter+".csv") file..."
													SaveIPConfig -type "production"
												}
											}

											#TODO: add a check here to make sure current is valid
											

										}#endif do we have a saved config?
									#endregion
									
									
									#region NO dhcp, NO dr_ipconfig, NO ipconfig
										else 
										{#!we don't have a saved config
											#saving the ipconfig
											Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "Active network interface index $($myvarNetAdapter.InterfaceIndex) has a static IP and we don't have a $($path+"ipconfig-"+$myvarNicCounter+".csv") file! Saving to $($path+"ipconfig-"+$myvarNicCounter+".csv")..."
											SaveIPConfig -type "production"
										}#end else saved config
									#endregion
								}#end else dr_config
							#endregion
						}#end else (active interface has static config)

					#endregion
				
				}#end else no specific action specified
				
			#endregion
			
			#region Save config
				#save the current state to previous
				SaveIPConfig -type "previous"
				
			#endregion

			++$myvarNicCounter

		}#end foreach NetAdapter
	#endregion

	Write-LogOutput -LogFile $myvarOutputLogFile -category "INFO" -message "We're done!"

#endregion

#region Cleanup

#let's figure out how much time this all took
Write-LogOutput -LogFile $myvarOutputLogFile -category "SUM" -message "total processing time: $($myvarElapsedTime.Elapsed.ToString())"

#cleanup after ourselves and delete all custom variables
Remove-Variable myvar* -ErrorAction SilentlyContinue
Remove-Variable ErrorActionPreference -ErrorAction SilentlyContinue
Remove-Variable help -ErrorAction SilentlyContinue
Remove-Variable history -ErrorAction SilentlyContinue
Remove-Variable log -ErrorAction SilentlyContinue
Remove-Variable path -ErrorAction SilentlyContinue
Remove-Variable debugme -ErrorAction SilentlyContinue
Remove-Variable * -ErrorAction SilentlyContinue
#endregion