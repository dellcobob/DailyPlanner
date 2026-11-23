# @Name:        Antivirus / Defender Status
# @Description: Shows Microsoft Defender health (real-time protection, signature age, last scans, tamper protection) and any other antivirus registered with Windows Security. Optionally lists recent detections.
# @Admin:       No
# @Changes:     No
# @Target:      Local, Remote
# @Tags:        defender, antivirus, av, malware, edr

[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'Also list threats detected in the last 30 days (needs admin)')]
    [switch]$IncludeThreats
)

try {
    $av = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop)
    foreach ($a in $av) {
        $hex = '{0:X6}' -f [int]$a.productState
        $enabled = $hex.Substring(2, 2) -in @('10', '11')
        $current = $hex.Substring(4, 2) -eq '00'
        $color = $(if ($enabled -and $current) { 'Green' } else { 'Yellow' })
        Write-Host ("Registered AV: {0}  enabled={1}  up-to-date={2}" -f $a.displayName, $enabled, $current) -ForegroundColor $color
    }
} catch {
    Write-Host 'Windows Security Center is not available (normal on servers).' -ForegroundColor DarkGray
}

try {
    $s = Get-MpComputerStatus -ErrorAction Stop
} catch {
    Write-Host "Microsoft Defender is not reporting status: $($_.Exception.Message)" -ForegroundColor Yellow
    return
}
$sigAge = [int]$s.AntivirusSignatureAge
$problems = @()
if (-not $s.RealTimeProtectionEnabled) { $problems += 'Real-time protection is OFF' }
if (-not $s.AntivirusEnabled) { $problems += 'Antivirus is disabled' }
if ($sigAge -gt 3) { $problems += "Signatures are $sigAge days old" }
if ($s.QuickScanAge -gt 14 -and $s.FullScanAge -gt 30) { $problems += 'No recent scan' }
foreach ($p in $problems) { Write-Host $p -ForegroundColor Red }
if (-not $problems.Count) { Write-Host 'Defender looks healthy.' -ForegroundColor Green }

$tamper = $null
if ($s.PSObject.Properties['IsTamperProtected']) { $tamper = $s.IsTamperProtected }
$mode = $null
if ($s.PSObject.Properties['AMRunningMode']) { $mode = $s.AMRunningMode }

[pscustomobject]@{
    Computer              = $env:COMPUTERNAME
    RunningMode           = $mode
    AntivirusEnabled      = $s.AntivirusEnabled
    RealTimeProtection    = $s.RealTimeProtectionEnabled
    BehaviorMonitor       = $s.BehaviorMonitorEnabled
    TamperProtected       = $tamper
    SignatureVersion      = $s.AntivirusSignatureVersion
    SignatureUpdated      = $s.AntivirusSignatureLastUpdated
    SignatureAgeDays      = $sigAge
    LastQuickScan         = $s.QuickScanEndTime
    LastFullScan          = $s.FullScanEndTime
    EngineVersion         = $s.AMEngineVersion
    Status                = $(if ($problems.Count) { 'WARN' } else { 'OK' })
}

if ($IncludeThreats) {
    $since = (Get-Date).AddDays(-30)
    $threats = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object { $_.InitialDetectionTime -gt $since })
    if (-not $threats.Count) { Write-Host 'No detections in the last 30 days.' -ForegroundColor Green }
    $names = @{}
    Get-MpThreat -ErrorAction SilentlyContinue | ForEach-Object { $names[[string]$_.ThreatID] = $_.ThreatName }
    foreach ($t in $threats) {
        [pscustomobject]@{
            Detected  = $t.InitialDetectionTime
            Threat    = $names[[string]$t.ThreatID]
            Action    = $t.ActionSuccess
            Resources = (@($t.Resources) -join '; ')
            User      = $t.DomainUser
            Process   = $t.ProcessName
        }
    }
}
