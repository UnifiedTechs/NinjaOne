#Requires -Version 5.1
<#
.SYNOPSIS
Installs machine-wide Mozilla Firefox directly from Mozilla's official MSI.
.DESCRIPTION
Downloads the latest standard release in US English (not ESR).
Run as SYSTEM in NinjaOne or from an elevated PowerShell session. No required
variables. Supports Windows x64/x86; ARM64 is rejected explicitly.
Skips an existing machine-wide Firefox installation; this is not an updater.
Logs remain in ProgramData\UTS\Logs\FirefoxInstall. Download is removed afterward.
Exit codes: 0 success/already installed (including MSI 3010), 1 script failure,
otherwise the Windows Installer failure code. Reboot requirements are logged;
3010 is mapped to 0 so NinjaOne reports success. Never initiates a reboot.
Revision: 2026-11-11
#>

# Configurable settings
$DownloadAttempts = 3
$DownloadTimeoutSeconds = 300
$LogDirectory = Join-Path $env:ProgramData 'UTS\Logs\FirefoxInstall'
$DownloadUrls = @{
    AMD64 = 'https://download.mozilla.org/?product=firefox-msi-latest-ssl&os=win64&lang=en-US'
    x86   = 'https://download.mozilla.org/?product=firefox-msi-latest-ssl&os=win&lang=en-US'
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ExitCode = 1
$WorkDirectory = $null
$ScriptLog = $null
$OriginalSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol

function Write-Log {
    param([string]$Message)
    $Line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Output $Line
    if ($ScriptLog) { Add-Content -LiteralPath $ScriptLog -Value $Line -Encoding UTF8 }
}

function Get-MachineFirefox {
    $Roots = @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)})
    foreach ($Root in ($Roots | Where-Object { $_ } | Select-Object -Unique)) {
        $Executable = Join-Path $Root 'Mozilla Firefox\firefox.exe'
        if (Test-Path -LiteralPath $Executable -PathType Leaf) { return $Executable }
    }
}

try {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
    if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this script as SYSTEM or an administrator.'
    }

    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    $RunId = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N'))
    $ScriptLog = Join-Path $LogDirectory "$RunId-script.log"
    $MsiLog = Join-Path $LogDirectory "$RunId-msi.log"
    $Architecture = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $Architecture = $env:PROCESSOR_ARCHITEW6432 }
    if (-not $DownloadUrls.ContainsKey($Architecture)) {
        throw "Unsupported operating system architecture: $Architecture"
    }

    $InstalledFirefox = Get-MachineFirefox
    if ($InstalledFirefox) {
        $Version = (Get-Item -LiteralPath $InstalledFirefox).VersionInfo.ProductVersion
        Write-Log "Firefox $Version is already installed at $InstalledFirefox. Skipping."
        $ExitCode = 0
    }
    else {
        $WorkDirectory = Join-Path $env:TEMP "UTS-Firefox-$RunId"
        New-Item -ItemType Directory -Path $WorkDirectory | Out-Null
        $Installer = Join-Path $WorkDirectory 'Firefox.msi'
        $DownloadUrl = $DownloadUrls[$Architecture]
        [Net.ServicePointManager]::SecurityProtocol = $OriginalSecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        for ($Attempt = 1; $Attempt -le $DownloadAttempts; $Attempt++) {
            try {
                Write-Log "Downloading $DownloadUrl (attempt $Attempt of $DownloadAttempts)."
                Invoke-WebRequest -Uri $DownloadUrl -OutFile $Installer -UseBasicParsing -TimeoutSec $DownloadTimeoutSeconds
                if ((Get-Item -LiteralPath $Installer).Length -eq 0) { throw 'Downloaded installer is empty.' }
                break
            }
            catch {
                if ($Attempt -eq $DownloadAttempts) { throw }
                Write-Log "Download failed: $($_.Exception.Message). Retrying."
                Start-Sleep -Seconds 10
            }
        }

        $Signature = Get-AuthenticodeSignature -LiteralPath $Installer
        if ($Signature.Status -ne 'Valid' -or -not $Signature.SignerCertificate -or
            $Signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Mozilla Corporation(,|$)') {
            throw "Installer must have a valid Mozilla Corporation signature. Status: $($Signature.Status)"
        }
        Write-Log 'Mozilla Corporation signature verified. Starting silent machine-wide installation.'
        $MsiExec = Join-Path $env:WINDIR 'System32\msiexec.exe'
        $Arguments = '/i "{0}" /qn /norestart REBOOT=ReallySuppress /L*v "{1}"' -f $Installer, $MsiLog
        $Process = Start-Process -FilePath $MsiExec -ArgumentList $Arguments -Wait -PassThru
        $ExitCode = $Process.ExitCode
        Write-Log "Windows Installer exit code: $ExitCode. MSI log: $MsiLog"
        if ($ExitCode -notin @(0, 3010)) {
            throw "Firefox installation failed with MSI exit code $ExitCode."
        }
        $InstalledFirefox = Get-MachineFirefox
        if (-not $InstalledFirefox) {
            $ExitCode = 1
            throw 'MSI reported success, but the machine-wide Firefox executable was not found.'
        }
        $Version = (Get-Item -LiteralPath $InstalledFirefox).VersionInfo.ProductVersion
        Write-Log "Firefox $Version installed at $InstalledFirefox."
        if ($ExitCode -eq 3010) {
            Write-Log 'REBOOT REQUIRED: Installation succeeded; no reboot was initiated. Returning 0 for NinjaOne.'
            $ExitCode = 0
        }
    }
}
catch {
    if ($ExitCode -eq 0 -or $ExitCode -eq 3010) { $ExitCode = 1 }
    $FailureMessage = "ERROR: $($_.Exception.Message)"
    try { Write-Log $FailureMessage } catch { Write-Output $FailureMessage }
}
finally {
    [Net.ServicePointManager]::SecurityProtocol = $OriginalSecurityProtocol
    if ($WorkDirectory -and (Test-Path -LiteralPath $WorkDirectory)) {
        # Remove only this run's known installer and then its empty directory.
        try {
            $DownloadedFile = Join-Path $WorkDirectory 'Firefox.msi'
            if (Test-Path -LiteralPath $DownloadedFile) { Remove-Item -LiteralPath $DownloadedFile -Force }
            Remove-Item -LiteralPath $WorkDirectory -Force
        }
        catch { Write-Warning "Could not remove temporary download: $($_.Exception.Message)" }
    }
}
exit $ExitCode
