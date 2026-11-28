# @Name:        User Sign-in Log
# @Description: Recent sign-ins for one user with app, IP, location, device, result and Conditional Access outcome. Lists the countries seen so unusual locations stand out. Needs Entra ID P1.
# @Admin:       No
# @Changes:     No
# @Target:      M365
# @Connect:     Graph
# @Scopes:      AuditLog.Read.All, Directory.Read.All
# @Modules:     Microsoft.Graph.Reports
# @Tags:        m365, sign-in, logs, investigation, location, compromised

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'User principal name (email)')]
    [string]$User,

    [int]$Days = 7,

    [switch]$FailuresOnly,

    [int]$Max = 500
)

if (-not (Get-MgContext)) { throw 'Not connected to Microsoft Graph. Click the Microsoft 365 button in Tech Kit first.' }
$since = (Get-Date).AddDays(-$Days).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$upn = $User.Trim() -replace "'", "''"
$filter = "userPrincipalName eq '$upn' and createdDateTime ge $since"
if ($FailuresOnly) { $filter += ' and status/errorCode ne 0' }

try {
    $logs = @(Get-MgAuditLogSignIn -Filter $filter -Top $Max -ErrorAction Stop)
} catch {
    if ($_.Exception.Message -match 'premium|license|Authentication_RequestFromNonPremiumTenant') {
        throw 'Sign-in logs through Graph need an Entra ID P1 or P2 license in this tenant.'
    }
    throw
}
if (-not $logs.Count) { Write-Host "No sign-ins for $User in the last $Days days." -ForegroundColor Yellow; return }

$rows = foreach ($l in $logs) {
    $ok = $l.Status.ErrorCode -eq 0
    [pscustomobject]@{
        Time        = $l.CreatedDateTime
        Result      = $(if ($ok) { 'Success' } else { "Failed: $($l.Status.FailureReason)" })
        App         = $l.AppDisplayName
        IP          = $l.IPAddress
        City        = $l.Location.City
        Country     = $l.Location.CountryOrRegion
        Client      = $l.ClientAppUsed
        OS          = $l.DeviceDetail.OperatingSystem
        Browser     = $l.DeviceDetail.Browser
        Interactive = $l.IsInteractive
        CA          = $l.ConditionalAccessStatus
        Risk        = $l.RiskLevelDuringSignIn
    }
}
$rows = @($rows)
$fails = @($rows | Where-Object { $_.Result -ne 'Success' }).Count
Write-Host "$($rows.Count) sign-in(s), $fails failed, in the last $Days days." -ForegroundColor Cyan
Write-Host 'Countries seen:' -ForegroundColor Cyan
$rows | Group-Object Country | Sort-Object Count -Descending | ForEach-Object {
    $ips = @($_.Group | Select-Object -ExpandProperty IP -Unique)
    Write-Host ("  {0,-4} {1,5} sign-ins from {2} IP(s)" -f $(if ($_.Name) { $_.Name } else { '??' }), $_.Count, $ips.Count)
}
$legacy = @($rows | Where-Object { $_.Client -match 'IMAP|POP|SMTP|Exchange ActiveSync|Other clients|MAPI' })
if ($legacy.Count) { Write-Host "$($legacy.Count) sign-in(s) used legacy protocols (IMAP/POP/SMTP/ActiveSync)." -ForegroundColor Yellow }
$rows
