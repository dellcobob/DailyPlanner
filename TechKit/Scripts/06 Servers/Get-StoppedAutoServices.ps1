# @Name:        Stopped Automatic Services
# @Description: Lists services set to start automatically that are not running, skipping ones that normally stop on their own. Use "Start, Stop or Restart a Service" to start one.
# @Admin:       No
# @Changes:     No
# @Target:      Local, Remote
# @Tags:        services, stopped, automatic, health

[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'Extra service names to ignore (wildcards allowed)')]
    [string[]]$Ignore = @(),

    [Parameter(HelpMessage = 'Show every stopped automatic service, including the usual harmless ones')]
    [switch]$ShowAll
)

$harmless = @('gupdate', 'gupdatem', 'sppsvc', 'RemoteRegistry', 'edgeupdate', 'edgeupdatem', 'MapsBroker', 'tiledatamodelsvc', 'WbioSrvc',
    'CDPSvc', 'ShellHWDetection', 'TrustedInstaller', 'wuauserv', 'BITS', 'UsoSvc', 'sacsvr', 'dmwappushservice', 'GoogleUpdaterService*',
    'MicrosoftEdgeElevationService', 'OneSyncSvc*', 'CDPUserSvc*', 'WpnUserService*', 'Intel(R) TPM Provisioning Service', 'clr_optimization*',
    'gpsvc', 'DoSvc', 'WaaSMedicSvc', 'StateRepository', 'NetTcpPortSharing', 'AGMService', 'AGSService')
$skip = @($Ignore)
if (-not $ShowAll) { $skip += $harmless }

$delayed = @{}
Get-ChildItem -Path 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction SilentlyContinue | ForEach-Object {
    $v = (Get-ItemProperty -Path $_.PSPath -Name DelayedAutostart -ErrorAction SilentlyContinue).DelayedAutostart
    if ($v -eq 1) { $delayed[$_.PSChildName] = $true }
}

$svcs = @(Get-CimInstance -ClassName Win32_Service -Filter "StartMode = 'Auto' AND State <> 'Running'" | Where-Object {
    $n = $_.Name
    -not ($skip | Where-Object { $n -like $_ })
})
if (-not $svcs.Count) { Write-Host "All automatic services are running on $env:COMPUTERNAME." -ForegroundColor Green; return }
Write-Host "$($svcs.Count) automatic service(s) not running on $env:COMPUTERNAME" -ForegroundColor Yellow
$svcs | Sort-Object DisplayName | ForEach-Object {
    [pscustomobject]@{
        Computer    = $env:COMPUTERNAME
        Name        = $_.Name
        DisplayName = $_.DisplayName
        State       = $_.State
        Start       = $(if ($delayed[$_.Name]) { 'Auto (delayed)' } else { 'Auto' })
        ExitCode    = $_.ExitCode
        RunAs       = $_.StartName
        Path        = $_.PathName
    }
}
