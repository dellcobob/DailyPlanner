# @Name:        Domain Health Summary
# @Description: Domain and forest overview: functional levels, FSMO role holders, every domain controller with site, OS and reachability, plus replication summary (repadmin) and optional dcdiag.
# @Admin:       No
# @Changes:     No
# @Target:      Local, Remote
# @Modules:     ActiveDirectory
# @Tags:        ad, domain controller, fsmo, replication, dcdiag, health

[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'Show repadmin /replsummary (needs repadmin, usually on DCs and RSAT PCs)')]
    [bool]$Replication = $true,

    [Parameter(HelpMessage = 'Run dcdiag /q against each DC (slow, shows only errors)')]
    [switch]$RunDcDiag
)

Import-Module ActiveDirectory -ErrorAction Stop
$domain = Get-ADDomain
$forest = Get-ADForest

Write-Host "Domain $($domain.DNSRoot) ($($domain.NetBIOSName))  domain level $($domain.DomainMode), forest level $($forest.ForestMode)" -ForegroundColor Cyan
Write-Host "FSMO: PDC=$($domain.PDCEmulator)  RID=$($domain.RIDMaster)  Infra=$($domain.InfrastructureMaster)  Schema=$($forest.SchemaMaster)  Naming=$($forest.DomainNamingMaster)" -ForegroundColor Cyan

$dcs = @(Get-ADDomainController -Filter * | Sort-Object Name)
foreach ($dc in $dcs) {
    $reach = @{}
    foreach ($port in @(389, 445, 88, 53)) {
        $c = New-Object System.Net.Sockets.TcpClient
        try { $reach[$port] = $c.ConnectAsync($dc.HostName, $port).Wait(1500) -and $c.Connected } catch { $reach[$port] = $false } finally { $c.Dispose() }
    }
    $ok = -not ($reach.Values -contains $false)
    $roles = @($dc.OperationMasterRoles | ForEach-Object { [string]$_ }) -join ', '
    if ($ok) { Write-Host "  $($dc.HostName)  reachable" -ForegroundColor Green } else { Write-Host "  $($dc.HostName)  NOT fully reachable (LDAP/SMB/Kerberos/DNS)" -ForegroundColor Red }
    [pscustomobject]@{
        DC          = $dc.Name
        Site        = $dc.Site
        IPv4        = $dc.IPv4Address
        OS          = $dc.OperatingSystem
        GC          = $dc.IsGlobalCatalog
        ReadOnly    = $dc.IsReadOnly
        Roles       = $roles
        LDAP        = $reach[389]
        SMB         = $reach[445]
        Kerberos    = $reach[88]
        DNS         = $reach[53]
        Status      = $(if ($ok) { 'OK' } else { 'FAIL' })
    }
}

if ($Replication) {
    $rep = Get-Command repadmin.exe -ErrorAction SilentlyContinue
    if ($rep) {
        Write-Host '== repadmin /replsummary' -ForegroundColor Cyan
        & repadmin.exe /replsummary 2>&1 | ForEach-Object { "$_" } | Where-Object { $_.Trim() } | ForEach-Object {
            if ($_ -match '\s([1-9]\d*)\s*/\s*\d+\s') { Write-Host $_ -ForegroundColor Yellow } else { Write-Host $_ }
        }
    } else {
        Write-Host 'repadmin is not installed here. Run this script with a DC in the Target box for replication details.' -ForegroundColor Yellow
    }
}

if ($RunDcDiag) {
    $diag = Get-Command dcdiag.exe -ErrorAction SilentlyContinue
    if (-not $diag) { Write-Host 'dcdiag is not installed here.' -ForegroundColor Yellow }
    else {
        foreach ($dc in $dcs) {
            Write-Host "== dcdiag /q /s:$($dc.HostName)" -ForegroundColor Cyan
            $out = @(& dcdiag.exe /q "/s:$($dc.HostName)" 2>&1 | ForEach-Object { "$_" } | Where-Object { $_.Trim() })
            if ($out.Count) { $out | ForEach-Object { Write-Host $_ -ForegroundColor Yellow } } else { Write-Host '   no errors' -ForegroundColor Green }
        }
    }
}
