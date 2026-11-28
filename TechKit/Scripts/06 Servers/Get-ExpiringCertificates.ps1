# @Name:        Expiring Certificates
# @Description: Finds certificates in the computer's Personal, Web Hosting and Remote Desktop stores that expire within N days (or already have), with subject names, issuer and private-key status.
# @Admin:       No
# @Changes:     No
# @Target:      Local, Remote
# @Tags:        certificates, ssl, tls, expiry, iis, rdp

[CmdletBinding()]
param(
    [int]$Days = 45,

    [bool]$IncludeExpired = $true,

    [Parameter(HelpMessage = 'List every certificate, not just the ones expiring soon')]
    [switch]$ShowAll
)

$stores = @('Cert:\LocalMachine\My', 'Cert:\LocalMachine\WebHosting', 'Cert:\LocalMachine\Remote Desktop')
$now = Get-Date
$limit = $now.AddDays($Days)
foreach ($store in $stores) {
    if (-not (Test-Path -LiteralPath $store)) { continue }
    foreach ($c in @(Get-ChildItem -LiteralPath $store -ErrorAction SilentlyContinue)) {
        $expired = $c.NotAfter -lt $now
        $soon = -not $expired -and $c.NotAfter -lt $limit
        if (-not $ShowAll -and -not $soon -and -not ($expired -and $IncludeExpired)) { continue }
        $san = ''
        $ext = $c.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' } | Select-Object -First 1
        if ($ext) { $san = ($ext.Format($false) -replace 'DNS Name=', '') }
        $status = 'OK'
        if ($expired) { $status = 'Expired' } elseif ($soon) { $status = 'Expiring' }
        $daysLeft = [int][Math]::Floor(($c.NotAfter - $now).TotalDays)
        if ($status -ne 'OK') {
            $color = $(if ($expired) { 'Red' } else { 'Yellow' })
            Write-Host ('{0,-9} {1,5} days  {2}' -f $status, $daysLeft, $c.Subject) -ForegroundColor $color
        }
        [pscustomobject]@{
            Computer      = $env:COMPUTERNAME
            Store         = ($store -replace '^Cert:\\LocalMachine\\', '')
            Subject       = $c.Subject
            Names         = $san
            Issuer        = $c.Issuer
            Expires       = $c.NotAfter
            DaysLeft      = $daysLeft
            Status        = $status
            HasPrivateKey = $c.HasPrivateKey
            Thumbprint    = $c.Thumbprint
        }
    }
}
