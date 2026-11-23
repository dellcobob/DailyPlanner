# @Name:        Install RSAT AD Tools
# @Description: Installs the Active Directory PowerShell module (RSAT) on this PC so the AD scripts can run here. Windows 10/11 downloads it from Windows Update; servers add the feature. Optionally adds Group Policy tools.
# @Admin:       Yes
# @Changes:     Yes
# @Target:      Local
# @Tags:        rsat, activedirectory, install, setup

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(HelpMessage = 'Also install Group Policy Management tools')]
    [switch]$IncludeGroupPolicy,

    [Parameter(HelpMessage = 'Also install DNS Server tools')]
    [switch]$IncludeDns
)

if (Get-Module -ListAvailable -Name ActiveDirectory) {
    Write-Host 'The ActiveDirectory module is already installed.' -ForegroundColor Green
}

$os = Get-CimInstance -ClassName Win32_OperatingSystem
if ($os.ProductType -eq 1) {
    $wanted = @('Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0')
    if ($IncludeGroupPolicy) { $wanted += 'Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0' }
    if ($IncludeDns) { $wanted += 'Rsat.Dns.Tools~~~~0.0.1.0' }
    foreach ($name in $wanted) {
        $cap = Get-WindowsCapability -Online -Name $name -ErrorAction Stop
        if ($cap.State -eq 'Installed') { Write-Host "$name is already installed." -ForegroundColor Green; continue }
        if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Add-WindowsCapability $name")) {
            Write-Host "Installing $name (downloads from Windows Update, can take several minutes)..." -ForegroundColor Cyan
            try {
                $r = Add-WindowsCapability -Online -Name $name -ErrorAction Stop
                Write-Host "Installed $name$(if ($r.RestartNeeded) { ' (restart needed)' })" -ForegroundColor Green
            } catch {
                Write-Host "Install failed: $($_.Exception.Message)" -ForegroundColor Red
                if ($_.Exception.Message -match '0x800f0954|0x8024402c|0x800f081f') {
                    Write-Host 'This PC probably gets updates from WSUS, which does not carry RSAT. Ask for the GPO "Specify settings for optional component installation" to allow downloading from Windows Update, or install from the Features on Demand ISO.' -ForegroundColor Yellow
                }
            }
        }
    }
} else {
    $features = @('RSAT-AD-PowerShell')
    if ($IncludeGroupPolicy) { $features += 'GPMC' }
    if ($IncludeDns) { $features += 'RSAT-DNS-Server' }
    if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Install-WindowsFeature $($features -join ', ')")) {
        $r = Install-WindowsFeature -Name $features -ErrorAction Stop
        Write-Host "Install-WindowsFeature: success=$($r.Success), restart needed=$($r.RestartNeeded)" -ForegroundColor Green
    }
}
