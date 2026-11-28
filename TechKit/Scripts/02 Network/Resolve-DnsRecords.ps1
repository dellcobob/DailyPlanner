# @Name:        DNS Lookup
# @Description: Looks up DNS records (A, MX, TXT, SPF, DMARC and more) for a name and compares the answer from this network's DNS with public resolvers.
# @Admin:       No
# @Changes:     No
# @Target:      Local, Remote
# @Tags:        dns, mx, txt, spf, dmarc, nslookup

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Name to look up, for example contoso.com or server01')]
    [string]$Name,

    [ValidateSet('Common', 'A', 'AAAA', 'CNAME', 'MX', 'TXT', 'NS', 'SOA', 'SRV', 'PTR')]
    [string]$Type = 'Common',

    [Parameter(HelpMessage = 'Ask this DNS server instead of the PC default')]
    [string]$Server = '',

    [Parameter(HelpMessage = 'Also ask 1.1.1.1 and 8.8.8.8 and compare')]
    [bool]$ComparePublic = $true
)

$types = @($Type)
if ($Type -eq 'Common') { $types = @('A', 'AAAA', 'CNAME', 'MX', 'TXT', 'NS') }
if ($Name -match '^\d+\.\d+\.\d+\.\d+$') { $types = @('PTR') }

$servers = @('')
if ($Server) { $servers = @($Server) }
if ($ComparePublic) { $servers += @('1.1.1.1', '8.8.8.8') }

function Get-RecordData {
    param($R)
    switch ($R.Type) {
        'A' { $R.IPAddress }
        'AAAA' { $R.IPAddress }
        'CNAME' { $R.NameHost }
        'PTR' { $R.NameHost }
        'NS' { $R.NameHost }
        'MX' { "$($R.Preference) $($R.NameExchange)" }
        'TXT' { ($R.Strings -join '') }
        'SRV' { "$($R.Priority) $($R.Weight) $($R.Port) $($R.NameTarget)" }
        'SOA' { "$($R.PrimaryServer) $($R.NameAdministrator) serial $($R.SerialNumber)" }
        default { [string]$R }
    }
}

$answers = @{}
foreach ($srv in $servers) {
    $label = $(if ($srv) { $srv } else { 'PC default' })
    foreach ($t in $types) {
        $p = @{ Name = $Name; Type = $t; DnsOnly = $true; ErrorAction = 'Stop'; QuickTimeout = $true }
        if ($srv) { $p.Server = $srv }
        try {
            $recs = @(Resolve-DnsName @p | Where-Object { $_.Section -eq 'Answer' -and $_.Type -eq $t })
        } catch {
            if ($_.Exception.Message -notmatch 'does not exist|No records') { Write-Host "$label $t : $($_.Exception.Message)" -ForegroundColor Yellow }
            $recs = @()
        }
        $data = @($recs | ForEach-Object { Get-RecordData $_ } | Sort-Object)
        $answers["$t|$label"] = ($data -join ' ; ')
        foreach ($r in $recs) {
            [pscustomobject]@{ Server = $label; Name = $r.Name; Type = $t; TTL = $r.TTL; Data = (Get-RecordData $r) }
        }
    }
}

if ($types -contains 'TXT' -and $Name -notmatch '^\d') {
    try {
        $dmarc = @(Resolve-DnsName -Name "_dmarc.$Name" -Type TXT -DnsOnly -ErrorAction Stop | Where-Object { $_.Type -eq 'TXT' })
        foreach ($d in $dmarc) { [pscustomobject]@{ Server = 'PC default'; Name = $d.Name; Type = 'DMARC'; TTL = $d.TTL; Data = ($d.Strings -join '') } }
    } catch { Write-Host "No DMARC record at _dmarc.$Name" -ForegroundColor Yellow }
    $spf = $answers["TXT|PC default"]
    if (-not $Server -and $spf -notmatch 'v=spf1') { Write-Host "No SPF (v=spf1) record found for $Name" -ForegroundColor Yellow }
}

if ($ComparePublic) {
    foreach ($t in $types) {
        $local = $answers["$t|$(if ($Server) { $Server } else { 'PC default' })"]
        $pub = $answers["$t|1.1.1.1"]
        if ($local -ne $pub) {
            Write-Host "Different $t answers: local [$local] vs 1.1.1.1 [$pub] (split DNS, caching or a stale record)" -ForegroundColor Yellow
        }
    }
}
