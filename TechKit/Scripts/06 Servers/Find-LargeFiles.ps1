# @Name:        Large Files & Folders
# @Description: "The disk is full" helper: biggest folders one level under a path and the largest individual files, skipping folders you cannot read.
# @Admin:       Yes
# @Changes:     No
# @Target:      Local, Remote
# @Tags:        disk, cleanup, large files, storage, treesize

[CmdletBinding()]
param(
    [string]$Path = 'C:\',

    [Parameter(HelpMessage = 'How many of the largest files to list')]
    [int]$Top = 25,

    [Parameter(HelpMessage = 'Ignore files smaller than this')]
    [int]$MinSizeMB = 100,

    [bool]$ShowFolderSizes = $true
)

if (-not (Test-Path -LiteralPath $Path)) { throw "Path not found: $Path" }
$root = (Resolve-Path -LiteralPath $Path).Path
$min = [int64]$MinSizeMB * 1MB
$big = New-Object System.Collections.Generic.List[object]
$folderTotals = @{}

$dirs = @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) })
$rootFiles = @(Get-ChildItem -LiteralPath $root -File -Force -ErrorAction SilentlyContinue)
$folderTotals['(files in root)'] = ($rootFiles | Measure-Object -Property Length -Sum).Sum
foreach ($f in $rootFiles) { if ($f.Length -ge $min) { $big.Add($f) } }

$n = 0
foreach ($dir in $dirs) {
    $n++
    Write-Progress -Activity "Scanning $root" -Status $dir.Name -PercentComplete ([int](100 * $n / [Math]::Max(1, $dirs.Count)))
    $sum = [int64]0
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($dir.FullName)
    while ($stack.Count) {
        $current = $stack.Pop()
        $di = New-Object System.IO.DirectoryInfo($current)
        try {
            foreach ($fi in $di.GetFiles()) {
                $sum += $fi.Length
                if ($fi.Length -ge $min) { $big.Add($fi) }
            }
            foreach ($sub in $di.GetDirectories()) {
                if (-not ($sub.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $stack.Push($sub.FullName) }
            }
        } catch { }
    }
    $folderTotals[$dir.Name] = $sum
}
Write-Progress -Activity "Scanning $root" -Completed

$drive = $null
try { $drive = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$($root.Substring(0, 2))'" } catch { }
if ($drive) { Write-Host ('{0} {1:N1} GB free of {2:N1} GB' -f $drive.DeviceID, ($drive.FreeSpace / 1GB), ($drive.Size / 1GB)) -ForegroundColor Cyan }

if ($ShowFolderSizes) {
    Write-Host "== Folder sizes under $root" -ForegroundColor Cyan
    $folderTotals.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 20 | ForEach-Object {
        Write-Host ('{0,10:N2} GB  {1}' -f ($_.Value / 1GB), $_.Key)
    }
}

Write-Host "== Largest files (>= $MinSizeMB MB)" -ForegroundColor Cyan
$big | Sort-Object Length -Descending | Select-Object -First $Top | ForEach-Object {
    [pscustomobject]@{
        Computer = $env:COMPUTERNAME
        SizeGB   = [Math]::Round($_.Length / 1GB, 2)
        Modified = $_.LastWriteTime
        File     = $_.FullName
    }
}
