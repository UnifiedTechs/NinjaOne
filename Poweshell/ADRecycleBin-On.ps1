#Script to determin if PC is an AD controller and if so Enable AD Recycle Bin and confirm it turned on.
# by Brian Cook - Unified Technology Solutions


$DomainRole = (Get-WmiObject -Class Win32_ComputerSystem).DomainRole
if ($DomainRole -eq 5) {
    # Specify the forest you want to enable the Recycle Bin on
    $forest = (Get-ADForest).Name
    Write-Output $forest
    # Check if the AD Recycle Bin is already enabled
    $recycleBinEnabled = (Get-ADOptionalFeature -Filter 'name -like "Recycle Bin Feature"' | 
        Where-Object { $_.EnabledScopes -ne $null })
    Write-Output $recycleBinEnabled

    if ($recycleBinEnabled) {
        # Note the AD Recyle Bin is already on
        Write-Output "AD Recycle Bin was already enabled on forest $forest."
        Ninja-Property-Set adRecycleBin "On"
        exit
    }
    else {
        # Enable the AD Recycle Bin feature
        Enable-ADOptionalFeature -Identity 'Recycle Bin Feature' `
            -Scope ForestOrConfigurationSet `
            -Target $forest `
            -Confirm $false
        Write-Output "Attempted to enable AD Recycle Bin."
    }

    # Confirm the AD Recycle Bin was enabled 
    $recycleBinEnabled = (Get-ADOptionalFeature -Filter 'name -like "Recycle Bin Feature"' | 
        Where-Object { $_.EnabledScopes -ne $null })

    if ($recycleBinEnabled) {
        #Set Status that it is on now.
        Write-Output "AD Recycle Bin has been enabled on forest $forest."
        Ninja-Property-Set adRecycleBin "On"
    }
    else {
        # Set Status that something went wrong.
        Write-Output "AD Recycle Bin has NOT been enabled on forest $forest."
        Ninja-Property-Set adRecycleBin "Script Failed to enable"
    }

}
else {
    Write-Output "This device is not a Primary Domain Controller."
    exit
}