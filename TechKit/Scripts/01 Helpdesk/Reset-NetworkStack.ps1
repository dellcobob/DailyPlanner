# @Name:        Reset Network Stack
# @Description: Fixes common "no internet" problems on this PC: flush DNS, renew DHCP, and optionally reset Winsock and TCP/IP (those two need a restart). Local only because it can drop the connection.
# @Admin:       Yes
# @Changes:     Yes
# @Target:      Local
# @Tags:        network, dns, dhcp, winsock, fix

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [bool]$FlushDns = $true,
    [bool]$RenewDhcp = $true,
    [Parameter(HelpMessage = 'netsh winsock reset (restart required)')]
    [bool]$ResetWinsock = $false,
    [Parameter(HelpMessage = 'netsh int ip reset (restart required)')]
    [bool]$ResetTcpIp = $false,
    [Parameter(HelpMessage = 'Clear the ARP and NetBIOS caches too')]
    [bool]$ClearArp = $true
)

function Invoke-Step {
    param([string]$Title, [string]$Exe, [string[]]$Arguments)
    if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, $Title)) {
        Write-Host "== $Title" -ForegroundColor Cyan
        $out = & $Exe @Arguments 2>&1
        $out | ForEach-Object { "$_" } | Where-Object { $_.Trim() } | Select-Object -First 30
        if ($LASTEXITCODE -eq 0) { Write-Host "   done" -ForegroundColor Green } else { Write-Host "   exit code $LASTEXITCODE" -ForegroundColor Yellow }
    }
}

$restart = $false
if ($FlushDns) { Invoke-Step -Title 'Flush DNS resolver cache' -Exe 'ipconfig.exe' -Arguments @('/flushdns') }
if ($ClearArp) {
    Invoke-Step -Title 'Clear ARP cache' -Exe 'netsh.exe' -Arguments @('interface', 'ip', 'delete', 'arpcache')
    Invoke-Step -Title 'Purge NetBIOS name cache' -Exe 'nbtstat.exe' -Arguments @('-R')
}
if ($RenewDhcp) {
    Invoke-Step -Title 'Release DHCP leases' -Exe 'ipconfig.exe' -Arguments @('/release')
    Invoke-Step -Title 'Renew DHCP leases' -Exe 'ipconfig.exe' -Arguments @('/renew')
    Invoke-Step -Title 'Re-register DNS' -Exe 'ipconfig.exe' -Arguments @('/registerdns')
}
if ($ResetWinsock) { Invoke-Step -Title 'Reset Winsock catalog' -Exe 'netsh.exe' -Arguments @('winsock', 'reset'); $restart = $true }
if ($ResetTcpIp) { Invoke-Step -Title 'Reset TCP/IP stack' -Exe 'netsh.exe' -Arguments @('int', 'ip', 'reset'); $restart = $true }

if ($restart -and -not $WhatIfPreference) {
    Write-Host 'Restart the computer to finish the Winsock / TCP/IP reset.' -ForegroundColor Yellow
}

Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = True' | ForEach-Object {
    [pscustomobject]@{
        Adapter = $_.Description
        IPv4    = (@($_.IPAddress) | Where-Object { $_ -match '^\d+\.' }) -join ', '
        Gateway = (@($_.DefaultIPGateway) -join ', ')
        DNS     = (@($_.DNSServerSearchOrder) -join ', ')
        DHCP    = $_.DHCPEnabled
    }
}
