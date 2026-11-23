# @Name:        Unlock AD Account
# @Description: Shows a user's lockout status and bad-password details, then unlocks the account. Leave Identity empty to unlock nothing and just list everyone who is locked out.
# @Admin:       No
# @Changes:     Yes
# @Target:      Local, Remote
# @Modules:     ActiveDirectory
# @Tags:        ad, unlock, lockout, helpdesk

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(HelpMessage = 'Logon name or UPN. Empty = list locked-out users only.')]
    [string]$Identity = ''
)

Import-Module ActiveDirectory -ErrorAction Stop

if (-not $Identity.Trim()) {
    $locked = @(Search-ADAccount -LockedOut -UsersOnly)
    if (-not $locked.Count) { Write-Host 'No locked-out users.' -ForegroundColor Green; return }
    Write-Host "$($locked.Count) locked-out user(s). Enter one in Identity to unlock it." -ForegroundColor Yellow
    $locked | ForEach-Object { Get-ADUser -Identity $_.DistinguishedName -Properties LockoutTime, BadLogonCount, LastBadPasswordAttempt } | ForEach-Object {
        [pscustomobject]@{
            SamAccountName  = $_.SamAccountName
            Name            = $_.Name
            LockedSince     = $(if ($_.LockoutTime) { [datetime]::FromFileTime($_.LockoutTime) } else { $null })
            BadLogonCount   = $_.BadLogonCount
            LastBadPassword = $_.LastBadPasswordAttempt
        }
    }
    return
}

$id = $Identity.Trim()
$u = $null
try { $u = Get-ADUser -Identity $id -Properties LockedOut, BadLogonCount, LastBadPasswordAttempt, LockoutTime -ErrorAction Stop } catch { }
if (-not $u) {
    $esc = $id -replace "'", "''"
    $u = @(Get-ADUser -Filter "UserPrincipalName -eq '$esc' -or mail -eq '$esc'" -Properties LockedOut, BadLogonCount, LastBadPasswordAttempt, LockoutTime)[0]
}
if (-not $u) { throw "No user matches '$id'." }

Write-Host ("{0}: locked={1}, bad logons={2}, last bad password={3}" -f $u.SamAccountName, $u.LockedOut, $u.BadLogonCount, $u.LastBadPasswordAttempt) -ForegroundColor Cyan
if (-not $u.LockedOut) {
    Write-Host 'The account is not locked out. If sign-in still fails, check the password, expiry and whether the account is enabled.' -ForegroundColor Green
    return
}
if ($PSCmdlet.ShouldProcess($u.SamAccountName, 'Unlock AD account')) {
    Unlock-ADAccount -Identity $u -ErrorAction Stop
    $after = Get-ADUser -Identity $u -Properties LockedOut
    if (-not $after.LockedOut) { Write-Host "$($u.SamAccountName) is unlocked." -ForegroundColor Green }
    else { Write-Host 'Still showing as locked on this DC (replication can take a minute).' -ForegroundColor Yellow }
    [pscustomobject]@{ SamAccountName = $u.SamAccountName; Action = 'Unlocked'; Time = Get-Date; By = "$env:USERDOMAIN\$env:USERNAME" }
}
