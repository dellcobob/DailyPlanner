# @Name:        Ping Sweep (Find Devices)
# @Description: Pings every address in a subnet at once and lists the devices that answer, with host names and MAC addresses. Leave Subnet empty to scan this PC's own network.
# @Admin:       No
# @Changes:     No
# @Target:      Local, Remote
# @Tags:        scan, discovery, ping, subnet, arp, devices

[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'CIDR range such as 192.168.1.0/24. Empty = the network this PC is on.')]
    [string]$Subnet = '',

    [Parameter(HelpMessage = 'Milliseconds to wait for each reply')]
    [int]$TimeoutMs = 500,

    [bool]$ResolveNames = $true,

    [Parameter(HelpMessage = 'Look up MAC addresses from the ARP table (same subnet only)')]
    [bool]$ShowMac = $true
)

function ConvertTo-UInt32 { param([string]$Ip) $b = ([System.Net.IPAddress]::Parse($Ip)).GetAddressBytes(); [Array]::Reverse($b); [BitConverter]::ToUInt32($b, 0) }
function ConvertTo-IpString { param([uint32]$Value) $b = [BitConverter]::GetBytes($Value); [Array]::Reverse($b); ([System.Net.IPAddress]$b).ToString() }

if (-not $Subnet) {
    $cfg = Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1
    if (-not $cfg) { throw 'Could not find a connected network. Enter a subnet like 192.168.1.0/24.' }
    $addr = @($cfg.IPv4Address)[0]
    $Subnet = "$($addr.IPAddress)/$($addr.PrefixLength)"
}
if ($Subnet -notmatch '^(\d{1,3}(\.\d{1,3}){3})/(\d{1,2})$') { throw "Subnet must look like 192.168.1.0/24 (got '$Subnet')." }
$prefix = [int]$Matches[3]
if ($prefix -lt 20 -or $prefix -gt 30) { throw 'Use a prefix between /20 (4094 hosts) and /30.' }

$ipValue = ConvertTo-UInt32 $Matches[1]
$mask = [uint32]([Math]::Pow(2, 32) - [Math]::Pow(2, 32 - $prefix))
$network = $ipValue -band $mask
$broadcast = $network + [uint32]([Math]::Pow(2, 32 - $prefix) - 1)
$targets = New-Object System.Collections.Generic.List[string]
for ($v = $network + 1; $v -lt $broadcast; $v++) { $targets.Add((ConvertTo-IpString ([uint32]$v))) }
Write-Host "Scanning $($targets.Count) addresses in $(ConvertTo-IpString $network)/$prefix ..." -ForegroundColor Cyan

$alive = New-Object System.Collections.Generic.List[object]
$batchSize = 256
for ($i = 0; $i -lt $targets.Count; $i += $batchSize) {
    $batch = $targets.GetRange($i, [Math]::Min($batchSize, $targets.Count - $i))
    Write-Progress -Activity 'Ping sweep' -Status "$i of $($targets.Count)" -PercentComplete ([int](100 * $i / $targets.Count))
    $pending = foreach ($t in $batch) {
        $ping = New-Object System.Net.NetworkInformation.Ping
        [pscustomobject]@{ IP = $t; Task = $ping.SendPingAsync($t, $TimeoutMs); Ping = $ping }
    }
    try { [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($pending | ForEach-Object { $_.Task })) } catch { }
    foreach ($p in $pending) {
        if ($p.Task.Status -eq 'RanToCompletion' -and $p.Task.Result.Status -eq 'Success') {
            $alive.Add([pscustomobject]@{ IP = $p.IP; Ms = [int]$p.Task.Result.RoundtripTime; TTL = $p.Task.Result.Options.Ttl })
        }
        $p.Ping.Dispose()
    }
}
Write-Progress -Activity 'Ping sweep' -Completed

$names = @{}
if ($ResolveNames -and $alive.Count) {
    $lookups = foreach ($a in $alive) { [pscustomobject]@{ IP = $a.IP; Task = [System.Net.Dns]::GetHostEntryAsync($a.IP) } }
    try { $null = [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($lookups | ForEach-Object { $_.Task }), 4000) } catch { }
    foreach ($l in $lookups) { if ($l.Task.Status -eq 'RanToCompletion') { $names[$l.IP] = $l.Task.Result.HostName } }
}
$macs = @{}
if ($ShowMac) {
    Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.LinkLayerAddress -and $_.LinkLayerAddress -ne '00-00-00-00-00-00' } |
        ForEach-Object { $macs[$_.IPAddress] = $_.LinkLayerAddress }
}

Write-Host "$($alive.Count) device(s) answered." -ForegroundColor Green
$alive | Sort-Object { ConvertTo-UInt32 $_.IP } | ForEach-Object {
    $os = ''
    if ($_.TTL -gt 100 -and $_.TTL -le 128) { $os = 'Windows?' } elseif ($_.TTL -le 64) { $os = 'Linux/Mac/device?' } elseif ($_.TTL -gt 128) { $os = 'Network gear?' }
    [pscustomobject]@{
        IP       = $_.IP
        HostName = $names[$_.IP]
        MAC      = $macs[$_.IP]
        Ms       = $_.Ms
        TTL      = $_.TTL
        Guess    = $os
    }
}
