# @Name:        Start, Stop or Restart a Service
# @Description: Starts, stops or restarts a Windows service by name or display name, shows dependent services first, waits for it to settle and reports the final state.
# @Admin:       Yes
# @Changes:     Yes
# @Target:      Local, Remote
# @Tags:        service, restart, start, stop

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Service name or display name, for example Spooler or "Print Spooler"')]
    [string]$Name,

    [ValidateSet('Restart', 'Start', 'Stop')]
    [string]$Action = 'Restart',

    [int]$TimeoutSeconds = 60,

    [Parameter(HelpMessage = 'Also stop services that depend on this one')]
    [switch]$IncludeDependents
)

$svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
if (-not $svc) { $svc = Get-Service -DisplayName $Name -ErrorAction SilentlyContinue }
if (-not $svc) { throw "No service named '$Name' on $env:COMPUTERNAME." }
if (@($svc).Count -gt 1) { throw "More than one service matches '$Name': $((@($svc) | ForEach-Object { $_.Name }) -join ', ')" }

$deps = @($svc.DependentServices | Where-Object { $_.Status -eq 'Running' })
Write-Host "$($svc.DisplayName) ($($svc.Name)) is $($svc.Status)" -ForegroundColor Cyan
if ($deps.Count) { Write-Host "Running services that depend on it: $(($deps | ForEach-Object { $_.Name }) -join ', ')" -ForegroundColor Yellow }
if ($deps.Count -and $Action -ne 'Start' -and -not $IncludeDependents) {
    Write-Host 'Tick IncludeDependents to allow stopping them as well.' -ForegroundColor Yellow
}

function Wait-State {
    param([string]$Want)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $svc.Refresh()
        if ([string]$svc.Status -eq $Want) { return $true }
        Start-Sleep -Milliseconds 500
    }
    $false
}

if (-not $PSCmdlet.ShouldProcess("$($svc.Name) on $env:COMPUTERNAME", $Action)) { return }

if ($Action -in @('Stop', 'Restart') -and $svc.Status -ne 'Stopped') {
    Stop-Service -InputObject $svc -Force:$IncludeDependents -ErrorAction Stop
    if (-not (Wait-State 'Stopped')) { Write-Host "Did not stop within $TimeoutSeconds s." -ForegroundColor Red }
    else { Write-Host 'Stopped.' -ForegroundColor Green }
}
if ($Action -in @('Start', 'Restart')) {
    Start-Service -InputObject $svc -ErrorAction Stop
    if (Wait-State 'Running') { Write-Host 'Running.' -ForegroundColor Green } else { Write-Host "Not running after $TimeoutSeconds s." -ForegroundColor Red }
    if ($Action -eq 'Restart' -and $IncludeDependents) {
        foreach ($d in $deps) { try { Start-Service -Name $d.Name -ErrorAction Stop; Write-Host "Started dependent $($d.Name)" -ForegroundColor Green } catch { Write-Host "Could not start $($d.Name)" -ForegroundColor Yellow } }
    }
}
$svc.Refresh()
[pscustomobject]@{ Computer = $env:COMPUTERNAME; Service = $svc.Name; DisplayName = $svc.DisplayName; Action = $Action; Status = [string]$svc.Status }
