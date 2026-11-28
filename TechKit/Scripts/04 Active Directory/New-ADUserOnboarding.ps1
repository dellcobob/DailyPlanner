# @Name:        New User (Active Directory onboarding)
# @Description: Adaxes-style onboarding from a client rules file: builds the logon name, UPN and e-mail from the naming convention, picks the OU and groups for the department, generates a password, sets the manager, optionally copies another user's groups and starts an Entra Connect sync. Run What-If first to preview.
# @Admin:       No
# @Changes:     Yes
# @Target:      Local
# @Modules:     ActiveDirectory
# @Choices:     RulesProfile = files:Identity\*.json
# @Choices:     Department = jsonkeys:Identity\*.json:Departments
# @Tags:        ad, onboarding, new user, starter, adaxes, lifecycle

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

    [Parameter(HelpMessage = 'Job title (default comes from the department)')]
    [string]$Title = '',

    [Parameter(HelpMessage = 'Manager logon name or UPN')]
    [string]$Manager = '',

    [string]$Office = '',
    [string]$Phone = '',
    [string]$EmployeeId = '',

    [Parameter(HelpMessage = 'Copy group memberships from this existing user (logon name)')]
    [string]$CopyGroupsFrom = '',

    [Parameter(HelpMessage = 'Account expiry date for contractors, for example 2027-03-31')]
    [string]$AccountExpires = '',

    [Parameter(HelpMessage = 'Leave empty to generate one')]
    [securestring]$Password,

    [Parameter(HelpMessage = 'Domain controller to use (empty = any)')]
    [string]$Server = '',

    [Parameter(HelpMessage = 'Entra Connect server: start a delta sync afterwards (empty = skip)')]
    [string]$SyncServer = ''
)

Import-Module ActiveDirectory -ErrorAction Stop
if (-not (Get-Command Get-TKIdentityRules -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\..\Core\TechKit.Core.psm1') -DisableNameChecking
}
if ($Server) { $PSDefaultParameterValues['*-AD*:Server'] = $Server }
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
    $t = $Template
    $t = $t.Replace('{first}', $first).Replace('{last}', $last).Replace('{First}', $FirstName.Trim()).Replace('{Last}', $LastName.Trim())
    $t = $t.Replace('{f}', $first.Substring(0, 1)).Replace('{l}', $last.Substring(0, 1)).Replace('{domain}', [string]$rules.Domain).Replace('{n}', $N)
    $t.Replace('{dept}', $Department)
}
function New-Password {
    param([int]$Length = 16)
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!@#$%*?-+=')
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $chars = [System.Collections.Generic.List[char]]::new()
    $all = -join $sets
    for ($i = 0; $i -lt $Length; $i++) {
        $set = $all
        if ($i -lt $sets.Count) { $set = $sets[$i] }
        $b = New-Object byte[] 4
        $rng.GetBytes($b)
        $chars.Add($set[[BitConverter]::ToUInt32($b, 0) % $set.Length])
    }
    -join ($chars | Sort-Object { Get-Random })
}

$naming = $rules.Naming
$maxSam = 20
if ($naming.MaxSamLength) { $maxSam = [int]$naming.MaxSamLength }

# Find a free logon name / UPN / mail using the naming convention
$sam = $null; $upn = $null; $mail = $null
for ($n = 1; $n -le 99; $n++) {
    $suffix = ''
    $samT = $naming.SamAccountName; $upnT = $naming.UserPrincipalName; $mailT = $naming.Mail
    if ($n -gt 1) {
        $suffix = [string]$n
        $samT = $naming.Conflict
        $upnT = $naming.Conflict + '@{domain}'
        $mailT = $naming.Conflict + '@{domain}'
    }
    $s = Expand-Name $samT $suffix
    if ($s.Length -gt $maxSam) { $s = $s.Substring(0, $maxSam - $suffix.Length) + $suffix }
    $u = Expand-Name $upnT $suffix
    $m = Expand-Name $mailT $suffix
    $clash = @(Get-ADUser -Filter "SamAccountName -eq '$s' -or UserPrincipalName -eq '$u' -or mail -eq '$m' -or proxyAddresses -eq 'smtp:$m'")
    if (-not $clash.Count) { $sam = $s; $upn = $u; $mail = $m; break }
    Write-Host "Name taken ($s / $u), trying the next one..." -ForegroundColor DarkGray
}
if (-not $sam) { throw 'Could not find a free account name.' }
$display = Expand-Name $naming.DisplayName

$ou = $dept.OU
if (-not $ou) { $ou = $rules.AD.DefaultOU }
try { $null = Get-ADOrganizationalUnit -Identity $ou -ErrorAction Stop } catch { throw "OU not found: $ou (check $RulesProfile.json)" }

$groups = [System.Collections.Generic.List[string]]::new()
foreach ($g in @($rules.AD.Groups) + @($dept.ADGroups)) { if ($g -and -not $groups.Contains($g)) { $groups.Add($g) } }
if ($CopyGroupsFrom) {
    $src = Get-ADUser -Identity $CopyGroupsFrom -Properties MemberOf -ErrorAction Stop
    foreach ($dn in @($src.MemberOf)) { $n = (Get-ADGroup -Identity $dn).SamAccountName; if (-not $groups.Contains($n)) { $groups.Add($n) } }
}

$managerObj = $null
if ($Manager) {
    try { $managerObj = Get-ADUser -Identity $Manager -ErrorAction Stop } catch {
        $esc = $Manager -replace "'", "''"
        $managerObj = @(Get-ADUser -Filter "UserPrincipalName -eq '$esc' -or mail -eq '$esc'")[0]
    }
    if (-not $managerObj) { throw "Manager '$Manager' not found." }
}
if (-not $Title) { $Title = [string]$dept.Title }

$plain = $null
if (-not $Password -or $Password.Length -eq 0) {
    $len = 16
    if ($rules.PasswordLength) { $len = [int]$rules.PasswordLength }
    $plain = New-Password -Length $len
    $Password = ConvertTo-SecureString -String $plain -AsPlainText -Force
}

Write-Host "Plan for $display" -ForegroundColor Cyan
Write-Host "  Logon name : $sam"
Write-Host "  UPN / mail : $upn / $mail"
Write-Host "  OU         : $ou"
Write-Host "  Title      : $Title ($Department)"
if ($managerObj) { Write-Host "  Manager    : $($managerObj.Name)" }
Write-Host "  Groups     : $($groups -join ', ')"

$newParams = @{
    Name                  = $display
    DisplayName           = $display
    GivenName             = $FirstName.Trim()
    Surname               = $LastName.Trim()
    SamAccountName        = $sam
    UserPrincipalName     = $upn
    EmailAddress          = $mail
    Path                  = $ou
    AccountPassword       = $Password
    Enabled               = $true
    ChangePasswordAtLogon = [bool]$rules.AD.MustChangePassword
    Department            = $Department
    Title                 = $Title
    OtherAttributes       = @{ proxyAddresses = "SMTP:$mail" }
}
if ($rules.Company) { $newParams.Company = [string]$rules.Company }
if ($Office) { $newParams.Office = $Office }
if ($Phone) { $newParams.OfficePhone = $Phone }
if ($EmployeeId) { $newParams.EmployeeID = $EmployeeId }
if ($managerObj) { $newParams.Manager = $managerObj.DistinguishedName }
if ($AccountExpires) { $newParams.AccountExpirationDate = [datetime]$AccountExpires }

$log = [System.Collections.Generic.List[object]]::new()
function Add-Step { param([string]$Step, [string]$Result) $log.Add([pscustomobject]@{ User = $sam; Step = $Step; Result = $Result }) }

if ($PSCmdlet.ShouldProcess("$display ($sam) in $ou", 'Create AD user')) {
    New-ADUser @newParams -ErrorAction Stop
    Add-Step 'Create account' 'OK'
    Write-Host "Created $sam." -ForegroundColor Green
} else {
    Add-Step 'Create account' 'What-If'
}
foreach ($g in $groups) {
    if ($PSCmdlet.ShouldProcess($sam, "Add to group $g")) {
        try { Add-ADGroupMember -Identity $g -Members $sam -ErrorAction Stop; Add-Step "Group $g" 'OK' }
        catch { Add-Step "Group $g" "FAIL: $($_.Exception.Message)"; Write-Host "Could not add to $g : $($_.Exception.Message)" -ForegroundColor Yellow }
    } else { Add-Step "Group $g" 'What-If' }
}
if ($SyncServer -and $PSCmdlet.ShouldProcess($SyncServer, 'Start Entra Connect delta sync')) {
    try {
        Invoke-Command -ComputerName $SyncServer -ScriptBlock { Import-Module ADSync; Start-ADSyncSyncCycle -PolicyType Delta } -ErrorAction Stop | Out-Null
        Add-Step 'Entra Connect delta sync' 'Started'
        Write-Host 'Delta sync started. The cloud account appears within a few minutes; then run "New User (Microsoft 365)" or let group-based licensing do the rest.' -ForegroundColor Green
    } catch { Add-Step 'Entra Connect delta sync' "FAIL: $($_.Exception.Message)" }
}
if ($plain -and -not $WhatIfPreference) {
    Write-Host "Initial password for $sam : $plain" -ForegroundColor Yellow
    Write-Host 'Give it to the user securely. It is not saved anywhere by Tech Kit.' -ForegroundColor DarkGray
}
[pscustomobject]@{ User = $sam; Step = 'Summary'; Result = "$display | $upn | $mail | $ou | $Title | groups: $($groups -join ', ')" }
$log
