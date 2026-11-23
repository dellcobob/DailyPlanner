# @Name:        Intune Devices Report
# @Description: Intune-managed devices with user, serial number, model, OS version, compliance, encryption and last check-in. Flags stale devices. Search by device name, user or serial to answer "which laptop does this person have?".
# @Admin:       No
# @Changes:     No
# @Target:      M365
# @Connect:     Graph
# @Scopes:      DeviceManagementManagedDevices.Read.All
# @Modules:     Microsoft.Graph.DeviceManagement
# @Tags:        intune, devices, asset, compliance, serial, endpoint

[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'Part of a device name, user UPN or serial number')]
    [string]$Search = '',

    [ValidateSet('All', 'Windows', 'iOS', 'Android', 'macOS')]
    [string]$Platform = 'All',

    [Parameter(HelpMessage = 'Flag devices that have not checked in for this many days')]
    [int]$StaleDays = 30,

    [switch]$NonCompliantOnly
)

if (-not (Get-MgContext)) { throw 'Not connected to Microsoft Graph. Click the Microsoft 365 button in Tech Kit first.' }
Write-Host 'Reading Intune devices...' -ForegroundColor Cyan
$devices = @(Get-MgDeviceManagementManagedDevice -All -ErrorAction Stop)
$now = Get-Date
$s = $Search.ToLowerInvariant()

$rows = foreach ($d in $devices) {
    if ($Platform -ne 'All' -and [string]$d.OperatingSystem -notlike "$Platform*") { continue }
    if ($s -and -not (([string]$d.DeviceName).ToLowerInvariant().Contains($s) -or ([string]$d.UserPrincipalName).ToLowerInvariant().Contains($s) -or ([string]$d.SerialNumber).ToLowerInvariant().Contains($s))) { continue }
    if ($NonCompliantOnly -and [string]$d.ComplianceState -eq 'compliant') { continue }
    $idle = $null
    if ($d.LastSyncDateTime) { $idle = [int]($now - [datetime]$d.LastSyncDateTime).TotalDays }
    [pscustomobject]@{
        Device      = $d.DeviceName
        User        = $d.UserPrincipalName
        OS          = $d.OperatingSystem
        OSVersion   = $d.OsVersion
        Compliance  = [string]$d.ComplianceState
        Encrypted   = $d.IsEncrypted
        LastSync    = $d.LastSyncDateTime
        DaysIdle    = $idle
        Stale       = $(if ($idle -ne $null -and $idle -gt $StaleDays) { 'Yes' } else { '' })
        Serial      = $d.SerialNumber
        Model       = "$($d.Manufacturer) $($d.Model)".Trim()
        Ownership   = [string]$d.ManagedDeviceOwnerType
        Enrolled    = $d.EnrolledDateTime
        StorageFreeGB = $(if ($d.FreeStorageSpaceInBytes) { [Math]::Round($d.FreeStorageSpaceInBytes / 1GB, 1) } else { $null })
    }
}
$rows = @($rows)
$non = @($rows | Where-Object { $_.Compliance -ne 'compliant' }).Count
$stale = @($rows | Where-Object { $_.Stale }).Count
Write-Host "$($rows.Count) device(s): $non not compliant, $stale not seen for $StaleDays+ days." -ForegroundColor $(if ($non -or $stale) { 'Yellow' } else { 'Green' })
$rows | Group-Object OS | Sort-Object Count -Descending | ForEach-Object { Write-Host ("  {0,5}  {1}" -f $_.Count, $_.Name) }
$rows | Sort-Object User, Device
