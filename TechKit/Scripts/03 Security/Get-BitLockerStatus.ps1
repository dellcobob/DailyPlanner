# @Name:        BitLocker Status
# @Description: Shows encryption status, method and key protectors for every drive. Can also display recovery passwords so you can record them (handle with care).
# @Admin:       Yes
# @Changes:     No
# @Target:      Local, Remote
# @Tags:        bitlocker, encryption, recovery key, tpm

[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'Show the 48-digit recovery passwords in the output')]
    [switch]$ShowRecoveryKeys
)

$vols = $null
try {
    $vols = @(Get-BitLockerVolume -ErrorAction Stop)
} catch {
    Write-Host 'BitLocker cmdlets are not available here; reading WMI instead.' -ForegroundColor DarkGray
}

if ($vols) {
    foreach ($v in $vols) {
        $color = 'Green'
        if ([string]$v.ProtectionStatus -ne 'On') { $color = 'Yellow' }
        if ($v.VolumeType -eq 'OperatingSystem' -and [string]$v.ProtectionStatus -ne 'On') { $color = 'Red' }
        Write-Host ('{0,-4} {1,-15} protection {2}, {3}% encrypted' -f $v.MountPoint, $v.VolumeType, $v.ProtectionStatus, $v.EncryptionPercentage) -ForegroundColor $color
        $keys = @($v.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' })
        [pscustomobject]@{
            Computer      = $env:COMPUTERNAME
            Drive         = $v.MountPoint
            Type          = [string]$v.VolumeType
            Protection    = [string]$v.ProtectionStatus
            Status        = [string]$v.VolumeStatus
            PercentDone   = $v.EncryptionPercentage
            Method        = [string]$v.EncryptionMethod
            Locked        = [string]$v.LockStatus
            Protectors    = (@($v.KeyProtector | ForEach-Object { [string]$_.KeyProtectorType }) -join ', ')
            RecoveryKeyId = (@($keys | ForEach-Object { $_.KeyProtectorId }) -join ', ')
            RecoveryKey   = $(if ($ShowRecoveryKeys) { (@($keys | ForEach-Object { $_.RecoveryPassword }) -join ', ') } else { '(hidden)' })
        }
    }
    if ($ShowRecoveryKeys) { Write-Host 'Recovery keys are shown above. Do not leave exported reports lying around.' -ForegroundColor Yellow }
    return
}

$status = @{ 0 = 'Off'; 1 = 'On'; 2 = 'Unknown' }
$conv = @{ 0 = 'Fully decrypted'; 1 = 'Fully encrypted'; 2 = 'Encrypting'; 3 = 'Decrypting'; 4 = 'Encryption paused'; 5 = 'Decryption paused' }
try {
    $wmi = @(Get-CimInstance -Namespace 'root/cimv2/Security/MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -ErrorAction Stop)
} catch {
    throw "BitLocker information is not available on this computer: $($_.Exception.Message)"
}
foreach ($w in $wmi) {
    $prot = Invoke-CimMethod -InputObject $w -MethodName GetProtectionStatus
    $cs = Invoke-CimMethod -InputObject $w -MethodName GetConversionStatus
    [pscustomobject]@{
        Computer    = $env:COMPUTERNAME
        Drive       = $w.DriveLetter
        Protection  = $status[[int]$prot.ProtectionStatus]
        Status      = $conv[[int]$cs.ConversionStatus]
        PercentDone = $cs.EncryptionPercentage
    }
}
