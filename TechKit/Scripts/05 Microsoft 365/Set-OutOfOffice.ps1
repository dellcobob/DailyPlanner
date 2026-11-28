# @Name:        Set Out of Office
# @Description: Turns automatic replies on (now or for a date range) or off for any mailbox, for the VIP who forgot before leaving. Shows the current setting first.
# @Admin:       No
# @Changes:     Yes
# @Target:      M365
# @Connect:     Exchange
# @Modules:     ExchangeOnlineManagement
# @Tags:        exchange, out of office, auto reply, vacation, oof

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Mailbox (UPN or e-mail)')]
    [string]$Mailbox,

    [ValidateSet('On', 'Scheduled', 'Off')]
    [string]$State = 'On',

    [Parameter(HelpMessage = 'Reply for people inside the organization')]
    [string]$InternalMessage = '',

    [Parameter(HelpMessage = 'Reply for outside senders (empty = same as internal)')]
    [string]$ExternalMessage = '',

    [ValidateSet('All', 'Known', 'None')]
    [string]$ExternalAudience = 'All',

    [Parameter(HelpMessage = 'For Scheduled: start, for example 2026-12-22 08:00')]
    [string]$Start = '',

    [Parameter(HelpMessage = 'For Scheduled: end, for example 2027-01-05 08:00')]
    [string]$End = ''
)

if (-not (Get-Command Get-MailboxAutoReplyConfiguration -ErrorAction SilentlyContinue)) { throw 'Not connected to Exchange Online. Click the Microsoft 365 button in Tech Kit first.' }
$cur = Get-MailboxAutoReplyConfiguration -Identity $Mailbox.Trim() -ErrorAction Stop
Write-Host "Current: $($cur.AutoReplyState)$(if ($cur.AutoReplyState -eq 'Scheduled') { " ($($cur.StartTime) to $($cur.EndTime))" })" -ForegroundColor Cyan

$p = @{ Identity = $Mailbox.Trim(); ErrorAction = 'Stop' }
switch ($State) {
    'Off' { $p.AutoReplyState = 'Disabled' }
    default {
        if (-not $InternalMessage) { throw 'Write an InternalMessage.' }
        $p.AutoReplyState = $(if ($State -eq 'Scheduled') { 'Scheduled' } else { 'Enabled' })
        $p.InternalMessage = $InternalMessage -replace "`r?`n", '<br>'
        $ext = $ExternalMessage
        if (-not $ext) { $ext = $InternalMessage }
        $p.ExternalMessage = $ext -replace "`r?`n", '<br>'
        $p.ExternalAudience = $ExternalAudience
        if ($State -eq 'Scheduled') {
            if (-not $Start -or -not $End) { throw 'Scheduled needs Start and End.' }
            $p.StartTime = [datetime]$Start
            $p.EndTime = [datetime]$End
            if ($p.EndTime -le $p.StartTime) { throw 'End must be after Start.' }
        }
    }
}
if ($PSCmdlet.ShouldProcess($Mailbox, "Set automatic replies to $($p.AutoReplyState)")) {
    Set-MailboxAutoReplyConfiguration @p
    $new = Get-MailboxAutoReplyConfiguration -Identity $Mailbox.Trim()
    Write-Host "Automatic replies are now $($new.AutoReplyState)." -ForegroundColor Green
    [pscustomobject]@{ Mailbox = $Mailbox; State = [string]$new.AutoReplyState; Start = $new.StartTime; End = $new.EndTime; ExternalAudience = [string]$new.ExternalAudience }
}
