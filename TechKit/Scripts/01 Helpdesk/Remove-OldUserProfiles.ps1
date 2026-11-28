# @Name:        User Profile Cleanup
# @Description: Lists Windows user profiles with their real last logon and logoff times (from the profile registry, not the unreliable folder dates) and removes profiles idle longer than N days. Leaves loaded, special and excluded profiles alone. Lists only unless you tick RemoveProfiles.
# @Admin:       Yes
# @Changes:     Yes
# @Target:      Local, Remote
# @Tags:        profiles, cleanup, disk, rds, shared pc, logon

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(HelpMessage = 'Profiles idle longer than this are candidates')]
    [int]$OlderThanDays = 90,

    [Parameter(HelpMessage = 'Actually delete the candidate profiles (otherwise just list)')]
    [switch]$RemoveProfiles,

    [Parameter(HelpMessage = 'User names never to remove (wildcards allowed)')]
    [string[]]$Exclude = @('Administrator', 'admin*', 'svc*'),

    [Parameter(HelpMessage = 'Measure each profile folder (slower)')]
    [switch]$IncludeSizes
)

function ConvertFrom-RegTime {
    param($Low, $High)
    if ($null -eq $Low -or $null -eq $High) { return $null }
    $lo = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int32]$Low), 0)
    $hi = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int32]$High), 0)
    $ft = ([int64]$hi -shl 32) -bor [int64]$lo
    if ($ft -le 0) { return $null }
    try { [DateTime]::FromFileTime($ft) } catch { $null }
}

$listKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
$cim = @{}
Get-CimInstance -ClassName Win32_UserProfile | ForEach-Object { $cim[$_.SID] = $_ }
$now = Get-Date
$me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$removed = 0

$rows = foreach ($k in @(Get-ChildItem -Path $listKey -ErrorAction Stop)) {
    $sid = $k.PSChildName
    if ($sid -notmatch '^S-1-5-21-' -and $sid -notmatch '^S-1-12-1-') { continue }
    $p = Get-ItemProperty -Path $k.PSPath
    $path = [string]$p.ProfileImagePath
    $user = Split-Path -Path $path -Leaf
    try { $user = (New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate([System.Security.Principal.NTAccount]).Value } catch { }
    $logon = ConvertFrom-RegTime $p.LocalProfileLoadTimeLow $p.LocalProfileLoadTimeHigh
    $logoff = ConvertFrom-RegTime $p.LocalProfileUnloadTimeLow $p.LocalProfileUnloadTimeHigh
    $c = $cim[$sid]
    $last = @($logon, $logoff) | Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1
    if (-not $last -and $c -and $c.LastUseTime) { $last = $c.LastUseTime }
    $idle = $null
    if ($last) { $idle = [int]($now - $last).TotalDays }

    $reason = ''
    $short = ($user -split '\\')[-1]
    if ($c -and $c.Loaded) { $reason = 'Signed in now' }
    elseif ($c -and $c.Special) { $reason = 'Special profile' }
    elseif ($sid -eq $me) { $reason = 'Your profile' }
    elseif (@($Exclude | Where-Object { $short -like $_ }).Count) { $reason = 'Excluded' }
    elseif ($null -eq $idle) { $reason = 'No usage data' }
    elseif ($idle -lt $OlderThanDays) { $reason = 'Recently used' }

    $size = $null
    if ($IncludeSizes -and (Test-Path -LiteralPath $path)) {
        $size = [Math]::Round(((Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum) / 1GB, 2)
    }

    $action = 'Kept'
    if (-not $reason) {
        $action = 'Candidate'
        if ($RemoveProfiles) {
            if (-not $c) {
                $action = 'Skipped (no WMI profile object)'
            } elseif ($PSCmdlet.ShouldProcess("$user ($path)", "Delete user profile idle $idle days")) {
                try {
                    Remove-CimInstance -InputObject $c -ErrorAction Stop
                    $action = 'Removed'
                    $removed++
                    Write-Host "Removed $user ($idle days idle)" -ForegroundColor Green
                } catch {
                    $action = "Failed: $($_.Exception.Message)"
                    Write-Host "Could not remove $user : $($_.Exception.Message)" -ForegroundColor Red
                }
            } else {
                $action = 'Would remove'
            }
        }
    }
    [pscustomobject]@{
        Computer   = $env:COMPUTERNAME
        User       = $user
        Path       = $path
        LastLogon  = $logon
        LastLogoff = $logoff
        DaysIdle   = $idle
        SizeGB     = $size
        Action     = $action
        Reason     = $reason
    }
}
$rows = @($rows)
$cand = @($rows | Where-Object { $_.Action -in @('Candidate', 'Would remove', 'Removed') }).Count
Write-Host "$($rows.Count) profile(s) on $env:COMPUTERNAME, $cand idle over $OlderThanDays days$(if ($RemoveProfiles) { ", $removed removed" })." -ForegroundColor Cyan
if (-not $RemoveProfiles -and $cand) { Write-Host 'Nothing was deleted. Tick RemoveProfiles (and try What-If first) to clean up.' -ForegroundColor DarkGray }
$rows | Sort-Object DaysIdle -Descending
