# @Name:        Repair Windows (DISM + SFC)
# @Description: Runs DISM to repair the Windows component store, then System File Checker. Scan only checks without repairing. Can take 10-30 minutes.
# @Admin:       Yes
# @Changes:     Yes
# @Target:      Local, Remote
# @Tags:        repair, dism, sfc, corruption, fix

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Repair', 'ScanOnly')]
    [string]$Mode = 'Repair',

    [Parameter(HelpMessage = 'Skip DISM and only run SFC')]
    [switch]$SfcOnly
)

function Invoke-Native {
    # Streams the tool's output live and records the lines and exit code.
    param([string]$Exe, [string[]]$Arguments, [switch]$Unicode)
    $script:NativeLines = New-Object System.Collections.Generic.List[string]
    $old = $null
    if ($Unicode) {
        try { $old = [Console]::OutputEncoding; [Console]::OutputEncoding = [System.Text.Encoding]::Unicode } catch { }
    }
    try {
        & $Exe @Arguments 2>&1 | ForEach-Object { ("$_" -replace "`0", '').TrimEnd() } |
            Where-Object { $_ -and $_ -notmatch '^\s*\[=*\s*[\d.]+%' -and $_ -notmatch '^\s*Verification\s+\d+% complete' } |
            ForEach-Object { $script:NativeLines.Add($_); Write-Host "   $_" }
    } finally {
        if ($old) { try { [Console]::OutputEncoding = $old } catch { } }
    }
    $script:NativeCode = $LASTEXITCODE
}

$results = @()
if (-not $SfcOnly) {
    $dismArgs = @('/Online', '/Cleanup-Image', '/RestoreHealth')
    if ($Mode -eq 'ScanOnly') { $dismArgs = @('/Online', '/Cleanup-Image', '/ScanHealth') }
    if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, "DISM $($dismArgs -join ' ')")) {
        Write-Host "== DISM $($dismArgs -join ' ')  (this can take a while)" -ForegroundColor Cyan
        Invoke-Native -Exe 'dism.exe' -Arguments $dismArgs
        $code = $script:NativeCode
        $ok = ($code -eq 0)
        if ($ok) { Write-Host 'DISM finished without errors.' -ForegroundColor Green } else { Write-Host "DISM exit code $code" -ForegroundColor Red }
        $results += [pscustomobject]@{ Computer = $env:COMPUTERNAME; Tool = 'DISM'; Mode = $Mode; ExitCode = $code; Result = $(if ($ok) { 'OK' } else { 'FAIL' }) }
    }
}

$sfcArg = '/scannow'
if ($Mode -eq 'ScanOnly') { $sfcArg = '/verifyonly' }
if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, "sfc $sfcArg")) {
    Write-Host "== sfc $sfcArg" -ForegroundColor Cyan
    Invoke-Native -Exe 'sfc.exe' -Arguments @($sfcArg) -Unicode
    $code = $script:NativeCode
    $text = ($script:NativeLines -join "`n")
    $summary = 'See C:\Windows\Logs\CBS\CBS.log'
    if ($text -match 'did not find any integrity violations') { $summary = 'No integrity violations' }
    elseif ($text -match 'found corrupt files and successfully repaired') { $summary = 'Corrupt files repaired' }
    elseif ($text -match 'found corrupt files but was unable to fix') { $summary = 'Corrupt files NOT repaired' }
    $color = 'Yellow'
    if ($summary -eq 'No integrity violations' -or $summary -eq 'Corrupt files repaired') { $color = 'Green' }
    Write-Host "SFC: $summary" -ForegroundColor $color
    $results += [pscustomobject]@{ Computer = $env:COMPUTERNAME; Tool = 'SFC'; Mode = $Mode; ExitCode = $code; Result = $summary }
}
$results
