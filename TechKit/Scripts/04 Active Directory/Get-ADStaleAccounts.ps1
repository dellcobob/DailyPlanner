# @Name:        Stale Users & Computers
# @Description: Finds enabled user and computer accounts that have not logged on for a number of days (or never), using lastLogonTimestamp. Good for cleanup and license reviews.
# @Admin:       No
# @Changes:     No
# @Target:      Local, Remote
# @Modules:     ActiveDirectory
# @Tags:        ad, stale, inactive, cleanup, audit

[CmdletBinding()]
param(
    [int]$Days = 90,

    [ValidateSet('Both', 'Users', 'Computers')]
    [string]$Type = 'Both',

    [Parameter(HelpMessage = 'Include accounts that are already disabled')]
    [switch]$IncludeDisabled,

    [Parameter(HelpMessage = 'Only search under this OU (distinguished name). Empty = whole domain.')]
    [string]$SearchBase = ''
)

Import-Module ActiveDirectory -ErrorAction Stop
$cutoff = (Get-Date).AddDays(-$Days)
$filter = "Enabled -eq 'True'"
if ($IncludeDisabled) { $filter = '*' }
$common = @{ Filter = $filter; ErrorAction = 'Stop' }
if ($SearchBase) { $common.SearchBase = $SearchBase }

$out = [System.Collections.Generic.List[object]]::new()
if ($Type -in @('Both', 'Users')) {
    Get-ADUser @common -Properties LastLogonDate, whenCreated, PasswordLastSet, Description | ForEach-Object {
        $last = $_.LastLogonDate
        if (($last -and $last -lt $cutoff) -or (-not $last -and $_.whenCreated -lt $cutoff)) {
            $out.Add([pscustomobject]@{
                Type = 'User'; Name = $_.Name; SamAccountName = $_.SamAccountName; Enabled = $_.Enabled
                LastLogon = $last; DaysInactive = $(if ($last) { [int]((Get-Date) - $last).TotalDays } else { 'Never' })
                PasswordLastSet = $_.PasswordLastSet; Created = $_.whenCreated; OS = ''; Description = $_.Description
                OU = ($_.DistinguishedName -split ',', 2)[1]
            })
        }
    }
}
if ($Type -in @('Both', 'Computers')) {
    Get-ADComputer @common -Properties LastLogonDate, whenCreated, PasswordLastSet, OperatingSystem, Description | ForEach-Object {
        $last = $_.LastLogonDate
        if (($last -and $last -lt $cutoff) -or (-not $last -and $_.whenCreated -lt $cutoff)) {
            $out.Add([pscustomobject]@{
                Type = 'Computer'; Name = $_.Name; SamAccountName = $_.SamAccountName; Enabled = $_.Enabled
                LastLogon = $last; DaysInactive = $(if ($last) { [int]((Get-Date) - $last).TotalDays } else { 'Never' })
                PasswordLastSet = $_.PasswordLastSet; Created = $_.whenCreated; OS = $_.OperatingSystem; Description = $_.Description
                OU = ($_.DistinguishedName -split ',', 2)[1]
            })
        }
    }
}
$users = @($out | Where-Object { $_.Type -eq 'User' }).Count
$comps = @($out | Where-Object { $_.Type -eq 'Computer' }).Count
Write-Host "Inactive for $Days+ days: $users user(s), $comps computer(s). lastLogonTimestamp can lag up to 14 days." -ForegroundColor Cyan
$out | Sort-Object Type, LastLogon
