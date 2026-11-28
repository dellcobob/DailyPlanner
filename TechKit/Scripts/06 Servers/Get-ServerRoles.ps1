# @Name:        Server Roles & Apps
# @Description: "What does this server do?" Lists installed roles and features, plus quick counts for IIS sites, SQL Server instances, Hyper-V VMs, shares, DHCP scopes and DNS zones when present.
# @Admin:       Yes
# @Changes:     No
# @Target:      Local, Remote
# @Tags:        server, roles, features, iis, sql, hyper-v, inventory

[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'List every installed feature, not just roles and role services')]
    [switch]$AllFeatures
)

$os = Get-CimInstance -ClassName Win32_OperatingSystem
Write-Host "$env:COMPUTERNAME  $($os.Caption)" -ForegroundColor Cyan

if ($os.ProductType -ne 1 -and (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue)) {
    $f = @(Get-WindowsFeature | Where-Object { $_.Installed })
    if (-not $AllFeatures) { $f = @($f | Where-Object { $_.FeatureType -in @('Role', 'Role Service') }) }
    $f | ForEach-Object {
        [pscustomobject]@{ Computer = $env:COMPUTERNAME; Kind = [string]$_.FeatureType; Name = $_.Name; DisplayName = $_.DisplayName; Detail = '' }
    }
} elseif ($os.ProductType -eq 1) {
    Write-Host 'This is a workstation; listing enabled optional features.' -ForegroundColor DarkGray
    Get-WindowsOptionalFeature -Online -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Enabled' } | ForEach-Object {
        [pscustomobject]@{ Computer = $env:COMPUTERNAME; Kind = 'Optional feature'; Name = $_.FeatureName; DisplayName = $_.FeatureName; Detail = '' }
    }
}

# Applications that commonly live on servers
$sql = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction SilentlyContinue)
if ($sql) {
    foreach ($p in $sql.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' }) {
        $ver = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$($p.Value)\Setup" -ErrorAction SilentlyContinue)
        Write-Host "SQL Server instance: $($p.Name) $($ver.Edition) $($ver.Version)" -ForegroundColor Green
        [pscustomobject]@{ Computer = $env:COMPUTERNAME; Kind = 'SQL Server'; Name = $p.Name; DisplayName = "$($ver.Edition)"; Detail = "$($ver.Version)" }
    }
}
if (Get-Service -Name W3SVC -ErrorAction SilentlyContinue) {
    try {
        Import-Module WebAdministration -ErrorAction Stop
        foreach ($s in @(Get-Website)) {
            $b = @($s.bindings.Collection | ForEach-Object { "$($_.protocol) $($_.bindingInformation)" }) -join '; '
            [pscustomobject]@{ Computer = $env:COMPUTERNAME; Kind = 'IIS site'; Name = $s.Name; DisplayName = [string]$s.State; Detail = $b }
        }
    } catch { Write-Host 'IIS is installed but the WebAdministration module could not load.' -ForegroundColor Yellow }
}
if (Get-Command Get-VM -ErrorAction SilentlyContinue) {
    try {
        foreach ($vm in @(Get-VM -ErrorAction Stop)) {
            [pscustomobject]@{ Computer = $env:COMPUTERNAME; Kind = 'Hyper-V VM'; Name = $vm.Name; DisplayName = [string]$vm.State; Detail = "$([Math]::Round($vm.MemoryAssigned / 1GB, 1)) GB RAM, uptime $($vm.Uptime)" }
        }
    } catch { }
}
if (Get-Command Get-DhcpServerv4Scope -ErrorAction SilentlyContinue) {
    try {
        foreach ($sc in @(Get-DhcpServerv4Scope -ErrorAction Stop)) {
            [pscustomobject]@{ Computer = $env:COMPUTERNAME; Kind = 'DHCP scope'; Name = [string]$sc.ScopeId; DisplayName = $sc.Name; Detail = "$($sc.StartRange) - $($sc.EndRange), $($sc.State)" }
        }
    } catch { }
}
if (Get-Command Get-DnsServerZone -ErrorAction SilentlyContinue) {
    try {
        foreach ($z in @(Get-DnsServerZone -ErrorAction Stop | Where-Object { -not $_.IsAutoCreated -and $_.ZoneName -ne 'TrustAnchors' })) {
            [pscustomobject]@{ Computer = $env:COMPUTERNAME; Kind = 'DNS zone'; Name = $z.ZoneName; DisplayName = [string]$z.ZoneType; Detail = $(if ($z.IsDsIntegrated) { 'AD-integrated' } else { '' }) }
        }
    } catch { }
}
$shares = @(Get-SmbShare -ErrorAction SilentlyContinue | Where-Object { -not $_.Name.EndsWith('$') })
foreach ($s in $shares) {
    [pscustomobject]@{ Computer = $env:COMPUTERNAME; Kind = 'File share'; Name = $s.Name; DisplayName = $s.Path; Detail = $s.Description }
}
