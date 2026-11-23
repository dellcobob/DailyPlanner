# @Name:        Reset AD Password
# @Description: Resets a user's Active Directory password, optionally requiring a change at next logon and unlocking the account. Leave the password empty to generate a strong one.
# @Admin:       No
# @Changes:     Yes
# @Target:      Local, Remote
# @Modules:     ActiveDirectory
# @Tags:        ad, password, reset, unlock, helpdesk

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Logon name or UPN')]
    [string]$Identity,

    [Parameter(HelpMessage = 'Leave empty to generate a random 14-character password')]
    [securestring]$NewPassword,

    [bool]$MustChangeAtLogon = $true,

    [bool]$UnlockAccount = $true
)

Import-Module ActiveDirectory -ErrorAction Stop

function New-StrongPassword {
    param([int]$Length = 14)
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!@#$%*?-+=')
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $pick = {
        param([string]$Set)
        $b = New-Object byte[] 4
        $rng.GetBytes($b)
        $Set[[BitConverter]::ToUInt32($b, 0) % $Set.Length]
    }
    $chars = New-Object System.Collections.Generic.List[char]
    foreach ($s in $sets) { $chars.Add((& $pick $s)) }
    $all = -join $sets
    while ($chars.Count -lt $Length) { $chars.Add((& $pick $all)) }
    -join ($chars | Sort-Object { Get-Random })
}

$id = $Identity.Trim()
$u = $null
try { $u = Get-ADUser -Identity $id -Properties LockedOut -ErrorAction Stop } catch { }
if (-not $u) {
    $esc = $id -replace "'", "''"
    $u = @(Get-ADUser -Filter "UserPrincipalName -eq '$esc' -or mail -eq '$esc'" -Properties LockedOut)[0]
}
if (-not $u) { throw "No user matches '$id'." }

$generated = $null
if (-not $NewPassword -or $NewPassword.Length -eq 0) {
    $generated = New-StrongPassword
    $NewPassword = ConvertTo-SecureString -String $generated -AsPlainText -Force
}

if ($PSCmdlet.ShouldProcess($u.SamAccountName, 'Reset AD password')) {
    Set-ADAccountPassword -Identity $u -Reset -NewPassword $NewPassword -ErrorAction Stop
    Write-Host "Password reset for $($u.SamAccountName)." -ForegroundColor Green
    if ($generated) { Write-Host "New password: $generated" -ForegroundColor Yellow }
}
if ($MustChangeAtLogon -and $PSCmdlet.ShouldProcess($u.SamAccountName, 'Require password change at next logon')) {
    Set-ADUser -Identity $u -ChangePasswordAtLogon $true -ErrorAction Stop
    Write-Host 'User must change the password at next logon.' -ForegroundColor Green
}
if ($UnlockAccount -and $u.LockedOut -and $PSCmdlet.ShouldProcess($u.SamAccountName, 'Unlock account')) {
    Unlock-ADAccount -Identity $u -ErrorAction Stop
    Write-Host 'Account unlocked.' -ForegroundColor Green
}
