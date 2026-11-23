# @Name:        Firewall Status
# @Description: Shows whether Windows Firewall is on for the Domain, Private and Public profiles, any third-party firewall, and optionally the inbound rules that allow traffic from anywhere.
# @Admin:       No
# @Changes:     No
# @Target:      Local, Remote
# @Tags:        firewall, audit, inbound, rules

[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'List enabled inbound Allow rules that accept any remote address (slower)')]
    [switch]$ListOpenRules
)

$active = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object { ([string]$_.NetworkCategory) -replace 'DomainAuthenticated', 'Domain' })
foreach ($p in (Get-NetFirewallProfile -ErrorAction Stop)) {
    $isActive = $active -contains [string]$p.Name
    $color = 'Green'
    if (-not $p.Enabled) { $color = 'Red' }
    Write-Host ('{0,-8} firewall {1}{2}' -f $p.Name, $(if ($p.Enabled) { 'ON' } else { 'OFF' }), $(if ($isActive) { '  (active network)' } else { '' })) -ForegroundColor $color
    [pscustomobject]@{
        Computer        = $env:COMPUTERNAME
        Profile         = $p.Name
        Enabled         = [bool]$p.Enabled
        ActiveNetwork   = $isActive
        DefaultInbound  = [string]$p.DefaultInboundAction
        DefaultOutbound = [string]$p.DefaultOutboundAction
        LogBlocked      = [string]$p.LogBlocked
        LogFile         = $p.LogFileName
    }
}

try {
    $third = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName FirewallProduct -ErrorAction Stop)
    foreach ($t in $third) { Write-Host "Third-party firewall registered: $($t.displayName)" -ForegroundColor Cyan }
} catch { }

if ($ListOpenRules) {
    Write-Host 'Collecting inbound allow rules (this can take a minute)...' -ForegroundColor Cyan
    $rules = @(Get-NetFirewallRule -Direction Inbound -Enabled True -Action Allow -ErrorAction SilentlyContinue)
    $i = 0
    foreach ($r in $rules) {
        $i++
        if ($i % 25 -eq 0) { Write-Progress -Activity 'Firewall rules' -Status "$i of $($rules.Count)" -PercentComplete ([int](100 * $i / $rules.Count)) }
        $addr = $r | Get-NetFirewallAddressFilter
        if (@($addr.RemoteAddress) -notcontains 'Any') { continue }
        $port = $r | Get-NetFirewallPortFilter
        $app = $r | Get-NetFirewallApplicationFilter
        [pscustomobject]@{
            Rule      = $r.DisplayName
            Profile   = [string]$r.Profile
            Protocol  = $port.Protocol
            LocalPort = (@($port.LocalPort) -join ',')
            Program   = $app.Program
            Group     = $r.DisplayGroup
        }
    }
    Write-Progress -Activity 'Firewall rules' -Completed
}
