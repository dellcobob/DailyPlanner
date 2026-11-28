# @Name:        Quick Speed Test
# @Description: Measures latency, download and optional upload speed against Cloudflare's speed test service. Good for "the internet is slow" tickets.
# @Admin:       No
# @Changes:     No
# @Target:      Local, Remote
# @Tags:        speed, bandwidth, latency, internet, slow

[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'Download size in MB (bigger = more accurate on fast links)')]
    [ValidateSet('10', '25', '50', '100')]
    [string]$DownloadMB = '25',

    [Parameter(HelpMessage = 'Also test upload (sends 10 MB of random data)')]
    [switch]$Upload
)

try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

$ping = New-Object System.Net.NetworkInformation.Ping
$lat = @()
for ($i = 0; $i -lt 5; $i++) {
    try { $r = $ping.Send('1.1.1.1', 2000); if ($r.Status -eq 'Success') { $lat += [int]$r.RoundtripTime } } catch { }
}
$ping.Dispose()
$latency = $null
$jitter = $null
if ($lat.Count) {
    $latency = [int](($lat | Measure-Object -Average).Average)
    $jitter = [int](($lat | Measure-Object -Maximum).Maximum - ($lat | Measure-Object -Minimum).Minimum)
    Write-Host "Latency to 1.1.1.1: $latency ms (jitter $jitter ms)" -ForegroundColor Cyan
} else {
    Write-Host 'Ping to 1.1.1.1 got no replies (ICMP may be blocked).' -ForegroundColor Yellow
}

$bytes = [int]$DownloadMB * 1000000
$wc = New-Object System.Net.WebClient
$down = $null
try {
    Write-Host "Downloading $DownloadMB MB..." -ForegroundColor Cyan
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $data = $wc.DownloadData("https://speed.cloudflare.com/__down?bytes=$bytes")
    $sw.Stop()
    $down = [Math]::Round(($data.Length * 8 / 1000000) / $sw.Elapsed.TotalSeconds, 1)
    Write-Host "Download: $down Mbps" -ForegroundColor Green
} catch {
    Write-Host "Download test failed: $($_.Exception.Message)" -ForegroundColor Red
}

$up = $null
if ($Upload) {
    try {
        Write-Host 'Uploading 10 MB...' -ForegroundColor Cyan
        $payload = New-Object byte[] 10000000
        (New-Object System.Random).NextBytes($payload)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $null = $wc.UploadData('https://speed.cloudflare.com/__up', 'POST', $payload)
        $sw.Stop()
        $up = [Math]::Round(($payload.Length * 8 / 1000000) / $sw.Elapsed.TotalSeconds, 1)
        Write-Host "Upload: $up Mbps" -ForegroundColor Green
    } catch {
        Write-Host "Upload test failed: $($_.Exception.Message)" -ForegroundColor Red
    }
}
$wc.Dispose()

[pscustomobject]@{
    Computer     = $env:COMPUTERNAME
    Time         = Get-Date
    LatencyMs    = $latency
    JitterMs     = $jitter
    DownloadMbps = $down
    UploadMbps   = $up
}
