<#
    Tech Kit pop-out console profile.
    Dot-sourced when you open a console from the Tech Kit toolbar. Loads the USB
    module path and adds a few shortcuts:

      tk                 list all scripts
      tk dns             list scripts whose name/description/tags match "dns"
      tkrun "Disk Space" -WarnPercent 15     run a script by (partial) name
      tkconnect          connect to Microsoft 365 (Graph + Exchange)
#>

$global:TKConsoleRoot = Split-Path -Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'TechKit.Core.psm1') -DisableNameChecking -Force
Initialize-TKEnvironment

$isAdmin = Test-TKAdmin
$title = 'Tech Kit Console'
if ($isAdmin) { $title += ' (Administrator)' }
try { $Host.UI.RawUI.WindowTitle = $title } catch { }

function global:tk {
    param([string]$Search)
    $all = Get-TKScript
    if ($Search) {
        $s = $Search.ToLowerInvariant()
        $all = $all | Where-Object { $_.SearchText -like "*$s*" }
    }
    $all | Sort-Object CategoryFolder, Name | Format-Table @{ n = 'Category'; e = { $_.Category } }, Name, @{ n = 'Flags'; e = { $_.Badges -join ' ' } }, @{ n = 'File'; e = { $_.Id } } -AutoSize
}

function global:tkrun {
    if ($args.Count -lt 1) { Write-Host 'Usage: tkrun "<script name>" [-Param value ...]' -ForegroundColor Yellow; return }
    $search = [string]$args[0]
    $rest = @()
    if ($args.Count -gt 1) { $rest = $args[1..($args.Count - 1)] }
    $all = @(Get-TKScript)
    $match = @($all | Where-Object { $_.Name -eq $search -or $_.FileName -eq $search })
    if ($match.Count -eq 0) { $match = @($all | Where-Object { $_.Name -like "*$search*" -or $_.FileName -like "*$search*" }) }
    if ($match.Count -eq 0) { Write-Host "No script matches '$search'." -ForegroundColor Red; return }
    if ($match.Count -gt 1) {
        Write-Host "More than one script matches '$search':" -ForegroundColor Yellow
        $match | ForEach-Object { Write-Host "  $($_.Name)  ($($_.Id))" }
        return
    }
    $s = $match[0]
    if ($s.Language -ne 'PowerShell') { Write-Host 'tkrun runs PowerShell scripts. Use the Tech Kit window for Python and Bash.' -ForegroundColor Yellow; return }
    Write-Host "Running $($s.Name)..." -ForegroundColor Cyan
    & $s.Path @rest
}

function global:tkconnect {
    param([string[]]$Service = @('Graph', 'Exchange'), [string]$Method = 'Interactive')
    Connect-TKM365 -Service $Service -Method $Method -Scopes (Get-TKAllScopes)
}

# Bash-style Tab completion (complete as far as possible, then list the options)
if (Get-Module -ListAvailable -Name PSReadLine) {
    try { Set-PSReadLineKeyHandler -Key Tab -Function Complete -ErrorAction Stop } catch { }
}

Set-Location -LiteralPath $global:TKConsoleRoot

Write-Host ''
Write-Host '  Tech Kit Console' -ForegroundColor Cyan -NoNewline
Write-Host ("  PowerShell {0} ({1})" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition) -ForegroundColor DarkGray
if ($isAdmin) { Write-Host '  Running as Administrator' -ForegroundColor Yellow }
Write-Host '  tk [search]   list scripts      tkrun "name" [-Param value]   run a script' -ForegroundColor DarkGray
Write-Host '  tkconnect     connect to Microsoft 365 (Graph + Exchange)' -ForegroundColor DarkGray
Write-Host "  USB modules:  $(Get-TKPath Modules)" -ForegroundColor DarkGray
Write-Host ''
