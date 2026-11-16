#Requires -Version 5.1
<#
.SYNOPSIS
Installs Adobe Acrobat Reader directly from Adobe for NinjaOne.
.DESCRIPTION
Run as SYSTEM or an administrator. No required variables or stored credentials.
Resolves the current continuous-track Reader installer (English UI) using Adobe's
public download page and service. Supports Windows x64/x86; rejects ARM64.
Skips existing machine-wide Acrobat or Reader, including paid Acrobat, to avoid
replacing an existing installation. This is an installer, not an updater.
Runs silently, accepts the Reader EULA, and suppresses automatic rebooting.
Logs: ProgramData\UTS\Logs\AdobeReaderInstall. Download removed afterward.
Exit codes: 0 success/already installed (including installer 3010), 1 script
failure, otherwise the installer failure code. Reboot requirements are logged.
Revision: 2026-11-16
#>

# Configurable settings
$DownloadAttempts = 3
$DownloadTimeoutSeconds = 1800
$MetadataTimeoutSeconds = 60
$X64Language = 'mui' # Adobe's x64 Reader catalog uses multilingual packages.
$X86Language = 'en'
$LogDirectory = Join-Path $env:ProgramData 'UTS\Logs\AdobeReaderInstall'
$DownloadPage = 'https://get.adobe.com/reader/enterprise/'
$ServiceRoot = 'https://rdc.adobe.io/reader'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ExitCode = 1
$WorkDirectory = $null
$ScriptLog = $null
$OriginalSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol
$OriginalProgressPreference = $ProgressPreference
$ProgressPreference = 'SilentlyContinue'

function Write-Log {
    param([string]$Message)
    $Line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Output $Line
    if ($ScriptLog) { Add-Content -LiteralPath $ScriptLog -Value $Line -Encoding UTF8 }
}

function Get-MachineAcrobat {
    $Roots = @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)})
    $RelativePaths = @(
        'Adobe\Acrobat DC\Acrobat\Acrobat.exe',
        'Adobe\Acrobat Reader DC\Reader\AcroRd32.exe',
        'Adobe\Reader 11.0\Reader\AcroRd32.exe',
        'Adobe\Acrobat 2020\Acrobat\Acrobat.exe',
        'Adobe\Acrobat 2017\Acrobat\Acrobat.exe'
    )
    foreach ($Root in ($Roots | Where-Object { $_ } | Select-Object -Unique)) {
        foreach ($RelativePath in $RelativePaths) {
            $Executable = Join-Path $Root $RelativePath
            if (Test-Path -LiteralPath $Executable -PathType Leaf) {
                return [pscustomobject]@{
                    Name = 'Adobe Acrobat/Reader'
                    Version = (Get-Item -LiteralPath $Executable).VersionInfo.ProductVersion
                    Path = $Executable
                }
            }
        }
    }
    # Registry views catch custom locations and older Acrobat installations.
    foreach ($View in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
        if ($View -eq [Microsoft.Win32.RegistryView]::Registry64 -and -not [Environment]::Is64BitOperatingSystem) { continue }
        $BaseKey = $null
        $UninstallKey = $null
        try {
            $BaseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $View)
            $UninstallKey = $BaseKey.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
            if (-not $UninstallKey) { continue }
            foreach ($SubKeyName in $UninstallKey.GetSubKeyNames()) {
                $Entry = $null
                try {
                    $Entry = $UninstallKey.OpenSubKey($SubKeyName)
                    if (-not $Entry) { continue }
                    $Name = [string]$Entry.GetValue('DisplayName')
                    if ($Name -match '^Adobe (Acrobat|Reader)(\s|\(|$)') {
                        return [pscustomobject]@{
                            Name = $Name
                            Version = [string]$Entry.GetValue('DisplayVersion')
                            Path = [string]$Entry.GetValue('InstallLocation')
                        }
                    }
                }
                finally { if ($Entry) { $Entry.Dispose() } }
            }
        }
        finally {
            if ($UninstallKey) { $UninstallKey.Dispose() }
            if ($BaseKey) { $BaseKey.Dispose() }
        }
    }
}

function Get-ReaderDownload {
    param([ValidateSet('AMD64', 'x86')][string]$Architecture)
    # Discover Adobe's public web-client identifier instead of storing an API key.
    # This is page configuration, not a customer credential. Fail if it changes.
    $Page = Invoke-WebRequest -Uri $DownloadPage -UseBasicParsing -TimeoutSec $MetadataTimeoutSeconds
    $AssetMatch = [regex]::Match($Page.Content, 'src=["''](?<path>/reader/[A-Za-z0-9]+/index\.js)["'']')
    if (-not $AssetMatch.Success) { throw 'Adobe download page format changed: index asset not found.' }
    $AssetUrl = 'https://get.adobe.com' + $AssetMatch.Groups['path'].Value
    $Asset = Invoke-WebRequest -Uri $AssetUrl -UseBasicParsing -TimeoutSec $MetadataTimeoutSeconds
    $ClientMatch = [regex]::Match($Asset.Content, 'api_key_prod\s*:\s*["''](?<value>[^"'']+)["'']')
    if (-not $ClientMatch.Success) { throw 'Adobe download page format changed: public client configuration not found.' }
    $PublicClient = [uri]::EscapeDataString($ClientMatch.Groups['value'].Value)
    $CatalogLanguage = if ($Architecture -eq 'AMD64') { $X64Language } else { $X86Language }
    $EscapedLanguage = [uri]::EscapeDataString($CatalogLanguage)
    # Adobe's catalog uses Windows 11 for x64 and Windows 10 for x86 packages.
    $CatalogOs = if ($Architecture -eq 'AMD64') { 'Windows%2011' } else { 'Windows%2010' }
    $Query = "os=$CatalogOs&site=enterprise&lang=$EscapedLanguage&api_key=$PublicClient"
    $Products = Invoke-RestMethod -Uri "$ServiceRoot/products?$Query" -TimeoutSec $MetadataTimeoutSeconds
    $Bitness = if ($Architecture -eq 'AMD64') { '64' } else { '32' }
    $Candidates = @($Products.products.reader | Where-Object { $_.displayName -match "Windows.*$Bitness[ -]?[Bb]it" })
    if ($Candidates.Count -eq 0) { throw "Adobe did not return a $Bitness-bit Reader installer." }
    $Product = $Candidates | Sort-Object { [version]$_.version } -Descending | Select-Object -First 1
    $ProductName = [uri]::EscapeDataString($Product.displayName)
    $Download = Invoke-RestMethod -Uri "$ServiceRoot/downloadUrl?name=$ProductName&$Query" -TimeoutSec $MetadataTimeoutSeconds
    $Uri = [uri]$Download.downloadURL
    if (-not $Uri.IsAbsoluteUri -or $Uri.Scheme -ne 'https' -or
        $Uri.Host -notmatch '^ardownload[0-9]*\.adobe\.com$' -or
        $Uri.AbsolutePath -notmatch '^/pub/adobe/(acrobat|reader)/win/AcrobatDC/[0-9]+/AcroRdr[^/]+\.exe$') {
        throw 'Adobe returned an unexpected installer URL. Refusing to download.'
    }
    [pscustomobject]@{ Url = $Uri.AbsoluteUri; Version = $Product.version; Name = $Product.displayName }
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
    if ($Architecture -notin @('AMD64', 'x86')) { throw "Unsupported OS architecture: $Architecture" }
    $Installed = Get-MachineAcrobat
    if ($Installed) {
        Write-Log "$($Installed.Name) $($Installed.Version) is already installed. Skipping. Location: $($Installed.Path)"
        $ExitCode = 0
    }
    else {
        [Net.ServicePointManager]::SecurityProtocol = $OriginalSecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $WorkDirectory = Join-Path $env:TEMP "UTS-AdobeReader-$RunId"
        New-Item -ItemType Directory -Path $WorkDirectory | Out-Null
        $Installer = Join-Path $WorkDirectory 'AdobeReader.exe'
        for ($Attempt = 1; $Attempt -le $DownloadAttempts; $Attempt++) {
            try {
                $Package = Get-ReaderDownload -Architecture $Architecture
                Write-Log "Downloading $($Package.Name) from $($Package.Url) (attempt $Attempt of $DownloadAttempts)."
                Invoke-WebRequest -Uri $Package.Url -OutFile $Installer -UseBasicParsing -TimeoutSec $DownloadTimeoutSeconds
                if ((Get-Item -LiteralPath $Installer).Length -eq 0) { throw 'Downloaded installer is empty.' }
                break
            }
            catch {
                if ($Attempt -eq $DownloadAttempts) { throw }
                Write-Log "Download lookup or transfer failed: $($_.Exception.Message). Retrying."
                Start-Sleep -Seconds 10
            }
        }
        $Signature = Get-AuthenticodeSignature -LiteralPath $Installer
        if ($Signature.Status -ne 'Valid' -or -not $Signature.SignerCertificate -or
            $Signature.SignerCertificate.Subject -notmatch '(^|,\s*)O="?Adobe (Inc\.|Systems Incorporated)"?(,|$)') {
            throw "Installer must have a valid Adobe signature. Status: $($Signature.Status)"
        }
        Write-Log 'Adobe signature verified. Starting silent machine-wide Reader installation.'
        $Arguments = '/sAll /rs /sl "1033" /msi /qn /norestart REBOOT=ReallySuppress ALLUSERS=1 EULA_ACCEPT=YES /L*v "{0}"' -f $MsiLog
        $Process = Start-Process -FilePath $Installer -ArgumentList $Arguments -Wait -PassThru
        $ExitCode = $Process.ExitCode
        Write-Log "Installer exit code: $ExitCode. MSI log: $MsiLog"
        if ($ExitCode -notin @(0, 3010)) { throw "Reader installation failed with exit code $ExitCode." }
        $Installed = Get-MachineAcrobat
        if (-not $Installed) {
            $ExitCode = 1
            throw 'Installer reported success, but Acrobat/Reader was not detected.'
        }
        Write-Log "$($Installed.Name) $($Installed.Version) installed. Location: $($Installed.Path)"
        if ($ExitCode -eq 3010) {
            Write-Log 'REBOOT REQUIRED: Installation succeeded; no reboot was initiated. Returning 0 for NinjaOne.'
            $ExitCode = 0
        }
    }
}
catch {
    if ($ExitCode -in @(0, 3010)) { $ExitCode = 1 }
    $FailureMessage = "ERROR: $($_.Exception.Message)"
    try { Write-Log $FailureMessage } catch { Write-Output $FailureMessage }
}
finally {
    [Net.ServicePointManager]::SecurityProtocol = $OriginalSecurityProtocol
    $ProgressPreference = $OriginalProgressPreference
    if ($WorkDirectory -and (Test-Path -LiteralPath $WorkDirectory)) {
        # Remove only the known download and this run's empty temporary directory.
        try {
            $DownloadedFile = Join-Path $WorkDirectory 'AdobeReader.exe'
            if (Test-Path -LiteralPath $DownloadedFile) { Remove-Item -LiteralPath $DownloadedFile -Force }
            Remove-Item -LiteralPath $WorkDirectory -Force
        }
        catch { Write-Warning "Could not remove temporary download: $($_.Exception.Message)" }
    }
}
exit $ExitCode
