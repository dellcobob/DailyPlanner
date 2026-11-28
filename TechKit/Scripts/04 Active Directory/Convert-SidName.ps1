# @Name:        SID and Name Lookup
# @Description: Converts user or group names to SIDs and SIDs back to names (handy for orphaned SIDs in permissions and logs). Also shows the Unix uidNumber/gidNumber when the domain has them. No RSAT needed.
# @Admin:       No
# @Changes:     No
# @Target:      Local, Remote
# @Tags:        sid, uid, username, translate, orphaned

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Names (DOMAIN\user, user, user@domain) or SIDs (S-1-5-...), one per line')]
    [string[]]$Identity
)

$inDomain = (Get-CimInstance -ClassName Win32_ComputerSystem).PartOfDomain
foreach ($raw in $Identity) {
    $id = $raw.Trim()
    if (-not $id) { continue }
    $sid = $null
    $name = $null
    $note = ''
    try {
        if ($id -match '^S-\d-\d+(-\d+)+$') {
            $sid = $id
            $name = (New-Object System.Security.Principal.SecurityIdentifier($id)).Translate([System.Security.Principal.NTAccount]).Value
        } else {
            $acct = $id
            if ($id -match '^[^\\@]+@(.+)$') { $acct = $id }
            $sid = (New-Object System.Security.Principal.NTAccount($acct)).Translate([System.Security.Principal.SecurityIdentifier]).Value
            $name = (New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate([System.Security.Principal.NTAccount]).Value
        }
    } catch {
        $note = 'Could not resolve (deleted account, or a domain this computer cannot reach)'
    }

    $uid = $null
    $gid = $null
    $class = ''
    if ($inDomain -and $sid) {
        try {
            $searcher = New-Object System.DirectoryServices.DirectorySearcher("(objectSid=$sid)")
            foreach ($prop in @('uidnumber', 'gidnumber', 'objectclass', 'distinguishedname')) { $null = $searcher.PropertiesToLoad.Add($prop) }
            $hit = $searcher.FindOne()
            if ($hit) {
                $uid = $hit.Properties['uidnumber'] | Select-Object -First 1
                $gid = $hit.Properties['gidnumber'] | Select-Object -First 1
                $class = @($hit.Properties['objectclass'])[-1]
            }
        } catch { }
    }
    $well = ''
    if ($sid -match '-500$') { $well = 'Built-in Administrator' } elseif ($sid -match '-512$') { $well = 'Domain Admins' } elseif ($sid -match '^S-1-5-32-') { $well = 'Built-in local group' }
    [pscustomobject]@{
        Input     = $id
        Name      = $name
        SID       = $sid
        Class     = $class
        UidNumber = $uid
        GidNumber = $gid
        WellKnown = $well
        Note      = $note
    }
}
