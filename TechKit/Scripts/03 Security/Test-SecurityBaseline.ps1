# @Name:        Security Quick Check
# @Description: Checks about 18 common hardening settings (SMBv1, LLMNR, NetBIOS, WDigest, LSA protection, UAC, RDP NLA, firewall, Defender, BitLocker, TLS 1.0, PowerShell 2, patch age and more) and gives PASS / WARN / FAIL with a fix for each.
# @Admin:       Yes
# @Changes:     No
# @Target:      Local, Remote
# @Tags:        hardening, baseline, audit, compliance, cis

[CmdletBinding()]
param()

$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string]$Check, [string]$Result, [string]$Detail, [string]$Fix = '')
    $color = switch ($Result) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'Gray' } }
    Write-Host ('{0,-5} {1,-34} {2}' -f $Result, $Check, $Detail) -ForegroundColor $color
    $results.Add([pscustomobject]@{ Computer = $env:COMPUTERNAME; Check = $Check; Result = $Result; Detail = $Detail; Fix = $Fix })
}
function Get-Reg {
    param([string]$Path, [string]$Name)
    try { (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { $null }
}

$os = Get-CimInstance -ClassName Win32_OperatingSystem
$isServer = $os.ProductType -ne 1

# SMB
try {
    $smb = Get-SmbServerConfiguration -ErrorAction Stop
    if ($smb.EnableSMB1Protocol) { Add-Result 'SMBv1 disabled' 'FAIL' 'SMBv1 server is enabled' 'Set-SmbServerConfiguration -EnableSMB1Protocol $false' }
    else { Add-Result 'SMBv1 disabled' 'PASS' 'SMBv1 server is off' }
    if ($smb.RequireSecuritySignature) { Add-Result 'SMB signing required' 'PASS' 'Server requires signing' }
    else { Add-Result 'SMB signing required' 'WARN' 'Signing not required' 'GPO: Microsoft network server: Digitally sign communications (always)' }
} catch { Add-Result 'SMB configuration' 'INFO' 'Could not read SMB settings' }

# Name resolution poisoning
$llmnr = Get-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' 'EnableMulticast'
if ($llmnr -eq 0) { Add-Result 'LLMNR disabled' 'PASS' 'Turned off by policy' }
else { Add-Result 'LLMNR disabled' 'WARN' 'LLMNR is on (spoofing risk)' 'GPO: DNS Client > Turn off multicast name resolution = Enabled' }

$nb = @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = True' | Where-Object { $_.TcpipNetbiosOptions -ne 2 })
if ($nb.Count -eq 0) { Add-Result 'NetBIOS over TCP/IP off' 'PASS' 'Disabled on all adapters' }
else { Add-Result 'NetBIOS over TCP/IP off' 'WARN' "$($nb.Count) adapter(s) still allow NetBIOS" 'Adapter > IPv4 > Advanced > WINS > Disable NetBIOS, or DHCP option' }

# Credential protection
$wd = Get-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest' 'UseLogonCredential'
if ($wd -eq 1) { Add-Result 'WDigest plaintext creds off' 'FAIL' 'UseLogonCredential = 1' 'Set UseLogonCredential to 0' }
else { Add-Result 'WDigest plaintext creds off' 'PASS' 'Not storing plaintext passwords' }

$ppl = Get-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'RunAsPPL'
if ($ppl -ge 1) { Add-Result 'LSA protection (RunAsPPL)' 'PASS' "RunAsPPL = $ppl" }
else { Add-Result 'LSA protection (RunAsPPL)' 'WARN' 'LSASS is not a protected process' 'Set HKLM\SYSTEM\CurrentControlSet\Control\Lsa RunAsPPL = 1 (test first)' }

$lm = Get-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'LmCompatibilityLevel'
if ($lm -ge 5) { Add-Result 'NTLMv2 only' 'PASS' "LmCompatibilityLevel = $lm" }
elseif ($null -eq $lm -or $lm -ge 3) { Add-Result 'NTLMv2 only' 'WARN' "LmCompatibilityLevel = $(if ($null -eq $lm) { 'default (3)' } else { $lm })" 'GPO: LAN Manager authentication level = Send NTLMv2 response only. Refuse LM & NTLM' }
else { Add-Result 'NTLMv2 only' 'FAIL' "LmCompatibilityLevel = $lm (LM/NTLMv1 allowed)" 'Raise to 5' }

# UAC
$lua = Get-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableLUA'
if ($lua -eq 0) { Add-Result 'UAC enabled' 'FAIL' 'EnableLUA = 0' 'Set EnableLUA = 1 and restart' } else { Add-Result 'UAC enabled' 'PASS' 'UAC is on' }

# RDP
$deny = Get-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections'
if ($deny -eq 0) {
    $nla = Get-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' 'UserAuthentication'
    if ($nla -eq 1) { Add-Result 'RDP requires NLA' 'PASS' 'RDP on, NLA required' }
    else { Add-Result 'RDP requires NLA' 'FAIL' 'RDP on without NLA' 'System Properties > Remote > Allow only with Network Level Authentication' }
} else { Add-Result 'RDP requires NLA' 'PASS' 'RDP is disabled' }

# Accounts
try {
    $guest = Get-CimInstance -ClassName Win32_UserAccount -Filter "LocalAccount = True" | Where-Object { $_.SID -match '-501$' }
    if ($guest -and -not $guest.Disabled) { Add-Result 'Guest account disabled' 'FAIL' 'Guest is enabled' 'Disable the Guest account' }
    else { Add-Result 'Guest account disabled' 'PASS' 'Guest is disabled' }
} catch { }

$laps = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\LAPS') -or (Test-Path 'HKLM:\SOFTWARE\Policies\Microsoft Services\AdmPwd') -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Policies\LAPS')
if ($laps) { Add-Result 'LAPS configured' 'PASS' 'Windows LAPS or legacy LAPS policy found' }
else { Add-Result 'LAPS configured' 'WARN' 'No LAPS policy found' 'Use Windows LAPS to rotate the local admin password' }

# Firewall and AV
try {
    $off = @(Get-NetFirewallProfile -ErrorAction Stop | Where-Object { -not $_.Enabled })
    if ($off.Count) { Add-Result 'Firewall on (all profiles)' 'FAIL' ("Off: " + (($off | ForEach-Object { $_.Name }) -join ', ')) 'Set-NetFirewallProfile -All -Enabled True' }
    else { Add-Result 'Firewall on (all profiles)' 'PASS' 'Domain, Private and Public on' }
} catch { Add-Result 'Firewall on (all profiles)' 'INFO' 'Could not read firewall profiles' }

try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    if ($mp.RealTimeProtectionEnabled -and $mp.AntivirusSignatureAge -le 3) { Add-Result 'Defender real-time + signatures' 'PASS' "Signatures $($mp.AntivirusSignatureAge) day(s) old" }
    elseif ($mp.RealTimeProtectionEnabled) { Add-Result 'Defender real-time + signatures' 'WARN' "Signatures $($mp.AntivirusSignatureAge) days old" 'Update-MpSignature' }
    else { Add-Result 'Defender real-time + signatures' 'WARN' 'Real-time protection off (third-party AV?)' 'Confirm another AV is active' }
} catch { Add-Result 'Defender real-time + signatures' 'INFO' 'Defender not reporting (third-party AV?)' }

# Encryption
try {
    $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
    if ([string]$bl.ProtectionStatus -eq 'On') { Add-Result 'BitLocker on system drive' 'PASS' "$($bl.EncryptionMethod)" }
    else { Add-Result 'BitLocker on system drive' $(if ($isServer) { 'INFO' } else { 'WARN' }) 'System drive is not protected' 'Turn on BitLocker and escrow the recovery key' }
} catch { Add-Result 'BitLocker on system drive' 'INFO' 'BitLocker status not available' }

try {
    if (Confirm-SecureBootUEFI -ErrorAction Stop) { Add-Result 'Secure Boot' 'PASS' 'Enabled' } else { Add-Result 'Secure Boot' 'WARN' 'Disabled' 'Enable Secure Boot in UEFI setup' }
} catch { Add-Result 'Secure Boot' 'INFO' 'Not supported or legacy BIOS' }

# Protocols
$tls10 = Get-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.0\Server' 'Enabled'
if ($tls10 -eq 0) { Add-Result 'TLS 1.0 server disabled' 'PASS' 'Disabled in SCHANNEL' }
elseif ([int]$os.BuildNumber -ge 26100) { Add-Result 'TLS 1.0 server disabled' 'PASS' 'Off by default on this Windows build' }
else { Add-Result 'TLS 1.0 server disabled' 'WARN' 'Not explicitly disabled' 'Disable TLS 1.0/1.1 under SCHANNEL\Protocols (test apps first)' }

try {
    if ($isServer) {
        $v2 = Get-WindowsFeature -Name PowerShell-V2 -ErrorAction Stop
        $v2on = $v2.Installed
    } else {
        $v2 = Get-WindowsOptionalFeature -Online -FeatureName MicrosoftWindowsPowerShellV2Root -ErrorAction Stop
        $v2on = [string]$v2.State -eq 'Enabled'
    }
    if ($v2on) { Add-Result 'PowerShell 2.0 removed' 'WARN' 'PowerShell 2.0 engine is installed (bypasses logging)' 'Disable-WindowsOptionalFeature -Online -FeatureName MicrosoftWindowsPowerShellV2Root' }
    else { Add-Result 'PowerShell 2.0 removed' 'PASS' 'Not installed' }
} catch { Add-Result 'PowerShell 2.0 removed' 'INFO' 'Could not check' }

$sbl = Get-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging' 'EnableScriptBlockLogging'
if ($sbl -eq 1) { Add-Result 'PowerShell script block logging' 'PASS' 'Enabled by policy' }
else { Add-Result 'PowerShell script block logging' 'WARN' 'Not enabled' 'GPO: Windows PowerShell > Turn on PowerShell Script Block Logging' }

$autorun = Get-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoDriveTypeAutoRun'
if ($autorun -eq 255) { Add-Result 'AutoRun disabled' 'PASS' 'All drive types' }
else { Add-Result 'AutoRun disabled' 'WARN' "NoDriveTypeAutoRun = $(if ($null -eq $autorun) { 'not set' } else { $autorun })" 'GPO: Turn off AutoPlay = All drives' }

# Patching
$last = Get-HotFix -ErrorAction SilentlyContinue | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1
if ($last) {
    $age = [int]((Get-Date) - $last.InstalledOn).TotalDays
    if ($age -le 35) { Add-Result 'Recently patched' 'PASS' "Last update $age days ago ($($last.HotFixID))" }
    elseif ($age -le 60) { Add-Result 'Recently patched' 'WARN' "Last update $age days ago" 'Run Windows Update' }
    else { Add-Result 'Recently patched' 'FAIL' "Last update $age days ago" 'Run Windows Update and check WSUS/Intune' }
}

$fail = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
$warn = @($results | Where-Object { $_.Result -eq 'WARN' }).Count
$pass = @($results | Where-Object { $_.Result -eq 'PASS' }).Count
Write-Host ''
Write-Host ("Summary for {0}: {1} pass, {2} warn, {3} fail" -f $env:COMPUTERNAME, $pass, $warn, $fail) -ForegroundColor $(if ($fail) { 'Red' } elseif ($warn) { 'Yellow' } else { 'Green' })
$results
