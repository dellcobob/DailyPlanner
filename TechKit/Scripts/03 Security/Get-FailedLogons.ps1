# @Name:        Failed Logons & Lockouts
# @Description: Summarizes failed sign-ins (event 4625) and account lockouts (4740) from the Security log, grouped by account and source, with the reason in plain English.
# @Admin:       Yes
# @Changes:     No
# @Target:      Local, Remote
# @Tags:        security log, brute force, lockout, 4625, 4740, audit

[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'How far back to look')]
    [int]$Hours = 24,

    [Parameter(HelpMessage = 'Maximum events to read')]
    [int]$MaxEvents = 5000,

    [Parameter(HelpMessage = 'List each event instead of a grouped summary')]
    [switch]$ShowEach
)

$reasons = @{
    '0xc000006a' = 'Wrong password'; '0xc0000064' = 'User does not exist'; '0xc0000234' = 'Account locked out'
    '0xc0000072' = 'Account disabled'; '0xc000006f' = 'Outside allowed hours'; '0xc0000070' = 'Workstation not allowed'
    '0xc0000071' = 'Password expired'; '0xc0000193' = 'Account expired'; '0xc0000224' = 'Must change password'
    '0xc0000133' = 'Clock out of sync'; '0xc000015b' = 'Logon type not granted'; '0xc000006d' = 'Bad user name or password'
    '0xc0000413' = 'Authentication firewall'; '0xc000018c' = 'Trust failure'
}
$logonTypes = @{ '2' = 'Interactive'; '3' = 'Network'; '4' = 'Batch'; '5' = 'Service'; '7' = 'Unlock'; '8' = 'NetworkCleartext'; '10' = 'RDP'; '11' = 'Cached' }

$start = (Get-Date).AddHours(-$Hours)
$events = @()
try {
    $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4625, 4740; StartTime = $start } -MaxEvents $MaxEvents -ErrorAction Stop)
} catch {
    if ($_.Exception.Message -match 'No events were found') {
        Write-Host "No failed logons or lockouts in the last $Hours hours on $env:COMPUTERNAME." -ForegroundColor Green
        return
    }
    throw
}

$rows = foreach ($e in $events) {
    $x = [xml]$e.ToXml()
    $d = @{}
    foreach ($n in $x.Event.EventData.Data) { $d[$n.Name] = [string]$n.'#text' }
    if ($e.Id -eq 4625) {
        $sub = ([string]$d['SubStatus']).ToLowerInvariant()
        $st = ([string]$d['Status']).ToLowerInvariant()
        $why = $reasons[$sub]
        if (-not $why) { $why = $reasons[$st] }
        if (-not $why) { $why = "Status $st / $sub" }
        [pscustomobject]@{
            Time      = $e.TimeCreated
            Event     = 'Failed logon'
            Account   = "$($d['TargetDomainName'])\$($d['TargetUserName'])"
            Reason    = $why
            LogonType = $logonTypes[[string]$d['LogonType']]
            Source    = $(if ($d['IpAddress'] -and $d['IpAddress'] -ne '-') { $d['IpAddress'] } else { $d['WorkstationName'] })
            Process   = $d['ProcessName']
        }
    } else {
        [pscustomobject]@{
            Time      = $e.TimeCreated
            Event     = 'Lockout'
            Account   = $d['TargetUserName']
            Reason    = 'Account locked out'
            LogonType = ''
            Source    = $d['TargetDomainName']   # for 4740 this field holds the caller computer
            Process   = ''
        }
    }
}
$rows = @($rows)
Write-Host "$($rows.Count) event(s) in the last $Hours hours on $env:COMPUTERNAME" -ForegroundColor Cyan
$lock = @($rows | Where-Object { $_.Event -eq 'Lockout' })
if ($lock.Count) { Write-Host "$($lock.Count) lockout(s)." -ForegroundColor Yellow }

if ($ShowEach) {
    $rows | Sort-Object Time -Descending
    return
}
$rows | Group-Object Account, Source, Reason | Sort-Object Count -Descending | ForEach-Object {
    $first = $_.Group | Sort-Object Time | Select-Object -First 1
    $last = $_.Group | Sort-Object Time | Select-Object -Last 1
    if ($_.Count -ge 20) { Write-Host "Many failures: $($first.Account) from $($first.Source) ($($_.Count)x, $($first.Reason))" -ForegroundColor Red }
    [pscustomobject]@{
        Count     = $_.Count
        Account   = $first.Account
        Source    = $first.Source
        Reason    = $first.Reason
        LogonType = $first.LogonType
        FirstSeen = $first.Time
        LastSeen  = $last.Time
    }
}
