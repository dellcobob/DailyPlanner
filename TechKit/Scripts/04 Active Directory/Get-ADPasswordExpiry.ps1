# @Name:        Password Expiry Report
# @Description: Lists users whose passwords expire within N days or have already expired, plus accounts set to never expire. Uses the computed expiry so fine-grained policies are respected.
# @Admin:       No
# @Changes:     No
# @Target:      Local, Remote
# @Modules:     ActiveDirectory
# @Tags:        ad, password, expiry, report

[CmdletBinding()]
param(
    [int]$WithinDays = 14,

    [bool]$IncludeExpired = $true,

    [Parameter(HelpMessage = 'Also list enabled accounts whose password never expires')]
    [bool]$IncludeNeverExpires = $true
)

Import-Module ActiveDirectory -ErrorAction Stop
$now = Get-Date
$limit = $now.AddDays($WithinDays)
$users = Get-ADUser -Filter "Enabled -eq 'True'" -Properties DisplayName, mail, PasswordLastSet, PasswordNeverExpires, 'msDS-UserPasswordExpiryTimeComputed'

$rows = foreach ($u in $users) {
    if ($u.PasswordNeverExpires) {
        if ($IncludeNeverExpires) {
            [pscustomobject]@{ Name = $u.Name; SamAccountName = $u.SamAccountName; Email = $u.mail; PasswordLastSet = $u.PasswordLastSet; Expires = $null; DaysLeft = $null; Status = 'Never expires' }
        }
        continue
    }
    $raw = $u.'msDS-UserPasswordExpiryTimeComputed'
    if (-not $raw -or $raw -eq 9223372036854775807) { continue }
    if (-not $u.PasswordLastSet) {
        if ($IncludeExpired) {
            [pscustomobject]@{ Name = $u.Name; SamAccountName = $u.SamAccountName; Email = $u.mail; PasswordLastSet = $null; Expires = $null; DaysLeft = $null; Status = 'Must change at next logon' }
        }
        continue
    }
    $exp = [datetime]::FromFileTime($raw)
    $days = [int][Math]::Floor(($exp - $now).TotalDays)
    if ($exp -lt $now) {
        if ($IncludeExpired) { [pscustomobject]@{ Name = $u.Name; SamAccountName = $u.SamAccountName; Email = $u.mail; PasswordLastSet = $u.PasswordLastSet; Expires = $exp; DaysLeft = $days; Status = 'Expired' } }
    } elseif ($exp -le $limit) {
        [pscustomobject]@{ Name = $u.Name; SamAccountName = $u.SamAccountName; Email = $u.mail; PasswordLastSet = $u.PasswordLastSet; Expires = $exp; DaysLeft = $days; Status = 'Expiring' }
    }
}
$rows = @($rows)
$exp = @($rows | Where-Object { $_.Status -eq 'Expiring' }).Count
$gone = @($rows | Where-Object { $_.Status -eq 'Expired' }).Count
$never = @($rows | Where-Object { $_.Status -eq 'Never expires' }).Count
Write-Host "Expiring within $WithinDays days: $exp   Expired: $gone   Never expires: $never" -ForegroundColor Cyan
if ($never -gt 0) { Write-Host 'Accounts with non-expiring passwords should be service accounts only. Review the list.' -ForegroundColor Yellow }
$rows | Sort-Object Status, DaysLeft
