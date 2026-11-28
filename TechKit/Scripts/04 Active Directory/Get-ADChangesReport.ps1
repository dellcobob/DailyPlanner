# @Name:        AD Changes Report
# @Description: What changed in Active Directory: new accounts, accounts expiring soon, recently disabled, and (compared with the last run) moved, renamed and deleted accounts. Export to HTML for a weekly e-mail so you hear about starters and leavers.
# @Admin:       No
# @Changes:     No
# @Target:      Local, Remote
# @Modules:     ActiveDirectory
# @Tags:        ad, report, new users, leavers, expiring, moved, weekly

[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'Look back this many days for new and disabled accounts')]
    [int]$Days = 7,

    [Parameter(HelpMessage = 'Flag accounts expiring within this many days')]
    [int]$ExpiringDays = 14,

    [Parameter(HelpMessage = 'Only this OU (distinguished name). Empty = whole domain.')]
    [string]$SearchBase = '',

    [bool]$IncludeComputers = $false,

    [Parameter(HelpMessage = 'Compare with the previous snapshot to find moved, renamed and deleted accounts (stored on the USB)')]
    [bool]$UseSnapshot = $true
)

Import-Module ActiveDirectory -ErrorAction Stop
$now = Get-Date
$since = $now.AddDays(-$Days)
$p = @{ Filter = '*'; Properties = @('whenCreated', 'whenChanged', 'AccountExpirationDate', 'Enabled', 'Department', 'Title', 'Manager', 'objectGUID', 'DisplayName') }
if ($SearchBase) { $p.SearchBase = $SearchBase }
$objects = @(Get-ADUser @p)
if ($IncludeComputers) {
    $pc = @{ Filter = '*'; Properties = @('whenCreated', 'whenChanged', 'Enabled', 'objectGUID', 'OperatingSystem') }
    if ($SearchBase) { $pc.SearchBase = $SearchBase }
    $objects += @(Get-ADComputer @pc)
}
function Get-OU { param([string]$Dn) ($Dn -split '(?<!\\),', 2)[1] }

$rows = [System.Collections.Generic.List[object]]::new()
foreach ($o in $objects) {
    $kind = $(if ($o.ObjectClass -eq 'computer') { 'Computer' } else { 'User' })
    if ($o.whenCreated -ge $since) {
        $rows.Add([pscustomobject]@{ Change = 'New'; Type = $kind; Name = $o.Name; SamAccountName = $o.SamAccountName; When = $o.whenCreated; Detail = "$($o.Title) $($o.Department)".Trim(); OU = Get-OU $o.DistinguishedName })
    }
    if ($o.AccountExpirationDate -and $o.AccountExpirationDate -ge $now -and $o.AccountExpirationDate -le $now.AddDays($ExpiringDays)) {
        $rows.Add([pscustomobject]@{ Change = 'Expiring'; Type = $kind; Name = $o.Name; SamAccountName = $o.SamAccountName; When = $o.AccountExpirationDate; Detail = "Account expires in $([int]($o.AccountExpirationDate - $now).TotalDays) day(s)"; OU = Get-OU $o.DistinguishedName })
    }
    if (-not $o.Enabled -and $o.whenChanged -ge $since -and $o.whenCreated -lt $since) {
        $rows.Add([pscustomobject]@{ Change = 'Disabled (recently changed)'; Type = $kind; Name = $o.Name; SamAccountName = $o.SamAccountName; When = $o.whenChanged; Detail = 'Disabled and modified in the period'; OU = Get-OU $o.DistinguishedName })
    }
}

if ($UseSnapshot -and $env:TECHKIT_ROOT) {
    $domain = (Get-ADDomain).DNSRoot
    $dir = Join-Path $env:TECHKIT_ROOT 'Reports\Snapshots'
    $suffix = $(if ($SearchBase) { '-' + (($SearchBase -replace '[^\w]', '_').Substring(0, [Math]::Min(40, $SearchBase.Length))) } else { '' })
    $file = Join-Path $dir "AD-$domain$suffix.json"
    $current = @{}
    foreach ($o in $objects) { $current[[string]$o.objectGUID] = @{ Name = $o.Name; Sam = $o.SamAccountName; DN = $o.DistinguishedName; Type = [string]$o.ObjectClass } }
    if (Test-Path -LiteralPath $file) {
        $old = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
        $taken = (Get-Item -LiteralPath $file).LastWriteTime
        foreach ($prop in $old.PSObject.Properties) {
            $guid = $prop.Name
            $was = $prop.Value
            if (-not $current.ContainsKey($guid)) {
                $rows.Add([pscustomobject]@{ Change = 'Deleted'; Type = $was.Type; Name = $was.Name; SamAccountName = $was.Sam; When = $null; Detail = "Gone since snapshot of $taken"; OU = Get-OU $was.DN })
                continue
            }
            $nowObj = $current[$guid]
            if ($nowObj.DN -ne $was.DN) {
                $oldOu = Get-OU $was.DN
                $newOu = Get-OU $nowObj.DN
                if ($oldOu -ne $newOu) {
                    $rows.Add([pscustomobject]@{ Change = 'Moved'; Type = $nowObj.Type; Name = $nowObj.Name; SamAccountName = $nowObj.Sam; When = $null; Detail = "From $oldOu"; OU = $newOu })
                } else {
                    $rows.Add([pscustomobject]@{ Change = 'Renamed'; Type = $nowObj.Type; Name = $nowObj.Name; SamAccountName = $nowObj.Sam; When = $null; Detail = "Was $($was.Name)"; OU = $newOu })
                }
            }
        }
        Write-Host "Compared with the snapshot from $taken." -ForegroundColor Cyan
    } else {
        Write-Host 'First run: snapshot saved. Moved, renamed and deleted accounts show up from the next run.' -ForegroundColor DarkGray
    }
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    $current | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $file -Encoding UTF8
}

$rows | Group-Object Change | ForEach-Object { Write-Host ("{0,4}  {1}" -f $_.Count, $_.Name) -ForegroundColor $(switch -Wildcard ($_.Name) { 'New' { 'Green' } 'Expiring' { 'Yellow' } 'Deleted' { 'Red' } default { 'Cyan' } }) }
if (-not $rows.Count) { Write-Host "No changes found in the last $Days days." -ForegroundColor Green }
$rows | Sort-Object Change, Name
