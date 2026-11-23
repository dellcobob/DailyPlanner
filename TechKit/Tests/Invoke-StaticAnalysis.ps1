<#
    Static checks for every PowerShell file in Tech Kit.

    1. Parses each file with the real PowerShell parser (syntax errors).
    2. Runs PSScriptAnalyzer with:
       - PSUseCompatibleSyntax  : syntax must work on Windows PowerShell 5.1 and PowerShell 7
       - PSUseCompatibleCommands: every built-in cmdlet and parameter used must exist on
         Windows 10 / Server 2019 with PowerShell 5.1 and with PowerShell 7
       - PSUseCompatibleTypes   : .NET types and members used must exist on those platforms
       - the default error/warning rules (minus a few that do not fit a GUI toolkit)

    Usage:  pwsh -File Tests\Invoke-StaticAnalysis.ps1     (needs PSScriptAnalyzer 1.21+)
    Exit code = number of errors.
#>
param(
    [string]$Root = (Split-Path -Path $PSScriptRoot -Parent),
    [switch]$IncludeInformation
)

$ErrorActionPreference = 'Stop'
Import-Module PSScriptAnalyzer -MinimumVersion 1.21.0

$files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Include *.ps1, *.psm1 |
    Where-Object { $_.FullName -notmatch '[\\/](Libraries|Modules|Runtimes)[\\/]' })
Write-Host "Checking $($files.Count) PowerShell files under $Root" -ForegroundColor Cyan

$results = [System.Collections.Generic.List[object]]::new()

# 1. Real parser
foreach ($f in $files) {
    $tokens = $null; $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    foreach ($e in $errors) {
        $results.Add([pscustomobject]@{ File = $f.FullName.Substring($Root.Length + 1); Line = $e.Extent.StartLineNumber; Severity = 'ParseError'; Rule = 'Parser'; Message = $e.Message })
    }
}

# 2. PSScriptAnalyzer
$profiles = @(
    'win-8_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework',   # Server 2019, Windows PowerShell 5.1
    'win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework',  # Windows 10 1809, Windows PowerShell 5.1
    'win-8_x64_10.0.17763.0_7.0.0_x64_3.1.2_core'                            # Server 2019, PowerShell 7
)
$settings = @{
    Rules        = @{
        PSUseCompatibleSyntax   = @{ Enable = $true; TargetVersions = @('5.1', '7.0') }
        PSUseCompatibleCommands = @{ Enable = $true; TargetProfiles = $profiles }
        PSUseCompatibleTypes    = @{ Enable = $true; TargetProfiles = $profiles }
    }
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',                          # colored status lines are the point
        'PSUseShouldProcessForStateChangingFunctions',    # internal helper functions
        'PSAvoidUsingPlainTextForPassword',               # inputs named *Password that are not secrets
        'PSAvoidUsingConvertToSecureStringWithPlainText', # generated passwords
        'PSUseSingularNouns',
        'PSAvoidGlobalVars',                              # the worker session shares state on purpose
        'PSUseBOMForUnicodeEncodedFile',
        'PSReviewUnusedParameter',
        'PSAvoidUsingPositionalParameters',
        'PSUseDeclaredVarsMoreThanAssignments',
        'PSAvoidUsingEmptyCatchBlock',
        'PSUseOutputTypeCorrectly',
        'PSAvoidUsingInvokeExpression',
        'PSUseApprovedVerbs'
    )
}
$i = 0
foreach ($f in $files) {
    $i++
    Write-Progress -Activity 'PSScriptAnalyzer' -Status $f.Name -PercentComplete ([int](100 * $i / $files.Count))
    foreach ($d in @(Invoke-ScriptAnalyzer -Path $f.FullName -Settings $settings)) {
        if (-not $IncludeInformation -and [string]$d.Severity -eq 'Information') { continue }
        $results.Add([pscustomobject]@{ File = $f.FullName.Substring($Root.Length + 1); Line = $d.Line; Severity = [string]$d.Severity; Rule = $d.RuleName; Message = $d.Message })
    }
}
Write-Progress -Activity 'PSScriptAnalyzer' -Completed

$results | Sort-Object Severity, File, Line | Format-Table Severity, File, Line, Rule, Message -AutoSize -Wrap | Out-String -Width 250 | Write-Host
$errorCount = @($results | Where-Object { $_.Severity -in @('ParseError', 'Error') }).Count
$warnCount = @($results | Where-Object { $_.Severity -eq 'Warning' }).Count
Write-Host "$errorCount error(s), $warnCount warning(s)" -ForegroundColor $(if ($errorCount) { 'Red' } elseif ($warnCount) { 'Yellow' } else { 'Green' })
exit $errorCount
