# @Name:        Wi-Fi Status
# @Description: Shows the current Wi-Fi connection (SSID, signal, band, channel, speed, security) and optionally nearby networks and saved profiles. Passwords are never shown.
# @Admin:       No
# @Changes:     No
# @Target:      Local, Remote
# @Tags:        wifi, wireless, wlan, signal, ssid

[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'List nearby networks with signal strength (Windows 11 may need location access)')]
    [switch]$ShowNearby,

    [Parameter(HelpMessage = 'List saved Wi-Fi profile names')]
    [switch]$ShowProfiles
)

function ConvertFrom-NetshBlock {
    param([string[]]$Lines)
    $h = [ordered]@{}
    foreach ($l in $Lines) {
        if ($l -match '^\s{2,}([^:]+?)\s*:\s(.*)$') { $h[$Matches[1].Trim()] = $Matches[2].Trim() }
    }
    $h
}

$svc = Get-Service -Name WlanSvc -ErrorAction SilentlyContinue
if (-not $svc -or $svc.Status -ne 'Running') {
    Write-Host 'The WLAN AutoConfig service is not running (no Wi-Fi adapter, or a server without the Wireless LAN feature).' -ForegroundColor Yellow
    return
}

$raw = @(netsh.exe wlan show interfaces)
$blocks = @()
$current = @()
foreach ($l in $raw) {
    if ($l -match '^\s+Name\s+:' -and $current.Count) { $blocks += , $current; $current = @() }
    $current += $l
}
if ($current.Count) { $blocks += , $current }

foreach ($b in $blocks) {
    $h = ConvertFrom-NetshBlock $b
    if (-not $h['Name']) { continue }
    $signal = $h['Signal']
    $pct = 0
    if ($signal -match '(\d+)') { $pct = [int]$Matches[1] }
    $color = 'Green'
    if ($pct -lt 40) { $color = 'Red' } elseif ($pct -lt 65) { $color = 'Yellow' }
    if ($h['State'] -match 'connected' -and $h['SSID']) {
        Write-Host ("{0}: connected to '{1}' at {2} signal" -f $h['Name'], $h['SSID'], $signal) -ForegroundColor $color
    } else {
        Write-Host ("{0}: {1}" -f $h['Name'], $h['State']) -ForegroundColor Yellow
    }
    [pscustomobject]@{
        Adapter   = $h['Name']
        State     = $h['State']
        SSID      = $h['SSID']
        BSSID     = $h['AP BSSID']
        Signal    = $signal
        Radio     = $h['Radio type']
        Band      = $h['Band']
        Channel   = $h['Channel']
        Receive   = $h['Receive rate (Mbps)']
        Transmit  = $h['Transmit rate (Mbps)']
        Auth      = $h['Authentication']
        Cipher    = $h['Cipher']
        Profile   = $h['Profile']
    }
}

if ($ShowNearby) {
    Write-Host '== Nearby networks' -ForegroundColor Cyan
    $ssid = $null
    $auth = $null
    foreach ($l in @(netsh.exe wlan show networks mode=bssid)) {
        if ($l -match '^SSID \d+ : (.*)$') { $ssid = $Matches[1].Trim(); if (-not $ssid) { $ssid = '(hidden)' } }
        elseif ($l -match '^\s+Authentication\s+:\s(.*)$') { $auth = $Matches[1].Trim() }
        elseif ($l -match '^\s+BSSID \d+\s+:\s(.*)$') { $bssid = $Matches[1].Trim() }
        elseif ($l -match '^\s+Signal\s+:\s(.*)$') { $sig = $Matches[1].Trim() }
        elseif ($l -match '^\s+Channel\s+:\s(.*)$') {
            [pscustomobject]@{ Nearby = $ssid; BSSID = $bssid; Signal = $sig; Channel = $Matches[1].Trim(); Auth = $auth }
        }
    }
}

if ($ShowProfiles) {
    Write-Host '== Saved Wi-Fi profiles' -ForegroundColor Cyan
    foreach ($l in @(netsh.exe wlan show profiles)) {
        if ($l -match ':\s(.+)$' -and $l -match 'Profile') { [pscustomobject]@{ SavedProfile = $Matches[1].Trim() } }
    }
}
