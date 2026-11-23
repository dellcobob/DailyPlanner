# @Name:        License Report
# @Description: Lists users with their licenses. Finds wasted licenses on blocked accounts and members with no license. Export to CSV for billing reviews.
# @Admin:       No
# @Changes:     No
# @Target:      M365
# @Connect:     Graph
# @Scopes:      User.Read.All, Organization.Read.All
# @Modules:     Microsoft.Graph.Users, Microsoft.Graph.Identity.DirectoryManagement
# @Tags:        m365, licenses, billing, report, cost

[CmdletBinding()]
param(
    [ValidateSet('Licensed', 'All', 'Unlicensed', 'BlockedWithLicense')]
    [string]$Show = 'Licensed',

    [Parameter(HelpMessage = 'Only users with this license part number, for example SPB or ENTERPRISEPACK')]
    [string]$Sku = ''
)

if (-not (Get-MgContext)) { throw 'Not connected to Microsoft Graph. Click the Microsoft 365 button in Tech Kit first.' }

$skus = @{}
Get-MgSubscribedSku -All | ForEach-Object { $skus[[string]$_.SkuId] = $_.SkuPartNumber }
Write-Host 'Reading users...' -ForegroundColor Cyan
$users = @(Get-MgUser -All -Property 'displayName,userPrincipalName,accountEnabled,assignedLicenses,userType,department,createdDateTime,onPremisesSyncEnabled')

$rows = foreach ($u in $users) {
    $lic = @($u.AssignedLicenses | ForEach-Object { $n = $skus[[string]$_.SkuId]; if ($n) { $n } else { [string]$_.SkuId } })
    [pscustomobject]@{
        DisplayName = $u.DisplayName
        UPN         = $u.UserPrincipalName
        SignIn      = $(if ($u.AccountEnabled) { 'Allowed' } else { 'Blocked' })
        Type        = $u.UserType
        Department  = $u.Department
        Synced      = [bool]$u.OnPremisesSyncEnabled
        Created     = $u.CreatedDateTime
        LicenseCount = $lic.Count
        Licenses    = ($lic -join ', ')
    }
}
$rows = @($rows)
$blocked = @($rows | Where-Object { $_.SignIn -eq 'Blocked' -and $_.LicenseCount -gt 0 })
$unlic = @($rows | Where-Object { $_.LicenseCount -eq 0 -and $_.Type -ne 'Guest' -and $_.SignIn -eq 'Allowed' })
Write-Host "$($rows.Count) accounts. $(@($rows | Where-Object { $_.LicenseCount -gt 0 }).Count) licensed, $($unlic.Count) enabled members without a license." -ForegroundColor Cyan
if ($blocked.Count) { Write-Host "$($blocked.Count) blocked account(s) still hold licenses (possible savings)." -ForegroundColor Yellow }

switch ($Show) {
    'Licensed' { $rows = @($rows | Where-Object { $_.LicenseCount -gt 0 }) }
    'Unlicensed' { $rows = $unlic }
    'BlockedWithLicense' { $rows = $blocked }
}
if ($Sku) { $rows = @($rows | Where-Object { ($_.Licenses -split ', ') -contains $Sku }) }
$rows | Sort-Object DisplayName
