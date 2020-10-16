param(
    [string] $VaultSubscriptionId,
    [string] $VaultResourceGroupName,
    [string] $VaultName,
    [string] $PrimaryRegion,
    [string] $DrRegion,
    [string] $DrResourceGroupId,
    [string] $SourceVmArmId,
    [string] $ProtectedItemName,
    [string] $RecoveryStagingStorageAccount,
    [string] $RecoveryReplicaDiskAccountType = 'Standard_LRS',
    [string] $RecoveryTargetDiskAccountType = 'Standard_LRS')

$VaultSubscriptionId
Write-Output ''
$message = 'Initiating Reverse replication in vault {0}.' -f $VaultName
Write-Output $message 

# Initialize the designated output of deployment script that can be accessed by various scripts in the template.
$DeploymentScriptOutputs = @{}

# Setup the vault context.
$message = 'Setting Vault context using vault {0} under resource group {1} in subscription {2}.' -f $VaultName, $VaultResourceGroupName, $VaultSubscriptionId
Write-Output $message
Select-AzSubscription -SubscriptionId $VaultSubscriptionId
$vault = Get-AzRecoveryServicesVault -ResourceGroupName $VaultResourceGroupName -Name $VaultName
Set-AzRecoveryServicesAsrVaultContext -vault $vault

# Look up the protected item and protection container mapping to be used for the enable replication.
$azureFabrics = get-asrfabric
$recFabric = $azureFabrics | where {$_.FabricSpecificDetails.Location -like $DrRegion -or $_.FabricSpecificDetails.Location -like $DrRegion.Replace(' ', '')}
$priFabric = $azureFabrics | where {$_.FabricSpecificDetails.Location -like $PrimaryRegion -or $_.FabricSpecificDetails.Location -like $PrimaryRegion.Replace(' ', '')}

$recContainer = Get-ASRProtectionContainer -Fabric $recFabric
$priContainer = Get-ASRProtectionContainer -Fabric $priFabric
$protectionContainerMappings = Get-ASRProtectionContainerMapping -ProtectionContainer $recContainer
$protectionContainerMapping = $protectionContainerMappings | where {$_.SourceProtectionContainerFriendlyName -like $recContainer.FriendlyName}
$rpi = Get-ASRReplicationProtectedItem -Name $ProtectedItemName -ProtectionContainer $priContainer 

Write-Output ''
$message = 'ProtectionContainermapping being used {0}' -f $protectionContainerMapping.ID
Write-Output $message

# Trigger Switch protection
# Retrieve DR VM.
$drResourceGroupName = $DrResourceGroupId.Split('/')[4]
$drVM = Get-AzVM -ResourceGroupName $drResourceGroupName -Name $ProtectedItemName
$message = 'Reverse replication to be triggered for {0}' -f $drVM.ID
$sourceVmResourceGroupId = $SourceVmArmId.Substring(0, $SourceVmArmId.ToLower().IndexOf('/providers'))
Write-Output $message

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
$job = Update-AzRecoveryServicesAsrProtectionDirection -AzureToAzure -LogStorageAccountId $RecoveryStagingStorageAccount  -ProtectionContainerMapping $protectionContainerMapping `
           -RecoveryResourceGroupId $sourceVmResourceGroupId -ReplicationProtectedItem $rpi

do {
    Start-Sleep -Seconds 50
    $job = Get-AsrJob -Job $job
    Write-Output $job.State
} while ($job.State -ne 'Succeeded' -and $job.State -ne 'Failed' -and $job.State -ne 'CompletedWithInformation')

$message = 'Reverse re plication completed. Waiting for IR.'
Write-Output $message

$targetObjectName = $job.TargetObjectName
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

$rpi = Get-ASRReplicationProtectedItem -Name $ProtectedItemName -ProtectionContainer $recContainer

$DeploymentScriptOutputs['ProtectedItemId'] = $rpi.ID
$DeploymentScriptOutputs