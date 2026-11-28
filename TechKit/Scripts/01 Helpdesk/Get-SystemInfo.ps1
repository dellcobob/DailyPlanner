# @Name:        System Info Summary
# @Description: One-page summary of a PC: model, serial, Windows version, uptime, CPU, memory, disk, signed-in user, domain, IP and pending reboot.
# @Admin:       No
# @Changes:     No
# @Target:      Local, Remote
# @Tags:        inventory, hardware, os, serial, uptime

[CmdletBinding()]
param()

$os = Get-CimInstance -ClassName Win32_OperatingSystem
$cs = Get-CimInstance -ClassName Win32_ComputerSystem
$bios = Get-CimInstance -ClassName Win32_BIOS
$cpu = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
$sysDrive = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'"
$cv = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'

$release = $cv.DisplayVersion
if (-not $release) { $release = $cv.ReleaseId }
$uptime = (Get-Date) - $os.LastBootUpTime

$pending = $false
$rebootKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
)
foreach ($k in $rebootKeys) { if (Test-Path -Path $k) { $pending = $true } }
$pfro = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
if ($pfro) { $pending = $true }

$ips = @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = True' |
    ForEach-Object { $_.IPAddress } | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notlike '169.254.*' })

$user = $cs.UserName
if (-not $user) {
    $explorer = Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" | Select-Object -First 1
    if ($explorer) {
        $owner = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner -ErrorAction SilentlyContinue
        if ($owner -and $owner.User) { $user = "$($owner.Domain)\$($owner.User)" }
    }
}

$domainText = $cs.Domain
if (-not $cs.PartOfDomain) { $domainText = "$($cs.Domain) (workgroup)" }

$memGB = [Math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
$freeMemGB = [Math]::Round($os.FreePhysicalMemory * 1KB / 1GB, 1)

Write-Host ''
Write-Host "  $($cs.Name)  " -ForegroundColor Cyan -NoNewline
Write-Host "$($cs.Manufacturer) $($cs.Model)" -ForegroundColor Gray
if ($pending) { Write-Host '  A reboot is pending on this computer.' -ForegroundColor Yellow }
if ($uptime.TotalDays -gt 30) { Write-Host ("  Up for {0} days. Consider a restart." -f [int]$uptime.TotalDays) -ForegroundColor Yellow }

[pscustomobject]@{
    ComputerName   = $cs.Name
    Manufacturer   = $cs.Manufacturer
    Model          = $cs.Model
    SerialNumber   = $bios.SerialNumber
    BIOSVersion    = $bios.SMBIOSBIOSVersion
    OS             = $os.Caption
    Version        = "$release (build $($os.BuildNumber).$($cv.UBR))"
    Installed      = $os.InstallDate
    LastBoot       = $os.LastBootUpTime
    Uptime         = ('{0}d {1}h {2}m' -f $uptime.Days, $uptime.Hours, $uptime.Minutes)
    PendingReboot  = $pending
    CPU            = ($cpu.Name -replace '\s+', ' ').Trim()
    Cores          = "$($cpu.NumberOfCores) cores / $($cpu.NumberOfLogicalProcessors) threads"
    MemoryGB       = $memGB
    MemoryFreeGB   = $freeMemGB
    SystemDrive    = ('{0} {1:N1} GB free of {2:N1} GB' -f $env:SystemDrive, ($sysDrive.FreeSpace / 1GB), ($sysDrive.Size / 1GB))
    SignedInUser   = $user
    Domain         = $domainText
    IPv4           = ($ips -join ', ')
    TimeZone       = (Get-CimInstance -ClassName Win32_TimeZone).Caption
}
