# Increase PST/OST file to 100GB for current user on PC.
# Written by Brian Cook - Unified Technology Solutions
# Run as System

# Get the currently logged-in user's username and SID
$session = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName
if (-not $session) {
    Write-Warning "No user currently logged in. Aborting."
    exit 1
}

# Split into domain and username
$domain, $username = $session -split '\\'

# Get the SID
$user = New-Object System.Security.Principal.NTAccount($domain, $username)
$sid = $user.Translate([System.Security.Principal.SecurityIdentifier]).Value

# Registry base path under HKEY_USERS
$regBase = "Registry::HKEY_USERS\$sid\Software\Microsoft\Office\16.0\Outlook\PST"

# Create the key if it doesn't exist
if (-not (Test-Path $regBase)) {
    New-Item -Path $regBase -Force | Out-Null
}

# Set registry values
New-ItemProperty -Path $regBase -Name "WarnLargeFileSize" -Value 97280 -PropertyType DWord -Force
New-ItemProperty -Path $regBase -Name "MaxLargeFileSize"  -Value 102400 -PropertyType DWord -Force
New-ItemProperty -Path $regBase -Name "WarnFileSize"     -Value 97280 -PropertyType DWord -Force
New-ItemProperty -Path $regBase -Name "MaxFileSize"       -Value 102400 -PropertyType DWord -Force

Write-Output ":white_check_mark: Registry updated for user $username ($sid)"