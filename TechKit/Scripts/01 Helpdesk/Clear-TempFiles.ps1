# @Name:        Clear Temp Files
# @Description: Deletes old files from Windows Temp and every user's Temp folder, optionally browser caches. Locked files are skipped. Use What-If to see how much would be freed.
# @Admin:       Yes
# @Changes:     Yes
# @Target:      Local, Remote
# @Tags:        cleanup, disk, temp, cache

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(HelpMessage = 'Only delete files not modified for this many days')]
    [int]$OlderThanDays = 2,

    [Parameter(HelpMessage = 'Also clear Edge, Chrome and Firefox caches (browsers should be closed)')]
    [switch]$BrowserCaches,

    [Parameter(HelpMessage = 'Also clear the Windows Update download cache')]
    [switch]$WindowsUpdateCache
)

$cutoff = (Get-Date).AddDays(-$OlderThanDays)
$folders = New-Object System.Collections.Generic.List[string]
$folders.Add((Join-Path $env:SystemRoot 'Temp'))

$profiles = Get-ChildItem -Path (Join-Path $env:SystemDrive 'Users') -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notin @('Public', 'Default', 'Default User', 'All Users') }
foreach ($p in $profiles) {
    $folders.Add((Join-Path $p.FullName 'AppData\Local\Temp'))
    if ($BrowserCaches) {
        $folders.Add((Join-Path $p.FullName 'AppData\Local\Microsoft\Edge\User Data\Default\Cache'))
        $folders.Add((Join-Path $p.FullName 'AppData\Local\Google\Chrome\User Data\Default\Cache'))
        $ff = Join-Path $p.FullName 'AppData\Local\Mozilla\Firefox\Profiles'
        if (Test-Path -LiteralPath $ff) {
            Get-ChildItem -LiteralPath $ff -Directory -ErrorAction SilentlyContinue | ForEach-Object { $folders.Add((Join-Path $_.FullName 'cache2')) }
        }
    }
}
if ($WindowsUpdateCache) { $folders.Add((Join-Path $env:SystemRoot 'SoftwareDistribution\Download')) }

$totalFreed = 0
foreach ($folder in $folders) {
    if (-not (Test-Path -LiteralPath $folder)) { continue }
    $files = @(Get-ChildItem -LiteralPath $folder -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cutoff })
    if ($files.Count -eq 0) { continue }
    $bytes = ($files | Measure-Object -Property Length -Sum).Sum
    $mb = [Math]::Round($bytes / 1MB, 1)
    $deleted = 0
    $freed = 0
    if ($PSCmdlet.ShouldProcess($folder, "Delete $($files.Count) files ($mb MB)")) {
        foreach ($f in $files) {
            try {
                $len = $f.Length
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                $deleted++
                $freed += $len
            } catch { }
        }
        $totalFreed += $freed
        Write-Host ('Cleared {0}: {1} of {2} files, {3:N1} MB' -f $folder, $deleted, $files.Count, ($freed / 1MB)) -ForegroundColor Green
    }
    [pscustomobject]@{
        Computer = $env:COMPUTERNAME
        Folder   = $folder
        Files    = $files.Count
        SizeMB   = $mb
        Deleted  = $deleted
        FreedMB  = [Math]::Round($freed / 1MB, 1)
    }
}
if (-not $WhatIfPreference) {
    Write-Host ('Total freed on {0}: {1:N1} MB' -f $env:COMPUTERNAME, ($totalFreed / 1MB)) -ForegroundColor Cyan
}
