# @Name:        Forwarding & Inbox Rules Audit
# @Description: Finds mailboxes that forward mail (mailbox forwarding and inbox rules), marks external destinations, and flags rules that delete or hide mail. A key check after a phishing or business-email-compromise incident.
# @Admin:       No
# @Changes:     No
# @Target:      M365
# @Connect:     Exchange
# @Modules:     ExchangeOnlineManagement
# @Tags:        exchange, forwarding, inbox rules, bec, phishing, security

[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'Check inbox rules on every mailbox (about 1 second per mailbox)')]
    [bool]$IncludeInboxRules = $true,

    [Parameter(HelpMessage = 'Only this mailbox (UPN); empty = all mailboxes')]
    [string]$Mailbox = ''
)

if (-not (Get-Command Get-EXOMailbox -ErrorAction SilentlyContinue)) { throw 'Not connected to Exchange Online. Click the Microsoft 365 button in Tech Kit first.' }

$domains = @(Get-AcceptedDomain | ForEach-Object { ([string]$_.DomainName).ToLowerInvariant() })
function Get-Addresses { param($Value) @([regex]::Matches(($Value -join ' '), '[\w\.\+\-'']+@[\w\.\-]+') | ForEach-Object { $_.Value.ToLowerInvariant() } | Select-Object -Unique) }
function Test-External {
    param([string[]]$Addresses)
    foreach ($a in $Addresses) { if ($domains -notcontains ($a -split '@')[-1]) { return $true } }
    $false
}

if ($Mailbox) { $mbs = @(Get-EXOMailbox -Identity $Mailbox.Trim() -Properties ForwardingSmtpAddress, ForwardingAddress, DeliverToMailboxAndForward) }
else { $mbs = @(Get-EXOMailbox -ResultSize Unlimited -Properties ForwardingSmtpAddress, ForwardingAddress, DeliverToMailboxAndForward) }
Write-Host "Checking $($mbs.Count) mailbox(es)..." -ForegroundColor Cyan

$i = 0
foreach ($m in $mbs) {
    $i++
    Write-Progress -Activity 'Forwarding audit' -Status $m.UserPrincipalName -PercentComplete ([int](100 * $i / [Math]::Max(1, $mbs.Count)))
    if ($m.ForwardingSmtpAddress -or $m.ForwardingAddress) {
        $dest = @(Get-Addresses @([string]$m.ForwardingSmtpAddress))
        $ext = Test-External $dest
        if ($m.ForwardingAddress) { $dest += "recipient: $($m.ForwardingAddress)" }
        if ($ext) { Write-Host "EXTERNAL mailbox forward: $($m.UserPrincipalName) -> $($dest -join ', ')" -ForegroundColor Red }
        [pscustomobject]@{
            Mailbox = $m.UserPrincipalName; Kind = 'Mailbox forwarding'; Rule = ''; Enabled = $true
            ForwardsTo = ($dest -join ', '); External = $(if ($ext) { 'Yes' } else { 'No' })
            KeepsCopy = $m.DeliverToMailboxAndForward; Suspicious = ''
        }
    }
    if (-not $IncludeInboxRules) { continue }
    $rules = @()
    try { $rules = @(Get-InboxRule -Mailbox $m.UserPrincipalName -ErrorAction Stop -WarningAction SilentlyContinue) } catch { }
    foreach ($r in $rules) {
        $fwd = @(Get-Addresses (@($r.ForwardTo) + @($r.ForwardAsAttachmentTo) + @($r.RedirectTo) | ForEach-Object { [string]$_ }))
        $sus = @()
        if ($r.DeleteMessage) { $sus += 'Deletes mail' }
        if ([string]$r.MoveToFolder -match 'RSS|Archive|Conversation History|Junk|Deleted') { $sus += "Moves to $($r.MoveToFolder)" }
        if ($r.MarkAsRead -and ($r.DeleteMessage -or $r.MoveToFolder)) { $sus += 'Marks read' }
        if ($r.Name -match '^[\W\.]{0,3}$') { $sus += 'Blank or odd name' }
        if (-not $fwd.Count -and -not $sus.Count) { continue }
        $ext = Test-External $fwd
        if ($ext -or $sus.Count -ge 2) { Write-Host "Review rule '$($r.Name)' on $($m.UserPrincipalName): $(($fwd + $sus) -join '; ')" -ForegroundColor Yellow }
        [pscustomobject]@{
            Mailbox = $m.UserPrincipalName; Kind = 'Inbox rule'; Rule = $r.Name; Enabled = $r.Enabled
            ForwardsTo = ($fwd -join ', '); External = $(if ($ext) { 'Yes' } elseif ($fwd.Count) { 'No' } else { '' })
            KeepsCopy = $null; Suspicious = ($sus -join '; ')
        }
    }
}
Write-Progress -Activity 'Forwarding audit' -Completed
Write-Host 'Done. Also check Exchange admin center > Mail flow > Rules for tenant-wide forwarding rules.' -ForegroundColor Cyan
