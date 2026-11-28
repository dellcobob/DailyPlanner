# @Name:        Scheduled Tasks Audit
# @Description: Lists non-Microsoft scheduled tasks with who they run as, what they run, last result and next run. Flags tasks that run from user-writable folders or as SYSTEM.
# @Admin:       Yes
# @Changes:     No
# @Target:      Local, Remote
# @Tags:        scheduled tasks, persistence, audit, startup

[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'Include tasks under \Microsoft\ too')]
    [switch]$IncludeMicrosoft
)

$tasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $IncludeMicrosoft -or $_.TaskPath -notlike '\Microsoft\*' })
$risky = '\\(Users|ProgramData|Temp|AppData|Public|Downloads)\\|\\Windows\\Temp\\|%TEMP%|%APPDATA%|%LOCALAPPDATA%'
foreach ($t in $tasks) {
    $info = $null
    try { $info = $t | Get-ScheduledTaskInfo -ErrorAction Stop } catch { }
    $actions = @($t.Actions | ForEach-Object {
        if ($_.Execute) { ("$($_.Execute) $($_.Arguments)").Trim() } else { $_.CimClass.CimClassName }
    }) -join ' | '
    $runAs = $t.Principal.UserId
    if (-not $runAs) { $runAs = $t.Principal.GroupId }
    $flag = @()
    if ($actions -match $risky) { $flag += 'Runs from user-writable path' }
    if ($runAs -match 'SYSTEM' -and $actions -match 'powershell|cmd\.exe|wscript|cscript|mshta|rundll32') { $flag += 'Script host as SYSTEM' }
    if ($actions -match '-enc(odedcommand)?\s|FromBase64String|DownloadString|IEX') { $flag += 'Obfuscated/downloader command' }
    if ($flag.Count) { Write-Host "Review: $($t.TaskPath)$($t.TaskName)  -> $($flag -join '; ')" -ForegroundColor Yellow }
    $last = $null
    $lastResult = $null
    $next = $null
    if ($info) {
        $last = $info.LastRunTime
        if ($last -and $last.Year -lt 2000) { $last = $null }
        $lastResult = '0x{0:X}' -f [int64]$info.LastTaskResult
        $next = $info.NextRunTime
    }
    [pscustomobject]@{
        Computer   = $env:COMPUTERNAME
        Task       = "$($t.TaskPath)$($t.TaskName)"
        State      = [string]$t.State
        RunAs      = $runAs
        Action     = $actions
        LastRun    = $last
        LastResult = $lastResult
        NextRun    = $next
        Author     = $t.Author
        Review     = ($flag -join '; ')
    }
}
Write-Host "$($tasks.Count) task(s) checked on $env:COMPUTERNAME" -ForegroundColor Cyan
