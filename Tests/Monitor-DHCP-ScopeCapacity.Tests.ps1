#Requires -Version 5.1
<#
Run with Windows PowerShell 5.1:
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\Monitor-DHCP-ScopeCapacity.Tests.ps1
Uses isolated child processes with synthetic service/module/DHCP responses.
Only Test-IsElevated is replaced in a temporary script copy; the rest of the
production script is executed unchanged. No live DHCP configuration is touched.
#>
[CmdletBinding()]
param ()
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) {
    throw 'Run these tests with Windows PowerShell 5.1.'
}
$ScriptPath = Join-Path $PSScriptRoot '..\Powershell\Monitor-DHCP-ScopeCapacity.ps1'
$Tokens = $null
$ParseErrors = $null
$Ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$Tokens, [ref]$ParseErrors)
if ($ParseErrors.Count) { throw ($ParseErrors -join "`n") }
$Source = [IO.File]::ReadAllText($ScriptPath)
$Elevation = $Ast.Find({ param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'Test-IsElevated' }, $true)
$Source = $Source.Substring(0, $Elevation.Extent.StartOffset) +
    'function Test-IsElevated { return (-not $global:Fixture.NotElevated) }' +
    $Source.Substring($Elevation.Extent.EndOffset)
$TempRoot = Join-Path ([IO.Path]::GetTempPath()) ('DhcpCapacityTests-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $TempRoot)
$TestScript = Join-Path $TempRoot 'Monitor.ps1'
[IO.File]::WriteAllText($TestScript, $Source)
$Wrapper = Join-Path $TempRoot 'Invoke-Fixture.ps1'
[IO.File]::WriteAllText($Wrapper, @'
param($FixturePath, $TestScript)
$ErrorActionPreference = 'Stop'
$global:Fixture = Import-Clixml -LiteralPath $FixturePath
$env:leaseThreshold = $Fixture.EnvThreshold
$env:excludeScope = $Fixture.EnvExclude
$env:includeScope = $Fixture.EnvInclude
function Get-CimInstance {
    [CmdletBinding()]param($ClassName, $Filter)
    if ($Fixture.DiscoveryFailure) { Write-Error 'Synthetic service discovery failure'; return }
    if (-not $Fixture.Absent) {
        $State = 'Running'
        if ($Fixture.Stopped) { $State = 'Stopped' }
        [pscustomobject]@{ Name = 'DHCPServer'; State = $State }
    }
}
function Get-Module {
    [CmdletBinding()]param([switch]$ListAvailable, $Name)
    if (-not $Fixture.MissingModule) { [pscustomobject]@{Name = 'DhcpServer'} }
}
function Import-Module {
    [CmdletBinding()]param($Name)
    if ($Fixture.ImportFailure) { Write-Error 'Synthetic import failure' }
}
function Get-DhcpServerv4Scope {
    [CmdletBinding()]param()
    if ($Fixture.V4Failure) { Write-Error 'Synthetic IPv4 discovery failure'; return }
    $Fixture.V4
}
function Get-DhcpServerv6Scope {
    [CmdletBinding()]param()
    if ($Fixture.V6Failure) { Write-Error 'Synthetic IPv6 discovery failure'; return }
    $Fixture.V6
}
function Get-DhcpServerv4ScopeStatistics {
    [CmdletBinding()]param($ScopeId)
    if ($ScopeId -eq 'inactive' -or $ScopeId -eq 'excluded') { throw 'Queried a scope that should have been filtered out' }
    if ($Fixture.StatsFailure -or $ScopeId -eq 'fail') { Write-Error 'Synthetic statistics failure'; return }
    if ($Fixture.EmptyStats) { return }
    if ($Fixture.MultipleStats) { $Fixture.Stats; $Fixture.Stats; return }
    $Fixture.Stats
}
function Get-DhcpServerv6ScopeStatistics {
    [CmdletBinding()]param($Prefix)
    if ($Prefix -eq 'inactive' -or $Prefix -eq 'excluded') { throw 'Queried a scope that should have been filtered out' }
    if ($Fixture.StatsFailure) { Write-Error 'Synthetic IPv6 statistics failure'; return }
    $Fixture.Stats
}
$Arguments = $Fixture.Arguments
& $TestScript @Arguments
exit $LASTEXITCODE
'@)

function New-Fixture {
    @{
        Arguments = @{}
        V4 = @([pscustomobject]@{ Name = 'Office'; State = 'Active'; ScopeId = 'office' })
        V6 = @()
        Stats = [pscustomobject]@{ AddressesFree = [uint64]20; AddressesInUse = [uint64]100 }
    }
}
$Results = New-Object 'System.Collections.Generic.List[string]'
function Test-Case {
    param([string]$Name, [hashtable]$Fixture, [int]$ExpectedExit, [string]$ExpectedText, [string]$ForbiddenText = '')
    $FixturePath = Join-Path $TempRoot 'Fixture.clixml'
    $Fixture | Export-Clixml -LiteralPath $FixturePath
    $Output = (& "$PSHOME\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Wrapper $FixturePath $TestScript 2>&1 | Out-String)
    $ActualExit = $LASTEXITCODE
    if ($ActualExit -ne $ExpectedExit -or $Output -notmatch $ExpectedText -or ($ForbiddenText -and $Output -match $ForbiddenText)) {
        throw "$Name failed: exit $ActualExit (expected $ExpectedExit). Output:`n$Output"
    }
    $Results.Add("PASS: $Name")
}
try {
    $f = New-Fixture; Test-Case 'Healthy default threshold' $f 0 '\[Healthy\]'
    $f = New-Fixture; $f.Absent = $true; $f.MissingModule = $true; $f.NotElevated = $true; $f.Arguments.LeaseThreshold = 'bad'; Test-Case 'Absent server skips before prerequisites and validation' $f 0 '\[Skipped\]' '\[Alert\]|\[Error\]'
    $f = New-Fixture; $f.Absent = $true; Test-Case 'RSAT alone skips' $f 0 '\[Skipped\]' '\[Alert\]|\[Error\]'
    $f = New-Fixture; $f.DiscoveryFailure = $true; Test-Case 'Service discovery failure' $f 2 '\[Error\]'
    $f = New-Fixture; $f.MissingModule = $true; Test-Case 'Installed server missing module' $f 2 'module is missing'
    $f = New-Fixture; $f.ImportFailure = $true; Test-Case 'Import failure' $f 2 '\[Error\]'
    $f = New-Fixture; $f.Stopped = $true; Test-Case 'Stopped service' $f 2 'not running'
    $f = New-Fixture; $f.NotElevated = $true; Test-Case 'Access denied' $f 2 'Access Denied'
    foreach ($Value in @('-1', '1.5', 'abc', '', '2147483648', '1e2')) {
        $f = New-Fixture; $f.Arguments.LeaseThreshold = $Value; Test-Case "Invalid threshold '$Value'" $f 2 'LeaseThreshold must'
    }
    $f = New-Fixture; $f.Arguments.LeaseThreshold = $null; Test-Case 'Null threshold' $f 2 'LeaseThreshold must'
    $f = New-Fixture; $f.Stats.AddressesFree = 9; Test-Case 'Low IPv4 capacity' $f 1 '\[Alert\] Available'
    $f = New-Fixture; $f.Stats.AddressesFree = 10; Test-Case 'Threshold equality' $f 0 '\[Healthy\]'
    $f = New-Fixture; $f.Arguments.LeaseThreshold = 0; $f.Stats.AddressesFree = 0; Test-Case 'Zero threshold' $f 0 '\[Healthy\]'
    $f = New-Fixture; $f.EnvThreshold = '21'; Test-Case 'Environment threshold' $f 1 '\[Alert\]'
    $f = New-Fixture; $f.EnvThreshold = 'bad'; $f.Arguments.LeaseThreshold = 10; Test-Case 'Explicit threshold overrides environment' $f 0 '\[Healthy\]'
    $f = New-Fixture; $f.EnvThreshold = 'null'; $f.EnvInclude = 'null'; $f.EnvExclude = ' '; Test-Case 'Unset environment sentinels' $f 0 '\[Healthy\]'
    $f = New-Fixture; $f.EnvThreshold = 'bad'; Test-Case 'Invalid environment threshold' $f 2 'LeaseThreshold must'
    $f = New-Fixture; $f.Arguments.IncludeScope = 'Missing'; Test-Case 'Unknown include' $f 2 'does not exist'
    $f = New-Fixture; $f.Arguments.ExcludeScope = 'Missing'; Test-Case 'Unknown exclude' $f 2 'does not exist'
    $f = New-Fixture; $f.Arguments.IncludeScope = ' office '; $f.Arguments.ExcludeScope = 'OFFICE'; Test-Case 'Overlap after normalization' $f 2 'both ExcludeScope and IncludeScope'
    foreach ($Value in @('', 'Office,,Lab', ' , ')) {
        $f = New-Fixture; $f.Arguments.IncludeScope = $Value; Test-Case "Invalid include '$Value'" $f 2 '\[Error\]'
    }
    $f = New-Fixture; $f.V4 += [pscustomobject]@{Name='Lab';State='Active';ScopeId='excluded'}; $f.Arguments.IncludeScope = @(' office, OFFICE '); $f.Arguments.ExcludeScope = ' Lab '; Test-Case 'Trimmed CSV arrays and filters before statistics' $f 0 '\[Healthy\] All 1'
    $f = New-Fixture; $f.EnvInclude = ' office '; $f.EnvExclude = 'Lab'; $f.V4 += [pscustomobject]@{Name='Lab';State='Active';ScopeId='excluded'}; Test-Case 'Environment filters' $f 0 '\[Healthy\] All 1'
    $f = New-Fixture; $f.EnvInclude = 'Missing'; $f.Arguments.IncludeScope = 'Office'; Test-Case 'Explicit filter overrides environment' $f 0 '\[Healthy\]'
    $f = New-Fixture; $f.V4 += [pscustomobject]@{Name='Old';State='Inactive';ScopeId='inactive'}; $f.V6 = @([pscustomobject]@{Name='Old6';State='Inactive';Prefix='inactive'}); Test-Case 'Inactive IPv4 and IPv6 scopes ignored' $f 0 '\[Healthy\] All 1'
    $f = New-Fixture; $f.V4[0].State = 'Inactive'; $f.Arguments.IncludeScope = 'Office'; Test-Case 'Inactive include skips' $f 0 '\[Skipped\]'
    $f = New-Fixture; $f.Arguments.ExcludeScope = 'Office'; Test-Case 'All scopes excluded' $f 0 '\[Skipped\]'
    $f = New-Fixture; $f.V4 = @(); Test-Case 'No scopes' $f 0 '\[Skipped\]'
    $f = New-Fixture; $f.V4Failure = $true; Test-Case 'Nonterminating IPv4 discovery error' $f 2 '\[Error\]'
    $f = New-Fixture; $f.V6Failure = $true; Test-Case 'Nonterminating IPv6 discovery error' $f 2 '\[Error\]'
    $f = New-Fixture; $f.StatsFailure = $true; Test-Case 'Nonterminating statistics error' $f 2 'check incomplete'
    $f = New-Fixture; $f.EmptyStats = $true; Test-Case 'Missing statistics' $f 2 'check incomplete'
    $f = New-Fixture; $f.MultipleStats = $true; Test-Case 'Multiple statistics results' $f 2 'check incomplete'
    foreach ($Value in @($null, -1, 'bad', '1.5', '18446744073709551616')) {
        $f = New-Fixture; $f.Stats.AddressesFree = $Value; Test-Case "Invalid statistics '$Value'" $f 2 'check incomplete'
    }
    $f = New-Fixture; $f.Stats = [pscustomobject]@{Free=20;InUse=10}; Test-Case 'Missing CIM address properties' $f 2 'check incomplete'
    $f = New-Fixture; $f.Stats.AddressesFree = 1; $f.V4 += [pscustomobject]@{Name='Broken';State='Active';ScopeId='fail'}; Test-Case 'Failure takes precedence over low capacity' $f 2 'check incomplete'
    $f = New-Fixture; $f.V4 = @(); $f.V6 = @([pscustomobject]@{Name='IPv6';State='Active';Prefix='2001:db8::'}); $f.Stats.AddressesFree = 2; Test-Case 'Low IPv6 capacity' $f 1 '\[Alert\]'
    $f = New-Fixture; $f.V4 = @(); $f.V6 = @([pscustomobject]@{Name='IPv6';State='Active';Prefix='2001:db8::'}); $f.Stats.AddressesFree = [uint64]::MaxValue; $f.Stats.AddressesInUse = [uint64]1; Test-Case 'Exact UInt64 IPv6 counts and total' $f 0 '1/18446744073709551615/18446744073709551616'
    $f = New-Fixture; $f.V6 = @([pscustomobject]@{Name='IPv6';State='Active';Prefix='2001:db8::'}); Test-Case 'Both address families checked' $f 0 '\[Healthy\] All 2'
    $Results
    "Passed $($Results.Count) cases; parser passed; Windows PowerShell $($PSVersionTable.PSVersion)."
}
finally {
    # The temporary directory is created above under the OS temp directory.
    Remove-Item -LiteralPath $TestScript, $Wrapper, (Join-Path $TempRoot 'Fixture.clixml') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $TempRoot -Force -ErrorAction SilentlyContinue
}
