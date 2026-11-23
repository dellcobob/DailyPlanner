# @Name:        Watch Log File (live)
# @Description: Shows the last lines of a log and keeps following it live, like Get-Content -Tail -Wait, with errors in red and warnings in yellow. Presets for CBS, DISM, Intune, ConfigMgr, Windows Setup and the firewall log. Press Stop to end.
# @Admin:       Yes
# @Changes:     No
# @Target:      Local, Remote
# @Tags:        log, tail, cbs, dism, intune, sccm, live, follow

[CmdletBinding()]
param(
    [ValidateSet('CBS (Windows servicing)', 'DISM', 'Intune Management Extension', 'ConfigMgr client', 'Windows Setup', 'Windows Firewall', 'Custom path')]
    [string]$Log = 'CBS (Windows servicing)',

    [Parameter(HelpMessage = 'Full path when Log is "Custom path"')]
    [string]$CustomPath = '',

    [Parameter(HelpMessage = 'How many existing lines to show first')]
    [int]$Tail = 20,

    [Parameter(HelpMessage = 'Only show lines matching this text or regex')]
    [string]$Filter = '',

    [Parameter(HelpMessage = 'Keep following new lines until you press Stop')]
    [bool]$Follow = $true
)

$paths = @{
    'CBS (Windows servicing)'     = "$env:SystemRoot\Logs\CBS\CBS.log"
    'DISM'                        = "$env:SystemRoot\Logs\DISM\dism.log"
    'Intune Management Extension' = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
    'ConfigMgr client'            = "$env:SystemRoot\CCM\Logs\CcmExec.log"
    'Windows Setup'               = "$env:SystemRoot\Panther\setupact.log"
    'Windows Firewall'            = "$env:SystemRoot\System32\LogFiles\Firewall\pfirewall.log"
}
$file = $CustomPath
if ($Log -ne 'Custom path') { $file = $paths[$Log] }
if (-not $file) { throw 'Enter a CustomPath.' }
if (-not (Test-Path -LiteralPath $file)) { throw "Log file not found on $env:COMPUTERNAME : $file" }

$item = Get-Item -LiteralPath $file
Write-Host ("== {0} on {1}  ({2:N1} MB, last written {3})" -f $file, $env:COMPUTERNAME, ($item.Length / 1MB), $item.LastWriteTime) -ForegroundColor Cyan
if ($Follow) { Write-Host '   Following new lines. Press Stop to end.' -ForegroundColor DarkGray }

# CMTrace-format logs (Intune, ConfigMgr) are turned into readable lines
$cm = '<!\[LOG\[(?<msg>.*?)\]LOG\]!><time="(?<time>[\d:]+)[^"]*" date="(?<date>[\d-]+)" component="(?<comp>[^"]*)"[^>]*type="(?<type>\d)"'

$p = @{ LiteralPath = $file; Tail = $Tail }
if ($Follow) { $p.Wait = $true }
Get-Content @p | ForEach-Object {
    $line = [string]$_
    $level = 0
    if ($line -match $cm) {
        $level = [int]$Matches['type'] - 1
        $line = '{0} {1}  {2}: {3}' -f $Matches['date'], $Matches['time'], $Matches['comp'], $Matches['msg']
    }
    if ($Filter -and $line -notmatch $Filter) { return }
    $color = 'Gray'
    if ($level -ge 2 -or $line -match '\b(error|failed|failure|fatal)\b|0x8[0-9a-f]{7}') { $color = 'Red' }
    elseif ($level -eq 1 -or $line -match '\bwarn(ing)?\b') { $color = 'Yellow' }
    elseif ($line -match '\b(success|succeeded|completed)\b') { $color = 'Green' }
    Write-Host $line -ForegroundColor $color
}
