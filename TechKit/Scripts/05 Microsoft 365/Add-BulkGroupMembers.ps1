# @Name:        Bulk Add Users to Group / Team
# @Description: Adds (or removes) a list of users to a Microsoft 365 group, Team, security group or, with Exchange connected, a distribution list. Paste UPNs or point at a CSV. Adding to a Team's group adds them to the Team.
# @Admin:       No
# @Changes:     Yes
# @Target:      M365
# @Connect:     Graph
# @Scopes:      GroupMember.ReadWrite.All, Group.Read.All, User.Read.All
# @Modules:     Microsoft.Graph.Groups, Microsoft.Graph.Users
# @Tags:        m365, teams, groups, bulk, membership, csv

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Group or Team name, or its e-mail address')]
    [string]$Group,

    [Parameter(HelpMessage = 'User UPNs / e-mail addresses, one per line')]
    [string[]]$Users = @(),

    [Parameter(HelpMessage = 'Or a CSV file with a UserPrincipalName, UPN, Email or Mail column')]
    [string]$CsvPath = '',

    [ValidateSet('Member', 'Owner')]
    [string]$Role = 'Member',

    [Parameter(HelpMessage = 'Remove the users instead of adding them')]
    [switch]$Remove
)

if (-not (Get-MgContext)) { throw 'Not connected to Microsoft Graph. Click the Microsoft 365 button in Tech Kit first.' }
$list = New-Object System.Collections.Generic.List[string]
foreach ($x in $Users) { foreach ($y in ($x -split '[,;\s]+')) { if ($y.Trim()) { $list.Add($y.Trim()) } } }
if ($CsvPath) {
    $rows = @(Import-Csv -LiteralPath $CsvPath)
    if ($rows.Count) {
        $cols = @($rows[0].PSObject.Properties.Name)
        $col = @('UserPrincipalName', 'UPN', 'Email', 'Mail', 'EmailAddress') | Where-Object { $cols -contains $_ } | Select-Object -First 1
        if (-not $col) { $col = $cols[0] }
        foreach ($r in $rows) { if ([string]$r.$col) { $list.Add(([string]$r.$col).Trim()) } }
    }
}
$list = @($list | Select-Object -Unique)
if (-not $list.Count) { throw 'No users given. Fill in Users or CsvPath.' }

$esc = $Group -replace "'", "''"
$found = @(Get-MgGroup -Filter "displayName eq '$esc' or mail eq '$esc'" -Property id, displayName, mail, groupTypes, mailEnabled, securityEnabled, resourceProvisioningOptions -ConsistencyLevel eventual -CountVariable groupCount)
if ($found.Count -ne 1) { throw $(if ($found.Count) { "More than one group matches '$Group'. Use its e-mail address." } else { "No group matches '$Group'." }) }
$g = $found[0]
$isDl = $g.MailEnabled -and ($g.GroupTypes -notcontains 'Unified')
$isTeam = @($g.AdditionalProperties['resourceProvisioningOptions']) -contains 'Team'
if ($g.GroupTypes -contains 'DynamicMembership') { throw "$($g.DisplayName) is a dynamic group; its members come from a rule." }
if ($isDl -and -not (Get-Command Add-DistributionGroupMember -ErrorAction SilentlyContinue)) { throw "$($g.DisplayName) is a distribution list or mail-enabled security group. Connect Exchange Online too, then run again." }
$kind = $(if ($isDl) { 'distribution list' } elseif ($isTeam) { 'Team' } elseif ($g.GroupTypes -contains 'Unified') { 'Microsoft 365 group' } else { 'security group' })
Write-Host "$($g.DisplayName) ($kind): $($list.Count) user(s) to $(if ($Remove) { 'remove' } else { 'add' }) as $Role" -ForegroundColor Cyan

$i = 0
foreach ($upn in $list) {
    $i++
    Write-Progress -Activity $g.DisplayName -Status $upn -PercentComplete ([int](100 * $i / $list.Count))
    $result = ''
    try {
        $usr = Get-MgUser -UserId $upn -Property id, userPrincipalName -ErrorAction Stop
        $action = $(if ($Remove) { "Remove $Role" } else { "Add as $Role" })
        if (-not $PSCmdlet.ShouldProcess("$upn -> $($g.DisplayName)", $action)) { $result = 'What-If' }
        elseif ($isDl) {
            if ($Role -eq 'Owner') { throw 'Owners of distribution lists are managed with Set-DistributionGroup -ManagedBy.' }
            $dlId = $(if ($g.Mail) { $g.Mail } else { $g.DisplayName })
            if ($Remove) { Remove-DistributionGroupMember -Identity $dlId -Member $upn -Confirm:$false -ErrorAction Stop }
            else { Add-DistributionGroupMember -Identity $dlId -Member $upn -ErrorAction Stop }
            $result = 'OK'
        } elseif ($Remove) {
            if ($Role -eq 'Owner') { Remove-MgGroupOwnerByRef -GroupId $g.Id -DirectoryObjectId $usr.Id -ErrorAction Stop }
            else { Remove-MgGroupMemberByRef -GroupId $g.Id -DirectoryObjectId $usr.Id -ErrorAction Stop }
            $result = 'OK'
        } else {
            if ($Role -eq 'Owner') {
                New-MgGroupOwnerByRef -GroupId $g.Id -BodyParameter @{ '@odata.id' = "https://graph.microsoft.com/v1.0/users/$($usr.Id)" } -ErrorAction Stop
            } else {
                New-MgGroupMember -GroupId $g.Id -DirectoryObjectId $usr.Id -ErrorAction Stop
            }
            $result = 'OK'
        }
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match 'already exist') { $result = 'Already a member' } else { $result = "FAIL: $msg" }
    }
    [pscustomobject]@{ User = $upn; Group = $g.DisplayName; Role = $Role; Action = $(if ($Remove) { 'Remove' } else { 'Add' }); Result = $result }
}
Write-Progress -Activity $g.DisplayName -Completed
