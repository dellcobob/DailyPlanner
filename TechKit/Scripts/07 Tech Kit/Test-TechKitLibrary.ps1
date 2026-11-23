# @Name:        Check Script Library
# @Description: Self-test for Tech Kit: parses every script, checks the metadata headers, and (if PSScriptAnalyzer is available) checks that each script works on both Windows PowerShell 5.1 and PowerShell 7. Run it after adding scripts.
# @Admin:       No
# @Changes:     No
# @Target:      Local
# @Tags:        tech kit, test, lint, analyzer, maintenance

[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'Run PSScriptAnalyzer compatibility and best-practice rules')]
    [bool]$RunAnalyzer = $true,

    [Parameter(HelpMessage = 'Download PSScriptAnalyzer to the USB if it is missing')]
    [switch]$InstallAnalyzer
)

if (-not (Get-Command Get-TKScript -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\..\Core\TechKit.Core.psm1') -DisableNameChecking
}
$root = Get-TKPath Scripts
$files = @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.py', '.sh') })
Write-Host "Checking $($files.Count) script(s) in $root" -ForegroundColor Cyan

$results = New-Object System.Collections.Generic.List[object]
foreach ($f in $files) {
    $rel = $f.FullName.Substring($root.Length).TrimStart('\', '/')
    $h = Read-TKHeader -Path $f.FullName
    foreach ($k in @('Name', 'Description')) {
        if (-not $h.Meta[$k]) { $results.Add([pscustomobject]@{ Script = $rel; Severity = 'Warning'; Check = 'Header'; Line = 1; Message = "Missing # @${k}:" }) }
    }
    foreach ($k in @('Admin', 'Changes')) {
        if ($h.Meta.Contains($k) -and $h.Meta[$k] -notmatch '^(Yes|No)$') { $results.Add([pscustomobject]@{ Script = $rel; Severity = 'Warning'; Check = 'Header'; Line = 1; Message = "@$k should be Yes or No" }) }
    }
    if ($f.Extension -ne '.ps1') { continue }
    $info = Get-TKPsParameters -Path $f.FullName
    foreach ($e in $info.Errors) { $results.Add([pscustomobject]@{ Script = $rel; Severity = 'Error'; Check = 'Syntax'; Line = 0; Message = $e }) }
    if ((ConvertTo-TKBool $h.Meta['Changes']) -and -not $info.SupportsWhatIf) {
        $results.Add([pscustomobject]@{ Script = $rel; Severity = 'Information'; Check = 'What-If'; Line = 1; Message = 'Makes changes but does not support What-If (add SupportsShouldProcess)' })
    }
}

if ($RunAnalyzer) {
    $pssa = Get-Module -ListAvailable -Name PSScriptAnalyzer | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $pssa -and $InstallAnalyzer) {
        Install-TKModule -Name PSScriptAnalyzer -Destination USB
        $pssa = Get-Module -ListAvailable -Name PSScriptAnalyzer | Select-Object -First 1
    }
    if (-not $pssa) {
        Write-Host 'PSScriptAnalyzer is not installed. Tick InstallAnalyzer to download it to the USB.' -ForegroundColor Yellow
    } else {
        Import-Module PSScriptAnalyzer -ErrorAction Stop
        $settings = @{
            Rules = @{
                PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1', '7.0') }
            }
            ExcludeRules = @('PSAvoidUsingWriteHost', 'PSUseShouldProcessForStateChangingFunctions', 'PSAvoidUsingPlainTextForPassword',
                'PSAvoidUsingConvertToSecureStringWithPlainText', 'PSUseSingularNouns', 'PSAvoidGlobalVars', 'PSUseDeclaredVarsMoreThanAssignments',
                'PSReviewUnusedParameter', 'PSAvoidUsingPositionalParameters', 'PSUseBOMForUnicodeEncodedFile')
        }
        $ps1 = @($files | Where-Object { $_.Extension -eq '.ps1' })
        $i = 0
        foreach ($f in $ps1) {
            $i++
            Write-Progress -Activity 'PSScriptAnalyzer' -Status $f.Name -PercentComplete ([int](100 * $i / $ps1.Count))
            $rel = $f.FullName.Substring($root.Length).TrimStart('\', '/')
            foreach ($d in @(Invoke-ScriptAnalyzer -Path $f.FullName -Settings $settings -ErrorAction SilentlyContinue)) {
                $results.Add([pscustomobject]@{ Script = $rel; Severity = [string]$d.Severity; Check = $d.RuleName; Line = $d.Line; Message = $d.Message })
            }
        }
        Write-Progress -Activity 'PSScriptAnalyzer' -Completed
    }
}

$errors = @($results | Where-Object { $_.Severity -eq 'Error' -or $_.Severity -eq 'ParseError' }).Count
$warnings = @($results | Where-Object { $_.Severity -eq 'Warning' }).Count
if ($errors) { Write-Host "$errors error(s), $warnings warning(s). Fix the errors first." -ForegroundColor Red }
elseif ($warnings) { Write-Host "No errors, $warnings warning(s)." -ForegroundColor Yellow }
else { Write-Host 'All scripts passed.' -ForegroundColor Green }
$results | Sort-Object Severity, Script, Line
