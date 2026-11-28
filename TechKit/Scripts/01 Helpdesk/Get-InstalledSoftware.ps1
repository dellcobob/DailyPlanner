# @Name:        Installed Software
# @Description: Lists installed programs (64-bit, 32-bit and per-user) with version, publisher and install date. Filter by name with wildcards.
# @Admin:       No
# @Changes:     No
# @Target:      Local, Remote
# @Tags:        inventory, software, apps, version

[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'Name filter, wildcards allowed (for example *Office* or Adobe*)')]
    [string]$Name = '*',

    [Parameter(HelpMessage = 'Include Windows updates and system components')]
    [switch]$IncludeSystemComponents
)

$paths = @(
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'; Scope = 'Machine'; Arch = '64-bit' },
    @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'; Scope = 'Machine'; Arch = '32-bit' },
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'; Scope = 'User'; Arch = '' }
)
$seen = @{}
$list = foreach ($p in $paths) {
    Get-ItemProperty -Path $p.Path -ErrorAction SilentlyContinue | ForEach-Object {
        if (-not $_.DisplayName) { return }
        if (-not $IncludeSystemComponents -and ($_.SystemComponent -eq 1 -or $_.ParentKeyName -or $_.ReleaseType -match 'Update|Hotfix')) { return }
        if ($_.DisplayName -notlike $Name) { return }
        $key = "$($_.DisplayName)|$($_.DisplayVersion)"
        if ($seen.ContainsKey($key)) { return }
        $seen[$key] = $true
        $date = $null
        if ($_.InstallDate -match '^\d{8}$') {
            try { $date = [datetime]::ParseExact($_.InstallDate, 'yyyyMMdd', $null).ToString('yyyy-MM-dd') } catch { }
        }
        [pscustomobject]@{
            Name      = $_.DisplayName
            Version   = $_.DisplayVersion
            Publisher = $_.Publisher
            Installed = $date
            Scope     = $p.Scope
            Arch      = $p.Arch
            SizeMB    = $(if ($_.EstimatedSize) { [Math]::Round($_.EstimatedSize / 1024, 1) } else { $null })
        }
    }
}
$list = @($list | Sort-Object Name)
Write-Host "$($list.Count) program(s) found on $env:COMPUTERNAME" -ForegroundColor Cyan
$list
