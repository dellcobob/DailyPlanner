# @Name:        Privileged Groups Audit
# @Description: Everyone in Domain Admins, Enterprise Admins, Schema Admins, Administrators, the Operators groups, DnsAdmins and Group Policy Creator Owners (nested members included), with last logon and password age. Save a baseline and later runs show who was added or removed.
# @Admin:       No
# @Changes:     No
# @Target:      Local, Remote
# @Modules:     ActiveDirectory
# @Tags:        ad, security, admins, privileged, audit, baseline

[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'Save this run as the baseline for later comparisons (stored on the USB)')]
    [switch]$SaveBaseline,

    [Parameter(HelpMessage = 'Flag admin accounts with no logon for this many days')]
    [int]$StaleDays = 90
)

Import-Module ActiveDirectory -ErrorAction Stop
$domain = Get-ADDomain
$sid = $domain.DomainSID.Value
$groups = [ordered]@{
    'Domain Admins'                 = "$sid-512"
    'Enterprise Admins'             = "$sid-519"
    'Schema Admins'                 = "$sid-518"
    'Group Policy Creator Owners'   = "$sid-520"
    'Administrators'                = 'S-1-5-32-544'
    'Account Operators'             = 'S-1-5-32-548'
    'Server Operators'              = 'S-1-5-32-549'
    'Print Operators'               = 'S-1-5-32-550'
    'Backup Operators'              = 'S-1-5-32-551'
    'DnsAdmins'                     = 'DnsAdmins'
}

$now = Get-Date
$rows = New-Object System.Collections.Generic.List[object]
foreach ($label in $groups.Keys) {
    $g = $null
    try { $g = Get-ADGroup -Identity $groups[$label] -ErrorAction Stop } catch { continue }
    $members = @()
    try { $members = @(Get-ADGroupMember -Identity $g -Recursive -ErrorAction Stop) } catch { Write-Host "$label : $($_.Exception.Message)" -ForegroundColor Yellow }
    foreach ($m in $members) {
        $info = $null
        if ($m.objectClass -eq 'user') {
            try { $info = Get-ADUser -Identity $m.DistinguishedName -Properties Enabled, LastLogonDate, PasswordLastSet, PasswordNeverExpires, Description } catch { }
        }
        $flags = @()
        if ($info) {
            if ($info.Enabled -and $info.PasswordNeverExpires) { $flags += 'Password never expires' }
            if ($info.Enabled -and ($null -eq $info.LastLogonDate -or ($now - $info.LastLogonDate).TotalDays -gt $StaleDays)) { $flags += "No logon in $StaleDays+ days" }
            if ($info.PasswordLastSet -and ($now - $info.PasswordLastSet).TotalDays -gt 365) { $flags += 'Password older than 1 year' }
        }
        $rows.Add([pscustomobject]@{
            Group          = $g.Name
            Member         = $m.Name
            SamAccountName = $m.SamAccountName
            Type           = $m.objectClass
            Enabled        = $(if ($info) { $info.Enabled } else { $null })
            LastLogon      = $(if ($info) { $info.LastLogonDate } else { $null })
            PasswordSet    = $(if ($info) { $info.PasswordLastSet } else { $null })
            Flags          = ($flags -join '; ')
            Change         = ''
        })
    }
}

# Baseline comparison (only possible when running on this PC inside Tech Kit, where the USB is reachable)
$baseFile = $null
if ($env:TECHKIT_ROOT) {
    $dir = Join-Path $env:TECHKIT_ROOT 'Reports\Baselines'
    $baseFile = Join-Path $dir ("PrivilegedGroups-{0}.json" -f $domain.DNSRoot)
    if (Test-Path -LiteralPath $baseFile) {
        $base = @(Get-Content -LiteralPath $baseFile -Raw | ConvertFrom-Json)
        $baseKeys = @{}
        foreach ($b in $base) { $baseKeys["$($b.Group)|$($b.SamAccountName)"] = $b }
        $nowKeys = @{}
        foreach ($r in $rows) {
            $k = "$($r.Group)|$($r.SamAccountName)"
            $nowKeys[$k] = $true
            if (-not $baseKeys.ContainsKey($k)) { $r.Change = 'ADDED since baseline'; Write-Host "ADDED: $($r.SamAccountName) -> $($r.Group)" -ForegroundColor Red }
        }
        foreach ($k in $baseKeys.Keys) {
            if (-not $nowKeys.ContainsKey($k)) {
                $b = $baseKeys[$k]
                Write-Host "REMOVED: $($b.SamAccountName) from $($b.Group)" -ForegroundColor Yellow
                $rows.Add([pscustomobject]@{ Group = $b.Group; Member = $b.Member; SamAccountName = $b.SamAccountName; Type = $b.Type; Enabled = $null; LastLogon = $null; PasswordSet = $null; Flags = ''; Change = 'REMOVED since baseline' })
            }
        }
        Write-Host "Compared with baseline from $((Get-Item -LiteralPath $baseFile).LastWriteTime)." -ForegroundColor Cyan
    } else {
        Write-Host 'No baseline yet. Tick SaveBaseline to record one.' -ForegroundColor DarkGray
    }
    if ($SaveBaseline) {
        if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        $rows | Where-Object { $_.Change -notlike 'REMOVED*' } | Select-Object Group, Member, SamAccountName, Type | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $baseFile -Encoding UTF8
        Write-Host "Baseline saved: $baseFile" -ForegroundColor Green
    }
} elseif ($SaveBaseline) {
    Write-Host 'Baselines can only be saved when the script runs on this PC (not remotely).' -ForegroundColor Yellow
}

$users = @($rows | Where-Object { $_.Type -eq 'user' } | Select-Object -ExpandProperty SamAccountName -Unique)
Write-Host "$($users.Count) unique user account(s) hold privileged group membership in $($domain.DNSRoot)." -ForegroundColor Cyan
foreach ($r in @($rows | Where-Object { $_.Flags })) { Write-Host "Review $($r.SamAccountName) ($($r.Group)): $($r.Flags)" -ForegroundColor Yellow }
$rows | Sort-Object Group, Member
