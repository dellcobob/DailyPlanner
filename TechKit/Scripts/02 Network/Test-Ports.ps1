# @Name:        Port Check
# @Description: Tests TCP ports on one or more hosts in parallel (for example RDP 3389, SMB 445, HTTPS 443). Accepts lists and ranges like 80,443,8000-8010.
# @Admin:       No
# @Changes:     No
# @Target:      Local, Remote
# @Tags:        port, tcp, firewall, scan, rdp, smb

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Host names or IP addresses, one per line')]
    [string[]]$Hosts,

    [Parameter(HelpMessage = 'Ports and ranges, comma separated')]
    [string]$Ports = '21,22,25,53,80,135,139,389,443,445,587,636,1433,3306,3389,5985,5986,8080,8443',

    [int]$TimeoutMs = 1500,

    [Parameter(HelpMessage = 'Only list open ports')]
    [switch]$OpenOnly
)

$known = @{
    21 = 'FTP'; 22 = 'SSH'; 23 = 'Telnet'; 25 = 'SMTP'; 53 = 'DNS'; 80 = 'HTTP'; 88 = 'Kerberos'; 110 = 'POP3'; 135 = 'RPC'
    139 = 'NetBIOS'; 143 = 'IMAP'; 389 = 'LDAP'; 443 = 'HTTPS'; 445 = 'SMB'; 465 = 'SMTPS'; 587 = 'SMTP submit'; 636 = 'LDAPS'
    993 = 'IMAPS'; 995 = 'POP3S'; 1433 = 'SQL Server'; 1723 = 'PPTP'; 3268 = 'Global Catalog'; 3306 = 'MySQL'; 3389 = 'RDP'
    5432 = 'PostgreSQL'; 5900 = 'VNC'; 5985 = 'WinRM HTTP'; 5986 = 'WinRM HTTPS'; 8080 = 'HTTP alt'; 8443 = 'HTTPS alt'; 9100 = 'Printer'
}

$portList = [System.Collections.Generic.List[int]]::new()
foreach ($part in ($Ports -split '[,;\s]+' | Where-Object { $_ })) {
    if ($part -match '^(\d+)-(\d+)$') {
        $a = [int]$Matches[1]; $b = [int]$Matches[2]
        for ($p = [Math]::Min($a, $b); $p -le [Math]::Max($a, $b); $p++) { $portList.Add($p) }
    } elseif ($part -match '^\d+$') {
        $portList.Add([int]$part)
    }
}
$portList = @($portList | Where-Object { $_ -ge 1 -and $_ -le 65535 } | Select-Object -Unique)
$total = $portList.Count * $Hosts.Count
if ($total -gt 5000) { throw "That is $total checks. Narrow it to 5000 or fewer." }
Write-Host "Testing $($portList.Count) port(s) on $($Hosts.Count) host(s)..." -ForegroundColor Cyan

$work = foreach ($h in $Hosts) { foreach ($p in $portList) { [pscustomobject]@{ Host = $h.Trim(); Port = $p } } }
$work = @($work)
$batch = 300
for ($i = 0; $i -lt $work.Count; $i += $batch) {
    $slice = $work[$i..([Math]::Min($i + $batch, $work.Count) - 1)]
    $jobs = foreach ($w in $slice) {
        $c = New-Object System.Net.Sockets.TcpClient
        $task = $null
        try { $task = $c.ConnectAsync($w.Host, $w.Port) } catch { }
        [pscustomobject]@{ Host = $w.Host; Port = $w.Port; Client = $c; Task = $task }
    }
    $tasks = [System.Threading.Tasks.Task[]]@($jobs | Where-Object { $_.Task } | ForEach-Object { $_.Task })
    try { $null = [System.Threading.Tasks.Task]::WaitAll($tasks, $TimeoutMs) } catch { }
    foreach ($j in $jobs) {
        $open = $j.Task -and $j.Task.Status -eq 'RanToCompletion' -and $j.Client.Connected
        $j.Client.Dispose()
        if ($OpenOnly -and -not $open) { continue }
        if ($open) { Write-Host ('OPEN    {0}:{1} {2}' -f $j.Host, $j.Port, $known[$j.Port]) -ForegroundColor Green }
        [pscustomobject]@{
            Host    = $j.Host
            Port    = $j.Port
            Service = $known[$j.Port]
            Status  = $(if ($open) { 'Open' } else { 'Closed/Filtered' })
        }
    }
}
