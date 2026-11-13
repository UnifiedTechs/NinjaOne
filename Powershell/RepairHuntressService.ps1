# Set up a condition in NinjaOne to detect if  any if these services are down and if so run this script.
# By Brian Cook - Unified Technology Solutions

# Set all Huntress services to start automatically
Set-Service -Name "HuntressAgent" -StartupType Automatic
Set-Service -Name "HuntressUpdater" -StartupType Automatic
Set-Service -Name "HuntressRio" -StartupType Automatic

# Start all Huntress services
Start-Service -Name "HuntressAgent"
Start-Service -Name "HuntressUpdater"
Start-Service -Name "HuntressRio"
