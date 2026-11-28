# @Name:        Tenant Overview
# @Description: First thing to run on a new client: organization name, domains, directory sync, license counts (used / available), user and guest totals, Global Admins and security defaults.
# @Admin:       No
# @Changes:     No
# @Target:      M365
# @Connect:     Graph
# @Scopes:      Organization.Read.All, Directory.Read.All, User.Read.All, Policy.Read.All
# @Modules:     Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.Users, Microsoft.Graph.Identity.SignIns
# @Tags:        m365, tenant, licenses, admins, overview, entra

[CmdletBinding()]
param()

if (-not (Get-MgContext)) { throw 'Not connected to Microsoft Graph. Click the Microsoft 365 button in Tech Kit first.' }

$skuNames = @{
    'O365_BUSINESS_ESSENTIALS' = 'Microsoft 365 Business Basic'; 'O365_BUSINESS_PREMIUM' = 'Microsoft 365 Business Standard'
    'SPB' = 'Microsoft 365 Business Premium'; 'O365_BUSINESS' = 'Microsoft 365 Apps for business'; 'OFFICESUBSCRIPTION' = 'Microsoft 365 Apps for enterprise'
    'ENTERPRISEPACK' = 'Office 365 E3'; 'ENTERPRISEPREMIUM' = 'Office 365 E5'; 'STANDARDPACK' = 'Office 365 E1'; 'SPE_E3' = 'Microsoft 365 E3'
    'SPE_E5' = 'Microsoft 365 E5'; 'SPE_F1' = 'Microsoft 365 F3'; 'DESKLESSPACK' = 'Office 365 F3'; 'EXCHANGESTANDARD' = 'Exchange Online (Plan 1)'
    'EXCHANGEENTERPRISE' = 'Exchange Online (Plan 2)'; 'EXCHANGEARCHIVE_ADDON' = 'Exchange Online Archiving'; 'EMS' = 'EMS E3'; 'EMSPREMIUM' = 'EMS E5'
    'AAD_PREMIUM' = 'Entra ID P1'; 'AAD_PREMIUM_P2' = 'Entra ID P2'; 'INTUNE_A' = 'Intune Plan 1'; 'ATP_ENTERPRISE' = 'Defender for Office 365 P1'
    'POWER_BI_STANDARD' = 'Power BI (free)'; 'POWER_BI_PRO' = 'Power BI Pro'; 'FLOW_FREE' = 'Power Automate Free'; 'TEAMS_EXPLORATORY' = 'Teams Exploratory'
    'MCOEV' = 'Teams Phone Standard'; 'MCOMEETADV' = 'Teams Audio Conferencing'; 'PROJECTPROFESSIONAL' = 'Project Plan 3'; 'VISIOCLIENT' = 'Visio Plan 2'
    'Microsoft_Teams_Premium' = 'Teams Premium'; 'Microsoft_365_Copilot' = 'Microsoft 365 Copilot'; 'WINDOWS_STORE' = 'Windows Store for Business'
}

$org = Get-MgOrganization | Select-Object -First 1
$domains = @($org.VerifiedDomains)
$default = ($domains | Where-Object { $_.IsDefault } | Select-Object -First 1).Name
$initial = ($domains | Where-Object { $_.IsInitial } | Select-Object -First 1).Name

Write-Host ''
Write-Host "  $($org.DisplayName)" -ForegroundColor Cyan
Write-Host "  Tenant ID: $($org.Id)   Default domain: $default   Initial: $initial"
Write-Host "  Created: $($org.CreatedDateTime)   Country: $($org.CountryLetterCode)"
if ($org.OnPremisesSyncEnabled) { Write-Host "  Directory sync ON, last sync $($org.OnPremisesLastSyncDateTime)" -ForegroundColor Yellow }
else { Write-Host '  Cloud-only directory (no AD sync)' }
Write-Host "  Domains: $(($domains | ForEach-Object { $_.Name }) -join ', ')"

$users = @(Get-MgUser -All -Property 'id,userType,accountEnabled')
$members = @($users | Where-Object { $_.UserType -ne 'Guest' })
$guests = @($users | Where-Object { $_.UserType -eq 'Guest' })
$disabled = @($members | Where-Object { -not $_.AccountEnabled })
Write-Host "  Users: $($members.Count) members ($($disabled.Count) disabled), $($guests.Count) guests"

try {
    $role = Get-MgDirectoryRole -All | Where-Object { $_.DisplayName -in @('Global Administrator', 'Company Administrator') } | Select-Object -First 1
    if ($role) {
        $ga = @(Get-MgDirectoryRoleMember -DirectoryRoleId $role.Id -All)
        $names = @($ga | ForEach-Object { $_.AdditionalProperties['userPrincipalName'] } | Where-Object { $_ })
        $color = 'Gray'
        if ($ga.Count -gt 4 -or $ga.Count -lt 2) { $color = 'Yellow' }
        Write-Host "  Global Admins ($($ga.Count)): $($names -join ', ')" -ForegroundColor $color
        if ($ga.Count -gt 4) { Write-Host '  More than 4 Global Admins. Microsoft recommends fewer than 5.' -ForegroundColor Yellow }
    }
} catch { Write-Host "  Could not read Global Admins: $($_.Exception.Message)" -ForegroundColor Yellow }

try {
    $sd = Get-MgPolicyIdentitySecurityDefaultEnforcementPolicy -ErrorAction Stop
    $ca = @(Get-MgIdentityConditionalAccessPolicy -All -ErrorAction SilentlyContinue)
    $caOn = @($ca | Where-Object { $_.State -eq 'enabled' }).Count
    if ($sd.IsEnabled) { Write-Host '  Security defaults: ON' -ForegroundColor Green }
    elseif ($caOn -gt 0) { Write-Host "  Security defaults off, $caOn Conditional Access polic$(if ($caOn -eq 1) { 'y' } else { 'ies' }) enabled" -ForegroundColor Green }
    else { Write-Host '  Security defaults OFF and no Conditional Access policies enabled. MFA may not be enforced!' -ForegroundColor Red }
} catch { Write-Host "  Could not read security defaults: $($_.Exception.Message)" -ForegroundColor Yellow }
Write-Host ''

Get-MgSubscribedSku -All | Sort-Object SkuPartNumber | ForEach-Object {
    $total = [int]$_.PrepaidUnits.Enabled
    $used = [int]$_.ConsumedUnits
    $name = $skuNames[$_.SkuPartNumber]
    if (-not $name) { $name = $_.SkuPartNumber }
    [pscustomobject]@{
        License   = $name
        SkuPart   = $_.SkuPartNumber
        Total     = $total
        Assigned  = $used
        Available = $total - $used
        Suspended = [int]$_.PrepaidUnits.Suspended
        Status    = $_.CapabilityStatus
    }
}
