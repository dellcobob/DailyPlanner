# @Name:        Shared Folders & Permissions
# @Description: Lists SMB shares with their share permissions, flags shares open to Everyone or Authenticated Users, and reports whether SMBv1 is enabled.
# @Admin:       Yes
# @Changes:     No
# @Target:      Local, Remote
# @Tags:        smb, shares, permissions, everyone, smbv1, audit

[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'Include admin shares like C$ and ADMIN$')]
    [switch]$IncludeHidden
)

try {
    $cfg = Get-SmbServerConfiguration -ErrorAction Stop
    if ($cfg.EnableSMB1Protocol) { Write-Host 'SMBv1 server protocol is ENABLED. Disable it unless something old truly needs it.' -ForegroundColor Red }
    else { Write-Host 'SMBv1 server protocol is disabled.' -ForegroundColor Green }
    if (-not $cfg.RequireSecuritySignature) { Write-Host 'SMB signing is not required on this server.' -ForegroundColor Yellow }
} catch { }

$shares = @(Get-SmbShare -ErrorAction Stop | Where-Object { $IncludeHidden -or -not $_.Name.EndsWith('$') })
if (-not $shares.Count) { Write-Host "No shared folders on $env:COMPUTERNAME." -ForegroundColor Green; return }

$broad = @('Everyone', 'NT AUTHORITY\Authenticated Users', 'BUILTIN\Users', 'NT AUTHORITY\ANONYMOUS LOGON')
foreach ($s in $shares) {
    foreach ($a in @(Get-SmbShareAccess -Name $s.Name -ErrorAction SilentlyContinue)) {
        $risk = ''
        if ($broad -contains $a.AccountName -and [string]$a.AccessControlType -eq 'Allow' -and [string]$a.AccessRight -in @('Full', 'Change')) {
            $risk = 'Broad write access'
            Write-Host "$($s.Name): $($a.AccountName) has $($a.AccessRight) access" -ForegroundColor Yellow
        }
        [pscustomobject]@{
            Computer = $env:COMPUTERNAME
            Share    = $s.Name
            Path     = $s.Path
            Account  = $a.AccountName
            Access   = [string]$a.AccessRight
            Type     = [string]$a.AccessControlType
            Risk     = $risk
            Encrypt  = $s.EncryptData
        }
    }
}
