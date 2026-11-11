#Requires -Version 5.1

<#
.SYNOPSIS
    Checks active local IPv4 and IPv6 DHCP scopes for low lease capacity.
.DESCRIPTION
    Returns 0 with [Healthy] when all selected active scopes meet LeaseThreshold,
    1 with [Alert] when free leases are below LeaseThreshold, or 2 with [Error]
    when configuration, permissions, discovery, or a statistics check fails.
    Check failures take precedence over low capacity. A machine without the
    local DHCPServer service (the DHCP Server role) returns 0 with [Skipped],
    even if the management tools are installed. Discovery errors are failures.
    Only State = Active scopes are checked. No selected active scopes returns
    0 with [Skipped]; inactive scopes may be named in filters but aren't checked.
    This script only reads local configuration and statistics.
.PARAMETER LeaseThreshold
    Minimum free leases required. Default: 10. Must be a whole number from 0
    through 2147483647. Free leases equal to the threshold are healthy; 0
    disables low-capacity alerts while still checking for query failures.
.PARAMETER ExcludeScope
    Exact scope names to exclude, as a string array or comma-separated list.
    Names are trimmed and compared without case sensitivity; no wildcards.
.PARAMETER IncludeScope
    Exact scope names to include, as a string array or comma-separated list.
    If omitted, all active scopes are eligible. Unknown names and names present
    in both filters are configuration errors. Names must not contain commas.
.EXAMPLE
    .\Monitor-DHCP-ScopeCapacity.ps1 -LeaseThreshold 10
.EXAMPLE
    .\Monitor-DHCP-ScopeCapacity.ps1 -IncludeScope 'Office','Guest' -ExcludeScope 'Lab'
.NOTES
    Minimum OS: Windows Server 2016. Run in 64-bit Windows PowerShell 5.1 as
    SYSTEM or an elevated administrator. DHCP servers require the DhcpServer
    module. Missing tools, a stopped service, or access errors return 2.

    NinjaOne setup (manual; this file does not deploy or configure anything):
    Add this as a Windows PowerShell automation, architecture 64-bit, Run As
    System. Add optional script variables leaseThreshold (Integer, default 10),
    excludeScope (String), and includeScope (String). Use comma-separated scope
    names for the string variables. Empty or literal 'null' environment values
    mean unset. Explicit PowerShell parameters override environment variables.
    Schedule at the interval appropriate for the environment. Configure script
    result monitoring to distinguish exit 1 (low capacity) and exit 2 (check
    failure); exit 0 is healthy/skipped and must not alert. NinjaOne treats
    nonzero exits as failed automation runs, so use the exit code and the final
    status line to distinguish capacity alerts from failures to check.
    Review [Skipped] results if a server is expected to have active scopes.

    References:
    https://www.ninjaone.com/docs/endpoint-management/scripting-and-automation/automation-script-variable-types/
    https://www.ninjaone.com/docs/endpoint-management/scripting-and-automation/automation-library-faq/
    https://learn.microsoft.com/en-us/previous-versions/windows/desktop/dhcpserverpsprov/dhcpserverv6scopestatistics
#>

[CmdletBinding()]
param (
    $LeaseThreshold = 10,
    [string[]]$ExcludeScope,
    [string[]]$IncludeScope
)

function Test-IsElevated {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object System.Security.Principal.WindowsPrincipal($id)
    $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

try {
    # Service registration distinguishes the server role from RSAT alone.
    # Do this before input/elevation/module checks so non-DHCP devices skip.
    $DhcpService = @(Get-CimInstance -ClassName Win32_Service -Filter "Name='DHCPServer'" -ErrorAction Stop)
    if ($DhcpService.Count -eq 0) {
        Write-Host '[Skipped] DHCP Server is not installed on this device.'
        exit 0
    }

    if (-not $PSBoundParameters.ContainsKey('LeaseThreshold') -and
        -not [string]::IsNullOrWhiteSpace($env:leaseThreshold) -and $env:leaseThreshold -ne 'null') {
        $LeaseThreshold = $env:leaseThreshold
    }
    if (-not $PSBoundParameters.ContainsKey('ExcludeScope') -and
        -not [string]::IsNullOrWhiteSpace($env:excludeScope) -and $env:excludeScope -ne 'null') {
        $ExcludeScope = $env:excludeScope
    }
    if (-not $PSBoundParameters.ContainsKey('IncludeScope') -and
        -not [string]::IsNullOrWhiteSpace($env:includeScope) -and $env:includeScope -ne 'null') {
        $IncludeScope = $env:includeScope
    }

    $ParsedThreshold = 0
    if ($null -eq $LeaseThreshold -or
        ([string]$LeaseThreshold).Trim() -notmatch '^[0-9]+$' -or
        -not [int]::TryParse(([string]$LeaseThreshold).Trim(), [ref]$ParsedThreshold)) {
        throw 'LeaseThreshold must be a whole number from 0 through 2147483647.'
    }
    $LeaseThreshold = $ParsedThreshold

    # Normalize each entry, including arrays whose entries contain commas.
    if ($PSBoundParameters.ContainsKey('ExcludeScope') -and
        [string]::IsNullOrWhiteSpace(($ExcludeScope -join ''))) {
        throw 'ExcludeScope must contain at least one scope name when supplied.'
    }
    if ($PSBoundParameters.ContainsKey('IncludeScope') -and
        [string]::IsNullOrWhiteSpace(($IncludeScope -join ''))) {
        throw 'IncludeScope must contain at least one scope name when supplied.'
    }
    foreach ($FilterName in @('ExcludeScope', 'IncludeScope')) {
        $FilterValues = Get-Variable -Name $FilterName -ValueOnly
        if ($null -ne $FilterValues) {
            $FilterValues = @($FilterValues | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() })
            if ($FilterValues -contains '') {
                throw "$FilterName contains an empty scope name."
            }
            Set-Variable -Name $FilterName -Value @($FilterValues | Sort-Object -Unique)
        }
    }
    $SimilarItems = @($ExcludeScope | Where-Object { $null -ne $_ -and $IncludeScope -contains $_ })
    if ($SimilarItems.Count -gt 0) {
        throw "The following scopes are in both ExcludeScope and IncludeScope: $($SimilarItems -join ', ')"
    }

    if (-not (Test-IsElevated)) {
        throw 'Access Denied. Please run with Administrator privileges or as SYSTEM.'
    }
    if ($DhcpService.Count -ne 1 -or $DhcpService[0].State -ne 'Running') {
        throw 'The DHCP Server service is not running.'
    }
    if (-not (Get-Module -ListAvailable -Name DhcpServer -ErrorAction Stop)) {
        throw 'The DHCP Server role is installed but the DhcpServer module is missing.'
    }
    Import-Module DhcpServer -ErrorAction Stop

    # Discover once per address family, preserving inactive names for validation.
    $v4scopes = @(Get-DhcpServerv4Scope -ErrorAction Stop)
    $v6Scopes = @(Get-DhcpServerv6Scope -ErrorAction Stop)
    $AllScopes = @($v4scopes | Select-Object -ExpandProperty Name) + @($v6Scopes | Select-Object -ExpandProperty Name)
    foreach ($Name in @($IncludeScope) + @($ExcludeScope)) {
        if ($null -eq $Name) { continue }
        if ($Name -notin $AllScopes) {
            throw "Scope: $Name does not exist in the DHCP server. Please check the scope name."
        }
    }

    $ShouldAlert = $false
    $CheckFailed = $false
    $CheckedScopes = 0
    foreach ($scope in @($v4scopes) + @($v6Scopes)) {
        $Name = $scope.Name
        if ($scope.State -ne 'Active') { continue }
        if ($ExcludeScope -and $Name -in $ExcludeScope) { continue }
        if ($IncludeScope -and $Name -notin $IncludeScope) { continue }

        try {
            if ($null -ne $scope.PSObject.Properties['ScopeId']) {
                $Stats = @(Get-DhcpServerv4ScopeStatistics -ScopeId $scope.ScopeId -ErrorAction Stop)
            }
            else {
                $Stats = @(Get-DhcpServerv6ScopeStatistics -Prefix $scope.Prefix -ErrorAction Stop)
            }
            if ($Stats.Count -ne 1) {
                throw 'Expected exactly one statistics result.'
            }
            # Both CIM classes expose AddressesFree/AddressesInUse. Use decimal
            # to preserve UInt64 IPv6 counts and avoid overflow when totaling.
            $Free = [decimal]0
            $InUse = [decimal]0
            if ($null -eq $Stats[0].AddressesFree -or $null -eq $Stats[0].AddressesInUse -or
                -not [decimal]::TryParse([string]$Stats[0].AddressesFree, [ref]$Free) -or
                -not [decimal]::TryParse([string]$Stats[0].AddressesInUse, [ref]$InUse) -or
                $Free -lt 0 -or $InUse -lt 0 -or
                $Free -gt [decimal][uint64]::MaxValue -or $InUse -gt [decimal][uint64]::MaxValue -or
                $Free -ne [decimal]::Truncate($Free) -or $InUse -ne [decimal]::Truncate($InUse)) {
                throw 'Statistics are missing valid nonnegative whole-number address counts.'
            }
            $CheckedScopes++
            if ($Free -lt $LeaseThreshold) {
                Write-Host "[Alert] Scope: $Name Leases Used(In Use/Free/Total): $InUse/$Free/$($InUse + $Free)"
                $ShouldAlert = $true
            }
            else {
                Write-Host "[Info] Scope: $Name Leases Used(In Use/Free/Total): $InUse/$Free/$($InUse + $Free)"
            }
        }
        catch {
            Write-Host "[Error] Scope: $Name could not be checked: $($_.Exception.Message)"
            $CheckFailed = $true
        }
    }

    if ($CheckFailed) {
        Write-Host '[Error] DHCP capacity check incomplete. One or more scope checks failed.'
        exit 2
    }
    if ($ShouldAlert) {
        Write-Host '[Alert] Available DHCP leases low in one or more active scopes.'
        exit 1
    }
    if ($CheckedScopes -eq 0) {
        Write-Host '[Skipped] No active DHCP scopes matched the selected filters.'
        exit 0
    }
    Write-Host "[Healthy] All $CheckedScopes selected active DHCP scopes have at least $LeaseThreshold free leases."
    exit 0
}
catch {
    Write-Host "[Error] DHCP capacity check failed: $($_.Exception.Message)"
    exit 2
}
