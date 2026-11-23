# @Name:        Folder Sizes (incl. size on disk)
# @Description: Sizes of the folders under a path, with optional size on disk so you can see that a 20 GB OneDrive folder only uses 2 GB locally. Good for low-disk tickets and file migrations.
# @Admin:       No
# @Changes:     No
# @Target:      Local, Remote
# @Tags:        disk, folder size, onedrive, size on disk, migration, storage

[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'Folder to measure, for example C:\Users or D:\Shares')]
    [string]$Path = 'C:\Users',

    [Parameter(HelpMessage = 'How many levels of subfolders to list')]
    [ValidateSet('1', '2', '3')]
    [string]$Depth = '1',

    [Parameter(HelpMessage = 'Also measure actual space used on disk and cloud-only (OneDrive) files. Slower.')]
    [switch]$SizeOnDisk,

    [Parameter(HelpMessage = 'Only list folders at least this big')]
    [int]$MinSizeMB = 0
)

if (-not (Test-Path -LiteralPath $Path)) { throw "Path not found: $Path" }
$root = (Resolve-Path -LiteralPath $Path).Path.TrimEnd('\')
if ($root.Length -eq 2) { $root += '\' }
$maxDepth = [int]$Depth

$cluster = 4096
if ($SizeOnDisk) {
    if (-not ('TKDiskSize' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class TKDiskSize
{
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern uint GetCompressedFileSizeW(string lpFileName, out uint lpFileSizeHigh);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool GetDiskFreeSpaceW(string lpRootPathName, out uint sectorsPerCluster, out uint bytesPerSector, out uint freeClusters, out uint totalClusters);
    public static long OnDisk(string path)
    {
        uint high;
        uint low = GetCompressedFileSizeW(path, out high);
        if (low == 0xFFFFFFFF && Marshal.GetLastWin32Error() != 0) return -1;
        return ((long)high << 32) + low;
    }
    public static long ClusterSize(string root)
    {
        uint spc, bps, free, total;
        if (GetDiskFreeSpaceW(root, out spc, out bps, out free, out total)) return (long)spc * bps;
        return 4096;
    }
}
'@
    }
    $cluster = [TKDiskSize]::ClusterSize([IO.Path]::GetPathRoot($root))
}

# Cloud-only placeholders (OneDrive "online-only") carry these attributes
$cloudMask = 0x400000 -bor 0x40000 -bor 0x1000
$results = New-Object System.Collections.Generic.List[object]

function Measure-Folder {
    param([System.IO.DirectoryInfo]$Dir, [int]$Level)
    $t = @{ Size = [int64]0; Disk = [int64]0; Cloud = [int64]0; Files = 0; Folders = 0; Denied = $false }
    try { $files = $Dir.GetFiles() } catch { $files = @(); $t.Denied = $true }
    foreach ($f in $files) {
        $t.Files++
        $t.Size += $f.Length
        if ($SizeOnDisk) {
            if (([int64]$f.Attributes -band $cloudMask) -ne 0) {
                $t.Cloud += $f.Length
            } else {
                $d = [TKDiskSize]::OnDisk($f.FullName)
                if ($d -lt 0) { $d = $f.Length }
                $t.Disk += [Math]::Ceiling($d / $cluster) * $cluster
            }
        }
    }
    try { $subs = $Dir.GetDirectories() } catch { $subs = @(); $t.Denied = $true }
    foreach ($s in $subs) {
        if (($s.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        $c = Measure-Folder -Dir $s -Level ($Level + 1)
        $t.Size += $c.Size; $t.Disk += $c.Disk; $t.Cloud += $c.Cloud; $t.Files += $c.Files; $t.Folders += 1 + $c.Folders
        if ($c.Denied) { $t.Denied = $true }
    }
    if ($Level -ge 1 -and $Level -le $maxDepth -and $t.Size -ge ([int64]$MinSizeMB * 1MB)) {
        $row = [ordered]@{
            Folder  = $Dir.FullName
            Level   = $Level
            SizeGB  = [Math]::Round($t.Size / 1GB, 2)
        }
        if ($SizeOnDisk) {
            $row.OnDiskGB = [Math]::Round($t.Disk / 1GB, 2)
            $row.CloudOnlyGB = [Math]::Round($t.Cloud / 1GB, 2)
        }
        $row.Files = $t.Files
        $row.Folders = $t.Folders
        $row.Note = $(if ($t.Denied) { 'Some folders could not be read' } else { '' })
        $results.Add([pscustomobject]$row)
    }
    if ($Level -eq 1) { Write-Progress -Activity "Measuring $root" -Status $Dir.Name }
    $t
}

$total = Measure-Folder -Dir (New-Object System.IO.DirectoryInfo($root)) -Level 0
Write-Progress -Activity "Measuring $root" -Completed

$msg = '{0}: {1:N2} GB in {2:N0} files' -f $root, ($total.Size / 1GB), $total.Files
if ($SizeOnDisk) { $msg += ('  |  on disk {0:N2} GB  |  cloud-only {1:N2} GB' -f ($total.Disk / 1GB), ($total.Cloud / 1GB)) }
Write-Host $msg -ForegroundColor Cyan
if ($total.Denied) { Write-Host 'Some folders were skipped (access denied). Run as admin for a complete total.' -ForegroundColor Yellow }
$results | Sort-Object SizeGB -Descending
