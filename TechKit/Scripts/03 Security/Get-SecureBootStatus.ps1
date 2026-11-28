# @Name:        Secure Boot Certificate Status (2023 CA)
# @Description: A readable wrapper for the Secure Boot one-liners: is Secure Boot on, are the new 2023 Microsoft certificates (KEK and DB) in firmware before the 2011 ones expire, what the Windows servicing status says, and recent Secure Boot update events.
# @Admin:       Yes
# @Changes:     No
# @Target:      Local, Remote
# @Tags:        secure boot, uefi, certificates, 2023 ca, kek, db, firmware

[CmdletBinding()]
param()

function Test-UefiVar {
    param([string]$Name, [string]$Text)
    try {
        $v = Get-SecureBootUEFI -Name $Name -ErrorAction Stop
        return ([System.Text.Encoding]::ASCII.GetString($v.Bytes) -match [regex]::Escape($Text))
    } catch { return $null }
}

$enabled = $null
$uefi = $true
try { $enabled = Confirm-SecureBootUEFI -ErrorAction Stop } catch [System.PlatformNotSupportedException] { $uefi = $false } catch { $enabled = $null }

$svcKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing'
$sbKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot'
$svc = Get-ItemProperty -Path $svcKey -ErrorAction SilentlyContinue
$sb = Get-ItemProperty -Path $sbKey -ErrorAction SilentlyContinue
$available = $null
if ($sb -and $null -ne $sb.AvailableUpdates) { $available = '0x{0:X}' -f [int]$sb.AvailableUpdates }

$kek2023 = Test-UefiVar -Name 'KEK' -Text 'Microsoft Corporation KEK 2K CA 2023'
$dbWin2023 = Test-UefiVar -Name 'db' -Text 'Windows UEFI CA 2023'
$dbUefi2023 = Test-UefiVar -Name 'db' -Text 'Microsoft UEFI CA 2023'
$dbOpt2023 = Test-UefiVar -Name 'db' -Text 'Microsoft Option ROM UEFI CA 2023'
$dbWin2011 = Test-UefiVar -Name 'db' -Text 'Microsoft Windows Production PCA 2011'
$dbxPca2011 = Test-UefiVar -Name 'dbx' -Text 'Microsoft Windows Production PCA 2011'

$events = @()
try {
    $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-TPM-WMI'; Id = 1795, 1796, 1797, 1798, 1799, 1800, 1801, 1802, 1803, 1808 } -MaxEvents 5 -ErrorAction Stop)
} catch { }

$cs = Get-CimInstance -ClassName Win32_ComputerSystem
$bios = Get-CimInstance -ClassName Win32_BIOS

$status = 'OK'
$advice = @()
if (-not $uefi) { $status = 'INFO'; $advice += 'Legacy BIOS boot: Secure Boot does not apply.' }
elseif ($enabled -eq $false) { $status = 'WARN'; $advice += 'Secure Boot is OFF. Turn it on in the UEFI setup.' }
elseif ($null -eq $enabled) { $status = 'INFO'; $advice += 'Could not read Secure Boot state (run as admin).' }
else {
    if (-not $kek2023) { $status = 'ACTION'; $advice += 'New KEK (2023) is missing. It usually comes with a firmware (BIOS) update from the manufacturer or via Windows servicing.' }
    if (-not $dbWin2023) { $status = 'ACTION'; $advice += "'Windows UEFI CA 2023' is not in DB yet. Install the latest cumulative update; Windows applies it, or set AvailableUpdates per Microsoft's Secure Boot guidance." }
    if ($dbWin2023 -and -not $dbUefi2023) { if ($status -eq 'OK') { $status = 'WARN' }; $advice += "'Microsoft UEFI CA 2023' (third-party loaders, some drivers) is not in DB." }
    if ($svc -and $svc.UEFICA2023Error) { $status = 'ACTION'; $advice += "Windows reports UEFICA2023Error = $($svc.UEFICA2023Error). Check the event log and firmware updates." }
}

$color = switch ($status) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'ACTION' { 'Red' } default { 'Gray' } }
Write-Host ("{0}: Secure Boot {1}  |  KEK 2023: {2}  |  DB Windows UEFI CA 2023: {3}  |  Servicing: {4}" -f $env:COMPUTERNAME,
    $(if ($enabled) { 'ON' } elseif ($enabled -eq $false) { 'OFF' } else { 'unknown' }), $kek2023, $dbWin2023, $svc.UEFICA2023Status) -ForegroundColor $color
foreach ($a in $advice) { Write-Host "  - $a" -ForegroundColor $color }
foreach ($e in $events) { Write-Host ("  event {0} {1}: {2}" -f $e.Id, $e.TimeCreated, (($e.Message -split "`r?`n")[0])) -ForegroundColor DarkGray }

[pscustomobject]@{
    Computer           = $env:COMPUTERNAME
    Model              = "$($cs.Manufacturer) $($cs.Model)"
    BIOS               = "$($bios.SMBIOSBIOSVersion) ($($bios.ReleaseDate))"
    UEFI               = $uefi
    SecureBoot         = $enabled
    KEK_2023           = $kek2023
    DB_WindowsCA2023   = $dbWin2023
    DB_UEFICA2023      = $dbUefi2023
    DB_OptionROM2023   = $dbOpt2023
    DB_WindowsPCA2011  = $dbWin2011
    DBX_PCA2011Revoked = $dbxPca2011
    ServicingStatus    = [string]$svc.UEFICA2023Status
    ServicingError     = [string]$svc.UEFICA2023Error
    AvailableUpdates   = $available
    LastEvent          = $(if ($events.Count) { "$($events[0].Id) at $($events[0].TimeCreated)" } else { '' })
    Status             = $status
    Advice             = ($advice -join ' ')
}
