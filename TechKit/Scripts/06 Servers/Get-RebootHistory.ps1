# @Name:        Reboot & Shutdown History
# @Description: When the computer restarted or shut down, who or what triggered it (Windows Update, a user, a program) and the reason given, including unexpected shutdowns.
# @Admin:       No
# @Changes:     No
# @Target:      Local, Remote
# @Tags:        reboot, shutdown, uptime, history, 1074, 6008

[CmdletBinding()]
param(
    [int]$Days = 30
)

$ids = 1074, 1076, 6005, 6006, 6008, 41
try {
    $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = $ids; StartTime = (Get-Date).AddDays(-$Days) } -ErrorAction Stop)
} catch {
    if ($_.Exception.Message -match 'No events were found') { Write-Host "No restart events in the last $Days days." -ForegroundColor Green; return }
    throw
}

$rows = foreach ($e in ($events | Sort-Object TimeCreated -Descending)) {
    $what = ''
    $who = ''
    $proc = ''
    $reason = ''
    switch ($e.Id) {
        1074 {
            $p = $e.Properties
            $proc = [string]$p[0].Value
            $reason = [string]$p[2].Value
            $what = [string]$p[4].Value
            $who = [string]$p[6].Value
            if ($p.Count -gt 5 -and $p[5].Value) { $reason = "$reason. Comment: $($p[5].Value)" }
        }
        1076 { $what = 'Shutdown reason recorded'; $reason = ($e.Message -split "`r?`n")[0] }
        6005 { $what = 'Started (event log service)' }
        6006 { $what = 'Clean shutdown' }
        6008 { $what = 'UNEXPECTED shutdown'; $reason = ($e.Message -split "`r?`n")[0] }
        41 { $what = 'Kernel power: rebooted without clean shutdown' }
    }
    [pscustomobject]@{
        Computer = $env:COMPUTERNAME
        Time     = $e.TimeCreated
        Event    = $e.Id
        What     = $what
        User     = $who
        Process  = ($proc -replace '^.*\\', '')
        Reason   = $reason
    }
}
$rows = @($rows)
$bad = @($rows | Where-Object { $_.Event -in @(6008, 41) }).Count
$boots = @($rows | Where-Object { $_.Event -eq 6005 }).Count
Write-Host "$boots start(s) in the last $Days days, $bad unexpected." -ForegroundColor $(if ($bad) { 'Yellow' } else { 'Cyan' })
$rows
