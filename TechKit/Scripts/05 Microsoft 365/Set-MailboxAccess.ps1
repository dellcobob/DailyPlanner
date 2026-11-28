# @Name:        Grant or Remove Mailbox Access
# @Description: Gives (or takes away) Full Access, Send As or Send on Behalf on a mailbox or shared mailbox, with auto-mapping in Outlook. Shows the current permissions first.
# @Admin:       No
# @Changes:     Yes
# @Target:      M365
# @Connect:     Exchange
# @Modules:     ExchangeOnlineManagement
# @Tags:        exchange, mailbox, permissions, shared mailbox, full access, send as, delegate

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Mailbox or shared mailbox (UPN or e-mail)')]
    [string]$Mailbox,

    [Parameter(Mandatory = $true, HelpMessage = 'People getting access, one per line')]
    [string[]]$User,

    [ValidateSet('FullAccess', 'SendAs', 'SendOnBehalf', 'FullAccess + SendAs')]
    [string]$Access = 'FullAccess',

    [Parameter(HelpMessage = 'Add the mailbox to their Outlook automatically (Full Access only)')]
    [bool]$AutoMapping = $true,

    [Parameter(HelpMessage = 'Remove the access instead of granting it')]
    [switch]$Remove
)

if (-not (Get-Command Get-EXOMailbox -ErrorAction SilentlyContinue)) { throw 'Not connected to Exchange Online. Click the Microsoft 365 button in Tech Kit first.' }
$mbx = Get-EXOMailbox -Identity $Mailbox.Trim() -Properties GrantSendOnBehalfTo, RecipientTypeDetails -ErrorAction Stop
Write-Host "$($mbx.DisplayName) <$($mbx.PrimarySmtpAddress)> ($($mbx.RecipientTypeDetails))" -ForegroundColor Cyan

$full = @(Get-EXOMailboxPermission -Identity $mbx.PrimarySmtpAddress | Where-Object { $_.User -notlike 'NT AUTHORITY\*' -and -not $_.IsInherited })
$sendAs = @(Get-EXORecipientPermission -Identity $mbx.PrimarySmtpAddress | Where-Object { $_.Trustee -notlike 'NT AUTHORITY\*' })
Write-Host "  Full Access now : $((@($full | ForEach-Object { $_.User })) -join ', ')"
Write-Host "  Send As now     : $((@($sendAs | ForEach-Object { $_.Trustee })) -join ', ')"
Write-Host "  On Behalf now   : $(@($mbx.GrantSendOnBehalfTo) -join ', ')"

$doFull = $Access -in @('FullAccess', 'FullAccess + SendAs')
$doSendAs = $Access -in @('SendAs', 'FullAccess + SendAs')
$doBehalf = $Access -eq 'SendOnBehalf'
$verb = $(if ($Remove) { 'Remove' } else { 'Grant' })

foreach ($raw in $User) {
    foreach ($who in ($raw -split '[,;\s]+' | Where-Object { $_ })) {
        $steps = @()
        if ($doFull) { $steps += 'FullAccess' }
        if ($doSendAs) { $steps += 'SendAs' }
        if ($doBehalf) { $steps += 'SendOnBehalf' }
        foreach ($s in $steps) {
            $res = 'OK'
            if (-not $PSCmdlet.ShouldProcess("$who on $($mbx.PrimarySmtpAddress)", "$verb $s")) { $res = 'What-If' }
            else {
                try {
                    switch ($s) {
                        'FullAccess' {
                            if ($Remove) { Remove-MailboxPermission -Identity $mbx.PrimarySmtpAddress -User $who -AccessRights FullAccess -InheritanceType All -Confirm:$false -ErrorAction Stop }
                            else { $null = Add-MailboxPermission -Identity $mbx.PrimarySmtpAddress -User $who -AccessRights FullAccess -InheritanceType All -AutoMapping $AutoMapping -ErrorAction Stop }
                        }
                        'SendAs' {
                            if ($Remove) { Remove-RecipientPermission -Identity $mbx.PrimarySmtpAddress -Trustee $who -AccessRights SendAs -Confirm:$false -ErrorAction Stop }
                            else { $null = Add-RecipientPermission -Identity $mbx.PrimarySmtpAddress -Trustee $who -AccessRights SendAs -Confirm:$false -ErrorAction Stop }
                        }
                        'SendOnBehalf' {
                            $change = $(if ($Remove) { @{ Remove = $who } } else { @{ Add = $who } })
                            Set-Mailbox -Identity $mbx.PrimarySmtpAddress -GrantSendOnBehalfTo $change -ErrorAction Stop
                        }
                    }
                    Write-Host "  $verb $s for $who" -ForegroundColor Green
                } catch {
                    $res = "FAIL: $($_.Exception.Message)"
                    Write-Host "  $verb $s for $who failed: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
            [pscustomobject]@{ Mailbox = [string]$mbx.PrimarySmtpAddress; User = $who; Permission = $s; Action = $verb; Result = $res }
        }
    }
}
if (-not $Remove -and $doFull -and $AutoMapping) { Write-Host 'Outlook picks up auto-mapped mailboxes within an hour or after a restart.' -ForegroundColor DarkGray }
