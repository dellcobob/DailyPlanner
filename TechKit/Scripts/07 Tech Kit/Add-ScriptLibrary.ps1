# @Name:        Add Script Library from GitHub
# @Description: Downloads a GitHub repository of scripts (for example github.com/admindroid-community/powershell-scripts) into the Libraries folder on the USB. It shows up as its own category; run again to update it. Libraries are other people's code: review before use.
# @Admin:       No
# @Changes:     No
# @Target:      Local
# @Tags:        tech kit, library, github, download, community scripts

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Repository URL, for example https://github.com/admindroid-community/powershell-scripts')]
    [string]$RepoUrl,

    [Parameter(HelpMessage = 'Name for the category (empty = repository name)')]
    [string]$Name = '',

    [Parameter(HelpMessage = 'Branch (empty = the repository default)')]
    [string]$Branch = ''
)

if (-not (Get-Command Get-TKPath -ErrorAction SilentlyContinue)) { Import-Module (Join-Path $PSScriptRoot '..\..\Core\TechKit.Core.psm1') -DisableNameChecking }
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

if ($RepoUrl -notmatch 'github\.com[/:]([^/]+)/([^/#?]+?)(\.git)?(/|$|\?|#)') { throw 'Use a GitHub repository URL like https://github.com/owner/repo' }
$owner = $Matches[1]
$repo = $Matches[2]
if (-not $Name) { $Name = $repo }
$Name = $Name -replace '[\\/:*?"<>|]', ''

$info = $null
try { $info = Invoke-RestMethod -Uri "https://api.github.com/repos/$owner/$repo" -UserAgent 'TechKit' -UseBasicParsing -ErrorAction Stop } catch { }
if (-not $Branch) {
    if ($info -and $info.default_branch) { $Branch = $info.default_branch } else { $Branch = 'main' }
}
$license = ''
if ($info -and $info.license) { $license = [string]$info.license.spdx_id }

$libRoot = Get-TKPath Libraries
$dest = Join-Path $libRoot $Name
$tmpZip = Join-Path $env:TEMP "techkit-$owner-$repo.zip"
$tmpDir = Join-Path $env:TEMP "techkit-$owner-$repo"

if (-not $PSCmdlet.ShouldProcess($dest, "Download $owner/$repo ($Branch)")) { return }

Write-Host "Downloading $owner/$repo ($Branch)..." -ForegroundColor Cyan
$old = $ProgressPreference
$ProgressPreference = 'SilentlyContinue'
try {
    Invoke-WebRequest -Uri "https://codeload.github.com/$owner/$repo/zip/refs/heads/$Branch" -OutFile $tmpZip -UserAgent 'TechKit' -UseBasicParsing -ErrorAction Stop
} finally { $ProgressPreference = $old }

if (Test-Path -LiteralPath $tmpDir) { Remove-Item -LiteralPath $tmpDir -Recurse -Force }
Expand-Archive -LiteralPath $tmpZip -DestinationPath $tmpDir -Force
$inner = Get-ChildItem -LiteralPath $tmpDir -Directory | Select-Object -First 1
if (-not $inner) { throw 'The download was empty.' }

if (Test-Path -LiteralPath $dest) {
    Write-Host "Replacing the existing library '$Name'." -ForegroundColor Yellow
    Remove-Item -LiteralPath $dest -Recurse -Force
}
if (-not (Test-Path -LiteralPath $libRoot)) { $null = New-Item -ItemType Directory -Path $libRoot -Force }
Move-Item -LiteralPath $inner.FullName -Destination $dest
Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem -LiteralPath $dest -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
Set-Content -LiteralPath (Join-Path $dest '_techkit-source.txt') -Value "https://github.com/$owner/$repo ($Branch) downloaded $(Get-Date -Format s)" -Encoding UTF8

$count = @(Get-ChildItem -LiteralPath $dest -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.py', '.sh') }).Count
Write-Host "Library '$Name' is ready with $count script(s). Click Reload library to see it." -ForegroundColor Green
if ($license -and $license -ne 'NOASSERTION') { Write-Host "License: $license" -ForegroundColor DarkGray }
else { Write-Host 'This repository has no license file: use it for your own work, but do not copy or share its scripts further.' -ForegroundColor Yellow }
Write-Host 'Review library scripts before running them on a client network.' -ForegroundColor Yellow
[pscustomobject]@{ Library = $Name; Source = "$owner/$repo"; Branch = $Branch; Scripts = $count; License = $license; Folder = $dest }
