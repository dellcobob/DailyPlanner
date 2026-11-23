# @Name:        Offboard User (Microsoft 365)
# @Description: Adaxes-style leaver workflow: block sign-in, revoke sessions, reset the password, convert the mailbox to shared, give the manager access, set an auto-reply, hide from the address book, remove group memberships and licenses. Every step is listed so the output doubles as the ticket record. Defaults come from the client's rules file.
# @Admin:       No
# @Changes:     Yes
# @Target:      M365
# @Connect:     Graph, Exchange
# @Scopes:      User.ReadWrite.All, User.RevokeSessions.All, User-PasswordProfile.ReadWrite.All, GroupMember.ReadWrite.All, LicenseAssignment.ReadWrite.All, Directory.Read.All
# @Modules:     Microsoft.Graph.Users, Microsoft.Graph.Users.Actions, Microsoft.Graph.Groups, ExchangeOnlineManagement
# @Choices:     RulesProfile = files:Identity\*.json
# @Tags:        m365, offboarding, leaver, termination, shared mailbox, adaxes, lifecycle

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'UPN of the leaver')]
    [string]$User,

    [Parameter(HelpMessage = 'Client rules file for the defaults (empty = use the switches below as shown)')]
    [string]$RulesProfile = '',

    [Parameter(HelpMessage = 'Who gets mailbox access and forwarding (empty = the user''s manager)')]
    [string]$Delegate = '',

    [bool]$BlockSignIn = $true,
    [bool]$RevokeSessions = $true,
    [bool]$ResetPassword = $true,
    [bool]$ConvertToShared = $true,
    [bool]$GrantDelegateAccess = $true,
    [bool]$SetAutoReply = $true,
    [bool]$ForwardToDelegate = $false,
    [bool]$HideFromAddressBook = $true,
    [bool]$RemoveGroups = $true,
    [bool]$RemoveLicenses = $true
)

if (-not (Get-MgContext)) { throw 'Not connected to Microsoft Graph. Click the Microsoft 365 button in Tech Kit first.' }
$company = ''
$replyTemplate = 'Thank you for your message. {Name} is no longer with {Company}. Please contact {Manager} at {ManagerMail}.'
if ($RulesProfile) {
    if (-not (Get-Command Get-TKIdentityRules -ErrorAction SilentlyContinue)) { Import-Module (Join-Path $PSScriptRoot '..\..\Core\TechKit.Core.psm1') -DisableNameChecking }
    $rules = Get-TKIdentityRules -Name $RulesProfile
    $o = $rules.Offboarding
    $company = [string]$rules.Company
    if ($o) {
        # Rules file values replace the switch defaults
        if ($o.Contains('ConvertToShared')) { $ConvertToShared = [bool]$o.ConvertToShared }
        if ($o.Contains('RemoveLicenses')) { $RemoveLicenses = [bool]$o.RemoveLicenses }
        if ($o.Contains('RemoveGroups')) { $RemoveGroups = [bool]$o.RemoveGroups }
        if ($o.Contains('HideFromGAL')) { $HideFromAddressBook = [bool]$o.HideFromGAL }
        if ($o.Contains('GrantManagerAccess')) { $GrantDelegateAccess = [bool]$o.GrantManagerAccess }
        if ($o.Contains('ForwardToManager')) { $ForwardToDelegate = [bool]$o.ForwardToManager }
        if ($o.AutoReply) { $replyTemplate = [string]$o.AutoReply }
    }
}

$u = Get-MgUser -UserId $User.Trim() -Property 'id,displayName,userPrincipalName,mail,accountEnabled,onPremisesSyncEnabled,assignedLicenses,companyName' -ErrorAction Stop
if (-not $company) { $company = [string]$u.CompanyName }
$log = New-Object System.Collections.Generic.List[object]
function Add-Step { param([string]$Step, [string]$Result) $log.Add([pscustomobject]@{ User = $u.UserPrincipalName; Time = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Step = $Step; Result = $Result }) }
function Invoke-Step {
    param([string]$Step, [scriptblock]$Action)
    if (-not $PSCmdlet.ShouldProcess($u.UserPrincipalName, $Step)) { Add-Step $Step 'What-If'; return }
    try {
        $r = & $Action
        $text = 'OK'
        if ($r -is [string] -and $r) { $text = $r }
        Add-Step $Step $text
        Write-Host "  $Step : $text" -ForegroundColor Green
    } catch {
        Add-Step $Step "FAIL: $($_.Exception.Message)"
        Write-Host "  $Step : FAILED $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host "Offboarding $($u.DisplayName) <$($u.UserPrincipalName)>" -ForegroundColor Cyan
if ($u.OnPremisesSyncEnabled) {
    Write-Host 'This user is synced from on-premises AD. Also run "Disable User (Offboarding)" in AD, or the next sync may undo sign-in blocking and the address book setting.' -ForegroundColor Yellow
}

$delegateUser = $null
if ($Delegate) { $delegateUser = Get-MgUser -UserId $Delegate -Property 'id,displayName,userPrincipalName,mail' -ErrorAction Stop }
else {
    try {
        $mgrRef = Get-MgUserManager -UserId $u.Id -ErrorAction Stop
        $delegateUser = Get-MgUser -UserId $mgrRef.Id -Property 'id,displayName,userPrincipalName,mail'
    } catch { }
}
if ($delegateUser) { Write-Host "Delegate / manager: $($delegateUser.DisplayName) <$($delegateUser.UserPrincipalName)>" -ForegroundColor Cyan }
elseif ($GrantDelegateAccess -or $ForwardToDelegate) { Write-Host 'No manager set and no Delegate given: mailbox access and forwarding steps are skipped.' -ForegroundColor Yellow }

# Record group memberships before anything is removed
$memberships = @(Get-MgUserMemberOf -UserId $u.Id -All | Where-Object { [string]$_.AdditionalProperties['@odata.type'] -eq '#microsoft.graph.group' })
foreach ($m in $memberships) { Add-Step 'Was member of' ([string]$m.AdditionalProperties['displayName']) }

if ($BlockSignIn) { Invoke-Step 'Block sign-in' { Update-MgUser -UserId $u.Id -AccountEnabled:$false -ErrorAction Stop } }
if ($ResetPassword) {
    Invoke-Step 'Reset password to a random value' {
        $b = New-Object byte[] 24
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
        Update-MgUser -UserId $u.Id -PasswordProfile @{ Password = ([Convert]::ToBase64String($b) + 'aA1!'); ForceChangePasswordNextSignIn = $true } -ErrorAction Stop
    }
}
if ($RevokeSessions) { Invoke-Step 'Revoke sessions' { $null = Revoke-MgUserSignInSession -UserId $u.Id -ErrorAction Stop } }

$hasMailbox = $false
try { $mbx = Get-EXOMailbox -Identity $u.UserPrincipalName -Properties RecipientTypeDetails -ErrorAction Stop; $hasMailbox = $true } catch { Add-Step 'Mailbox' 'No mailbox found; mailbox steps skipped' }
if ($hasMailbox) {
    if ($ConvertToShared -and [string]$mbx.RecipientTypeDetails -ne 'SharedMailbox') {
        Invoke-Step 'Convert mailbox to shared' { Set-Mailbox -Identity $u.UserPrincipalName -Type Shared -ErrorAction Stop }
    }
    if ($GrantDelegateAccess -and $delegateUser) {
        Invoke-Step "Give $($delegateUser.UserPrincipalName) full access" { $null = Add-MailboxPermission -Identity $u.UserPrincipalName -User $delegateUser.UserPrincipalName -AccessRights FullAccess -AutoMapping $true -ErrorAction Stop }
    }
    if ($SetAutoReply) {
        $mgrName = $(if ($delegateUser) { $delegateUser.DisplayName } else { 'our team' })
        $mgrMail = $(if ($delegateUser) { $delegateUser.Mail } else { '' })
        $msg = $replyTemplate.Replace('{Name}', $u.DisplayName).Replace('{Company}', $company).Replace('{Manager}', $mgrName).Replace('{ManagerMail}', $mgrMail)
        Invoke-Step 'Set auto-reply' { Set-MailboxAutoReplyConfiguration -Identity $u.UserPrincipalName -AutoReplyState Enabled -InternalMessage $msg -ExternalMessage $msg -ExternalAudience All -ErrorAction Stop }
    }
    if ($ForwardToDelegate -and $delegateUser) {
        Invoke-Step "Forward mail to $($delegateUser.UserPrincipalName)" { Set-Mailbox -Identity $u.UserPrincipalName -ForwardingSmtpAddress $delegateUser.Mail -DeliverToMailboxAndForward $true -ErrorAction Stop }
    }
    if ($HideFromAddressBook) {
        if ($u.OnPremisesSyncEnabled) { Add-Step 'Hide from address book' 'Skipped: set msExchHideFromAddressLists in on-premises AD for synced users' }
        else { Invoke-Step 'Hide from address book' { Set-Mailbox -Identity $u.UserPrincipalName -HiddenFromAddressListsEnabled $true -ErrorAction Stop } }
    }
}

if ($RemoveGroups) {
    foreach ($m in $memberships) {
        $gname = [string]$m.AdditionalProperties['displayName']
        $types = @($m.AdditionalProperties['groupTypes'])
        $mailEnabled = [bool]$m.AdditionalProperties['mailEnabled']
        if ($types -contains 'DynamicMembership') { Add-Step "Remove from $gname" 'Skipped (dynamic group: update its rule or the user attributes)'; continue }
        if ($m.AdditionalProperties['onPremisesSyncEnabled']) { Add-Step "Remove from $gname" 'Skipped (group synced from AD: remove it there)'; continue }
        if ($mailEnabled -and $types -notcontains 'Unified') {
            $dlId = [string]$m.AdditionalProperties['mail']
            if (-not $dlId) { $dlId = $gname }
            Invoke-Step "Remove from list $gname" { Remove-DistributionGroupMember -Identity $dlId -Member $u.UserPrincipalName -BypassSecurityGroupManagerCheck -Confirm:$false -ErrorAction Stop }
        } else {
            Invoke-Step "Remove from group $gname" { Remove-MgGroupMemberByRef -GroupId $m.Id -DirectoryObjectId $u.Id -ErrorAction Stop }
        }
    }
}

if ($RemoveLicenses -and @($u.AssignedLicenses).Count) {
    if ($ConvertToShared -and $hasMailbox) { Start-Sleep -Seconds 5 }
    Invoke-Step 'Remove licenses' {
        $ids = @($u.AssignedLicenses | ForEach-Object { [string]$_.SkuId })
        $null = Set-MgUserLicense -UserId $u.Id -AddLicenses @() -RemoveLicenses $ids -ErrorAction Stop
        "Removed $($ids.Count) license(s) (group-based licenses must be removed by taking the user out of the licensing group)"
    }
}

Write-Host 'Done. Keep this output (Export CSV/HTML) as the offboarding record.' -ForegroundColor Cyan
$log
