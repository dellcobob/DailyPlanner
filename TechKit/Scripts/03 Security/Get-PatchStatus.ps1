# @Name:        Patch Status
# @Description: Shows the Windows build, recent updates from Windows Update history, days since the last update and pending reboot. Optionally searches for missing updates (local only, slower).
# @Admin:       No
# @Changes:     No
# @Target:      Local, Remote
# @Tags:        updates, patches, hotfix, windows update, compliance

[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'How many recent updates to list')]
    [int]$Recent = 15,

    [Parameter(HelpMessage = 'Search Windows Update / WSUS for missing updates (does not work over remoting)')]
    [switch]$CheckMissing
)

$os = Get-CimInstance -ClassName Win32_OperatingSystem
$cv = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$build = "$($os.BuildNumber).$($cv.UBR)"

$pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')

$history = @()
try {
    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $count = $searcher.GetTotalHistoryCount()
    if ($count -gt 0) {
        $history = @($searcher.QueryHistory(0, [Math]::Min($count, 200)) | Where-Object { $_.Title -and $_.Operation -eq 1 } |
            Sort-Object Date -Descending | Select-Object -First $Recent | ForEach-Object {
                $res = switch ($_.ResultCode) { 2 { 'Succeeded' } 3 { 'Succeeded with errors' } 4 { 'Failed' } 5 { 'Aborted' } default { 'In progress' } }
                [pscustomobject]@{
                    Computer  = $env:COMPUTERNAME
                    Installed = $_.Date.ToLocalTime()
                    Result    = $res
                    Title     = $_.Title
                }
            })
    }
} catch {
    Write-Host "Windows Update history is not available: $($_.Exception.Message)" -ForegroundColor DarkGray
}

$hotfix = @(Get-HotFix -ErrorAction SilentlyContinue | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending)
$lastDate = $null
$okHistory = @($history | Where-Object { $_.Result -like 'Succeeded*' })
if ($okHistory.Count) { $lastDate = $okHistory[0].Installed }
if ($hotfix.Count -and (-not $lastDate -or $hotfix[0].InstalledOn -gt $lastDate)) { $lastDate = $hotfix[0].InstalledOn }
$days = $null
if ($lastDate) { $days = [int]((Get-Date) - $lastDate).TotalDays }

$color = 'Green'
if ($null -eq $days -or $days -gt 45) { $color = 'Red' } elseif ($days -gt 30) { $color = 'Yellow' }
Write-Host ("{0}  {1} build {2}" -f $env:COMPUTERNAME, $os.Caption, $build) -ForegroundColor Cyan
Write-Host ("Last update installed: {0}  ({1} days ago)" -f $lastDate, $days) -ForegroundColor $color
if ($pending) { Write-Host 'A reboot is pending to finish installing updates.' -ForegroundColor Yellow }
$failed = @($history | Where-Object { $_.Result -eq 'Failed' })
if ($failed.Count) { Write-Host "$($failed.Count) of the recent updates failed. See the list below." -ForegroundColor Yellow }

$history

if ($CheckMissing) {
    Write-Host 'Searching for missing updates (can take several minutes)...' -ForegroundColor Cyan
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $result = $session.CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
        if ($result.Updates.Count -eq 0) { Write-Host 'No missing updates found.' -ForegroundColor Green }
        foreach ($u in $result.Updates) {
            [pscustomobject]@{
                Computer = $env:COMPUTERNAME
                Missing  = $u.Title
                Severity = $u.MsrcSeverity
                KB       = (@($u.KBArticleIDs) -join ', ')
                SizeMB   = [Math]::Round($u.MaxDownloadSize / 1MB, 1)
            }
        }
    } catch {
        Write-Host "Update search failed (over remoting this is expected): $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
