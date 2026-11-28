# @Name:        Exchange RBAC Lookup
# @Description: Answers "which Exchange role lets someone run this cmdlet?", "what can this role do?" and "which roles does this person have?". Useful when building least-privilege delegation for helpdesk staff or app registrations.
# @Admin:       No
# @Changes:     No
# @Target:      M365
# @Connect:     Exchange
# @Modules:     ExchangeOnlineManagement
# @Tags:        exchange, rbac, roles, permissions, delegation, least privilege

[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'Cmdlet to look up, for example Set-Mailbox')]
    [string]$Cmdlet = '',

    [Parameter(HelpMessage = 'Optional parameters the cmdlet must allow, one per line (for example ForwardingSmtpAddress)')]
    [string[]]$Parameter = @(),

    [Parameter(HelpMessage = 'Role name to list, for example "Mail Recipients"')]
    [string]$Role = '',

    [Parameter(HelpMessage = 'User or group whose effective roles you want to see')]
    [string]$Assignee = ''
)

if (-not (Get-Command Get-ManagementRoleEntry -ErrorAction SilentlyContinue)) { throw 'Not connected to Exchange Online (or your account cannot read RBAC). Click the Microsoft 365 button in Tech Kit first.' }
if (-not $Cmdlet -and -not $Role -and -not $Assignee) { throw 'Fill in Cmdlet, Role or Assignee.' }

if ($Cmdlet) {
    $p = @{ Identity = "*\$Cmdlet"; ErrorAction = 'Stop' }
    $params = @($Parameter | ForEach-Object { $_ -split '[,;\s]+' } | Where-Object { $_ })
    if ($params.Count) { $p.Parameters = $params }
    $entries = @(Get-ManagementRoleEntry @p)
    Write-Host "$($entries.Count) role(s) allow $Cmdlet$(if ($params.Count) { " with $($params -join ', ')" })" -ForegroundColor Cyan
    foreach ($e in $entries) {
        $groups = @(Get-ManagementRoleAssignment -Role $e.Role -Delegating:$false -ErrorAction SilentlyContinue | Select-Object -ExpandProperty RoleAssigneeName -Unique)
        [pscustomobject]@{ Lookup = 'Cmdlet'; Cmdlet = $Cmdlet; Role = $e.Role; AssignedTo = ($groups -join ', ') }
    }
}
if ($Role) {
    $entries = @(Get-ManagementRoleEntry -Identity "$Role\*" -ErrorAction Stop)
    Write-Host "Role '$Role' has $($entries.Count) cmdlet(s)." -ForegroundColor Cyan
    foreach ($e in ($entries | Sort-Object Name)) {
        [pscustomobject]@{ Lookup = 'Role'; Role = $Role; Cmdlet = $e.Name; Parameters = (@($e.Parameters) -join ', ') }
    }
}
if ($Assignee) {
    $assign = @(Get-ManagementRoleAssignment -RoleAssignee $Assignee -Delegating:$false -ErrorAction Stop)
    Write-Host "$Assignee has $($assign.Count) role assignment(s) (directly or through role groups)." -ForegroundColor Cyan
    foreach ($a in ($assign | Sort-Object Role)) {
        [pscustomobject]@{ Lookup = 'Assignee'; Assignee = $Assignee; Role = $a.Role; Via = $a.RoleAssigneeName; Scope = $a.RecipientWriteScope }
    }
}
