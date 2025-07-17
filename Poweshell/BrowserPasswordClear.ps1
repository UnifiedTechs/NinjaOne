# powershell script to delete saved passwords in Microsoft edge, Firefox, and Google Chrome for all users.
# Usefull for Lab and shared computers
# by Brian Cook - Unified Technology Solutions

# Function to close processes
function Close-BrowserProcesses {
    param (
        [string]$ProcessName
    )
    $processes = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
    if ($processes) {
        Write-Host "Closing $ProcessName processes..."
        Stop-Process -Name $ProcessName -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2  # Wait briefly to ensure processes are terminated
    } else {
        Write-Host "$ProcessName is not running."
    }
}

# Close browser processes for Edge, Chrome, and Firefox
Close-BrowserProcesses -ProcessName "msedge"
Close-BrowserProcesses -ProcessName "chrome"
Close-BrowserProcesses -ProcessName "firefox"

# Get all user profiles
$users = Get-ChildItem -Path "C:\Users" -Directory

foreach ($user in $users) {
    # Microsoft Edge saved passwords
    $edgePath = "C:\Users\$($user.Name)\AppData\Local\Microsoft\Edge\User Data\Default\Login Data"
    if (Test-Path $edgePath) {
        try {
            Remove-Item -Path $edgePath -Force
            Write-Host "Deleted saved passwords for Microsoft Edge for user: $($user.Name)"
        } catch {
            Write-Host "Failed to delete Microsoft Edge passwords for user: $($user.Name) - $($_.Exception.Message)"
        }
    }

    # Google Chrome saved passwords
    $chromePath = "C:\Users\$($user.Name)\AppData\Local\Google\Chrome\User Data\Default\Login Data"
    if (Test-Path $chromePath) {
        try {
            Remove-Item -Path $chromePath -Force
            Write-Host "Deleted saved passwords for Google Chrome for user: $($user.Name)"
        } catch {
            Write-Host "Failed to delete Google Chrome passwords for user: $($user.Name) - $($_.Exception.Message)"
        }
    }

    # Firefox saved passwords
    $firefoxProfilePath = "C:\Users\$($user.Name)\AppData\Roaming\Mozilla\Firefox\Profiles"
    if (Test-Path $firefoxProfilePath) {
        Get-ChildItem -Path $firefoxProfilePath -Directory | ForEach-Object {
            $loginsJson = Join-Path -Path $_.FullName -ChildPath "logins.json"
            $key4Db = Join-Path -Path $_.FullName -ChildPath "key4.db"
            if (Test-Path $loginsJson) {
                try {
                    Remove-Item -Path $loginsJson -Force
                    Write-Host "Deleted logins.json (passwords) for Firefox for user: $($user.Name)"
                } catch {
                    Write-Host "Failed to delete logins.json for Firefox for user: $($user.Name) - $($_.Exception.Message)"
                }
            }
            if (Test-Path $key4Db) {
                try {
                    Remove-Item -Path $key4Db -Force
                    Write-Host "Deleted key4.db (encryption key) for Firefox for user: $($user.Name)"
                } catch {
                    Write-Host "Failed to delete key4.db for Firefox for user: $($user.Name) - $($_.Exception.Message)"
                }
            }
        }
    }
}

Write-Host "Password deletion process completed."