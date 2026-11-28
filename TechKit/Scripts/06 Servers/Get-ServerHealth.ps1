# @Name:        Server Health Check
# @Description: One line per server: uptime, CPU, memory, lowest disk, pending reboot, stopped automatic services, errors in the last 24 hours and days since patching, with an overall OK / WARN / FAIL. Put several servers in the Target box.
# @Admin:       No
# @Changes:     No
# @Target:      Local, Remote
# @Tags:        health, server, monitoring, cpu, memory, disk, uptime

[CmdletBinding()]
param(
    [int]$DiskWarnPercent = 15,
    [int]$MemoryWarnPercent = 90,
    [int]$CpuWarnPercent = 85
)

# A hashtable keeps the state shared with Set-Status whether this runs locally or over remoting
$state = @{ Status = 'OK' }
$notes = [System.Collections.Generic.List[string]]::new()
function Set-Status {
    param([string]$Level, [string]$Note)
    $notes.Add($Note)
    if ($Level -eq 'FAIL' -or ($Level -eq 'WARN' -and $state.Status -eq 'OK')) { $state.Status = $Level }
}

$os = Get-CimInstance -ClassName Win32_OperatingSystem
$uptime = (Get-Date) - $os.LastBootUpTime

$cpuSamples = @()
for ($i = 0; $i -lt 3; $i++) {
    $cpuSamples += (Get-CimInstance -ClassName Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
    if ($i -lt 2) { Start-Sleep -Milliseconds 700 }
}
$cpu = [int](($cpuSamples | Measure-Object -Average).Average)
if ($cpu -ge $CpuWarnPercent) { Set-Status 'WARN' "CPU $cpu%" }

$memUsed = [Math]::Round(100 * (1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize), 1)
if ($memUsed -ge $MemoryWarnPercent) { Set-Status 'WARN' "Memory $memUsed%" }

$disks = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType = 3' | Where-Object { $_.Size })
$low = $disks | Sort-Object { $_.FreeSpace / $_.Size } | Select-Object -First 1
$lowPct = $null
if ($low) {
    $lowPct = [Math]::Round(100 * $low.FreeSpace / $low.Size, 1)
    if ($lowPct -lt 5) { Set-Status 'FAIL' "$($low.DeviceID) $lowPct% free" } elseif ($lowPct -lt $DiskWarnPercent) { Set-Status 'WARN' "$($low.DeviceID) $lowPct% free" }
}

$pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
if ($pending) { Set-Status 'WARN' 'Reboot pending' }

$ignore = @('gupdate', 'gupdatem', 'sppsvc', 'RemoteRegistry', 'edgeupdate', 'edgeupdatem', 'MapsBroker', 'tiledatamodelsvc', 'WbioSrvc',
    'CDPSvc', 'ShellHWDetection', 'TrustedInstaller', 'wuauserv', 'BITS', 'UsoSvc', 'sacsvr', 'dmwappushservice', 'GoogleUpdaterService*', 'MicrosoftEdgeElevationService', 'OneSyncSvc*', 'CDPUserSvc*', 'WpnUserService*', 'Intel(R) TPM Provisioning Service')
$stopped = @(Get-CimInstance -ClassName Win32_Service -Filter "StartMode = 'Auto' AND State <> 'Running'" | Where-Object {
    $n = $_.Name
    -not ($ignore | Where-Object { $n -like $_ })
})
if ($stopped.Count) { Set-Status 'WARN' ("Stopped: " + (($stopped | Select-Object -First 4 | ForEach-Object { $_.Name }) -join ', ')) }

$errCount = 0
try {
    $errCount = @(Get-WinEvent -FilterHashtable @{ LogName = 'System', 'Application'; Level = 1, 2; StartTime = (Get-Date).AddHours(-24) } -MaxEvents 1000 -ErrorAction Stop).Count
} catch { }
if ($errCount -ge 50) { Set-Status 'WARN' "$errCount errors in 24h" }

$lastPatch = Get-HotFix -ErrorAction SilentlyContinue | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1
$patchDays = $null
if ($lastPatch) {
    $patchDays = [int]((Get-Date) - $lastPatch.InstalledOn).TotalDays
    if ($patchDays -gt 60) { Set-Status 'FAIL' "Not patched for $patchDays days" } elseif ($patchDays -gt 35) { Set-Status 'WARN' "Last patch $patchDays days ago" }
}

$status = $state.Status
$color = switch ($status) { 'OK' { 'Green' } 'WARN' { 'Yellow' } default { 'Red' } }
Write-Host ("{0,-5} {1}  {2}" -f $status, $env:COMPUTERNAME, ($notes -join '; ')) -ForegroundColor $color

[pscustomobject]@{
    Server         = $env:COMPUTERNAME
    Status         = $status
    OS             = ($os.Caption -replace 'Microsoft ', '')
    UptimeDays     = [Math]::Round($uptime.TotalDays, 1)
    CpuPercent     = $cpu
    MemoryPercent  = $memUsed
    MemoryGB       = [Math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    LowestDisk     = $(if ($low) { "$($low.DeviceID) $lowPct% free" } else { '' })
    PendingReboot  = $pending
    StoppedAuto    = $stopped.Count
    Errors24h      = $errCount
    DaysSincePatch = $patchDays
    Notes          = ($notes -join '; ')
}
