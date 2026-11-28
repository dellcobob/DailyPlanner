# @Name:        Recent Errors & Critical Events
# @Description: Groups Critical and Error events from the System and Application logs by source and ID, and calls out crashes, unexpected shutdowns, disk and NTFS problems.
# @Admin:       No
# @Changes:     No
# @Target:      Local, Remote
# @Tags:        event log, errors, critical, crash, bsod, disk

[CmdletBinding()]
param(
    [int]$Hours = 24,

    [ValidateSet('Both', 'System', 'Application')]
    [string]$Log = 'Both',

    [Parameter(HelpMessage = 'List every event instead of grouping')]
    [switch]$ShowEach,

    [int]$MaxEvents = 2000
)

$logs = @('System', 'Application')
if ($Log -ne 'Both') { $logs = @($Log) }
$events = @()
try {
    $events = @(Get-WinEvent -FilterHashtable @{ LogName = $logs; Level = 1, 2; StartTime = (Get-Date).AddHours(-$Hours) } -MaxEvents $MaxEvents -ErrorAction Stop)
} catch {
    if ($_.Exception.Message -match 'No events were found') { Write-Host "No errors in the last $Hours hours on $env:COMPUTERNAME." -ForegroundColor Green; return }
    throw
}

$known = @{
    'Microsoft-Windows-Kernel-Power|41'   = 'Unexpected power loss or hard reset'
    'EventLog|6008'                       = 'Unexpected shutdown'
    'Microsoft-Windows-WER-SystemErrorReporting|1001' = 'Blue screen (bugcheck)'
    'BugCheck|1001'                       = 'Blue screen (bugcheck)'
    'disk|7'                              = 'Bad block on disk'
    'disk|51'                             = 'Disk paging error'
    'disk|153'                            = 'Disk I/O retried'
    'Ntfs|55'                             = 'File system corruption'
    'Ntfs|98'                             = 'Volume needs chkdsk'
    'Microsoft-Windows-Ntfs|55'           = 'File system corruption'
    'Microsoft-Windows-Ntfs|98'           = 'Volume needs chkdsk'
    'Application Error|1000'              = 'Application crash'
    'Application Hang|1002'               = 'Application hang'
    'Service Control Manager|7031'        = 'Service crashed'
    'Service Control Manager|7034'        = 'Service terminated unexpectedly'
    'Service Control Manager|7000'        = 'Service failed to start'
    'Service Control Manager|7009'        = 'Service start timeout'
    'Microsoft-Windows-Time-Service|36'   = 'Time not synchronized'
    'NETLOGON|5719'                       = 'Could not reach a domain controller'
    'Microsoft-Windows-GroupPolicy|1129'  = 'Group Policy: no network connectivity to DC'
}

$rows = foreach ($e in $events) {
    $key = "$($e.ProviderName)|$($e.Id)"
    $msg = ''
    try { $msg = ($e.Message -split "`r?`n")[0] } catch { }
    if (-not $msg) { $msg = '(no message text)' }
    [pscustomobject]@{
        Time    = $e.TimeCreated
        Log     = $e.LogName
        Level   = $e.LevelDisplayName
        Source  = $e.ProviderName
        Id      = $e.Id
        Meaning = $known[$key]
        Message = $(if ($msg.Length -gt 200) { $msg.Substring(0, 197) + '...' } else { $msg })
    }
}
$rows = @($rows)
Write-Host "$($rows.Count) error/critical event(s) in the last $Hours hours on $env:COMPUTERNAME" -ForegroundColor Cyan
$rows | Where-Object { $_.Meaning } | Group-Object Meaning | ForEach-Object {
    Write-Host ("  {0,4}x  {1}" -f $_.Count, $_.Name) -ForegroundColor Yellow
}

if ($ShowEach) { $rows | Sort-Object Time -Descending; return }
$rows | Group-Object Source, Id | Sort-Object Count -Descending | ForEach-Object {
    $latest = $_.Group | Sort-Object Time -Descending | Select-Object -First 1
    [pscustomobject]@{
        Count    = $_.Count
        Source   = $latest.Source
        Id       = $latest.Id
        Level    = $latest.Level
        Meaning  = $latest.Meaning
        LastSeen = $latest.Time
        Message  = $latest.Message
    }
}
