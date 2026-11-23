# @Name:        Fix Print Spooler
# @Description: Shows printers and stuck jobs, then stops the Print Spooler, clears the queue folder and starts it again. Tick List only to just look.
# @Admin:       Yes
# @Changes:     Yes
# @Target:      Local, Remote
# @Tags:        printer, spooler, queue, fix

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(HelpMessage = 'Only list printers and queued jobs, change nothing')]
    [switch]$ListOnly
)

$jobs = @(Get-CimInstance -ClassName Win32_PrintJob -ErrorAction SilentlyContinue)
$printers = @(Get-CimInstance -ClassName Win32_Printer -ErrorAction SilentlyContinue)
foreach ($p in $printers) {
    $count = @($jobs | Where-Object { $_.Name -like "$($p.Name),*" }).Count
    [pscustomobject]@{
        Printer = $p.Name
        Default = $p.Default
        Status  = $p.PrinterStatus
        Port    = $p.PortName
        Driver  = $p.DriverName
        Shared  = $p.Shared
        Jobs    = $count
    }
}
if ($jobs.Count) { Write-Host "$($jobs.Count) job(s) in the queue." -ForegroundColor Yellow } else { Write-Host 'The print queue is empty.' -ForegroundColor Green }
if ($ListOnly) { return }

$spoolDir = Join-Path $env:SystemRoot 'System32\spool\PRINTERS'
if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Stop Print Spooler, clear the queue folder, start Print Spooler')) {
    Write-Host 'Stopping Print Spooler...' -ForegroundColor Cyan
    Stop-Service -Name Spooler -Force -ErrorAction Stop
    $files = @(Get-ChildItem -LiteralPath $spoolDir -File -Force -ErrorAction SilentlyContinue)
    $files | Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Host "Removed $($files.Count) spool file(s)." -ForegroundColor Cyan
    Start-Service -Name Spooler -ErrorAction Stop
    $svc = Get-Service -Name Spooler
    if ($svc.Status -eq 'Running') { Write-Host 'Print Spooler is running again.' -ForegroundColor Green }
    else { Write-Host "Print Spooler status: $($svc.Status)" -ForegroundColor Red }
}
