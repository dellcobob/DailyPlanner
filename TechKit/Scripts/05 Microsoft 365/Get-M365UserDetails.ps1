# @Name:        M365 User Lookup
# @Description: Everything about one Microsoft 365 user: sign-in status, licenses, MFA methods, last sign-in, password age, manager, groups and (if Exchange is connected) mailbox size and forwarding.
# @Admin:       No
# @Changes:     No
# @Target:      M365
# @Connect:     Graph
# @Scopes:      User.Read.All, Directory.Read.All, UserAuthenticationMethod.Read.All, AuditLog.Read.All
# @Modules:     Microsoft.Graph.Users, Microsoft.Graph.Identity.SignIns, Microsoft.Graph.Identity.DirectoryManagement
# @Tags:        m365, user, mfa, licenses, sign-in, helpdesk

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'UPN / email, or the start of a display name')]
    [string]$User
)

if (-not (Get-MgContext)) { throw 'Not connected to Microsoft Graph. Click the Microsoft 365 button in Tech Kit first.' }
$props = 'id,displayName,userPrincipalName,mail,accountEnabled,createdDateTime,lastPasswordChangeDateTime,department,jobTitle,officeLocation,mobilePhone,businessPhones,assignedLicenses,onPremisesSyncEnabled,usageLocation,userType,proxyAddresses'

$u = $null
$q = $User.Trim()
if ($q -match '@') {
    try { $u = Get-MgUser -UserId $q -Property $props -ErrorAction Stop } catch { }
}
if (-not $u) {
    $esc = $q -replace "'", "''"
    $found = @(Get-MgUser -Filter "startswith(displayName,'$esc') or startswith(userPrincipalName,'$esc') or startswith(mail,'$esc')" -Property $props -Top 25 -ConsistencyLevel eventual -CountVariable userCount)
    if ($found.Count -eq 0) { throw "No user matches '$q'." }
    if ($found.Count -gt 1 -and $found.Count -le 12) {
        $choices = [System.Collections.ObjectModel.Collection[System.Management.Automation.Host.ChoiceDescription]]::new()
        for ($i = 0; $i -lt $found.Count; $i++) {
            $hot = $(if ($i -lt 9) { '&' + ($i + 1) + ' ' } else { '' })
            $choices.Add((New-Object System.Management.Automation.Host.ChoiceDescription("$hot$($found[$i].DisplayName) <$($found[$i].UserPrincipalName)>", [string]$found[$i].UserPrincipalName)))
        }
        try {
            $pick = $Host.UI.PromptForChoice('Several users match', "Pick one of the $($found.Count) users matching '$q'.", $choices, 0)
            $found = @($found[$pick])
        } catch { }
    }
    if ($found.Count -gt 1) {
        Write-Host "$($found.Count) users match. Run again with the full UPN." -ForegroundColor Yellow
        $found | ForEach-Object { [pscustomobject]@{ DisplayName = $_.DisplayName; UPN = $_.UserPrincipalName; Enabled = $_.AccountEnabled; Type = $_.UserType } }
        return
    }
    $u = $found[0]
}

$skuMap = @{}
try { Get-MgSubscribedSku -All | ForEach-Object { $skuMap[[string]$_.SkuId] = $_.SkuPartNumber } } catch { }
$licenses = @($u.AssignedLicenses | ForEach-Object { $n = $skuMap[[string]$_.SkuId]; if ($n) { $n } else { [string]$_.SkuId } })

$lastSignIn = $null
$lastNonInteractive = $null
try {
    $si = (Get-MgUser -UserId $u.Id -Property 'signInActivity' -ErrorAction Stop).SignInActivity
    $lastSignIn = $si.LastSignInDateTime
    $lastNonInteractive = $si.LastNonInteractiveSignInDateTime
} catch { $lastSignIn = '(needs Entra ID P1 + AuditLog.Read.All)' }

$methods = @()
try {
    $methods = @(Get-MgUserAuthenticationMethod -UserId $u.Id -ErrorAction Stop | ForEach-Object {
        $t = [string]$_.AdditionalProperties['@odata.type']
        switch -Wildcard ($t) {
            '*microsoftAuthenticator*' { 'Authenticator app' }
            '*phoneAuthentication*' { "Phone ($($_.AdditionalProperties['phoneNumber']))" }
            '*fido2*' { 'FIDO2 key' }
            '*windowsHelloForBusiness*' { 'Windows Hello' }
            '*softwareOath*' { 'Software OTP' }
            '*temporaryAccessPass*' { 'Temporary Access Pass' }
            '*emailAuthentication*' { 'Email (SSPR)' }
            '*passwordAuthentication*' { 'Password' }
            '*platformCredential*' { 'Platform credential' }
            '*passkey*' { 'Passkey' }
            default { $t -replace '#microsoft.graph.', '' }
        }
    })
} catch { $methods = @('(could not read: needs UserAuthenticationMethod.Read.All)') }
$strong = @($methods | Where-Object { $_ -ne 'Password' -and $_ -ne 'Email (SSPR)' -and $_ -notlike '(*' })

$manager = $null
try { $manager = (Get-MgUserManager -UserId $u.Id -ErrorAction Stop).AdditionalProperties['displayName'] } catch { }
$groups = @()
try {
    $groups = @(Get-MgUserMemberOf -UserId $u.Id -All -ErrorAction Stop | ForEach-Object {
        $name = $_.AdditionalProperties['displayName']
        if ([string]$_.AdditionalProperties['@odata.type'] -like '*directoryRole*') { "[Role] $name" } else { $name }
    } | Sort-Object)
} catch { }

if (-not $u.AccountEnabled) { Write-Host 'Sign-in is BLOCKED for this account.' -ForegroundColor Red }
if (-not $licenses.Count -and $u.UserType -ne 'Guest') { Write-Host 'No licenses assigned.' -ForegroundColor Yellow }
if (-not $strong.Count) { Write-Host 'No MFA method registered.' -ForegroundColor Red } else { Write-Host "MFA methods: $($strong -join ', ')" -ForegroundColor Green }
$roles = @($groups | Where-Object { $_ -like '`[Role`]*' })
if ($roles.Count) { Write-Host "Admin roles: $(($roles -replace '^\[Role\] ') -join ', ')" -ForegroundColor Yellow }

$mailbox = $null
if (Get-Command Get-EXOMailbox -ErrorAction SilentlyContinue) {
    try {
        $mb = Get-EXOMailbox -Identity $u.UserPrincipalName -Properties ForwardingSmtpAddress, ForwardingAddress, RecipientTypeDetails -ErrorAction Stop
        $st = Get-EXOMailboxStatistics -Identity $u.UserPrincipalName -ErrorAction Stop
        $mailbox = "$($mb.RecipientTypeDetails), $($st.TotalItemSize), $($st.ItemCount) items"
        if ($mb.ForwardingSmtpAddress -or $mb.ForwardingAddress) {
            Write-Host "Mailbox forwards to $($mb.ForwardingSmtpAddress)$($mb.ForwardingAddress)" -ForegroundColor Yellow
            $mailbox += ", forwards to $($mb.ForwardingSmtpAddress)$($mb.ForwardingAddress)"
        }
    } catch { }
}

[pscustomobject]@{
    DisplayName        = $u.DisplayName
    UPN                = $u.UserPrincipalName
    Mail               = $u.Mail
    SignInAllowed      = $u.AccountEnabled
    Type               = $u.UserType
    SyncedFromAD       = [bool]$u.OnPremisesSyncEnabled
    Created            = $u.CreatedDateTime
    PasswordChanged    = $u.LastPasswordChangeDateTime
    LastSignIn         = $lastSignIn
    LastNonInteractive = $lastNonInteractive
    Licenses           = ($licenses -join ', ')
    MfaMethods         = ($methods -join ', ')
    JobTitle           = $u.JobTitle
    Department         = $u.Department
    Office             = $u.OfficeLocation
    Phone              = (@($u.BusinessPhones) + @($u.MobilePhone) | Where-Object { $_ }) -join ', '
    UsageLocation      = $u.UsageLocation
    Manager            = $manager
    Mailbox            = $mailbox
    Aliases            = (@($u.ProxyAddresses | Where-Object { $_ -clike 'smtp:*' } | ForEach-Object { $_.Substring(5) }) -join ', ')
    Groups             = ($groups -join ', ')
}
