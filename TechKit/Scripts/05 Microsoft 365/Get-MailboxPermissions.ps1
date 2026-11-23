# @Name:        Mailbox Permissions
# @Description: Who has Full Access, Send As and Send on Behalf on a mailbox, or on every mailbox (slower). Answers "who can read this inbox?".
# @Admin:       No
# @Changes:     No
# @Target:      M365
# @Connect:     Exchange
# @Modules:     ExchangeOnlineManagement
# @Tags:        exchange, mailbox, permissions, full access, send as, delegation

[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'Mailbox UPN; empty = all mailboxes')]
    [string]$Mailbox = '',

    [ValidateSet('All', 'UserMailbox', 'SharedMailbox')]
    [string]$Type = 'All'
)

if (-not (Get-Command Get-EXOMailbox -ErrorAction SilentlyContinue)) { throw 'Not connected to Exchange Online. Click the Microsoft 365 button in Tech Kit first.' }

if ($Mailbox) {
    $mbs = @(Get-EXOMailbox -Identity $Mailbox.Trim() -Properties GrantSendOnBehalfTo, RecipientTypeDetails)
} else {
    $types = @('UserMailbox', 'SharedMailbox')
    if ($Type -ne 'All') { $types = @($Type) }
    $mbs = @(Get-EXOMailbox -ResultSize Unlimited -RecipientTypeDetails $types -Properties GrantSendOnBehalfTo, RecipientTypeDetails)
}
$i = 0
foreach ($m in $mbs) {
    $i++
    Write-Progress -Activity 'Mailbox permissions' -Status $m.UserPrincipalName -PercentComplete ([int](100 * $i / [Math]::Max(1, $mbs.Count)))
    try {
        Get-EXOMailboxPermission -Identity $m.UserPrincipalName -ErrorAction Stop |
            Where-Object { $_.User -notlike 'NT AUTHORITY\*' -and -not $_.IsInherited -and $_.User -notlike 'S-1-5-*' } | ForEach-Object {
                [pscustomobject]@{ Mailbox = $m.UserPrincipalName; Type = [string]$m.RecipientTypeDetails; Permission = (@($_.AccessRights) -join ', '); Trustee = $_.User }
            }
    } catch { Write-Host "$($m.UserPrincipalName): $($_.Exception.Message)" -ForegroundColor Yellow }
    try {
        Get-EXORecipientPermission -Identity $m.UserPrincipalName -ErrorAction Stop |
            Where-Object { $_.Trustee -notlike 'NT AUTHORITY\*' } | ForEach-Object {
                [pscustomobject]@{ Mailbox = $m.UserPrincipalName; Type = [string]$m.RecipientTypeDetails; Permission = (@($_.AccessRights) -join ', '); Trustee = $_.Trustee }
            }
    } catch { }
    foreach ($d in @($m.GrantSendOnBehalfTo)) {
        if ($d) { [pscustomobject]@{ Mailbox = $m.UserPrincipalName; Type = [string]$m.RecipientTypeDetails; Permission = 'SendOnBehalf'; Trustee = [string]$d } }
    }
}
Write-Progress -Activity 'Mailbox permissions' -Completed
