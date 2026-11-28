# @Name:        Update USB Modules
# @Description: Downloads or refreshes the PowerShell modules carried on the USB (Microsoft Graph, Exchange Online and anything listed in Config\modules.json) from the PowerShell Gallery. Needs internet.
# @Admin:       No
# @Changes:     No
# @Target:      Local
# @Tags:        tech kit, modules, graph, exchange, update, maintenance

[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'Extra module names to add to the USB list, one per line')]
    [string[]]$Add = @(),

    [Parameter(HelpMessage = 'Only show what is on the USB now')]
    [switch]$ListOnly
)

if (-not (Get-Command Install-TKModule -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\..\Core\TechKit.Core.psm1') -DisableNameChecking
}
$modDir = Get-TKPath Modules
$cfgFile = Join-Path (Get-TKPath Config) 'modules.json'
$cfg = Get-Content -LiteralPath $cfgFile -Raw | ConvertFrom-Json
$list = @($cfg.Modules)

if ($Add.Count) {
    $list = @($list + ($Add | ForEach-Object { $_.Trim() } | Where-Object { $_ }) | Select-Object -Unique)
    $cfg.Modules = $list
    $cfg | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $cfgFile -Encoding UTF8
    Write-Host "Added to Config\modules.json: $($Add -join ', ')" -ForegroundColor Green
}

$onUsb = @(Get-ChildItem -LiteralPath $modDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $vers = @(Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    [pscustomobject]@{ Module = $_.Name; Versions = ($vers -join ', '); InList = ($list -contains $_.Name) }
})
if ($ListOnly) {
    if (-not $onUsb.Count) { Write-Host 'The USB Modules folder is empty.' -ForegroundColor Yellow }
    $onUsb
    return
}

Write-Host "Updating $($list.Count) module(s) in $modDir (dependencies come along automatically)..." -ForegroundColor Cyan
Install-TKModule -Name $list -Destination USB
Unblock-TKFiles -Force
$size = (Get-ChildItem -LiteralPath $modDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
Write-Host ('USB Modules folder is now {0:N0} MB.' -f ($size / 1MB)) -ForegroundColor Green
Write-Host 'Old versions are kept side by side. Delete older version folders by hand to save space.' -ForegroundColor DarkGray
