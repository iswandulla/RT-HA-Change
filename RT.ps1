#-------------------------------------------------------------------------
#
# Copyright (c) Microsoft.  All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
#--------------------------------------------------------------------------
#
# High Availability (HA) Network Virtual Appliance (NVA) Failover Function
#
# This script provides a sample for monitoring HA NVA firewall status and performing
# failover and/or failback if needed.
#
# This script is used as part of an Azure function app called by a Timer Trigger event.  
#
# To configure this function app, the following items must be setup:
#
#   - Provision the pre-requisite Azure Resource Groups, Virtual Networks and Subnets, Network Virtual Appliances
#
#   - Create an Azure timer function app
#
#   - Set the Azure function app settings with credentials
#     SP_PASSWORD, SP_USERNAME, TENANTID, SUBSCRIPTIONID, AZURECLOUD must be added
#     AZURECLOUD = "AzureCloud" or "AzureUSGovernment"
#
#   - Set Firewall VM names and Resource Group in the Azure function app settings
#     FW1NAME, FW2NAME, FWMONITOR, FW1FQDN, FW1PORT, FW2FQDN, FW2PORT, FWRGNAME, FWTRIES, FWDELAY, FWUDRTAG must be added
#     FWMONITOR = "VMStatus" or "TCPPort" - If using "TCPPort", then also set FW1FQDN, FW2FQDN, FW1PORT and FW2PORT values
#
#   - Set Timer Schedule where positions represent: Seconds - Minutes - Hours - Day - Month - DayofWeek
#     Example:  "*/30 * * * * *" to run on multiples of 30 seconds
#     Example:  "0 */5 * * * *" to run on multiples of 5 minutes on the 0-second mark
# Will Mason Edits
# Because the code is leagacy i have done some work to prune its functionality
# The Majority of commands are AzureRM and eventualy will need to be updated to supported Azure Commands
# I have also removed the email alerting for this.  i will post it back in later or on another version.  This version is the source test version and will be used to make 
# the production function.  While the variables are hardcoded here, they will not be so in the final.
#
#--------------------------------------------------------------------------

Write-Output -InputObject "HA NVA timer trigger function executed at:$(Get-Date)"

#--------------------------------------------------------------------------
# Set firewall monitoring variables here
#--------------------------------------------------------------------------

$VMFW1Name = "VMXNC"      # Set the Name of the primary NVA firewall
$VMFW2Name = "VMXEUS"      # Set the Name of the secondary NVA firewall
$FW1RGName = "VMXCluster-NC"    # Set the ResourceGroup that contains FW1
$FW2RGName = "VMXCluster-EUS"     # Set the ResourceGroup that contains FW2
$Monitor = "VMStatus"     # "VMStatus" or "TCPPort" are valid values

#--------------------------------------------------------------------------
# The parameters below are required if using "TCPPort" mode for monitoring
#--------------------------------------------------------------------------

$TCPFW1Server = 23.101.170.222   # Hostname of the site to be monitored via the primary NVA firewall if using "TCPPort"
$TCPFW1Port = 80    # TCP Port of the site to be monitored via the primary NVA firewall if using "TCPPort"
$TCPFW2Server = 40.88.123.202   # Hostname of the site to be monitored via the secondary NVA firewall if using "TCPPort"
$TCPFW2Port = 80     # TCP Port of the site to be monitored via the secondary NVA firewall if using "TCPPort"

#--------------------------------------------------------------------------
# Set the failover and failback behavior for the firewalls
#--------------------------------------------------------------------------

$FailOver = $True              # Trigger to enable fail-over to secondary NVA firewall if primary NVA firewall drops when active
$FailBack = $True              # Trigger to enable fail-back to primary NVA firewall is secondary NVA firewall drops when active
$IntTries = "2"       # Number of Firewall tests to try 
$IntSleep = "3"       # Delay in seconds between tries

#--------------------------------------------------------------------------
# Code blocks for supporting functions
#--------------------------------------------------------------------------



Function Test-VMStatus ($VM, $FWResourceGroup) 
{
  $VMDetail = Get-AzVM -ResourceGroupName $FWResourceGroup -Name $VM -Status
  foreach ($VMStatus in $VMDetail.Statuses)
  { 
    $Status = $VMStatus.code
      
    if($Status.CompareTo('PowerState/running') -eq 0)
    {
      Return $False
    }
  }
  Return $True  
}

Function Test-TCPPort ($Server, $Port)
{
  $TCPClient = New-Object -TypeName system.Net.Sockets.TcpClient
  $Iar = $TCPClient.BeginConnect($Server, $Port, $Null, $Null)
  $Wait = $Iar.AsyncWaitHandle.WaitOne(1000, $False)
  return $Wait
}

Function Start-Failover 
{
  foreach ($SubscriptionID in $Script:ListOfSubscriptionIDs){
    Set-AzContext -SubscriptionId $SubscriptionID
    $RTable = @()
    $TagValue = 'MerakiHA'
    $Res = Get-AzResource -TagName nva_ha_udr -TagValue $TagValue

    foreach ($RTable in $Res)
    {
      $Table = Get-AzRouteTable -ResourceGroupName $RTable.ResourceGroupName -Name $RTable.Name
      
      foreach ($RouteName in $Table.Routes)
      {
        Write-Output -InputObject "Updating route table..."
        Write-Output -InputObject $RTable.Name

        for ($i = 0; $i -lt $PrimaryInts.count; $i++)
        {
          if($RouteName.NextHopIpAddress -eq $SecondaryInts[$i])
          {
            Write-Output -InputObject 'Secondary NVA is already ACTIVE' 
            
          }
          elseif($RouteName.NextHopIpAddress -eq $PrimaryInts[$i])
          {
            Set-AzRouteConfig -Name $RouteName.Name  -NextHopType VirtualAppliance -RouteTable $Table -AddressPrefix $RouteName.AddressPrefix -NextHopIpAddress $SecondaryInts[$i] 
          }
        }

      }
  
      $UpdateTable = [scriptblock]{param($Table) Set-AzRouteTable -RouteTable $Table}
      &$UpdateTable $Table

    }
  }

  

}

Function Start-Failback 
{
  foreach ($SubscriptionID in $Script:ListOfSubscriptionIDs)
  {
    Set-AzContext -SubscriptionId $SubscriptionID
    $TagValue = 'MerakiHA'
    $Res = Get-Azresource -TagName nva_ha_udr -TagValue $TagValue

    foreach ($RTable in $Res)
    {
      $Table = Get-AzRouteTable -ResourceGroupName $RTable.ResourceGroupName -Name $RTable.Name

      foreach ($RouteName in $Table.Routes)
      {
        Write-Output -InputObject "Updating route table..."
        Write-Output -InputObject $RTable.Name

        for ($i = 0; $i -lt $PrimaryInts.count; $i++)
        {
          if($RouteName.NextHopIpAddress -eq $PrimaryInts[$i])
          {
            Write-Output -InputObject 'Primary NVA is already ACTIVE' 
          
          }
          elseif($RouteName.NextHopIpAddress -eq $SecondaryInts[$i])
          {
            Set-AzRouteConfig -Name $RouteName.Name  -NextHopType VirtualAppliance -RouteTable $Table -AddressPrefix $RouteName.AddressPrefix -NextHopIpAddress $PrimaryInts[$i]
          }  
        }

      }  

      $UpdateTable = [scriptblock]{param($Table) Set-AzRouteTable -RouteTable $Table}
      &$UpdateTable $Table 

    }
  }

  

}

Function Get-FWInterfaces
{
  $Nics = Get-AzNetworkInterface | Where-Object -Property VirtualMachine -NE -Value $Null
  $VMS1 = Get-AzVM -Name $VMFW1Name -ResourceGroupName $FW1RGName
  $VMS2 = Get-AzVM -Name $VMFW2Name -ResourceGroupName $FW2RGName

  foreach($Nic in $Nics)
  {

    if (($Nic.VirtualMachine.Id -EQ $VMS1.Id) -Or ($Nic.VirtualMachine.Id -EQ $VMS2.Id)) 
    {
      $VM = $VMS | Where-Object -Property Id -EQ -Value $Nic.VirtualMachine.Id
      $Prv = $Nic.IpConfigurations | Select-Object -ExpandProperty PrivateIpAddress  

      if ($VM.Name -eq $VMFW1Name)
      {
        $Script:PrimaryInts += $Prv
      }
      elseif($VM.Name -eq $vmFW2Name)
      {
        $Script:SecondaryInts += $Prv
      }

    }

  }
}

Function Get-Subscriptions
{
  Write-Output -InputObject "Enumerating all subscriptins ..."
  $Script:ListOfSubscriptionIDs = (Get-Azsubscription).SubscriptionId
  Write-Output -InputObject $Script:ListOfSubscriptionIDs
}

#--------------------------------------------------------------------------
# Main code block for Azure function app                       
#--------------------------------------------------------------------------

$Password = ConvertTo-SecureString MJt8Q~GejHo5HUc_60fzJQMjI7cXsGYQPAPQIaM3 -AsPlainText -Force
$Credential = New-Object System.Management.Automation.PSCredential ("7788ac52-34cd-4119-8e5f-89b49887e7fe", $Password)
$AzureEnv = Get-AzEnvironment -Name AzureCloud
Add-AzAccount -ServicePrincipal -Tenant 663cbc2d-6d5d-43d1-90df-d94dfea99f85 -Credential $Credential -SubscriptionId a0a63775-8bdf-42e1-a9fe-83d6ac1810d7 -Environment $AzureEnv

$Context = Get-AzContext
Set-AzContext -Context $Context

$Script:PrimaryInts = @()
$Script:SecondaryInts = @()
$Script:ListOfSubscriptionIDs = @()

# Check NVA firewall status $intTries with $intSleep between tries

$CtrFW1 = 0
$CtrFW2 = 0
$FW1Down = $True
$FW2Down = $True

$VMS = Get-AzVM

Get-Subscriptions
Get-FWInterfaces

# Test primary and secondary NVA firewall status 

For ($Ctr = 1; $Ctr -le $IntTries; $Ctr++)
{
  
  if ($Monitor -eq 'VMStatus')
  {
    $FW1Down = Test-VMStatus -VM $VMFW1Name -FwResourceGroup $FW1RGName
    $FW2Down = Test-VMStatus -VM $VMFW2Name -FwResourceGroup $FW2RGName
  }

  if ($Monitor -eq 'TCPPort')
  {
    $FW1Down = -not (Test-TCPPort -Server $TCPFW1Server -Port $TCPFW1Port)
    $FW2Down = -not (Test-TCPPort -Server $TCPFW2Server -Port $TCPFW2Port)
  }

  Write-Output -InputObject "Pass $Ctr of $IntTries - FW1Down is $FW1Down, FW2Down is $FW2Down"

  if ($FW1Down) 
  {
    $CtrFW1++
  }

  if ($FW2Down) 
  {
    $CtrFW2++
  }

  Write-Output -InputObject "Sleeping $IntSleep seconds"
  Start-Sleep $IntSleep
}

# Reset individual test status and determine overall NVA firewall status

$FW1Down = $False
$FW2Down = $False

if ($CtrFW1 -eq $intTries) 
{
  $FW1Down = $True
}

if ($CtrFW2 -eq $intTries) 
{
  $FW2Down = $True
}

# Failover or failback if needed

if (($FW1Down) -and -not ($FW2Down))
{
  if ($FailOver)
  {
    Write-Output -InputObject 'FW1 Down - Failing over to FW2'
    Start-Failover 
  }
}
elseif (-not ($FW1Down) -and ($FW2Down))
{
  if ($FailBack)
  {
    Write-Output -InputObject 'FW2 Down - Failing back to FW1'
    Start-Failback
  }
  else 
  {
    Write-Output -InputObject 'FW2 Down - Failing back disabled'
  }
}
elseif (($FW1Down) -and ($FW2Down))
{
  Write-Output -InputObject 'Both FW1 and FW2 Down - Manual recovery action required'
 
}
else
{
  Write-Output -InputObject 'Both FW1 and FW2 Up - No action is required'
}
