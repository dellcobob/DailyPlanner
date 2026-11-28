# @Name:        Guest Users Report
# @Description: Lists external guest accounts with invite status, age and last sign-in so you can clean up stale guests.
# @Admin:       No
# @Changes:     No
# @Target:      M365
# @Connect:     Graph
# @Scopes:      User.Read.All, AuditLog.Read.All
# @Modules:     Microsoft.Graph.Users
# @Tags:        m365, guests, external, b2b, cleanup

[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'Only guests created more than this many days ago (0 = all)')]
    [int]$OlderThanDays = 0,

    [Parameter(HelpMessage = 'Only guests with no sign-in for this many days (0 = ignore; needs Entra ID P1)')]
    [int]$InactiveDays = 0
)

if (-not (Get-MgContext)) { throw 'Not connected to Microsoft Graph. Click the Microsoft 365 button in Tech Kit first.' }
$base = 'id,displayName,mail,userPrincipalName,createdDateTime,externalUserState,externalUserStateChangeDateTime,accountEnabled,companyName'
$hasSignIn = $true
try {
    $guests = @(Get-MgUser -All -Filter "userType eq 'Guest'" -Property "$base,signInActivity" -ErrorAction Stop)
} catch {
    $hasSignIn = $false
    Write-Host 'Last sign-in needs Entra ID P1 and AuditLog.Read.All; listing without it.' -ForegroundColor Yellow
    $guests = @(Get-MgUser -All -Filter "userType eq 'Guest'" -Property $base)
}

$now = Get-Date
$rows = foreach ($g in $guests) {
    $created = $g.CreatedDateTime
    $age = $null
    if ($created) { $age = [int]($now - [datetime]$created).TotalDays }
    $last = $null
    if ($hasSignIn -and $g.SignInActivity) { $last = $g.SignInActivity.LastSignInDateTime }
    $idle = $null
    if ($last) { $idle = [int]($now - [datetime]$last).TotalDays }
    if ($OlderThanDays -gt 0 -and $null -ne $age -and $age -lt $OlderThanDays) { continue }
    if ($InactiveDays -gt 0 -and $hasSignIn -and $null -ne $idle -and $idle -lt $InactiveDays) { continue }
    $domain = ''
    if ($g.Mail -match '@(.+)$') { $domain = $Matches[1] }
    [pscustomobject]@{
        DisplayName  = $g.DisplayName
        Mail         = $g.Mail
        Domain       = $domain
        Company      = $g.CompanyName
        InviteState  = $g.ExternalUserState
        Created      = $created
        AgeDays      = $age
        LastSignIn   = $(if ($hasSignIn) { $(if ($last) { $last } else { 'Never' }) } else { 'n/a' })
        DaysIdle     = $idle
        SignIn       = $(if ($g.AccountEnabled) { 'Allowed' } else { 'Blocked' })
    }
}
$rows = @($rows)
$pending = @($rows | Where-Object { $_.InviteState -eq 'PendingAcceptance' }).Count
Write-Host "$($rows.Count) guest(s). $pending invitation(s) never accepted." -ForegroundColor Cyan
$rows | Group-Object Domain | Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object { Write-Host ("  {0,4}  {1}" -f $_.Count, $_.Name) }
$rows | Sort-Object Domain, DisplayName
