# @Name:        AD User Lookup
# @Description: Everything a helpdesk call needs about a user: enabled, locked out, password last set and expiry, last logon, bad password count, manager, OU and groups. Accepts logon name, UPN, email or a wildcard search.
# @Admin:       No
# @Changes:     No
# @Target:      Local, Remote
# @Modules:     ActiveDirectory
# @Tags:        ad, user, lockout, password, helpdesk

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Logon name, UPN, email, display name, or a wildcard like *smith*')]
    [string]$Identity
)

Import-Module ActiveDirectory -ErrorAction Stop
$props = @('DisplayName', 'mail', 'Enabled', 'LockedOut', 'LastLogonDate', 'PasswordLastSet', 'PasswordExpired', 'PasswordNeverExpires',
    'msDS-UserPasswordExpiryTimeComputed', 'AccountExpirationDate', 'BadLogonCount', 'LastBadPasswordAttempt', 'whenCreated',
    'Title', 'Department', 'Manager', 'MemberOf', 'telephoneNumber', 'Description', 'LockoutTime', 'UserPrincipalName')

$id = $Identity.Trim()
$users = @()
if ($id -match '\*') {
    $esc = $id -replace "'", "''"
    $users = @(Get-ADUser -Filter "SamAccountName -like '$esc' -or Name -like '$esc' -or UserPrincipalName -like '$esc' -or mail -like '$esc'" -Properties $props | Select-Object -First 50)
} else {
    try { $users = @(Get-ADUser -Identity $id -Properties $props -ErrorAction Stop) } catch { }
    if (-not $users.Count) {
        $esc = $id -replace "'", "''"
        $users = @(Get-ADUser -Filter "UserPrincipalName -eq '$esc' -or mail -eq '$esc' -or DisplayName -eq '$esc' -or Name -eq '$esc'" -Properties $props)
    }
}
if (-not $users.Count) { throw "No user matches '$id'." }

if ($users.Count -gt 1) {
    Write-Host "$($users.Count) users match. Run again with one logon name for full details." -ForegroundColor Yellow
    $users | ForEach-Object {
        [pscustomobject]@{ SamAccountName = $_.SamAccountName; Name = $_.Name; UPN = $_.UserPrincipalName; Enabled = $_.Enabled; LockedOut = $_.LockedOut; LastLogon = $_.LastLogonDate }
    }
    return
}

$u = $users[0]
$expires = $null
$raw = $u.'msDS-UserPasswordExpiryTimeComputed'
if ($raw -and $raw -ne 0 -and $raw -ne 9223372036854775807) { $expires = [datetime]::FromFileTime($raw) }
$manager = $null
if ($u.Manager) { try { $manager = (Get-ADUser -Identity $u.Manager).Name } catch { $manager = $u.Manager } }
$groups = @($u.MemberOf | ForEach-Object { ($_ -split ',')[0] -replace '^CN=' } | Sort-Object)
$ou = ($u.DistinguishedName -split ',', 2)[1]

if (-not $u.Enabled) { Write-Host 'Account is DISABLED.' -ForegroundColor Red }
if ($u.LockedOut) { Write-Host "Account is LOCKED OUT (last bad password $($u.LastBadPasswordAttempt)). Use 'Unlock AD Account'." -ForegroundColor Red }
if ($u.PasswordExpired) { Write-Host 'Password has EXPIRED.' -ForegroundColor Red }
elseif ($expires -and $expires -lt (Get-Date).AddDays(7)) { Write-Host "Password expires soon: $expires" -ForegroundColor Yellow }
if ($u.Enabled -and -not $u.LockedOut -and -not $u.PasswordExpired) { Write-Host 'Account is enabled and not locked.' -ForegroundColor Green }

[pscustomobject]@{
    Name                 = $u.Name
    SamAccountName       = $u.SamAccountName
    UPN                  = $u.UserPrincipalName
    Email                = $u.mail
    Enabled              = $u.Enabled
    LockedOut            = $u.LockedOut
    BadLogonCount        = $u.BadLogonCount
    LastBadPassword      = $u.LastBadPasswordAttempt
    LastLogon            = $u.LastLogonDate
    PasswordLastSet      = $u.PasswordLastSet
    PasswordExpires      = $(if ($u.PasswordNeverExpires) { 'Never' } else { $expires })
    AccountExpires       = $u.AccountExpirationDate
    Created              = $u.whenCreated
    Title                = $u.Title
    Department           = $u.Department
    Phone                = $u.telephoneNumber
    Manager              = $manager
    Description          = $u.Description
    OU                   = $ou
    Groups               = ($groups -join ', ')
}
