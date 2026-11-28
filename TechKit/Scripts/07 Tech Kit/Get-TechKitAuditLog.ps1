# @Name:        View Audit Log
# @Description: Shows the Tech Kit audit log (Logs\audit.csv on the USB): every run of a script that makes changes, with who, when, which computer, target, inputs, ticket, approver and result. Filter by date or text and export for the client.
# @Admin:       No
# @Changes:     No
# @Target:      Local
# @Tags:        tech kit, audit, log, changes, compliance, report

[CmdletBinding()]
param(
    [int]$Days = 30,

    [Parameter(HelpMessage = 'Only rows containing this text (user, script, target, ticket...)')]
    [string]$Search = '',

    [Parameter(HelpMessage = 'Hide What-If (dry) runs')]
    [switch]$HideWhatIf
)

if (-not (Get-Command Get-TKPath -ErrorAction SilentlyContinue)) { Import-Module (Join-Path $PSScriptRoot '..\..\Core\TechKit.Core.psm1') -DisableNameChecking }
$file = Join-Path (Get-TKPath Logs) 'audit.csv'
if (-not (Test-Path -LiteralPath $file)) { Write-Host 'The audit log is empty. It fills up as you run scripts that make changes.' -ForegroundColor Yellow; return }

$since = (Get-Date).AddDays(-$Days)
$rows = @(Import-Csv -LiteralPath $file | Where-Object {
    $t = [datetime]::MinValue
    [datetime]::TryParse($_.Time, [ref]$t) -and $t -ge $since
})
if ($Search) { $rows = @($rows | Where-Object { (($_.PSObject.Properties | ForEach-Object { $_.Value }) -join ' ') -like "*$Search*" }) }
if ($HideWhatIf) { $rows = @($rows | Where-Object { $_.WhatIf -ne 'True' }) }

$fails = @($rows | Where-Object { $_.Result -notlike 'Done*' }).Count
Write-Host "$($rows.Count) entr$(if ($rows.Count -eq 1) { 'y' } else { 'ies' }) in the last $Days days, $fails not fully successful." -ForegroundColor Cyan
$rows | Group-Object Operator | ForEach-Object { Write-Host ("  {0,4}  {1}" -f $_.Count, $_.Name) }
$rows | Sort-Object Time -Descending
