# @Name:        Archive & Clean Old Files
# @Description: Zips files older than N days (IIS logs, app logs, exports) into one archive per month and deletes the originals once they are safely in the zip. Or just deletes, or just zips. Use What-If to see how much space you would get back.
# @Admin:       Yes
# @Changes:     Yes
# @Target:      Local, Remote
# @Tags:        logs, cleanup, zip, archive, disk, iis, retention

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Folder with the files, for example C:\inetpub\logs\LogFiles')]
    [string]$Path,

    [Parameter(HelpMessage = 'File pattern, for example *.log or *.*')]
    [string]$Include = '*.log',

    [int]$OlderThanDays = 30,

    [bool]$Recurse = $true,

    [ValidateSet('ZipThenDelete', 'ZipOnly', 'DeleteOnly')]
    [string]$Mode = 'ZipThenDelete',

    [Parameter(HelpMessage = 'Where the zips go (empty = an _Archive folder inside Path)')]
    [string]$ArchiveFolder = '',

    [Parameter(HelpMessage = 'Also delete archives older than this many days (0 = keep all)')]
    [int]$DeleteArchivesOlderThanDays = 0
)

if (-not (Test-Path -LiteralPath $Path)) { throw "Path not found: $Path" }
$root = (Resolve-Path -LiteralPath $Path).Path
if (-not $ArchiveFolder) { $ArchiveFolder = Join-Path $root '_Archive' }
$cutoff = (Get-Date).AddDays(-$OlderThanDays)

$files = @(Get-ChildItem -LiteralPath $root -Filter $Include -File -Recurse:$Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt $cutoff -and $_.FullName -notlike "$ArchiveFolder*" })
if (-not $files.Count) { Write-Host "No $Include files older than $OlderThanDays days under $root." -ForegroundColor Green; return }
$total = ($files | Measure-Object -Property Length -Sum).Sum
Write-Host ("{0} file(s), {1:N1} MB older than {2} days under {3}" -f $files.Count, ($total / 1MB), $OlderThanDays, $root) -ForegroundColor Cyan

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$freed = [int64]0

foreach ($group in ($files | Group-Object { $_.LastWriteTime.ToString('yyyy-MM') } | Sort-Object Name)) {
    $sizeMB = [Math]::Round((($group.Group | Measure-Object -Property Length -Sum).Sum) / 1MB, 1)
    $zipPath = Join-Path $ArchiveFolder ("{0}_{1}.zip" -f ((Split-Path -Path $root -Leaf) -replace '[^\w\-]', '_'), $group.Name)
    $zipped = 0
    $deleted = 0
    if ($Mode -ne 'DeleteOnly') {
        if ($PSCmdlet.ShouldProcess($zipPath, "Add $($group.Count) files ($sizeMB MB) from $($group.Name)")) {
            if (-not (Test-Path -LiteralPath $ArchiveFolder)) { $null = New-Item -ItemType Directory -Path $ArchiveFolder -Force }
            $zipMode = [System.IO.Compression.ZipArchiveMode]::Create
            if (Test-Path -LiteralPath $zipPath) { $zipMode = [System.IO.Compression.ZipArchiveMode]::Update }
            $zip = [System.IO.Compression.ZipFile]::Open($zipPath, $zipMode)
            try {
                foreach ($f in $group.Group) {
                    $entryName = $f.FullName.Substring($root.Length).TrimStart('\')
                    try {
                        $null = [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, $entryName, [System.IO.Compression.CompressionLevel]::Optimal)
                        $zipped++
                        if ($Mode -eq 'ZipThenDelete') {
                            $len = $f.Length
                            try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $deleted++; $freed += $len } catch { }
                        }
                    } catch {
                        Write-Host "Skipped (in use?): $($f.FullName)" -ForegroundColor DarkGray
                    }
                }
            } finally {
                $zip.Dispose()
            }
        }
    } else {
        foreach ($f in $group.Group) {
            if ($PSCmdlet.ShouldProcess($f.FullName, 'Delete')) {
                $len = $f.Length
                try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $deleted++; $freed += $len } catch { }
            }
        }
    }
    $zipMB = $null
    if (Test-Path -LiteralPath $zipPath) { $zipMB = [Math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 1) }
    [pscustomobject]@{
        Computer   = $env:COMPUTERNAME
        Month      = $group.Name
        Files      = $group.Count
        OriginalMB = $sizeMB
        Zipped     = $zipped
        Deleted    = $deleted
        Archive    = $(if ($Mode -ne 'DeleteOnly') { $zipPath } else { '' })
        ArchiveMB  = $zipMB
    }
}

if ($DeleteArchivesOlderThanDays -gt 0 -and (Test-Path -LiteralPath $ArchiveFolder)) {
    $oldZips = @(Get-ChildItem -LiteralPath $ArchiveFolder -Filter '*.zip' -File | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$DeleteArchivesOlderThanDays) })
    foreach ($z in $oldZips) {
        if ($PSCmdlet.ShouldProcess($z.FullName, 'Delete old archive')) { $freed += $z.Length; Remove-Item -LiteralPath $z.FullName -Force }
    }
}
if (-not $WhatIfPreference) { Write-Host ('Freed {0:N1} MB on {1}.' -f ($freed / 1MB), $env:COMPUTERNAME) -ForegroundColor Green }
