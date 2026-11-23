# @Name:        Folder Permissions Report
# @Description: NTFS permissions for a folder, plus only the subfolders whose permissions differ (inheritance broken or extra explicit entries). Hides SYSTEM, CREATOR OWNER and other noise. Can also write the two CSV files (root and subfolders).
# @Admin:       Yes
# @Changes:     No
# @Target:      Local, Remote
# @Tags:        ntfs, permissions, acl, share, audit, migration

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Folder to report on, for example D:\Shares\Finance')]
    [string]$Path,

    [Parameter(HelpMessage = 'How many levels of subfolders to check')]
    [int]$Depth = 3,

    [Parameter(HelpMessage = 'Hide SYSTEM, CREATOR OWNER, TrustedInstaller, app packages and similar built-in entries')]
    [bool]$HideSystemAccounts = $true,

    [Parameter(HelpMessage = 'Also hide BUILTIN\Administrators')]
    [switch]$HideAdministrators,

    [Parameter(HelpMessage = 'Optional folder to save <name>_root.csv and <name>_subfolders.csv into')]
    [string]$ExportFolder = ''
)

if (-not (Test-Path -LiteralPath $Path)) { throw "Path not found: $Path" }
$root = (Resolve-Path -LiteralPath $Path).Path

$noise = @('NT AUTHORITY\SYSTEM', 'CREATOR OWNER', 'CREATOR GROUP', 'OWNER RIGHTS', 'NT SERVICE\TrustedInstaller',
    'APPLICATION PACKAGE AUTHORITY\ALL APPLICATION PACKAGES', 'APPLICATION PACKAGE AUTHORITY\ALL RESTRICTED APPLICATION PACKAGES')
if ($HideAdministrators) { $noise += 'BUILTIN\Administrators' }

function Get-FriendlyRights {
    param($Rights)
    $r = [int64]$Rights
    $map = @{ 268435456 = 'Full Control'; -536805376 = 'Modify'; -1610612736 = 'Read & Execute'; 1179817 = 'Read & Execute'; 1180063 = 'Read & Write'; 1245631 = 'Modify'; 2032127 = 'Full Control'; 1179785 = 'Read' }
    if ($map.ContainsKey($r)) { return $map[$r] }
    $fs = [System.Security.AccessControl.FileSystemRights]$Rights
    if (($fs -band [System.Security.AccessControl.FileSystemRights]::FullControl) -eq [System.Security.AccessControl.FileSystemRights]::FullControl) { return 'Full Control' }
    if (($fs -band [System.Security.AccessControl.FileSystemRights]::Modify) -eq [System.Security.AccessControl.FileSystemRights]::Modify) { return 'Modify' }
    if (($fs -band [System.Security.AccessControl.FileSystemRights]::ReadAndExecute) -eq [System.Security.AccessControl.FileSystemRights]::ReadAndExecute) {
        if (($fs -band [System.Security.AccessControl.FileSystemRights]::Write) -ne 0) { return 'Read, Execute & Write' }
        return 'Read & Execute'
    }
    "Special ($fs)"
}

function Get-AppliesTo {
    param($Rule)
    $i = [string]$Rule.InheritanceFlags
    $p = [string]$Rule.PropagationFlags
    if ($i -eq 'None') { return 'This folder only' }
    $text = switch ($i) {
        'ContainerInherit, ObjectInherit' { 'This folder, subfolders and files' }
        'ContainerInherit' { 'This folder and subfolders' }
        'ObjectInherit' { 'This folder and files' }
        default { $i }
    }
    if ($p -match 'InheritOnly') { $text = $text -replace '^This folder(, | and )', '' -replace '^subfolders', 'Subfolders' -replace '^files', 'Files'; $text += ' only' }
    $text
}

function Get-Rows {
    param([string]$Folder, [string]$Scope, [switch]$ExplicitOnly)
    try {
        $acl = Get-Acl -LiteralPath $Folder -ErrorAction Stop
    } catch {
        return [pscustomobject]@{ Scope = $Scope; Folder = $Folder; Identity = ''; Rights = ''; Type = ''; Inherited = $null; AppliesTo = ''; InheritanceBlocked = $null; Owner = ''; Note = "Cannot read: $($_.Exception.Message)" }
    }
    $blocked = $acl.AreAccessRulesProtected
    foreach ($rule in $acl.Access) {
        $id = [string]$rule.IdentityReference
        if ($HideSystemAccounts -and ($noise -contains $id -or $id -like 'S-1-15-*')) { continue }
        if ($ExplicitOnly -and $rule.IsInherited -and -not $blocked) { continue }
        [pscustomobject]@{
            Scope              = $Scope
            Folder             = $Folder
            Identity           = $id
            Rights             = Get-FriendlyRights $rule.FileSystemRights
            Type               = [string]$rule.AccessControlType
            Inherited          = $rule.IsInherited
            AppliesTo          = Get-AppliesTo $rule
            InheritanceBlocked = $blocked
            Owner              = $acl.Owner
            Note               = $(if ($id -match '^S-1-5-21-') { 'Orphaned SID (deleted account)' } else { '' })
        }
    }
}

$rootRows = @(Get-Rows -Folder $root -Scope 'Root')
Write-Host "Root: $root  ($($rootRows.Count) entries, owner $(($rootRows | Select-Object -First 1).Owner))" -ForegroundColor Cyan

$subRows = New-Object System.Collections.Generic.List[object]
$queue = New-Object System.Collections.Generic.Queue[object]
$queue.Enqueue(@($root, 0))
$checked = 0
while ($queue.Count) {
    $item = $queue.Dequeue()
    $dir = $item[0]
    $level = $item[1]
    if ($level -ge $Depth) { continue }
    $children = @()
    try { $children = [IO.Directory]::GetDirectories($dir) } catch { }
    foreach ($c in $children) {
        $checked++
        if ($checked % 50 -eq 0) { Write-Progress -Activity 'Checking subfolder permissions' -Status $c }
        foreach ($r in @(Get-Rows -Folder $c -Scope 'Subfolder' -ExplicitOnly)) { $subRows.Add($r) }
        $queue.Enqueue(@($c, ($level + 1)))
    }
}
Write-Progress -Activity 'Checking subfolder permissions' -Completed
$diffFolders = @($subRows | Select-Object -ExpandProperty Folder -Unique)
Write-Host "$checked subfolder(s) checked, $($diffFolders.Count) with different permissions." -ForegroundColor Cyan
foreach ($f in @($subRows | Where-Object { $_.InheritanceBlocked } | Select-Object -ExpandProperty Folder -Unique)) {
    Write-Host "Inheritance blocked: $f" -ForegroundColor Yellow
}
foreach ($r in @($rootRows + $subRows | Where-Object { $_.Note -like 'Orphaned*' } | Select-Object -First 10)) {
    Write-Host "Orphaned SID $($r.Identity) on $($r.Folder)" -ForegroundColor Yellow
}

if ($ExportFolder) {
    if (-not (Test-Path -LiteralPath $ExportFolder)) { $null = New-Item -ItemType Directory -Path $ExportFolder -Force }
    $base = ((Split-Path -Path $root -Leaf) -replace '[^\w\-]', '_')
    if (-not $base) { $base = 'root' }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmm'
    $f1 = Join-Path $ExportFolder "$($base)_root_$stamp.csv"
    $f2 = Join-Path $ExportFolder "$($base)_subfolders_$stamp.csv"
    $rootRows | Export-Csv -LiteralPath $f1 -NoTypeInformation -Encoding UTF8
    $subRows | Export-Csv -LiteralPath $f2 -NoTypeInformation -Encoding UTF8
    Write-Host "Saved $f1" -ForegroundColor Green
    Write-Host "Saved $f2" -ForegroundColor Green
}
$rootRows
$subRows
