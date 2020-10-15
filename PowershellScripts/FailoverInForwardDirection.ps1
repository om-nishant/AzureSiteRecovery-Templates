param(
    [string] $VaultSubscriptionId,
    [string] $VaultResourceGroupName,
    [string] $VaultName,
    [string] $PrimaryFabricName,
    [string] $EnableProtectionName)

Write-Output ''
$EnableProtectionName = 'omn-templateVM-01'
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
$rpi = Get-ASRReplicationProtectedItem -Name $EnableProtectionName -ProtectionContainer $priContainer

$message = 'Starting Failover for {0}.' -f $rpi.Id
Write-Output $message

$job = Start-ASRFO -ReplicationProtectedItem $rpi -Direction PrimaryToRecovery
do {
    Start-Sleep -Seconds 50
    $job = Get-AsrJob -Job $job
    Write-Output $job.State
} while ($job.State -ne 'Succeeded' -and $job.State -ne 'Failed' -and $job.State -ne 'CompletedWithInformation')

$message = 'Completed Failover for {0}.' -f $rpi.Id
Write-Output ''

$DeploymentScriptOutputs['ProtectedItemId'] = $rpi.ID
$DeploymentScriptOutputs