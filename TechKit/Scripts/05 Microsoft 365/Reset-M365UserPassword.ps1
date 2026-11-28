# @Name:        Reset M365 Password
# @Description: Resets a cloud user's password (generates a strong one if you leave it empty), optionally forces a change at next sign-in and signs them out everywhere. Users synced from AD must be reset in AD instead.
# @Admin:       No
# @Changes:     Yes
# @Target:      M365
# @Connect:     Graph
# @Scopes:      User.ReadWrite.All, User-PasswordProfile.ReadWrite.All, User.RevokeSessions.All
# @Modules:     Microsoft.Graph.Users, Microsoft.Graph.Users.Actions
# @Tags:        m365, password, reset, helpdesk

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'User principal name (email)')]
    [string]$User,

    [Parameter(HelpMessage = 'Leave empty to generate a random 14-character password')]
    [securestring]$NewPassword,

    [bool]$ForceChangeAtNextSignIn = $true,

    [Parameter(HelpMessage = 'Also sign the user out of all sessions')]
    [switch]$RevokeSessions
)

if (-not (Get-MgContext)) { throw 'Not connected to Microsoft Graph. Click the Microsoft 365 button in Tech Kit first.' }

$u = Get-MgUser -UserId $User.Trim() -Property 'id,displayName,userPrincipalName,onPremisesSyncEnabled' -ErrorAction Stop
if ($u.OnPremisesSyncEnabled) {
    Write-Host "$($u.UserPrincipalName) is synced from on-premises AD. Reset the password in AD (Reset AD Password) unless password writeback is enabled." -ForegroundColor Yellow
}

$plain = $null
$generated = $false
if ($NewPassword -and $NewPassword.Length -gt 0) {
    $plain = (New-Object System.Net.NetworkCredential('', $NewPassword)).Password
} else {
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!@#$%*?-+=')
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $chars = [System.Collections.Generic.List[char]]::new()
    $all = -join $sets
    for ($i = 0; $i -lt 14; $i++) {
        $set = $all
        if ($i -lt $sets.Count) { $set = $sets[$i] }
        $b = New-Object byte[] 4
        $rng.GetBytes($b)
        $chars.Add($set[[BitConverter]::ToUInt32($b, 0) % $set.Length])
    }
    $plain = -join ($chars | Sort-Object { Get-Random })
    $generated = $true
}

if ($PSCmdlet.ShouldProcess($u.UserPrincipalName, 'Reset Microsoft 365 password')) {
    Update-MgUser -UserId $u.Id -PasswordProfile @{ Password = $plain; ForceChangePasswordNextSignIn = $ForceChangeAtNextSignIn } -ErrorAction Stop
    Write-Host "Password reset for $($u.UserPrincipalName)." -ForegroundColor Green
    if ($generated) { Write-Host "New password: $plain" -ForegroundColor Yellow }
    if ($ForceChangeAtNextSignIn) { Write-Host 'They must choose a new password at next sign-in.' -ForegroundColor Green }
}
if ($RevokeSessions -and $PSCmdlet.ShouldProcess($u.UserPrincipalName, 'Revoke all sign-in sessions')) {
    $null = Revoke-MgUserSignInSession -UserId $u.Id -ErrorAction Stop
    Write-Host 'All sessions revoked. Apps will ask them to sign in again within minutes to an hour.' -ForegroundColor Green
}
