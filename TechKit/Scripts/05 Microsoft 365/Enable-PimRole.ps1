# @Name:        Activate PIM Role
# @Description: Lists the Entra admin roles you are eligible for through Privileged Identity Management and activates one for a few hours with a justification, without clicking through the portal. Leave Role empty to just list.
# @Admin:       No
# @Changes:     Yes
# @Target:      M365
# @Connect:     Graph
# @Scopes:      RoleEligibilitySchedule.Read.Directory, RoleAssignmentSchedule.ReadWrite.Directory, User.Read
# @Modules:     Microsoft.Graph.Identity.Governance, Microsoft.Graph.Users
# @Tags:        pim, privileged identity, admin roles, activate, just in time, entra

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(HelpMessage = 'Role to activate, for example "Exchange Administrator". Empty = list eligible roles.')]
    [string]$Role = '',

    [ValidateSet('1', '2', '4', '8')]
    [string]$Hours = '2',

    [Parameter(HelpMessage = 'Why you need it (required by most PIM policies)')]
    [string]$Justification = '',

    [string]$TicketNumber = ''
)

$ctx = Get-MgContext
if (-not $ctx) { throw 'Not connected to Microsoft Graph. Click the Microsoft 365 button in Tech Kit first.' }
if (-not $ctx.Account) { throw 'PIM activation needs a signed-in admin account (not app sign-in).' }
$me = Get-MgUser -UserId $ctx.Account -Property id, displayName -ErrorAction Stop

$eligible = @(Get-MgRoleManagementDirectoryRoleEligibilityScheduleInstance -Filter "principalId eq '$($me.Id)'" -ExpandProperty roleDefinition -All -ErrorAction Stop)
$active = @(Get-MgRoleManagementDirectoryRoleAssignmentScheduleInstance -Filter "principalId eq '$($me.Id)'" -ExpandProperty roleDefinition -All -ErrorAction SilentlyContinue)

if (-not $Role) {
    Write-Host "$($me.DisplayName) is eligible for $($eligible.Count) role(s)." -ForegroundColor Cyan
    foreach ($e in $eligible) {
        $on = @($active | Where-Object { $_.RoleDefinitionId -eq $e.RoleDefinitionId -and $_.AssignmentType -eq 'Activated' })
        [pscustomobject]@{
            Role        = $e.RoleDefinition.DisplayName
            Scope       = $e.DirectoryScopeId
            EligibleTo  = $e.EndDateTime
            ActiveNow   = $(if ($on.Count) { "Yes, until $($on[0].EndDateTime)" } else { 'No' })
        }
    }
    return
}

$match = @($eligible | Where-Object { $_.RoleDefinition.DisplayName -eq $Role })
if (-not $match.Count) { $match = @($eligible | Where-Object { $_.RoleDefinition.DisplayName -like "*$Role*" }) }
if ($match.Count -ne 1) { throw $(if ($match.Count) { "More than one eligible role matches '$Role': $(($match | ForEach-Object { $_.RoleDefinition.DisplayName }) -join ', ')" } else { "You are not eligible for a role matching '$Role'. Leave Role empty to list your roles." }) }
$target = $match[0]
if (-not $Justification) { throw 'Enter a Justification (PIM usually requires one).' }

$body = @{
    Action           = 'selfActivate'
    PrincipalId      = $me.Id
    RoleDefinitionId = $target.RoleDefinitionId
    DirectoryScopeId = $target.DirectoryScopeId
    Justification    = $Justification
    ScheduleInfo     = @{
        StartDateTime = (Get-Date).ToUniversalTime().ToString('o')
        Expiration    = @{ Type = 'AfterDuration'; Duration = "PT$($Hours)H" }
    }
}
if ($TicketNumber) { $body.TicketInfo = @{ TicketNumber = $TicketNumber; TicketSystem = 'Tech Kit' } }

if ($PSCmdlet.ShouldProcess($target.RoleDefinition.DisplayName, "Activate for $Hours hour(s)")) {
    try {
        $req = New-MgRoleManagementDirectoryRoleAssignmentScheduleRequest -BodyParameter $body -ErrorAction Stop
        Write-Host "Requested: $($target.RoleDefinition.DisplayName) for $Hours hour(s). Status: $($req.Status)" -ForegroundColor Green
        if ($req.Status -match 'Pending') { Write-Host 'This role needs approval. You will get access once an approver accepts.' -ForegroundColor Yellow }
        Write-Host 'New permissions can take a few minutes to apply. Reconnect from the Microsoft 365 button if a script still gets "access denied".' -ForegroundColor DarkGray
        [pscustomobject]@{ Role = $target.RoleDefinition.DisplayName; Hours = $Hours; Status = $req.Status; RequestId = $req.Id }
    } catch {
        $m = $_.Exception.Message
        if ($m -match 'RoleAssignmentExists') { Write-Host 'That role is already active.' -ForegroundColor Green }
        elseif ($m -match 'MFA|multifactor|AcrsValidationFailed') { Write-Host 'The role requires a fresh MFA sign-in. Reconnect to Microsoft 365 (Interactive) and try again.' -ForegroundColor Yellow }
        else { throw }
    }
}
