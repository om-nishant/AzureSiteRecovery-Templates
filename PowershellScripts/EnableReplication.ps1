param(
    [string] $VaultSubscriptionId,
    [string] $VaultResourceGroupName,
    [string] $VaultName,
    [string] $PrimaryFabricName,
    [string] $ProtectionContainerMappingName,
    [string] $TargetResourceGroupId,
    [string] $TargetVirtualNetworkId,
    [string] $SourceVmArmId,
    [string] $EnableProtectionName = $null,
    [string] $PrimaryStagingStorageAccount,
    [string] $RecoveryReplicaDiskAccountType = 'Standard_LRS',
    [string] $RecoveryTargetDiskAccountType = 'Standard_LRS')

Write-Output ''

$message = 'Enabling protection for virtual machine {0} in vault {1} using target resource group {2} and target virtual network {3}.' -f $SourceVmArmId, $VaultName, $TargetResourceGroupId, $TargetVirtualNetworkId
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
$priFabric = get-asrfabric -Name $PrimaryFabricName
$priContainer = Get-ASRProtectionContainer -Fabric $priFabric
$protectionContainerMapping = Get-ASRProtectionContainerMapping -Name $ProtectionContainerMappingName -ProtectionContainer $priContainer

Write-Output ''
$message = 'ProtectionContainermapping being used {0}' -f $protectionContainerMapping.ID
Write-Output $message

# Trigger Enable protection
$vmIdTokens = $SourceVmArmId.Split('/');
$vmName = $vmIdTokens[8]
$vmResourceGroupName = $vmIdTokens[4]
$vm = Get-AzVM -ResourceGroupName $vmResourceGroupName -Name $vmName
$message = 'Enable protection to be triggered for {0}' -f $vm.ID
Write-Output $message

$message = 'Storage account to be used {0}' -f $PrimaryStagingStorageAccount
Write-Output $message

if ($EnableProtectionName -eq $null -or $EnableProtectionName.Length -eq 0) {
    $message = 'Using VM name as Enable Protection name: {0}' -f $vmName
    Write-Output $message
    $EnableProtectionName = $vmName
}

$message = 'Enable protection name {0}' -f $EnableProtectionName
Write-Output $message

Write-Output ''

$diskList =  New-Object System.Collections.ArrayList

$osDisk =	New-AzRecoveryServicesAsrAzureToAzureDiskReplicationConfig -DiskId $Vm.StorageProfile.OsDisk.ManagedDisk.Id `
    -LogStorageAccountId $PrimaryStagingStorageAccount -ManagedDisk  -RecoveryReplicaDiskAccountType $RecoveryReplicaDiskAccountType `
    -RecoveryResourceGroupId  $TargetResourceGroupId -RecoveryTargetDiskAccountType $RecoveryTargetDiskAccountType          
$diskList.Add($osDisk)

foreach($dataDisk in $script:AzureArtifactsInfo.Vm.StorageProfile.DataDisks)
{
    $disk = New-AzRecoveryServicesAsrAzureToAzureDiskReplicationConfig -DiskId $dataDisk.ManagedDisk.Id `
        -LogStorageAccountId $PrimaryStagingStorageAccount -ManagedDisk  -RecoveryReplicaDiskAccountType $RecoveryReplicaDiskAccountType `
        -RecoveryResourceGroupId  $TargetResourceGroupId -RecoveryTargetDiskAccountType $RecoveryTargetDiskAccountType
    $diskList.Add($disk)
}

$message = 'Enable protection being triggered'
Write-Output $message

$job = New-ASRReplicationProtectedItem -Name $EnableProtectionName -ProtectionContainerMapping $protectionContainerMapping `
    -AzureVmId $SourceVmArmId -AzureToAzureDiskReplicationConfiguration $diskList -RecoveryResourceGroupId $TargetResourceGroupId `
    -RecoveryAzureNetworkId $TargetVirtualNetworkId

do {
    Start-Sleep -Seconds 50
    $job = Get-AsrJob -Job $job
    Write-Output $job.State
} while ($job.State -ne 'Succeeded' -and $job.State -ne 'Failed' -and $job.State -ne 'CompletedWithInformation')

$message = 'Enable protection completed. Waiting for IR.'
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

$rpi = Get-ASRReplicationProtectedItem -Name $EnableProtectionName -ProtectionContainer $priContainer

$DeploymentScriptOutputs['ProtectedItemId'] = $rpi.ID
$DeploymentScriptOutputs