# @Name:        Locked-Out Users & Lockout Source
# @Description: Lists locked-out accounts and, by reading lockout events (4740) on the PDC emulator, which computer caused each lockout. Helps find the old phone or mapped drive with a stale password.
# @Admin:       No
# @Changes:     No
# @Target:      Local, Remote
# @Modules:     ActiveDirectory
# @Tags:        ad, lockout, 4740, source, pdc

[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'Read lockout events from the PDC (needs Event Log Readers or admin on the DC)')]
    [bool]$FindSource = $true,

    [Parameter(HelpMessage = 'Hours of lockout events to read')]
    [int]$Hours = 24,

    [Parameter(HelpMessage = 'Only this user (logon name); empty = everyone locked out now')]
    [string]$Identity = ''
)

Import-Module ActiveDirectory -ErrorAction Stop

$locked = @()
if ($Identity) { $locked = @(Get-ADUser -Identity $Identity.Trim() -Properties LockedOut, LockoutTime, BadLogonCount, LastBadPasswordAttempt) }
else { $locked = @(Search-ADAccount -LockedOut -UsersOnly | ForEach-Object { Get-ADUser -Identity $_.DistinguishedName -Properties LockedOut, LockoutTime, BadLogonCount, LastBadPasswordAttempt }) }

$sources = @{}
if ($FindSource) {
    $pdc = (Get-ADDomain).PDCEmulator
    Write-Host "Reading lockout events from $pdc ..." -ForegroundColor Cyan
    try {
        $ev = @(Get-WinEvent -ComputerName $pdc -FilterHashtable @{ LogName = 'Security'; Id = 4740; StartTime = (Get-Date).AddHours(-$Hours) } -ErrorAction Stop)
        foreach ($e in $ev) {
            $x = [xml]$e.ToXml()
            $d = @{}
            foreach ($n in $x.Event.EventData.Data) { $d[$n.Name] = [string]$n.'#text' }
            $user = $d['TargetUserName']
            if (-not $sources.ContainsKey($user)) { $sources[$user] = [System.Collections.Generic.List[string]]::new() }
            $entry = "$($d['TargetDomainName']) @ $($e.TimeCreated.ToString('MM-dd HH:mm'))"
            if (-not $sources[$user].Contains($entry)) { $sources[$user].Add($entry) }
        }
        Write-Host "$($ev.Count) lockout event(s) found." -ForegroundColor Cyan
    } catch {
        if ($_.Exception.Message -match 'No events were found') { Write-Host 'No lockout events in that window.' -ForegroundColor Green }
        else { Write-Host "Could not read the PDC Security log: $($_.Exception.Message)" -ForegroundColor Yellow }
    }
}

if (-not $locked.Count -and -not $sources.Count) { Write-Host 'Nobody is locked out right now.' -ForegroundColor Green; return }

foreach ($u in $locked) {
    [pscustomobject]@{
        SamAccountName  = $u.SamAccountName
        Name            = $u.Name
        LockedNow       = $u.LockedOut
        LockedSince     = $(if ($u.LockoutTime) { [datetime]::FromFileTime($u.LockoutTime) } else { $null })
        BadLogonCount   = $u.BadLogonCount
        LastBadPassword = $u.LastBadPasswordAttempt
        LockoutSource   = $(if ($sources.ContainsKey($u.SamAccountName)) { $sources[$u.SamAccountName] -join '; ' } else { '' })
    }
}
# Users that were locked out earlier but are not locked now
foreach ($k in $sources.Keys) {
    if (@($locked | Where-Object { $_.SamAccountName -eq $k }).Count) { continue }
    [pscustomobject]@{
        SamAccountName = $k; Name = ''; LockedNow = $false; LockedSince = $null; BadLogonCount = $null; LastBadPassword = $null
        LockoutSource = ($sources[$k] -join '; ')
    }
}
