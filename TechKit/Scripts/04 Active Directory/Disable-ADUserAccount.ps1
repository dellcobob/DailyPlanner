# @Name:        Disable User (Offboarding)
# @Description: Offboards an AD user: disables the account, optionally resets the password, removes group memberships (saved in the output as a record), stamps the description and moves it to a disabled-users OU.
# @Admin:       No
# @Changes:     Yes
# @Target:      Local, Remote
# @Modules:     ActiveDirectory
# @Tags:        ad, offboarding, disable, leaver, termination

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Logon name or UPN of the leaver')]
    [string]$Identity,

    [Parameter(HelpMessage = 'Set a random password so cached sessions cannot be reused')]
    [bool]$ResetPassword = $true,

    [Parameter(HelpMessage = 'Remove from all groups except Domain Users (the list is kept in the output)')]
    [bool]$RemoveGroups = $false,

    [Parameter(HelpMessage = 'Write "Disabled <date> by <you>" into the description')]
    [bool]$StampDescription = $true,

    [Parameter(HelpMessage = 'Distinguished name of the OU to move the account to (optional)')]
    [string]$MoveToOU = ''
)

Import-Module ActiveDirectory -ErrorAction Stop
$id = $Identity.Trim()
$u = $null
try { $u = Get-ADUser -Identity $id -Properties MemberOf, Description, Enabled, Manager -ErrorAction Stop } catch { }
if (-not $u) {
    $esc = $id -replace "'", "''"
    $u = @(Get-ADUser -Filter "UserPrincipalName -eq '$esc' -or mail -eq '$esc'" -Properties MemberOf, Description, Enabled, Manager)[0]
}
if (-not $u) { throw "No user matches '$id'." }

$me = "$env:USERDOMAIN\$env:USERNAME"
$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
Write-Host "Offboarding $($u.Name) ($($u.SamAccountName)), currently enabled=$($u.Enabled), $(@($u.MemberOf).Count) group(s)" -ForegroundColor Cyan

# Record of what the account had, for the ticket
foreach ($g in @($u.MemberOf)) {
    [pscustomobject]@{ User = $u.SamAccountName; Item = 'Group'; Value = (($g -split ',')[0] -replace '^CN='); Action = $(if ($RemoveGroups) { 'Removed' } else { 'Kept' }); Time = $stamp }
}

if ($PSCmdlet.ShouldProcess($u.SamAccountName, 'Disable account')) {
    Disable-ADAccount -Identity $u -ErrorAction Stop
    Write-Host 'Account disabled.' -ForegroundColor Green
}
if ($ResetPassword -and $PSCmdlet.ShouldProcess($u.SamAccountName, 'Reset password to a random value')) {
    $bytes = New-Object byte[] 24
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $pw = [Convert]::ToBase64String($bytes) + 'aA1!'
    Set-ADAccountPassword -Identity $u -Reset -NewPassword (ConvertTo-SecureString -String $pw -AsPlainText -Force) -ErrorAction Stop
    Write-Host 'Password reset to a random value (not shown).' -ForegroundColor Green
}
if ($RemoveGroups) {
    foreach ($g in @($u.MemberOf)) {
        if ($PSCmdlet.ShouldProcess($u.SamAccountName, "Remove from $(($g -split ',')[0] -replace '^CN=')")) {
            try { Remove-ADGroupMember -Identity $g -Members $u -Confirm:$false -ErrorAction Stop }
            catch { Write-Host "Could not remove from $g : $($_.Exception.Message)" -ForegroundColor Yellow }
        }
    }
    if (-not $WhatIfPreference) { Write-Host 'Group memberships removed.' -ForegroundColor Green }
}
if ($StampDescription -and $PSCmdlet.ShouldProcess($u.SamAccountName, 'Update description')) {
    $desc = "Disabled $stamp by $me"
    if ($u.Description) { $desc = "$desc | was: $($u.Description)" }
    if ($desc.Length -gt 1024) { $desc = $desc.Substring(0, 1024) }
    Set-ADUser -Identity $u -Description $desc -ErrorAction Stop
}
if ($MoveToOU -and $PSCmdlet.ShouldProcess($u.SamAccountName, "Move to $MoveToOU")) {
    Move-ADObject -Identity $u.DistinguishedName -TargetPath $MoveToOU -ErrorAction Stop
    Write-Host "Moved to $MoveToOU" -ForegroundColor Green
}
[pscustomobject]@{ User = $u.SamAccountName; Item = 'Account'; Value = $u.Name; Action = 'Offboarded'; Time = $stamp }
