# @Name:        Force Group Policy Update
# @Description: Runs gpupdate /force for computer and/or user policy and shows which GPOs applied. Remote runs refresh computer policy for that PC.
# @Admin:       Yes
# @Changes:     Yes
# @Target:      Local, Remote
# @Tags:        gpo, group policy, gpupdate, gpresult

[CmdletBinding()]
param(
    [ValidateSet('Both', 'Computer', 'User')]
    [string]$Scope = 'Both',

    [Parameter(HelpMessage = 'Show the applied GPO summary afterwards (gpresult /r)')]
    [bool]$ShowResult = $true
)

$gpArgs = @('/force')
if ($Scope -ne 'Both') { $gpArgs += "/target:$($Scope.ToLowerInvariant())" }
Write-Host "== gpupdate $($gpArgs -join ' ')" -ForegroundColor Cyan
& gpupdate.exe @gpArgs 2>&1 | ForEach-Object { "$_" } | Where-Object { $_.Trim() }
if ($LASTEXITCODE -eq 0) { Write-Host 'Policy refresh finished.' -ForegroundColor Green } else { Write-Host "gpupdate exit code $LASTEXITCODE" -ForegroundColor Yellow }

if ($ShowResult) {
    $grScope = 'computer'
    if ($Scope -eq 'User') { $grScope = 'user' }
    Write-Host "== Applied policy ($grScope)" -ForegroundColor Cyan
    & gpresult.exe /r /scope $grScope 2>&1 | ForEach-Object { "$_" } | Where-Object { $_.Trim() }
}
