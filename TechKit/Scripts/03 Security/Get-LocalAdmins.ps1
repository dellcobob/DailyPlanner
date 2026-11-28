# @Name:        Local Administrators
# @Description: Lists every member of the local Administrators group (users, groups, domain and Entra ID accounts) and highlights anything unexpected.
# @Admin:       No
# @Changes:     No
# @Target:      Local, Remote
# @Tags:        audit, admin, privileges, local group

[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'Names you expect to see (not highlighted). Wildcards allowed.')]
    [string[]]$Expected = @('*\Administrator', '*\Domain Admins', '*\Enterprise Admins')
)

$sid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
$groupName = $sid.Translate([System.Security.Principal.NTAccount]).Value.Split('\')[-1]
$members = @()

try {
    $members = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop | ForEach-Object {
        [pscustomobject]@{ Name = [string]$_.Name; Type = [string]$_.ObjectClass; Source = [string]$_.PrincipalSource; SID = [string]$_.SID }
    })
} catch {
    # Get-LocalGroupMember fails when the group holds orphaned SIDs; fall back to ADSI.
    $group = [ADSI]"WinNT://$env:COMPUTERNAME/$groupName,group"
    foreach ($m in @($group.Invoke('Members'))) {
        $path = $m.GetType().InvokeMember('ADsPath', 'GetProperty', $null, $m, $null)
        $class = $m.GetType().InvokeMember('Class', 'GetProperty', $null, $m, $null)
        $sidBytes = $m.GetType().InvokeMember('objectSid', 'GetProperty', $null, $m, $null)
        $sidText = ''
        try { $sidText = (New-Object System.Security.Principal.SecurityIdentifier($sidBytes, 0)).Value } catch { }
        $name = ($path -replace '^WinNT://', '' -replace '/', '\')
        $source = 'Domain/Other'
        if ($name -like "$env:COMPUTERNAME\*") { $source = 'Local' }
        $members += [pscustomobject]@{ Name = $name; Type = $class; Source = $source; SID = $sidText }
    }
}

foreach ($m in $members) {
    $ok = $false
    foreach ($e in $Expected) { if ($m.Name -like $e) { $ok = $true } }
    if ($m.SID -match '^S-1-5-21-.*-500$') { $ok = $true }
    $enabled = ''
    if ($m.Source -eq 'Local' -and $m.Type -eq 'User') {
        try { $enabled = [string](Get-LocalUser -SID $m.SID -ErrorAction Stop).Enabled } catch { }
    }
    if (-not $ok) { Write-Host "Review: $($m.Name) ($($m.Type), $($m.Source)) is a local admin" -ForegroundColor Yellow }
    [pscustomobject]@{
        Computer = $env:COMPUTERNAME
        Member   = $m.Name
        Type     = $m.Type
        Source   = $m.Source
        Enabled  = $enabled
        Expected = $(if ($ok) { 'Yes' } else { 'Review' })
        SID      = $m.SID
    }
}
Write-Host "$($members.Count) member(s) in $groupName on $env:COMPUTERNAME" -ForegroundColor Cyan
