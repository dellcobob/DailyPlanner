# @Name:        Traceroute
# @Description: Traces the network path to a host hop by hop with latency and names, showing where traffic slows down or stops.
# @Admin:       No
# @Changes:     No
# @Target:      Local, Remote
# @Tags:        tracert, route, latency, hops

[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'Host name or IP to trace to')]
    [string]$Destination = '8.8.8.8',

    [int]$MaxHops = 30,

    [int]$TimeoutMs = 1500,

    [bool]$ResolveNames = $true
)

try {
    $targetIp = @([System.Net.Dns]::GetHostAddresses($Destination) | Where-Object { $_.AddressFamily -eq 'InterNetwork' })[0]
} catch {
    throw "Cannot resolve $Destination : $($_.Exception.Message)"
}
if (-not $targetIp) { throw "No IPv4 address for $Destination" }
Write-Host "Tracing route to $Destination [$targetIp], max $MaxHops hops" -ForegroundColor Cyan

$buffer = [byte[]](1..32)
$ping = New-Object System.Net.NetworkInformation.Ping
try {
    for ($ttl = 1; $ttl -le $MaxHops; $ttl++) {
        $opts = New-Object System.Net.NetworkInformation.PingOptions($ttl, $true)
        $times = @()
        $hopAddr = $null
        $status = ''
        for ($try = 0; $try -lt 3; $try++) {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            try { $reply = $ping.Send($targetIp, $TimeoutMs, $buffer, $opts) } catch { $reply = $null }
            $sw.Stop()
            if ($reply -and ($reply.Status -eq 'TtlExpired' -or $reply.Status -eq 'Success')) {
                $hopAddr = $reply.Address.ToString()
                $times += [int]$sw.ElapsedMilliseconds
                $status = [string]$reply.Status
            }
        }
        $name = ''
        if ($hopAddr -and $ResolveNames) {
            try { $name = [System.Net.Dns]::GetHostEntry($hopAddr).HostName } catch { }
        }
        $avg = $null
        if ($times.Count) { $avg = [int](($times | Measure-Object -Average).Average) }
        $line = ('{0,3}  {1,-16} {2,6}  {3}' -f $ttl, $(if ($hopAddr) { $hopAddr } else { '*' }), $(if ($null -ne $avg) { "$avg ms" } else { 'timeout' }), $name)
        $color = 'Gray'
        if (-not $hopAddr) { $color = 'DarkGray' } elseif ($avg -gt 150) { $color = 'Yellow' }
        Write-Host $line -ForegroundColor $color
        [pscustomobject]@{
            Hop      = $ttl
            Address  = $hopAddr
            HostName = $name
            AvgMs    = $avg
            Replies  = "$($times.Count)/3"
        }
        if ($status -eq 'Success') {
            Write-Host 'Destination reached.' -ForegroundColor Green
            break
        }
    }
} finally {
    $ping.Dispose()
}
