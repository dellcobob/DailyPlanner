# @Name:        Connectivity Check
# @Description: Step-by-step "is it the network?" test: adapter, gateway, DNS servers, name resolution, internet ping, HTTPS, Microsoft 365 endpoints and the public IP address.
# @Admin:       No
# @Changes:     No
# @Target:      Local, Remote
# @Tags:        internet, ping, dns, troubleshoot, m365, public ip

[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'Extra hosts to test on TCP 443 (one per line)')]
    [string[]]$ExtraHosts = @(),

    [Parameter(HelpMessage = 'Look up the public IP address (calls api.ipify.org)')]
    [bool]$PublicIP = $true
)

try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

function Test-Ping {
    param([string]$Target, [int]$Timeout = 1500)
    try {
        $p = New-Object System.Net.NetworkInformation.Ping
        $r = $p.Send($Target, $Timeout)
        if ($r.Status -eq 'Success') { return [int]$r.RoundtripTime }
    } catch { }
    -1
}

function Test-Tcp {
    param([string]$Target, [int]$Port, [int]$Timeout = 3000)
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $t = $c.ConnectAsync($Target, $Port)
        if ($t.Wait($Timeout) -and $c.Connected) { return [int]$sw.ElapsedMilliseconds }
    } catch { } finally { $c.Dispose() }
    -1
}

function Write-Check {
    param([string]$Check, [string]$Target, [bool]$Ok, [string]$Detail, [string]$Fail = 'FAIL')
    $result = $(if ($Ok) { 'PASS' } else { $Fail })
    $color = $(if ($Ok) { 'Green' } elseif ($Fail -eq 'WARN') { 'Yellow' } else { 'Red' })
    Write-Host ('{0,-5} {1,-28} {2,-32} {3}' -f $result, $Check, $Target, $Detail) -ForegroundColor $color
    [pscustomobject]@{ Computer = $env:COMPUTERNAME; Check = $Check; Target = $Target; Result = $result; Detail = $Detail }
}

$cfg = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' })
if (-not $cfg.Count) {
    Write-Check 'Network adapter with gateway' '-' $false 'No connected adapter has a default gateway'
} else {
    foreach ($c in $cfg) {
        $ip = @($c.IPv4Address | ForEach-Object { $_.IPAddress }) -join ', '
        Write-Check 'Adapter' $c.InterfaceAlias ($ip -notlike '169.254.*') "IP $ip"
        $gw = @($c.IPv4DefaultGateway)[0].NextHop
        $ms = Test-Ping $gw
        Write-Check 'Gateway ping' $gw ($ms -ge 0) $(if ($ms -ge 0) { "$ms ms" } else { 'no reply (some routers block ping)' }) 'WARN'
        foreach ($d in @($c.DNSServer | Where-Object { $_.AddressFamily -eq 2 } | ForEach-Object { $_.ServerAddresses })) {
            $ms = Test-Tcp $d 53 2000
            Write-Check 'DNS server reachable (TCP 53)' $d ($ms -ge 0) $(if ($ms -ge 0) { "$ms ms" } else { 'not reachable' }) 'WARN'
        }
    }
}

foreach ($name in @('www.microsoft.com', 'login.microsoftonline.com')) {
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $addr = @([System.Net.Dns]::GetHostAddresses($name) | Where-Object { $_.AddressFamily -eq 'InterNetwork' })
        Write-Check 'DNS resolution' $name ($addr.Count -gt 0) ("{0} ({1} ms)" -f ($addr | Select-Object -First 1), $sw.ElapsedMilliseconds)
    } catch {
        Write-Check 'DNS resolution' $name $false $_.Exception.Message
    }
}

foreach ($t in @('1.1.1.1', '8.8.8.8')) {
    $ms = Test-Ping $t
    Write-Check 'Internet ping' $t ($ms -ge 0) $(if ($ms -ge 0) { "$ms ms" } else { 'no reply' }) 'WARN'
}

try {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 8
    $ok = ($r.Content -match 'Microsoft Connect Test')
    Write-Check 'HTTP internet test' 'msftconnecttest.com' $ok $(if ($ok) { "$($sw.ElapsedMilliseconds) ms" } else { 'unexpected content (captive portal or proxy?)' })
} catch {
    Write-Check 'HTTP internet test' 'msftconnecttest.com' $false $_.Exception.Message
}

$m365 = @('login.microsoftonline.com', 'outlook.office365.com', 'graph.microsoft.com', 'teams.microsoft.com') + @($ExtraHosts | Where-Object { $_ })
foreach ($h in $m365) {
    $ms = Test-Tcp $h 443
    Write-Check 'HTTPS reachable (TCP 443)' $h ($ms -ge 0) $(if ($ms -ge 0) { "$ms ms" } else { 'blocked or unreachable' })
}

$proxy = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue)
if ($proxy -and $proxy.ProxyEnable -eq 1) {
    Write-Check 'Proxy' $proxy.ProxyServer $true 'A user proxy is configured' 'WARN'
}

if ($PublicIP) {
    try {
        $pub = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -TimeoutSec 8).ip
        Write-Check 'Public IP' 'api.ipify.org' ([bool]$pub) $pub
    } catch {
        Write-Check 'Public IP' 'api.ipify.org' $false $_.Exception.Message 'WARN'
    }
}
