# @Name:        Block Sign-in & Revoke Sessions
# @Description: Compromised account or urgent leaver: blocks sign-in, revokes every session and refresh token, and optionally resets the password and removes mailbox forwarding. Run it first, investigate after.
# @Admin:       No
# @Changes:     Yes
# @Target:      M365
# @Connect:     Graph
# @Scopes:      User.ReadWrite.All, User.RevokeSessions.All, User-PasswordProfile.ReadWrite.All
# @Modules:     Microsoft.Graph.Users, Microsoft.Graph.Users.Actions
# @Tags:        m365, compromised, block, revoke, incident, leaver

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'User principal name (email)')]
    [string]$User,

    [bool]$BlockSignIn = $true,

    [bool]$RevokeSessions = $true,

    [Parameter(HelpMessage = 'Set a random password (not shown) so the old one stops working')]
    [bool]$ResetPassword = $true,

    [Parameter(HelpMessage = 'Remove mailbox forwarding (needs Exchange Online connected)')]
    [bool]$RemoveForwarding = $true
)

if (-not (Get-MgContext)) { throw 'Not connected to Microsoft Graph. Click the Microsoft 365 button in Tech Kit first.' }
$u = Get-MgUser -UserId $User.Trim() -Property 'id,displayName,userPrincipalName,accountEnabled,onPremisesSyncEnabled' -ErrorAction Stop
$log = [System.Collections.Generic.List[object]]::new()
function Add-Log { param([string]$Step, [string]$Result) $log.Add([pscustomobject]@{ User = $u.UserPrincipalName; Step = $Step; Result = $Result; Time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }) }

Write-Host "Securing $($u.DisplayName) <$($u.UserPrincipalName)>" -ForegroundColor Cyan
if ($u.OnPremisesSyncEnabled) { Write-Host 'Synced from AD: also disable the account in AD or the next sync may turn sign-in back on.' -ForegroundColor Yellow }

if ($BlockSignIn -and $PSCmdlet.ShouldProcess($u.UserPrincipalName, 'Block sign-in')) {
    try { Update-MgUser -UserId $u.Id -AccountEnabled:$false -ErrorAction Stop; Write-Host 'Sign-in blocked.' -ForegroundColor Green; Add-Log 'Block sign-in' 'OK' }
    catch { Write-Host "Block failed: $($_.Exception.Message)" -ForegroundColor Red; Add-Log 'Block sign-in' "FAIL: $($_.Exception.Message)" }
}
if ($ResetPassword -and $PSCmdlet.ShouldProcess($u.UserPrincipalName, 'Reset password to a random value')) {
    $bytes = New-Object byte[] 24
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $pw = [Convert]::ToBase64String($bytes) + 'aA1!'
    try {
        Update-MgUser -UserId $u.Id -PasswordProfile @{ Password = $pw; ForceChangePasswordNextSignIn = $true } -ErrorAction Stop
        Write-Host 'Password reset to a random value (not shown).' -ForegroundColor Green
        Add-Log 'Reset password' 'OK'
    } catch { Write-Host "Password reset failed: $($_.Exception.Message)" -ForegroundColor Red; Add-Log 'Reset password' "FAIL: $($_.Exception.Message)" }
}
if ($RevokeSessions -and $PSCmdlet.ShouldProcess($u.UserPrincipalName, 'Revoke all sessions and refresh tokens')) {
    try { $null = Revoke-MgUserSignInSession -UserId $u.Id -ErrorAction Stop; Write-Host 'Sessions revoked.' -ForegroundColor Green; Add-Log 'Revoke sessions' 'OK' }
    catch { Write-Host "Revoke failed: $($_.Exception.Message)" -ForegroundColor Red; Add-Log 'Revoke sessions' "FAIL: $($_.Exception.Message)" }
}
if ($RemoveForwarding) {
    if (Get-Command Set-Mailbox -ErrorAction SilentlyContinue) {
        try {
            $mb = Get-EXOMailbox -Identity $u.UserPrincipalName -Properties ForwardingSmtpAddress, ForwardingAddress -ErrorAction Stop
            if ($mb.ForwardingSmtpAddress -or $mb.ForwardingAddress) {
                if ($PSCmdlet.ShouldProcess($u.UserPrincipalName, "Remove forwarding to $($mb.ForwardingSmtpAddress)$($mb.ForwardingAddress)")) {
                    Set-Mailbox -Identity $u.UserPrincipalName -ForwardingSmtpAddress $null -ForwardingAddress $null -DeliverToMailboxAndForward $false -ErrorAction Stop
                    Write-Host 'Mailbox forwarding removed.' -ForegroundColor Green
                    Add-Log 'Remove forwarding' "OK (was $($mb.ForwardingSmtpAddress)$($mb.ForwardingAddress))"
                }
            } else { Add-Log 'Remove forwarding' 'None set' }
            $rules = @(Get-InboxRule -Mailbox $u.UserPrincipalName -ErrorAction SilentlyContinue | Where-Object { $_.ForwardTo -or $_.RedirectTo -or $_.ForwardAsAttachmentTo })
            foreach ($r in $rules) { Write-Host "Inbox rule '$($r.Name)' forwards mail. Review it with the Forwarding & Inbox Rules Audit." -ForegroundColor Yellow }
        } catch { Write-Host "Mailbox check failed: $($_.Exception.Message)" -ForegroundColor Yellow }
    } else {
        Write-Host 'Exchange Online is not connected, forwarding was not checked.' -ForegroundColor Yellow
        Add-Log 'Remove forwarding' 'Skipped (Exchange not connected)'
    }
}
Write-Host 'Next: review sign-in logs, MFA methods and inbox rules for this user.' -ForegroundColor Cyan
$log
