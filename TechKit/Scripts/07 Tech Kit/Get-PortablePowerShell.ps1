# @Name:        Put PowerShell 7 on the USB
# @Description: Downloads the official PowerShell 7 zip from GitHub and extracts it to Runtimes\pwsh on the USB, so Tech Kit runs on PowerShell 7 even on PCs that only have Windows PowerShell 5.1.
# @Admin:       No
# @Changes:     No
# @Target:      Local
# @Tags:        tech kit, pwsh, powershell 7, portable, setup

[CmdletBinding()]
param(
    [ValidateSet('x64', 'arm64', 'x86')]
    [string]$Architecture = 'x64',

    [Parameter(HelpMessage = 'Exact version like 7.4.6. Empty = latest stable release.')]
    [string]$Version = ''
)

if (-not (Get-Command Get-TKPath -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\..\Core\TechKit.Core.psm1') -DisableNameChecking
}
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

$dest = Join-Path (Get-TKPath Runtimes) 'pwsh'
$running = (Get-Process -Id $PID).Path
if ($running -like "$dest*") { throw 'Tech Kit is running from Runtimes\pwsh right now. Switch Settings > PowerShell to Windows PowerShell 5.1, restart Tech Kit, then run this again.' }

# Windows PowerShell 5.1 does not allow User-Agent in -Headers, so use -UserAgent
if ($Version) {
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/PowerShell/PowerShell/releases/tags/v$($Version.TrimStart('v'))" -UserAgent 'TechKit' -UseBasicParsing
} else {
    $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' -UserAgent 'TechKit' -UseBasicParsing
}
$asset = @($rel.assets | Where-Object { $_.name -match "^PowerShell-[\d\.]+-win-$Architecture\.zip$" }) | Select-Object -First 1
if (-not $asset) { throw "No win-$Architecture zip found in release $($rel.tag_name)." }

$tmp = Join-Path $env:TEMP $asset.name
Write-Host "Downloading $($asset.name) ($([Math]::Round($asset.size / 1MB)) MB)..." -ForegroundColor Cyan
$old = $ProgressPreference
$ProgressPreference = 'SilentlyContinue'
try { Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmp -UseBasicParsing } finally { $ProgressPreference = $old }

if (Test-Path -LiteralPath $dest) {
    Write-Host "Replacing the existing $dest" -ForegroundColor Yellow
    Remove-Item -LiteralPath $dest -Recurse -Force
}
$null = New-Item -ItemType Directory -Path $dest -Force
Write-Host "Extracting to $dest ..." -ForegroundColor Cyan
Expand-Archive -LiteralPath $tmp -DestinationPath $dest -Force
Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
Get-ChildItem -LiteralPath $dest -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

if (Test-Path -LiteralPath (Join-Path $dest 'pwsh.exe')) {
    Write-Host "PowerShell $($rel.tag_name) is on the USB. Restart Tech Kit to use it (Settings > PowerShell = Auto)." -ForegroundColor Green
} else {
    Write-Host 'Extraction finished but pwsh.exe was not found. Check the Runtimes\pwsh folder.' -ForegroundColor Red
}
[pscustomobject]@{ Version = $rel.tag_name; Architecture = $Architecture; Path = $dest }
