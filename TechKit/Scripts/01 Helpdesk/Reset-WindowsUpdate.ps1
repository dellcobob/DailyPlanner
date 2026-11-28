# @Name:        Reset Windows Update
# @Description: Fixes stuck Windows Update: stops the update services, renames the SoftwareDistribution and catroot2 caches, and starts the services again.
# @Admin:       Yes
# @Changes:     Yes
# @Target:      Local, Remote
# @Tags:        windows update, fix, wuauserv, bits

[CmdletBinding(SupportsShouldProcess = $true)]
param()

$services = @('wuauserv', 'bits', 'cryptsvc', 'msiserver')
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$folders = @(
    (Join-Path $env:SystemRoot 'SoftwareDistribution'),
    (Join-Path $env:SystemRoot 'System32\catroot2')
)

if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Stop $($services -join ', '), rename update caches, start services")) {
    foreach ($f in $folders) { Write-Host "Would rename $f to $(Split-Path $f -Leaf).old-$stamp" }
    return
}

foreach ($s in $services) {
    $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Stopped') {
        Write-Host "Stopping $s..." -ForegroundColor Cyan
        Stop-Service -Name $s -Force -ErrorAction SilentlyContinue
    }
}
Start-Sleep -Seconds 2

foreach ($f in $folders) {
    if (-not (Test-Path -LiteralPath $f)) { continue }
    $newName = "$(Split-Path $f -Leaf).old-$stamp"
    try {
        Rename-Item -LiteralPath $f -NewName $newName -ErrorAction Stop
        Write-Host "Renamed $f -> $newName" -ForegroundColor Green
        [pscustomobject]@{ Computer = $env:COMPUTERNAME; Item = $f; Action = "Renamed to $newName"; Result = 'OK' }
    } catch {
        Write-Host "Could not rename $f : $($_.Exception.Message)" -ForegroundColor Red
        [pscustomobject]@{ Computer = $env:COMPUTERNAME; Item = $f; Action = 'Rename'; Result = 'FAIL' }
    }
}

foreach ($s in @('cryptsvc', 'bits', 'wuauserv')) {
    try {
        Start-Service -Name $s -ErrorAction Stop
        Write-Host "Started $s" -ForegroundColor Green
    } catch {
        Write-Host "Could not start $s : $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
Write-Host 'Done. Open Settings > Windows Update and check for updates. The .old folders can be deleted later.' -ForegroundColor Cyan
