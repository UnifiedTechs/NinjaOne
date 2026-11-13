# Creates a Desktop shortcut to a website on the desktop of "All Users" profile using variables entered on run.
# By Brian Cook - Unified Technology Solutions


# NinjaOne Script Variables
# %WEBSITE_URL%      (String) - The URL to open, e.g., https://yourdomain.com
# %SHORTCUT_NAME%    (String) - The name of the shortcut, e.g., "Company Portal"

# These variables will be replaced by NinjaOne at runtime
$WebsiteURL = $env:websiteUrl
$ShortcutName = $env:shortcutName

# All Users desktop path
$PublicDesktopPath = "$env:Public\Desktop"

# Full path to the shortcut file
$ShortcutFile = Join-Path -Path $PublicDesktopPath -ChildPath "$ShortcutName.lnk"

# Optional: Remove existing shortcut if it exists
if (Test-Path $ShortcutFile) {
    Remove-Item $ShortcutFile -Force
}

# Create WScript.Shell COM object
$Shell = New-Object -ComObject WScript.Shell

# Create the shortcut
$Shortcut = $Shell.CreateShortcut($ShortcutFile)
$Shortcut.TargetPath = $WebsiteURL
$Shortcut.IconLocation = "C:\Windows\System32\shell32.dll, 220"  # Globe icon
$Shortcut.Save()

Write-Output "Shortcut '$ShortcutName' pointing to '$WebsiteURL' created on All Users desktop."