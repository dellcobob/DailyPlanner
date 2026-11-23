# @Name:        Disk Space Report
# @Description: Lists every fixed drive with size, free space and percent free, and flags drives below your threshold.
# @Admin:       No
# @Changes:     No
# @Target:      Local, Remote
# @Tags:        disk, storage, free space

[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'Warn when free space is below this percent')]
    [int]$WarnPercent = 15,

    [Parameter(HelpMessage = 'Fail when free space is below this percent')]
    [int]$CriticalPercent = 5
)

$disks = Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType = 3'
foreach ($d in $disks) {
    if (-not $d.Size) { continue }
    $pct = [Math]::Round(($d.FreeSpace / $d.Size) * 100, 1)
    $status = 'OK'
    $color = 'Green'
    if ($pct -lt $CriticalPercent) { $status = 'FAIL'; $color = 'Red' }
    elseif ($pct -lt $WarnPercent) { $status = 'WARN'; $color = 'Yellow' }
    Write-Host ('{0,-4} {1,6:N1} GB free of {2,7:N1} GB  ({3}% free)  {4}' -f $d.DeviceID, ($d.FreeSpace / 1GB), ($d.Size / 1GB), $pct, $status) -ForegroundColor $color

    [pscustomobject]@{
        Computer    = $env:COMPUTERNAME
        Drive       = $d.DeviceID
        Label       = $d.VolumeName
        FileSystem  = $d.FileSystem
        SizeGB      = [Math]::Round($d.Size / 1GB, 1)
        FreeGB      = [Math]::Round($d.FreeSpace / 1GB, 1)
        FreePercent = $pct
        Status      = $status
    }
}
