# @Name:        Group Membership
# @Description: Shows every group a user belongs to (including nested groups), or every member of a group (recursively). Use it for "why can't they see the share?" and access reviews.
# @Admin:       No
# @Changes:     No
# @Target:      Local, Remote
# @Modules:     ActiveDirectory
# @Tags:        ad, groups, nested, access, permissions

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'A user logon name (UserGroups) or a group name (GroupMembers)')]
    [string]$Identity,

    [ValidateSet('UserGroups', 'GroupMembers')]
    [string]$Mode = 'UserGroups',

    [bool]$Recursive = $true
)

Import-Module ActiveDirectory -ErrorAction Stop
$id = $Identity.Trim()

if ($Mode -eq 'UserGroups') {
    $obj = $null
    try { $obj = Get-ADUser -Identity $id -Properties MemberOf, PrimaryGroup -ErrorAction Stop } catch { }
    if (-not $obj) { try { $obj = Get-ADComputer -Identity $id -Properties MemberOf, PrimaryGroup -ErrorAction Stop } catch { } }
    if (-not $obj) { throw "No user or computer named '$id'." }
    $direct = @($obj.MemberOf)
    if ($Recursive) {
        $dn = $obj.DistinguishedName -replace '\\', '\5c' -replace '\(', '\28' -replace '\)', '\29'
        $groups = @(Get-ADGroup -LDAPFilter "(member:1.2.840.113556.1.4.1941:=$dn)" -Properties Description)
    } else {
        $groups = @($direct | ForEach-Object { Get-ADGroup -Identity $_ -Properties Description })
    }
    Write-Host "$($obj.SamAccountName) is in $($groups.Count) group(s) ($($direct.Count) direct), primary group: $(($obj.PrimaryGroup -split ',')[0] -replace '^CN=')" -ForegroundColor Cyan
    $groups | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{
            Group       = $_.Name
            Membership  = $(if ($direct -contains $_.DistinguishedName) { 'Direct' } else { 'Nested' })
            Scope       = [string]$_.GroupScope
            Category    = [string]$_.GroupCategory
            Description = $_.Description
        }
    }
} else {
    $g = Get-ADGroup -Identity $id -ErrorAction Stop
    $members = @()
    try {
        $members = @(Get-ADGroupMember -Identity $g -Recursive:$Recursive -ErrorAction Stop)
    } catch {
        Write-Host "Get-ADGroupMember failed ($($_.Exception.Message)); reading the member attribute instead." -ForegroundColor Yellow
        $members = @((Get-ADGroup -Identity $g -Properties member).member | ForEach-Object { Get-ADObject -Identity $_ -Properties sAMAccountName })
    }
    Write-Host "$($g.Name) has $($members.Count) member(s)$(if ($Recursive) { ' including nested groups' })" -ForegroundColor Cyan
    $members | Sort-Object objectClass, Name | ForEach-Object {
        $enabled = ''
        if ($_.objectClass -eq 'user') { try { $enabled = [string](Get-ADUser -Identity $_.DistinguishedName).Enabled } catch { } }
        [pscustomobject]@{
            Member         = $_.Name
            SamAccountName = $_.SamAccountName
            Type           = $_.objectClass
            Enabled        = $enabled
        }
    }
}
