# @Name:        Active Connections (netstat)
# @Description: Lists TCP connections or listening ports with the program that owns each one. Handy for "what is talking to the internet?" and "what is listening on this port?".
# @Admin:       No
# @Changes:     No
# @Target:      Local, Remote
# @Tags:        netstat, ports, listening, process, connections

[CmdletBinding()]
param(
    [ValidateSet('Established', 'Listening', 'All')]
    [string]$State = 'Established',

    [Parameter(HelpMessage = 'Only show this program (for example chrome or svchost)')]
    [string]$ProcessName = '',

    [Parameter(HelpMessage = 'Only show this local or remote port')]
    [int]$Port = 0,

    [Parameter(HelpMessage = 'Reverse-DNS the remote addresses (slower)')]
    [switch]$ResolveNames
)

$procs = @{}
Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $procs[[int]$_.Id] = $_.ProcessName }

$conns = @(Get-NetTCPConnection -ErrorAction SilentlyContinue)
switch ($State) {
    'Established' { $conns = @($conns | Where-Object { $_.State -eq 'Established' }) }
    'Listening' { $conns = @($conns | Where-Object { $_.State -eq 'Listen' }) }
}

$rows = foreach ($c in $conns) {
    [pscustomobject]@{
        Protocol      = 'TCP'
        LocalAddress  = $c.LocalAddress
        LocalPort     = $c.LocalPort
        RemoteAddress = $c.RemoteAddress
        RemotePort    = $c.RemotePort
        State         = [string]$c.State
        Process       = $procs[[int]$c.OwningProcess]
        PID           = $c.OwningProcess
        RemoteName    = ''
    }
}
if ($State -ne 'Established') {
    $rows = @($rows) + @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{
            Protocol = 'UDP'; LocalAddress = $_.LocalAddress; LocalPort = $_.LocalPort; RemoteAddress = ''; RemotePort = $null
            State = 'Listen'; Process = $procs[[int]$_.OwningProcess]; PID = $_.OwningProcess; RemoteName = ''
        }
    })
}

$rows = @($rows | Where-Object { $_ })
if ($ProcessName) { $rows = @($rows | Where-Object { $_.Process -like "*$ProcessName*" }) }
if ($Port -gt 0) { $rows = @($rows | Where-Object { $_.LocalPort -eq $Port -or $_.RemotePort -eq $Port }) }

if ($ResolveNames) {
    $cache = @{}
    foreach ($r in $rows) {
        $ip = [string]$r.RemoteAddress
        if (-not $ip -or $ip -in @('0.0.0.0', '::', '127.0.0.1', '::1')) { continue }
        if (-not $cache.ContainsKey($ip)) {
            try { $cache[$ip] = [System.Net.Dns]::GetHostEntry($ip).HostName } catch { $cache[$ip] = '' }
        }
        $r.RemoteName = $cache[$ip]
    }
}

Write-Host "$($rows.Count) entr$(if ($rows.Count -eq 1) { 'y' } else { 'ies' }) on $env:COMPUTERNAME" -ForegroundColor Cyan
$rows | Sort-Object Process, LocalPort
