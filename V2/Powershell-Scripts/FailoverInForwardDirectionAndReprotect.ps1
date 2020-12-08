﻿param(
    [string] $VaultSubscriptionId,
    [string] $VaultResourceGroupName,
    [string] $VaultName,
    [string] $PrimaryRegion,
	[string[]] $SourceVmArmIds
	[string] $RecoveryStagingStorageAccount,
    [string] $RecoveryReplicaDiskAccountType = 'Standard_LRS',
    [string] $RecoveryTargetDiskAccountType = 'Standard_LRS')

$message = 'Performing Failover for virtual machine {0} in vault {1} using target resource group {2} and target virtual network {3}.' -f $SourceVmArmId, $VaultName, $TargetResourceGroupId, $TargetVirtualNetworkId
Write-Output $message 

# Initialize the designated output of deployment script that can be accessed by various scripts in the template.
$DeploymentScriptOutputs = @{}

# Setup the vault context.
$message = 'Setting Vault context using vault {0} under resource group {1} in subscription {2}.' -f $VaultName, $VaultResourceGroupName, $VaultSubscriptionId
Write-Output $message
Select-AzSubscription -SubscriptionId $VaultSubscriptionId
$vault = Get-AzRecoveryServicesVault -ResourceGroupName $VaultResourceGroupName -Name $VaultName
Set-AzRecoveryServicesAsrVaultContext -vault $vault

# Look up the protection container mapping to be used for the enable replication.
$priFabric = get-asrfabric | where {$_.FabricSpecificDetails.Location -like $PrimaryRegion -or $_.FabricSpecificDetails.Location -like $PrimaryRegion.Replace(' ', '')}
$priContainer = Get-ASRProtectionContainer -Fabric $priFabric
$recContainer = Get-ASRProtectionContainer -Fabric $recFab
$reverseContainerMapping = Get-ASRProtectionContainerMapping -ProtectionContainer $recContainer | where {$_.TargetProtectionContainerId -like $priContainer.Id}

$rpisInContainer = Get-ASRReplicationProtectedItem -ProtectionContainer $priContainer | where {$SourceVmArmIds -contains $_.ProviderSpecificDetails.FabricObjectId}

# Setup the vault context.
$message = 'Replication protected Items in Container:'
Write-Output $message
$rpisInContainer

$failoverJobs = New-Object System.Collections.ArrayList
$rpiLookUpByJobId = @{}
foreach ($rpi in $rpisInContainer) {
	# Trigger Failover.
	$message = 'Triggering failover for {0}.' -f $rpi.FriendlyName
	Write-Output $message
	$job = Start-ASRFO -ReplicationProtectedItem $rpi -Direction PrimaryToRecovery
	$failoverJobs.Add($job)
	$rpiLookUpByJobId[$job.Id] = $rpi
}

$failoverCommitJobs = New-Object System.Collections.ArrayList

foreach ($job in $failoverJobs) {
	do {
		Start-Sleep -Seconds 50
		$job = Get-AsrJob -Job $job
		Write-Output $job.State
	} while ($job.State -ne 'Succeeded' -and $job.State -ne 'Failed' -and $job.State -ne 'CompletedWithInformation')
	
	
	$message = 'Failover completed for {0} with state {1}. Starting commit FO.' -f $job.TargetObjectName, $job.State
	Write-Output $message
	$rpi = $rpiLookUpByJobId[$job.ID]
	$commitJob = Start-ASRCommitFailover -ReplicationProtectedItem $rpi
	$failoverCommitJobs.Add($commitJob)
	$rpiLookUpByJobId[$commitJob.Id] = $rpi
	
}

$reverseReplicationJobs = New-Object System.Collections.ArrayList
$drVmArmIds = New-Object System.Collections.ArrayList

foreach ($job in $failoverCommitJobs) {
	do {
		Start-Sleep -Seconds 50
		$job = Get-AsrJob -Job $job
		Write-Output $job.State
	} while ($job.State -ne 'Succeeded' -and $job.State -ne 'Failed' -and $job.State -ne 'CompletedWithInformation')

	$rpi = $rpiLookUpByJobId[$job.ID]
	$ProtectedItemName = $rpi.FriendlyName
	$message = 'Committed Failover for {0}.' -f $ProtectedItemName
	Write-Output ''
	
	$DrResourceGroupId = $rpi.ProviderSpecificDetails.RecoveryAzureResourceGroupId
	$drResourceGroupName = $DrResourceGroupId.Split('/')[4]
	$drVM = Get-AzVM -ResourceGroupName $drResourceGroupName -Name $ProtectedItemName
	$drVmArmIds.Add($drVM.Id)
	$message = 'Reverse replication to be triggered for {0}' -f $drVM.ID
	Write-Output $message
	$SourceVmArmId = $rpi.ProviderSpecificDetails.FabricObjectId
	$sourceVmResourceGroupId = $SourceVmArmId.Substring(0, $SourceVmArmId.ToLower().IndexOf('/providers'))

	$message = 'Storage account to be used {0}' -f $RecoveryStagingStorageAccount
	Write-Output $message
	
	# Prepare disk configuration.
	$diskList =  New-Object System.Collections.ArrayList
	$osDisk =	New-AzRecoveryServicesAsrAzureToAzureDiskReplicationConfig -DiskId $drVM.StorageProfile.OsDisk.ManagedDisk.Id `
		-LogStorageAccountId $RecoveryStagingStorageAccount -ManagedDisk  -RecoveryReplicaDiskAccountType $RecoveryReplicaDiskAccountType `
		-RecoveryResourceGroupId  $sourceVmResourceGroupId -RecoveryTargetDiskAccountType $RecoveryTargetDiskAccountType          
	$diskList.Add($osDisk)
	
	foreach($dataDisk in $drVM.StorageProfile.DataDisks)
	{
		$disk = New-AzRecoveryServicesAsrAzureToAzureDiskReplicationConfig -DiskId $dataDisk.ManagedDisk.Id `
			-LogStorageAccountId $RecoveryStagingStorageAccount -ManagedDisk  -RecoveryReplicaDiskAccountType $RecoveryReplicaDiskAccountType `
			-RecoveryResourceGroupId  $sourceVmResourceGroupId -RecoveryTargetDiskAccountType $RecoveryTargetDiskAccountType
		$diskList.Add($disk)
	}
	
	$message = 'Reverse replication being triggered'
	Write-Output $message
	$reverseReplciationJob = Update-AzRecoveryServicesAsrProtectionDirection -AzureToAzure -LogStorageAccountId $RecoveryStagingStorageAccount  -ProtectionContainerMapping 			$reverseContainerMapping  -RecoveryResourceGroupId $sourceVmResourceGroupId -ReplicationProtectedItem $rpi
	$reverseReplicationJobs.Add($reverseReplciationJob)	
}

foreach ($job in $reverseReplicationJobs) {
	$targetObjectName = $job.TargetObjectName

	do {
		Start-Sleep -Seconds 50
		$job = Get-AsrJob -Job $job
		Write-Output $job.State
	} while ($job.State -ne 'Succeeded' -and $job.State -ne 'Failed' -and $job.State -ne 'CompletedWithInformation')
	
	$message = 'Reverse replication completed for {0}. Waiting for IR.' -f $targetObjectName
	Write-Output $message
	
	$startTime = $job.StartTime
	$irFinished = $false
	do 
	{
		$irJobs = Get-ASRJob | where {$_.JobType -like '*IrCompletion' -and $_.TargetObjectName -eq $targetObjectName -and $_.StartTime -gt $startTime} | Sort-Object StartTime -Descending | select -First 2  
		if ($irJobs -ne $null -and $irJobs.Length -ne $0) {
			$secondaryIrJob = $irJobs | where {$_.JobType -like 'SecondaryIrCompletion'}
			if ($secondaryIrJob -ne $null -and $secondaryIrJob.Length -ge $1) {
				$irFinished = $secondaryIrJob.State -eq 'Succeeded' -or $secondaryIrJob.State -eq 'Failed'
			}
			else {
				$irFinished = $irJobs.State -eq 'Failed'
			}
		}
	
		if (-not $irFinished) {
			Start-Sleep -Seconds 50
		}
	} while (-not $irFinished)
}

$rpisInContainer = Get-ASRReplicationProtectedItem -ProtectionContainer $recContainer | where {$drVmArmIds -contains $_.ProviderSpecificDetails.FabricObjectId}
$reprotectedArmIds = New-Object System.Collections.ArrayList
$rpisInContainer | $reprotectedArmIds.Add($_.Id)

$DeploymentScriptOutputs['ReProtectedItemArmIds'] = $reprotectedArmIds -Join ','
$message = 'Reprotected Items ARM IDs {0}' -f $DeploymentScriptOutputs['ReProtectedItemArmIds']
Write-Output $message