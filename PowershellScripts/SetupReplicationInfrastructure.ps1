param(
    [string] $VaultSubscriptionId,
    [string] $VaultResourceGroupName,
    [string] $VaultName,
    [string] $PrimaryRegion,
    [string] $RecoveryRegion,
    [string] $policyName = 'A2APolicy')

# Initialize the designated output of deployment script that can be accessed by various scripts in the template.
$DeploymentScriptOutputs = @{}

# Setup the vault context.
$message = 'Setting Vault context using vault {0} under resource group {1} in subscription {2}.' -f $VaultName, $VaultResourceGroupName, $VaultSubscriptionId
Write-Output $message
Select-AzSubscription -SubscriptionId $VaultSubscriptionId
$vault = Get-AzRecoveryServicesVault -ResourceGroupName $VaultResourceGroupName -Name $VaultName
Set-AzRecoveryServicesAsrVaultContext -vault $vault
$azureFabrics = get-asrfabric
Foreach($fabric in $azureFabrics) {
    $message = 'Fabric {0} in location {1}.' -f $fabric.Name, $fabric.FabricSpecificDetails.Location
    Write-Output $message
}

# Setup the fabrics. Create if the fabrics do not already exist.
$PrimaryRegion = $PrimaryRegion.Replace(' ', '')
$RecoveryRegion = $RecoveryRegion.Replace(' ', '')
$priFab = $azureFabrics | where {$_.FabricSpecificDetails.Location -like $PrimaryRegion}
if ($priFab -eq $null) {
    Write-Output 'Primary Fabric does not exist. Creating Primary Fabric.'
    $job = New-ASRFabric -Azure -Name $primaryRegion -Location $primaryRegion
    do {
        Start-Sleep -Seconds 50
        $job = Get-AsrJob -Job $job
    } while ($job.State -ne 'Succeeded' -and $job.State -ne 'Failed' -and $job.State -ne 'CompletedWithInformation')

    $priFab = get-asrfabric -Name $primaryRegion
    Write-Output 'Created Primary Fabric.'
}

$recFab = $azureFabrics | where {$_.FabricSpecificDetails.Location -eq $RecoveryRegion}
if ($recFab -eq $null) {
    Write-Output 'Recovery Fabric does not exist. Creating Recovery Fabric.'
    $job = New-ASRFabric -Azure -Name $recoveryRegion -Location $recoveryRegion
    do {
        Start-Sleep -Seconds 50
        $job = Get-AsrJob -Job $job
    } while ($job.State -ne 'Succeeded' -and $job.State -ne 'Failed' -and $job.State -ne 'CompletedWithInformation')

    $recFab = get-asrfabric -Name $RecoveryRegion
    Write-Output 'Created Recovery Fabric.'
}

$message = 'Primary Fabric {0}' -f $priFab.Id
Write-Output $message
$message = 'Recovery Fabric {0}' -f $recFab.Id
Write-Output $message

$DeploymentScriptOutputs['PrimaryFabric'] = $priFab.Name
$DeploymentScriptOutputs['RecoveryFabric'] = $recFab.Name

# Setup the Protection Containers. Create if the protection containers do not already exist.
$priContainer = Get-ASRProtectionContainer -Fabric $priFab
if ($priContainer -eq $null) {
    Write-Output 'Primary Protection container does not exist. Creating Primary Protection Container.'
    $job = New-AzRecoveryServicesAsrProtectionContainer -Name $priFab.Name.Replace(' ', '') -Fabric $priFab
    do {
        Start-Sleep -Seconds 50
        $job = Get-AsrJob -Job $job
    } while ($job.State -ne 'Succeeded' -and $job.State -ne 'Failed' -and $job.State -ne 'CompletedWithInformation')

    $priContainer = Get-ASRProtectionContainer -Name $priFab.Name -Fabric $priFab
    Write-Output 'Created Primary Protection Container.'
}

$recContainer = Get-ASRProtectionContainer -Fabric $recFab
if ($recContainer -eq $null) {
    Write-Output 'Recovery Protection container does not exist. Creating Recovery Protection Container.'
    $job = New-AzRecoveryServicesAsrProtectionContainer -Name $recFab.Name.Replace(' ', '') -Fabric $recFab
    do {
        Start-Sleep -Seconds 50
        $job = Get-AsrJob -Job $job
    } while ($job.State -ne 'Succeeded' -and $job.State -ne 'Failed' -and $job.State -ne 'CompletedWithInformation')

    $recContainer = Get-ASRProtectionContainer -Name $recFab.Name -Fabric $recFab
    Write-Output 'Created Recovery Protection Container.'
}


$message = 'Primary Protection Container {0}' -f $priContainer.Id
Write-Output $message
$message = 'Recovery Protection Container {0}' -f $recContainer.Id
Write-Output $message

$DeploymentScriptOutputs['PrimaryProtectionContainer'] = $priContainer.Name
$DeploymentScriptOutputs['RecoveryProtectionContainer'] = $recContainer.Name

$protectionContainerMappings = Get-ASRProtectionContainerMapping -ProtectionContainer $priContainer | where {$_.TargetProtectionContainerId -like $recContainer.Id}
if ($protectionContainerMappings -eq $null) {
    Write-Output 'Protection Container mapping does not already exist. Creating protection container.' 
    $policy = Get-ASRPolicy -Name $policyName
    if ($policy -eq $null) {
        Write-Output 'Replication policy does not already exist. Creating Replication policy.' 
        $job = New-ASRPolicy -AzureToAzure -Name $policyName -RecoveryPointRetentionInHours 1 -ApplicationConsistentSnapshotFrequencyInHours 1
        do {
            Start-Sleep -Seconds 50
            $job = Get-AsrJob -Job $job
        } while ($job.State -ne 'Succeeded' -and $job.State -ne 'Failed' -and $job.State -ne 'CompletedWithInformation')

        $policy = Get-ASRPolicy -Name $policyName
        Write-Output 'Created Replication policy.' 
    }

    $protectionContainerMappingName = $priContainer.Name +  "To" + $recContainer.Name
    $job = New-ASRProtectionContainerMapping -Name $protectionContainerMappingName -Policy $policy -PrimaryProtectionContainer $priContainer -RecoveryProtectionContainer $recContainer
    do {
        Start-Sleep -Seconds 50
        $job = Get-AsrJob -Job $job
    } while ($job.State -ne 'Succeeded' -and $job.State -ne 'Failed' -and $job.State -ne 'CompletedWithInformation')

    $protectionContainerMappings = Get-ASRProtectionContainerMapping -Name $protectionContainerMappingName -ProtectionContainer $priContainer
    Write-Output 'Created Protection Container mapping.'   
}

$message = 'Protection Container mapping {0}' -f $protectionContainerMappings.Id
Write-Output $message

$DeploymentScriptOutputs['ProtectionContainerMapping'] = $protectionContainerMappings.Name

# Log consolidated output.
Write-Output 'Infrastrucure Details'
foreach ($key in $DeploymentScriptOutputs.Keys)
{
    $message = '{0} : {1}' -f $key, $DeploymentScriptOutputs[$key]
    Write-Output $message
}
 
