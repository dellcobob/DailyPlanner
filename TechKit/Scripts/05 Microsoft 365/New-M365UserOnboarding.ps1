# @Name:        New User (Microsoft 365 onboarding)
# @Description: Adaxes-style cloud onboarding from a client rules file: builds the UPN and e-mail from the naming convention, creates the account, assigns licenses, adds the department's groups, Teams and SharePoint sites, sets the manager and (with Exchange connected) adds distribution lists. Run What-If first.
# @Admin:       No
# @Changes:     Yes
# @Target:      M365
# @Connect:     Graph
# @Scopes:      User.ReadWrite.All, GroupMember.ReadWrite.All, Group.Read.All, Organization.Read.All, LicenseAssignment.ReadWrite.All
# @Modules:     Microsoft.Graph.Users, Microsoft.Graph.Groups, Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.Users.Actions
# @Choices:     RulesProfile = files:Identity\*.json
# @Choices:     Department = jsonkeys:Identity\*.json:Departments
# @Tags:        m365, onboarding, new user, starter, licenses, adaxes, lifecycle

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Client rules file in Config\Identity')]
    [string]$RulesProfile,

    [Parameter(Mandatory = $true)]
    [string]$FirstName,

    [Parameter(Mandatory = $true)]
    [string]$LastName,

    [Parameter(Mandatory = $true, HelpMessage = 'Must be a department in the rules file')]
    [string]$Department,

    [string]$Title = '',

    [Parameter(HelpMessage = 'Manager UPN')]
    [string]$Manager = '',

    [string]$Office = '',
    [string]$MobilePhone = '',

    [Parameter(HelpMessage = 'Copy group memberships from this existing user (UPN)')]
    [string]$CopyGroupsFrom = '',

    [Parameter(HelpMessage = 'Leave empty to generate one')]
    [securestring]$Password
)

if (-not (Get-MgContext)) { throw 'Not connected to Microsoft Graph. Click the Microsoft 365 button in Tech Kit first.' }
if (-not (Get-Command Get-TKIdentityRules -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\..\Core\TechKit.Core.psm1') -DisableNameChecking
}
$rules = Get-TKIdentityRules -Name $RulesProfile
$dept = $rules.Departments[$Department]
if (-not $dept) { throw "Department '$Department' is not in $RulesProfile.json. Valid: $(@($rules.Departments.Keys) -join ', ')" }

function ConvertTo-Plain {
    param([string]$Text)
    $norm = $Text.Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $norm.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark) { $null = $sb.Append($ch) }
    }
    ($sb.ToString().ToLowerInvariant() -replace '[^a-z0-9\-]', '')
}
function Expand-Name {
    param([string]$Template, [string]$N = '')
    $first = ConvertTo-Plain $FirstName
    $last = ConvertTo-Plain $LastName
    $t = $Template.Replace('{first}', $first).Replace('{last}', $last).Replace('{First}', $FirstName.Trim()).Replace('{Last}', $LastName.Trim())
    $t = $t.Replace('{f}', $first.Substring(0, 1)).Replace('{l}', $last.Substring(0, 1)).Replace('{domain}', [string]$rules.Domain).Replace('{n}', $N)
    $t.Replace('{dept}', $Department)
}

$naming = $rules.Naming
$upn = $null; $mail = $null
for ($n = 1; $n -le 99; $n++) {
    $suffix = ''
    $upnT = $naming.UserPrincipalName; $mailT = $naming.Mail
    if ($n -gt 1) { $suffix = [string]$n; $upnT = $naming.Conflict + '@{domain}'; $mailT = $naming.Conflict + '@{domain}' }
    $u = Expand-Name $upnT $suffix
    $m = Expand-Name $mailT $suffix
    $clash = @(Get-MgUser -Filter "userPrincipalName eq '$u' or mail eq '$m'" -Property id -ConsistencyLevel eventual -CountVariable c)
    if (-not $clash.Count) { $upn = $u; $mail = $m; break }
    Write-Host "Name taken ($u), trying the next one..." -ForegroundColor DarkGray
}
if (-not $upn) { throw 'Could not find a free user name.' }
$display = Expand-Name $naming.DisplayName
$nick = ($upn -split '@')[0]
if (-not $Title) { $Title = [string]$dept.Title }

# Licenses: part numbers -> SKU ids, with a free-seat check
$skus = @{}
Get-MgSubscribedSku -All | ForEach-Object { $skus[$_.SkuPartNumber] = $_ }
$licenseIds = New-Object System.Collections.Generic.List[string]
foreach ($l in @($rules.Cloud.Licenses) + @($dept.Licenses)) {
    if (-not $l) { continue }
    $sku = $skus[$l]
    if (-not $sku) { Write-Host "License $l is not in this tenant. Skipping." -ForegroundColor Yellow; continue }
    $free = [int]$sku.PrepaidUnits.Enabled - [int]$sku.ConsumedUnits
    if ($free -lt 1) { Write-Host "No free $l licenses ($($sku.ConsumedUnits) of $($sku.PrepaidUnits.Enabled) used). Buy one, then assign it." -ForegroundColor Red; continue }
    if (-not $licenseIds.Contains([string]$sku.SkuId)) { $licenseIds.Add([string]$sku.SkuId) }
}

$groupNames = New-Object System.Collections.Generic.List[string]
foreach ($g in @($rules.Cloud.Groups) + @($dept.CloudGroups) + @($dept.SharePointSites)) { if ($g -and -not $groupNames.Contains($g)) { $groupNames.Add($g) } }
$dls = New-Object System.Collections.Generic.List[string]
foreach ($d in @($rules.Cloud.DistributionLists) + @($dept.DistributionLists)) { if ($d -and -not $dls.Contains($d)) { $dls.Add($d) } }
if ($CopyGroupsFrom) {
    $src = Get-MgUser -UserId $CopyGroupsFrom -ErrorAction Stop
    foreach ($m in @(Get-MgUserMemberOf -UserId $src.Id -All)) {
        if ([string]$m.AdditionalProperties['@odata.type'] -ne '#microsoft.graph.group') { continue }
        $name = [string]$m.AdditionalProperties['displayName']
        if ($name -and -not $groupNames.Contains($name)) { $groupNames.Add($name) }
    }
}

Write-Host "Plan for $display" -ForegroundColor Cyan
Write-Host "  UPN / mail : $upn / $mail"
Write-Host "  Title      : $Title ($Department)"
Write-Host "  Licenses   : $((@($licenseIds | ForEach-Object { $id = $_; ($skus.Values | Where-Object { [string]$_.SkuId -eq $id }).SkuPartNumber })) -join ', ')"
Write-Host "  Groups     : $($groupNames -join ', ')"
if ($dls.Count) { Write-Host "  Lists      : $($dls -join ', ')" }

$plain = $null
if ($Password -and $Password.Length -gt 0) { $plain = (New-Object System.Net.NetworkCredential('', $Password)).Password }
else {
    $bytes = New-Object byte[] 12
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $plain = ([Convert]::ToBase64String($bytes) -replace '[+/=]', 'x') + 'K7!'
}

$log = New-Object System.Collections.Generic.List[object]
function Add-Step { param([string]$Step, [string]$Result) $log.Add([pscustomobject]@{ User = $upn; Step = $Step; Result = $Result }) }

$user = $null
$body = @{
    AccountEnabled    = $true
    DisplayName       = $display
    GivenName         = $FirstName.Trim()
    Surname           = $LastName.Trim()
    UserPrincipalName = $upn
    MailNickname      = $nick
    UsageLocation     = [string]$rules.UsageLocation
    Department        = $Department
    JobTitle          = $Title
    PasswordProfile   = @{ Password = $plain; ForceChangePasswordNextSignIn = $true }
}
if ($rules.Company) { $body.CompanyName = [string]$rules.Company }
if ($Office) { $body.OfficeLocation = $Office }
if ($MobilePhone) { $body.MobilePhone = $MobilePhone }

if ($PSCmdlet.ShouldProcess($upn, 'Create Microsoft 365 user')) {
    $user = New-MgUser -BodyParameter $body -ErrorAction Stop
    Add-Step 'Create account' 'OK'
    Write-Host "Created $upn." -ForegroundColor Green
} else { Add-Step 'Create account' 'What-If' }

if ($Manager -and $PSCmdlet.ShouldProcess($upn, "Set manager $Manager")) {
    try {
        $mgr = Get-MgUser -UserId $Manager -ErrorAction Stop
        Set-MgUserManagerByRef -UserId $user.Id -BodyParameter @{ '@odata.id' = "https://graph.microsoft.com/v1.0/users/$($mgr.Id)" } -ErrorAction Stop
        Add-Step 'Manager' 'OK'
    } catch { Add-Step 'Manager' "FAIL: $($_.Exception.Message)" }
}

if ($licenseIds.Count -and $PSCmdlet.ShouldProcess($upn, "Assign $($licenseIds.Count) license(s)")) {
    try {
        $add = @($licenseIds | ForEach-Object { @{ SkuId = $_ } })
        $null = Set-MgUserLicense -UserId $user.Id -AddLicenses $add -RemoveLicenses @() -ErrorAction Stop
        Add-Step 'Licenses' 'OK'
        Write-Host 'Licenses assigned. The mailbox is created in a few minutes.' -ForegroundColor Green
    } catch { Add-Step 'Licenses' "FAIL: $($_.Exception.Message)"; Write-Host "License assignment failed: $($_.Exception.Message)" -ForegroundColor Red }
}

foreach ($name in $groupNames) {
    if (-not $PSCmdlet.ShouldProcess($upn, "Add to group '$name'")) { Add-Step "Group $name" 'What-If'; continue }
    $esc = $name -replace "'", "''"
    $grp = @(Get-MgGroup -Filter "displayName eq '$esc'" -Property id, displayName, groupTypes, mailEnabled, securityEnabled)
    if ($grp.Count -ne 1) { Add-Step "Group $name" $(if ($grp.Count) { 'FAIL: more than one group has this name' } else { 'FAIL: group not found' }); continue }
    $g = $grp[0]
    if ($g.GroupTypes -contains 'DynamicMembership') { Add-Step "Group $name" 'Skipped (dynamic group)'; continue }
    if ($g.MailEnabled -and $g.GroupTypes -notcontains 'Unified') { $dls.Add($name); Add-Step "Group $name" 'Moved to the distribution list step'; continue }
    try {
        New-MgGroupMember -GroupId $g.Id -DirectoryObjectId $user.Id -ErrorAction Stop
        Add-Step "Group $name" 'OK'
    } catch { Add-Step "Group $name" "FAIL: $($_.Exception.Message)" }
}

if ($dls.Count) {
    if (Get-Command Add-DistributionGroupMember -ErrorAction SilentlyContinue) {
        foreach ($dl in $dls) {
            if (-not $PSCmdlet.ShouldProcess($upn, "Add to distribution list $dl")) { Add-Step "List $dl" 'What-If'; continue }
            try { Add-DistributionGroupMember -Identity $dl -Member $upn -ErrorAction Stop; Add-Step "List $dl" 'OK' }
            catch { Add-Step "List $dl" "Pending: $($_.Exception.Message) (mailbox may not exist yet; run Bulk Add Users to Group later)" }
        }
    } else {
        foreach ($dl in $dls) { Add-Step "List $dl" 'Skipped: connect Exchange Online to manage distribution lists' }
    }
}

if (-not $WhatIfPreference -and $user) {
    Write-Host "Temporary password for $upn : $plain" -ForegroundColor Yellow
    Write-Host 'They must change it at first sign-in. It is not saved anywhere by Tech Kit.' -ForegroundColor DarkGray
}
[pscustomobject]@{ User = $upn; Step = 'Summary'; Result = "$display | $mail | $Title | $Department" }
$log
