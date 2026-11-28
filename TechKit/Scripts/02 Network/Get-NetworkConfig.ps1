# @Name:        Network Configuration
# @Description: Shows each connected adapter with IP address, subnet, gateway, DNS servers, DHCP state, MAC, link speed and network profile (Public/Private/Domain).
# @Admin:       No
# @Changes:     No
# @Target:      Local, Remote
# @Tags:        ip, ipconfig, dns, gateway, dhcp, adapter

[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'Include adapters that are disconnected or disabled')]
    [switch]$IncludeDisconnected
)

$profiles = @{}
Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object { $profiles[$_.InterfaceIndex] = "$($_.NetworkCategory) ($($_.Name))" }

$adapters = Get-NetAdapter -ErrorAction SilentlyContinue
if (-not $IncludeDisconnected) { $adapters = $adapters | Where-Object { $_.Status -eq 'Up' } }

foreach ($a in ($adapters | Sort-Object ifIndex)) {
    $ip4 = @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)
    $ip6 = @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue | Where-Object { $_.PrefixOrigin -ne 'WellKnown' -and $_.IPAddress -notlike 'fe80*' })
    $gw = @(Get-NetRoute -InterfaceIndex $a.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty NextHop)
    $dns = @(Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ServerAddresses)
    $ipif = Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    $suffix = (Get-DnsClient -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue).ConnectionSpecificSuffix

    if (@($ip4 | Where-Object { $_.IPAddress -like '169.254.*' }).Count) {
        Write-Host "$($a.Name): has a 169.254.x.x address, so DHCP did not answer." -ForegroundColor Yellow
    }
    [pscustomobject]@{
        Computer   = $env:COMPUTERNAME
        Adapter    = $a.Name
        Description = $a.InterfaceDescription
        Status     = $a.Status
        IPv4       = (@($ip4 | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" }) -join ', ')
        Gateway    = ($gw -join ', ')
        DNS        = ($dns -join ', ')
        DHCP       = $(if ($ipif) { [string]$ipif.Dhcp } else { '' })
        DnsSuffix  = $suffix
        IPv6       = (@($ip6 | ForEach-Object { $_.IPAddress }) -join ', ')
        MAC        = $a.MacAddress
        LinkSpeed  = $a.LinkSpeed
        Profile    = $profiles[[int]$a.ifIndex]
    }
}
