# @Name:        Mailbox Size Report
# @Description: Size, item count, quota used and last logon for every mailbox (or the largest N), with optional archive sizes. Finds mailboxes about to hit their quota.
# @Admin:       No
# @Changes:     No
# @Target:      M365
# @Connect:     Exchange
# @Modules:     ExchangeOnlineManagement
# @Tags:        exchange, mailbox, size, quota, storage

[CmdletBinding()]
param(
    [ValidateSet('All', 'UserMailbox', 'SharedMailbox')]
    [string]$Type = 'All',

    [Parameter(HelpMessage = 'Only show the largest N mailboxes (0 = all)')]
    [int]$Top = 0,

    [switch]$IncludeArchive
)

if (-not (Get-Command Get-EXOMailbox -ErrorAction SilentlyContinue)) { throw 'Not connected to Exchange Online. Click the Microsoft 365 button in Tech Kit first.' }

function ConvertTo-Bytes {
    param($Value)
    $s = [string]$Value
    if ($s -match '\(([\d,\.\s]+) bytes\)') { return [int64]($Matches[1] -replace '[^\d]', '') }
    $null
}

$types = @('UserMailbox', 'SharedMailbox')
if ($Type -ne 'All') { $types = @($Type) }
Write-Host 'Reading mailboxes...' -ForegroundColor Cyan
$mbs = @(Get-EXOMailbox -ResultSize Unlimited -RecipientTypeDetails $types -Properties ProhibitSendQuota, ArchiveStatus)
$i = 0
$rows = foreach ($m in $mbs) {
    $i++
    Write-Progress -Activity 'Mailbox statistics' -Status $m.UserPrincipalName -PercentComplete ([int](100 * $i / [Math]::Max(1, $mbs.Count)))
    $st = $null
    try { $st = Get-EXOMailboxStatistics -Identity $m.ExternalDirectoryObjectId -Properties LastLogonTime -ErrorAction Stop } catch { }
    $bytes = $null
    if ($st) { $bytes = ConvertTo-Bytes $st.TotalItemSize }
    $quota = ConvertTo-Bytes $m.ProhibitSendQuota
    $archive = $null
    if ($IncludeArchive -and [string]$m.ArchiveStatus -eq 'Active') {
        try { $archive = ConvertTo-Bytes (Get-EXOMailboxStatistics -Identity $m.ExternalDirectoryObjectId -Archive -ErrorAction Stop).TotalItemSize } catch { }
    }
    $pct = $null
    if ($bytes -and $quota) { $pct = [Math]::Round(100 * $bytes / $quota, 1) }
    [pscustomobject]@{
        DisplayName = $m.DisplayName
        UPN         = $m.UserPrincipalName
        Type        = [string]$m.RecipientTypeDetails
        SizeGB      = $(if ($bytes -ne $null) { [Math]::Round($bytes / 1GB, 2) } else { $null })
        Items       = $(if ($st) { $st.ItemCount } else { $null })
        QuotaGB     = $(if ($quota) { [Math]::Round($quota / 1GB, 1) } else { $null })
        PercentUsed = $pct
        LastLogon   = $(if ($st) { $st.LastLogonTime } else { $null })
        ArchiveGB   = $(if ($archive -ne $null) { [Math]::Round($archive / 1GB, 2) } else { $null })
    }
}
Write-Progress -Activity 'Mailbox statistics' -Completed
$rows = @($rows | Sort-Object SizeGB -Descending)
$near = @($rows | Where-Object { $_.PercentUsed -ge 90 })
$total = ($rows | Measure-Object -Property SizeGB -Sum).Sum
Write-Host ("{0} mailboxes, {1:N1} GB total." -f $rows.Count, $total) -ForegroundColor Cyan
foreach ($n in $near) { Write-Host "$($n.UPN) is at $($n.PercentUsed)% of quota" -ForegroundColor Yellow }
if ($Top -gt 0) { $rows = @($rows | Select-Object -First $Top) }
$rows
