<#
    Tech Kit engine tests. Runs on Windows PowerShell 5.1, PowerShell 7 on Windows,
    and PowerShell 7 on Linux/macOS (no WPF needed). Works on a temporary copy of the
    kit, so your settings, audit log and tenant profiles are never touched.

    Usage:  pwsh -File Tests\Test-Engine.ps1 [-LibraryPath <folder of third-party scripts>]
    Exit code = number of failed tests.
#>
param(
    [string]$Root = (Split-Path -Path $PSScriptRoot -Parent),
    [string]$LibraryPath = $env:TK_TEST_LIBRARY
)

$ErrorActionPreference = 'Stop'
$script:Pass = 0
$script:Fail = 0
$script:Failures = [System.Collections.Generic.List[string]]::new()

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:Pass++
        Write-Host "  PASS  $Name" -ForegroundColor Green
    } catch {
        $script:Fail++
        $script:Failures.Add("$Name : $($_.Exception.Message)")
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        Write-Host "        $($_.Exception.Message)" -ForegroundColor Red
        if ($_.InvocationInfo) { Write-Host "        at line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())" -ForegroundColor DarkGray }
    }
}
function Assert-True { param($Condition, [string]$Message = '') if (-not $Condition) { throw "Expected true. $Message" } }
function Assert-Equal { param($Expected, $Actual, [string]$Message = '') if ($Expected -ne $Actual) { throw "Expected '$Expected' but got '$Actual'. $Message" } }
function Assert-Match { param([string]$Text, [string]$Pattern, [string]$Message = '') if ($Text -notmatch $Pattern) { throw "Expected text to match /$Pattern/. $Message`nText: $Text" } }

# ---------------------------------------------------------------------------
#  Work on a copy of the kit
# ---------------------------------------------------------------------------
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('techkit-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $tmp
foreach ($item in @('Core', 'Config', 'Scripts', 'Templates')) {
    Copy-Item -LiteralPath (Join-Path $Root $item) -Destination (Join-Path $tmp $item) -Recurse
}
foreach ($f in @('settings.json', 'tenants.json', 'saved-values.json', '.unblocked')) {
    $p = Join-Path $tmp "Config/$f"
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
}
if ($LibraryPath -and (Test-Path -LiteralPath $LibraryPath)) {
    $null = New-Item -ItemType Directory -Path (Join-Path $tmp 'Libraries') -Force
    Copy-Item -LiteralPath $LibraryPath -Destination (Join-Path $tmp 'Libraries/TestLibrary') -Recurse
}
$work = Join-Path $tmp 'work'
$null = New-Item -ItemType Directory -Path $work

Write-Host "Testing Tech Kit engine on PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)), copy at $tmp" -ForegroundColor Cyan
Import-Module (Join-Path $tmp 'Core/TechKit.Core.psm1') -Force -DisableNameChecking

# ---------------------------------------------------------------------------
Write-Host "`nLibrary and metadata" -ForegroundColor Cyan
# ---------------------------------------------------------------------------
$all = @(Get-TKScript -WarningAction SilentlyContinue)
$builtIn = @($all | Where-Object { -not $_.IsLibrary })

Test-Case 'every built-in script loads with a name, description and no syntax errors' {
    $files = @(Get-ChildItem -LiteralPath (Join-Path $tmp 'Scripts') -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.py', '.sh') })
    Assert-Equal $files.Count $builtIn.Count 'scripts discovered'
    foreach ($s in $builtIn) {
        Assert-True $s.Name "name for $($s.Id)"
        Assert-True $s.Description "description for $($s.Id)"
        Assert-Equal 0 @($s.ParseErrors).Count "parse errors in $($s.Id): $($s.ParseErrors -join '; ')"
    }
}

Test-Case 'script names are unique' {
    $dupes = @($builtIn | Group-Object Name | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    Assert-Equal 0 $dupes.Count ($dupes -join ', ')
}

Test-Case 'param() blocks become the right input kinds' {
    $ports = $builtIn | Where-Object { $_.FileName -eq 'Test-Ports.ps1' }
    $hosts = $ports.Params | Where-Object { $_.Name -eq 'Hosts' }
    Assert-Equal 'List' $hosts.Kind 'Hosts kind'
    Assert-True $hosts.Mandatory 'Hosts mandatory'
    Assert-True ($hosts.Help -like 'Host names*') 'Hosts help text'
    $dns = $builtIn | Where-Object { $_.FileName -eq 'Resolve-DnsRecords.ps1' }
    $type = $dns.Params | Where-Object { $_.Name -eq 'Type' }
    Assert-Equal 'Choice' $type.Kind
    Assert-True (@($type.Choices) -contains 'MX') 'ValidateSet values'
    Assert-Equal 'Common' $type.Default
    $net = $builtIn | Where-Object { $_.FileName -eq 'Reset-NetworkStack.ps1' }
    Assert-Equal 'Bool' ($net.Params | Where-Object { $_.Name -eq 'FlushDns' }).Kind
    Assert-Equal $true ($net.Params | Where-Object { $_.Name -eq 'FlushDns' }).Default
    $reset = $builtIn | Where-Object { $_.FileName -eq 'Reset-ADUserPassword.ps1' }
    Assert-Equal 'Secure' ($reset.Params | Where-Object { $_.Name -eq 'NewPassword' }).Kind
    Assert-True $reset.WhatIf 'SupportsShouldProcess detected'
    $temp = $builtIn | Where-Object { $_.FileName -eq 'Clear-TempFiles.ps1' }
    Assert-Equal 'Switch' ($temp.Params | Where-Object { $_.Name -eq 'BrowserCaches' }).Kind
    Assert-True ($temp.Badges -contains 'ADMIN' -and $temp.Badges -contains 'CHANGES' -and $temp.Badges -contains 'REMOTE') 'badges'
}

Test-Case 'Python and Bash @Param lines are parsed' {
    $py = $builtIn | Where-Object { $_.FileName -eq 'tls-certificate-check.py' }
    $h = $py.Params | Where-Object { $_.Name -eq 'Hosts' }
    Assert-Equal 'List' $h.Kind
    Assert-True $h.Mandatory
    Assert-Equal '30' ($py.Params | Where-Object { $_.Name -eq 'WarnDays' }).Default
    $sh = $builtIn | Where-Object { $_.FileName -eq 'linux-health-check.sh' }
    Assert-True ($sh.Targets -notcontains 'Local' -and $sh.SupportsRemote) 'remote only'
}

Test-Case '@Choices resolve from Config files' {
    $files = @(Resolve-TKChoices -Spec 'files:Identity\*.json')
    Assert-True ($files -contains 'Example') ($files -join ',')
    $depts = @(Resolve-TKChoices -Spec 'jsonkeys:Identity\*.json:Departments')
    Assert-Equal 'Sales,Finance,IT' ($depts -join ',')
    Assert-Equal 'a,b c' ((Resolve-TKChoices -Spec 'list:a, b c') -join ',')
    $on = $builtIn | Where-Object { $_.FileName -eq 'New-ADUserOnboarding.ps1' }
    Assert-Equal 'files:Identity\*.json' $on.Choices['RulesProfile']
}

Test-Case 'header write / split round trip keeps metadata, choices and body' {
    $path = Join-Path $work 'roundtrip.ps1'
    $meta = [ordered]@{ Name = 'Round Trip'; Description = 'Test'; Admin = 'No'; Changes = 'Yes'; Target = 'Local, Remote' }
    $body = "param([string]`$Site)`r`nWrite-Output `$Site"
    Set-TKScriptContent -Path $path -Meta $meta -Body $body -Choices ([ordered]@{ Site = 'list:A, B' })
    $h = Read-TKHeader -Path $path
    Assert-Equal 'Round Trip' $h.Meta['Name']
    Assert-Equal 'list:A, B' $h.Choices['Site']
    $parts = Split-TKScriptFile -Path $path
    Assert-Equal $body $parts.Body
    $bytes = [IO.File]::ReadAllBytes($path)
    Assert-True ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) '.ps1 saved with UTF-8 BOM for Windows PowerShell 5.1'
}

if ($LibraryPath) {
    Test-Case 'third-party library scripts load (names, descriptions, inferred flags)' {
        $lib = @($all | Where-Object { $_.IsLibrary })
        Assert-True ($lib.Count -gt 0) 'library scripts found'
        $noName = @($lib | Where-Object { -not $_.Name })
        Assert-Equal 0 $noName.Count
        $withDesc = @($lib | Where-Object { $_.Description }).Count
        Write-Host ("        {0} library scripts, {1} with a description, {2} flagged as making changes, {3} with parse errors" -f $lib.Count, $withDesc, @($lib | Where-Object { $_.Changes }).Count, @($lib | Where-Object { $_.ParseErrors.Count }).Count) -ForegroundColor DarkGray
        Assert-True (($lib | Select-Object -First 1).Badges -contains 'LIB') 'LIB badge'
    }
}

# ---------------------------------------------------------------------------
Write-Host "`nSettings, roles, audit" -ForegroundColor Cyan
# ---------------------------------------------------------------------------
Test-Case 'settings save and load' {
    $s = Get-TKSettings
    Assert-Equal 'Midnight' $s.ThemeName
    Assert-True ($s.Colors.Accent -match '^#[0-9A-F]{6}$') 'theme colors filled in'
    $s.FontSize = 15
    $s.Favorites = @('a.ps1', 'b.ps1')
    Save-TKSettings -Settings $s
    $s2 = Get-TKSettings
    Assert-Equal 15 $s2.FontSize
    Assert-Equal 'a.ps1,b.ps1' ($s2.Favorites -join ',')
    Assert-Equal $true $s2.AuditChanges
}

Test-Case 'roles filter scripts as configured' {
    $r = Get-TKRoles
    Assert-True $r.Roles.Contains('Helpdesk')
    $help = $r.Roles['Helpdesk']
    $auditor = $r.Roles['Read-only auditor']
    $admin = $r.Roles['Administrator']
    $disk = $builtIn | Where-Object { $_.FileName -eq 'Get-DiskSpace.ps1' }
    $offboard = $builtIn | Where-Object { $_.FileName -eq 'Start-M365UserOffboarding.ps1' }
    $unlock = $builtIn | Where-Object { $_.FileName -eq 'Unlock-ADUserAccount.ps1' }
    $temp = $builtIn | Where-Object { $_.FileName -eq 'Clear-TempFiles.ps1' }
    Assert-True (Test-TKRoleAllows $help $disk) 'helpdesk sees Helpdesk\*'
    Assert-True (Test-TKRoleAllows $help $unlock) 'helpdesk sees Unlock AD Account'
    Assert-True (-not (Test-TKRoleAllows $help $offboard)) 'helpdesk denied offboarding'
    Assert-True (-not (Test-TKRoleAllows $auditor $temp)) 'auditor cannot see change scripts'
    Assert-True (Test-TKRoleAllows $auditor $disk) 'auditor sees read-only scripts'
    Assert-True (Test-TKRoleAllows $admin $offboard) 'admin sees everything'
    Assert-Equal $true (Get-TKRoleValue $help 'RequireTicket' $false)
    Assert-Equal $false (Get-TKRoleValue $help 'AllowTerminal' $true)
}

Test-Case 'audit log appends rows with a stable header' {
    for ($i = 1; $i -le 2; $i++) {
        Write-TKAudit -Entry ([ordered]@{ Time = "2026-01-0$i 10:00:00"; Operator = 'T\tester'; Script = "S$i"; Result = 'Done' })
    }
    $rows = @(Import-Csv -LiteralPath (Join-Path $tmp 'Logs/audit.csv'))
    Assert-Equal 2 $rows.Count
    Assert-Equal 'S2' $rows[1].Script
}

Test-Case 'identity rules load as nested hashtables' {
    $rules = Get-TKIdentityRules -Name 'Example'
    Assert-Equal 'example.com' $rules.Domain
    Assert-Equal 'Sales Representative' $rules.Departments['Sales'].Title
    Assert-True (@($rules.Departments['Sales'].ADGroups) -contains 'CRM Users')
}

# ---------------------------------------------------------------------------
Write-Host "`nBackground session (custom host)" -ForegroundColor Cyan
# ---------------------------------------------------------------------------
Import-TKHostType
$script:Sink = New-Object TechKit.OutputSink
$script:Worker = New-TKRunspace -Sink $script:Sink -HostName 'Tech Kit test'

function Invoke-InWorker {
    param([string]$Script, [object[]]$Arguments = @(), [switch]$GlobalScope, [scriptblock]$OnPrompt, [int]$TimeoutSec = 60, [switch]$NoCollect, [scriptblock]$WhileRunning)
    $ps = [PowerShell]::Create()
    $ps.Runspace = $script:Worker
    $null = $ps.AddScript($Script, (-not $GlobalScope))
    foreach ($a in $Arguments) { $null = $ps.AddArgument($a) }
    $ps.Commands.Commands[0].MergeMyResults([System.Management.Automation.Runspaces.PipelineResultTypes]::All, [System.Management.Automation.Runspaces.PipelineResultTypes]::Output)
    $null = $ps.AddCommand('Out-TKSink')
    if ($NoCollect) { $null = $ps.AddParameter('NoCollect', $true) }
    $items = [System.Collections.Generic.List[object]]::new()
    $handle = $ps.BeginInvoke()
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $ranHook = $false
    while (-not $handle.IsCompleted) {
        $pr = $script:Sink.PendingPrompt
        if ($pr -and -not $pr.Taken) {
            $pr.Taken = $true
            if ($OnPrompt) { & $OnPrompt $pr } else { $pr.Cancelled = $true }
            $null = $pr.Done.Set()
        }
        foreach ($i in $script:Sink.Drain(1000)) { $items.Add($i) }
        if ($WhileRunning -and -not $ranHook) { $ranHook = [bool](& $WhileRunning $ps $items) }
        if ((Get-Date) -gt $deadline) { $ps.Stop(); throw "Timed out after $TimeoutSec s" }
        Start-Sleep -Milliseconds 40
    }
    $err = $null
    try { $null = $ps.EndInvoke($handle) } catch { $err = $_.Exception; while ($err.InnerException -and $err -is [System.Management.Automation.MethodInvocationException]) { $err = $err.InnerException } }
    foreach ($i in $script:Sink.Drain(100000)) { $items.Add($i) }
    $state = [string]$ps.InvocationStateInfo.State
    $ps.Dispose()
    [pscustomobject]@{ Items = $items.ToArray(); Error = $err; State = $state; Text = (($items | ForEach-Object { $_.Text }) -join "`n") }
}

function New-TestScript {
    param([string]$Name, [string]$Code)
    $p = Join-Path $work $Name
    Set-Content -LiteralPath $p -Value $Code -Encoding UTF8
    $p
}

Test-Case 'output, Write-Host colors, warnings, errors and verbose reach the sink' {
    $p = New-TestScript 'streams.ps1' @'
[CmdletBinding()] param()
Write-Host 'green line' -ForegroundColor Green
Write-Host 'plain line'
Write-Warning 'careful'
Write-Error 'something broke'
Write-Verbose 'detail' -Verbose
[pscustomobject]@{ Name = 'alpha'; Value = 1 }
[pscustomobject]@{ Name = 'beta'; Value = 2 }
'@
    $r = Invoke-InWorker -Script 'param($a) Invoke-TKScript @a' -Arguments @(@{ Path = $p })
    Assert-True (-not $r.Error) "no terminating error: $($r.Error)"
    $green = $r.Items | Where-Object { $_.Text -eq 'green line' }
    Assert-Equal 'Host' $green.Kind
    Assert-Equal ([int][ConsoleColor]::Green) $green.Color 'Write-Host color kept'
    Assert-True (@($r.Items | Where-Object { $_.Kind -eq 'Warning' -and $_.Text -eq 'WARNING: careful' }).Count -eq 1) 'warning once'
    Assert-True (@($r.Items | Where-Object { $_.Kind -eq 'Error' -and $_.Text -like '*something broke*' }).Count -eq 1) 'error once'
    Assert-True (@($r.Items | Where-Object { $_.Kind -eq 'Verbose' -and $_.Text -like 'VERBOSE: detail' }).Count -eq 1) 'verbose'
    $out = ($r.Items | Where-Object { $_.Kind -eq 'Output' } | ForEach-Object { $_.Text }) -join "`n"
    Assert-Match $out 'Name\s+Value' 'objects formatted as one table'
    Assert-Match $out 'alpha\s+1'
    Assert-Equal 1 ([regex]::Matches($out, 'Name\s+Value')).Count 'single table header'
    $results = $script:Worker.SessionStateProxy.GetVariable('TKResults')
    Assert-Equal 2 $results.Count 'objects kept for export'
}

Test-Case 'Write-Host is not shown twice (host + information stream)' {
    $p = New-TestScript 'once.ps1' "Write-Host 'only once' -ForegroundColor Cyan"
    $r = Invoke-InWorker -Script 'param($a) Invoke-TKScript @a' -Arguments @(@{ Path = $p })
    Assert-Equal 1 @($r.Items | Where-Object { $_.Text -eq 'only once' }).Count
}

Test-Case 'parameters are passed by name, including switches and arrays' {
    $p = New-TestScript 'params.ps1' @'
param([string]$Name, [int]$Count, [switch]$Loud, [string[]]$Items, [bool]$Flag = $true)
"name=$Name count=$Count loud=$Loud items=$($Items -join '+') flag=$Flag"
'@
    $r = Invoke-InWorker -Script 'param($a) Invoke-TKScript @a' -Arguments @(@{ Path = $p; Parameters = @{ Name = 'x'; Count = '3'; Loud = $true; Items = [string[]]@('a', 'b'); Flag = $false } })
    Assert-Match $r.Text 'name=x count=3 loud=True items=a\+b flag=False'
}

Test-Case 'What-If messages are captured and nothing is changed' {
    $target = Join-Path $work 'should-not-exist.txt'
    $p = New-TestScript 'whatif.ps1' @"
[CmdletBinding(SupportsShouldProcess = `$true)] param()
if (`$PSCmdlet.ShouldProcess('$target', 'Create file')) { Set-Content -LiteralPath '$target' -Value 'x' }
"@
    $r = Invoke-InWorker -Script 'param($a) Invoke-TKScript @a' -Arguments @(@{ Path = $p; DryRun = $true })
    Assert-Match $r.Text 'What if: Performing the operation "Create file"'
    Assert-True (-not (Test-Path -LiteralPath $target)) 'file not created'
    $r2 = Invoke-InWorker -Script 'param($a) Invoke-TKScript @a' -Arguments @(@{ Path = $p; DryRun = $false })
    Assert-True (Test-Path -LiteralPath $target) 'file created on a real run'
}

Test-Case 'Read-Host prompts are answered through the GUI hook' {
    $p = New-TestScript 'readhost.ps1' '$n = Read-Host "Your name"; "hello $n"'
    $r = Invoke-InWorker -Script 'param($a) Invoke-TKScript @a' -Arguments @(@{ Path = $p }) -OnPrompt { param($pr) Assert-Equal 'ReadLine' $pr.Type; $pr.Response = 'Sam' }
    Assert-Match $r.Text 'hello Sam'
}

Test-Case 'Get-Credential prompt returns a PSCredential' {
    $p = New-TestScript 'cred.ps1' '$c = Get-Credential -UserName "corp\admin" -Message "Sign in"; "user=$($c.UserName) len=$($c.GetNetworkCredential().Password.Length)"'
    $r = Invoke-InWorker -Script 'param($a) Invoke-TKScript @a' -Arguments @(@{ Path = $p }) -OnPrompt {
        param($pr)
        Assert-Equal 'Credential' $pr.Type
        $pr.Response = New-Object System.Management.Automation.PSCredential('corp\admin', (ConvertTo-SecureString 'Secret123' -AsPlainText -Force))
    }
    Assert-Match $r.Text 'user=corp\\admin len=9'
}

Test-Case 'a choice prompt returns the picked index' {
    $p = New-TestScript 'choice.ps1' @'
$c = [System.Collections.ObjectModel.Collection[System.Management.Automation.Host.ChoiceDescription]]::new()
$c.Add((New-Object System.Management.Automation.Host.ChoiceDescription('&One', 'first')))
$c.Add((New-Object System.Management.Automation.Host.ChoiceDescription('&Two', 'second')))
$i = $Host.UI.PromptForChoice('Pick', 'Which?', $c, 0)
"picked=$i"
'@
    $r = Invoke-InWorker -Script 'param($a) Invoke-TKScript @a' -Arguments @(@{ Path = $p }) -OnPrompt { param($pr) Assert-Equal '&One,&Two' ($pr.Choices -join ','); $pr.Response = 1 }
    Assert-Match $r.Text 'picked=1'
}

Test-Case 'a cancelled choice stops the script instead of picking the default (ShouldContinue safety)' {
    $marker = Join-Path $work 'continued.txt'
    $p = New-TestScript 'shouldcontinue.ps1' @"
[CmdletBinding()] param()
if (`$PSCmdlet.ShouldContinue('Delete everything?', 'Confirm')) { Set-Content -LiteralPath '$marker' -Value 'x' }
"@
    $r = Invoke-InWorker -Script 'param($a) Invoke-TKScript @a' -Arguments @(@{ Path = $p })
    Assert-True (-not (Test-Path -LiteralPath $marker)) 'did not continue'
    Assert-True (@($r.Items | Where-Object { $_.Kind -eq 'Error' }).Count -ge 1) 'reported as an error'
}

Test-Case 'a terminating error is reported and buffered table output is still flushed' {
    $p = New-TestScript 'throws.ps1' @'
[pscustomobject]@{ Col = 'before' }
throw 'boom'
'@
    $r = Invoke-InWorker -Script 'param($a) Invoke-TKScript @a' -Arguments @(@{ Path = $p })
    Assert-Match $r.Text 'before' 'output before the throw'
    Assert-True (@($r.Items | Where-Object { $_.Kind -eq 'Error' -and $_.Text -match 'boom' }).Count -eq 1) 'error shown'
    Assert-True (@($r.Items | Where-Object { $_.Kind -eq 'Verbose' -and $_.Text -match 'at line 2' }).Count -eq 1) 'line number shown'
}

Test-Case 'progress and Clear-Host become status items' {
    $p = New-TestScript 'progress.ps1' "Write-Progress -Activity 'Scanning' -Status 'half' -PercentComplete 50; Clear-Host; Write-Progress -Activity 'Scanning' -Completed"
    $r = Invoke-InWorker -Script 'param($a) Invoke-TKScript @a' -Arguments @(@{ Path = $p })
    $prog = @($r.Items | Where-Object { $_.Kind -eq 'Progress' })
    Assert-True ($prog.Count -ge 1) 'progress item'
    Assert-Equal 50 $prog[0].Percent
    # PowerShell 7 on Linux/macOS clears by running /usr/bin/clear instead of going through the host
    if ([IO.Path]::DirectorySeparatorChar -eq '\') { Assert-True (@($r.Items | Where-Object { $_.Kind -eq 'Clear' }).Count -ge 1) 'clear item' }
}

Test-Case 'terminal commands keep variables between runs (global scope)' {
    $null = Invoke-InWorker -Script '$tkTestVar = 41' -GlobalScope -NoCollect
    $r = Invoke-InWorker -Script '$tkTestVar + 1' -GlobalScope -NoCollect
    Assert-Match $r.Text '^42$'
}

Test-Case 'Stop interrupts a long-running script' {
    $p = New-TestScript 'long.ps1' 'Write-Host "started"; Start-Sleep -Seconds 60; Write-Host "never"'
    $r = Invoke-InWorker -Script 'param($a) Invoke-TKScript @a' -Arguments @(@{ Path = $p }) -TimeoutSec 30 -WhileRunning {
        param($ps, $items)
        if (@($items | Where-Object { $_.Text -eq 'started' }).Count) { $null = $ps.BeginStop($null, $null); return $true }
        $false
    }
    Assert-Equal 'Stopped' $r.State
    Assert-True ($r.Text -notmatch 'never')
}

Test-Case 'CSV and HTML export of the last results' {
    $p = New-TestScript 'export.ps1' "[pscustomobject]@{ Check = 'SMBv1'; Result = 'PASS'; Items = @('a','b') }; [pscustomobject]@{ Check = 'LLMNR'; Result = 'FAIL'; Items = @() }"
    $null = Invoke-InWorker -Script 'param($a) Invoke-TKScript @a' -Arguments @(@{ Path = $p })
    $ps = [PowerShell]::Create(); $ps.Runspace = $script:Worker
    $csv = [string]($ps.AddScript("Export-TKResult -Format Csv -Title 'Unit Test' -Folder '$work'").Invoke()[0]); $ps.Dispose()
    $rows = @(Import-Csv -LiteralPath $csv)
    Assert-Equal 2 $rows.Count
    Assert-Equal 'a; b' $rows[0].Items 'arrays flattened'
    $ps = [PowerShell]::Create(); $ps.Runspace = $script:Worker
    $html = [string]($ps.AddScript("Export-TKResult -Format Html -Title 'Unit <Test>' -Subtitle 'sub' -OutputText 'raw & text' -Folder '$work'").Invoke()[0]); $ps.Dispose()
    $text = Get-Content -LiteralPath $html -Raw
    Assert-Match $text '<td class="good">PASS</td>'
    Assert-Match $text '<td class="bad">FAIL</td>'
    Assert-Match $text 'Unit &lt;Test&gt;' 'title HTML-encoded'
    Assert-Match $text 'raw &amp; text' 'output text encoded'
}

Test-Case 'Connect-MgGraph / Connect-ExchangeOnline wrappers exist in the session' {
    $ps = [PowerShell]::Create(); $ps.Runspace = $script:Worker
    $types = @($ps.AddScript("(Get-Command Connect-MgGraph).CommandType; (Get-Command Connect-ExchangeOnline).CommandType").Invoke() | ForEach-Object { [string]$_ })
    $ps.Dispose()
    Assert-Equal 'Function,Function' ($types -join ',')
}

Test-Case 'TECHKIT_ROOT points at the kit' {
    Assert-Equal $tmp $env:TECHKIT_ROOT
}

$py = Find-TKInterpreter -Name python
if ($py) {
    Test-Case 'Python scripts get --Name value arguments and --whatif' {
        $p = Join-Path $work 'args.py'
        Set-Content -LiteralPath $p -Value "import sys`nprint('args=' + ' '.join(sys.argv[1:]))`nprint('oops', file=sys.stderr)" -Encoding UTF8
        $r = Invoke-InWorker -Script 'param($a) Invoke-TKScript @a' -Arguments @(@{ Path = $p; Arguments = [string[]]@('--Host', 'a b', '--Verbose'); DryRun = $true })
        Assert-Match $r.Text 'args=--Host a b --Verbose --whatif'
        Assert-True (@($r.Items | Where-Object { $_.Kind -eq 'Error' -and $_.Text -match 'oops' }).Count -eq 1) 'stderr shown as error'
    }
}
$bash = Find-TKInterpreter -Name bash
if ($bash) {
    Test-Case 'Bash scripts receive arguments through stdin streaming' {
        $p = Join-Path $work 'args.sh'
        [IO.File]::WriteAllText($p, "#!/usr/bin/env bash`r`necho ""count=`$# first=`$1 second=`$2""`r`n")
        $r = Invoke-InWorker -Script 'param($a) Invoke-TKScript @a' -Arguments @(@{ Path = $p; Arguments = [string[]]@('--Path', '/var/log') })
        Assert-Match $r.Text 'count=2 first=--Path second=/var/log' 'CRLF line endings handled'
        Assert-True (@($r.Items | Where-Object { $_.Kind -eq 'Error' }).Count -eq 0) "no errors: $($r.Text)"
    }
}

# ---------------------------------------------------------------------------
Write-Host "`nElevated runner (run directly, without UAC)" -ForegroundColor Cyan
# ---------------------------------------------------------------------------
Test-Case 'job file round trip: secure inputs, streamed output, results file, End marker' {
    $p = New-TestScript 'elevated.ps1' @'
param([securestring]$Secret, [string]$Plain)
Write-Host "secret length $((New-Object System.Net.NetworkCredential('', $Secret)).Password.Length)" -ForegroundColor Green
[pscustomobject]@{ Plain = $Plain }
'@
    $dir = Join-Path $work 'job'
    $null = New-Item -ItemType Directory -Path $dir
    $key = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($key)
    $sec = ConvertTo-SecureString 'abcdef' -AsPlainText -Force
    $job = @{
        Invoke = @{ Path = $p; Parameters = @{ Secret = @{ __tkSecure = (ConvertFrom-SecureString -SecureString $sec -Key $key) }; Plain = 'hi' }; Arguments = @(); ComputerName = @(); DryRun = $false }
        OutFile = (Join-Path $dir 'out.jsonl'); ResultFile = (Join-Path $dir 'results.xml'); StopFile = (Join-Path $dir 'stop'); Key = $key
    }
    $jobFile = Join-Path $dir 'job.xml'
    Export-Clixml -InputObject $job -LiteralPath $jobFile
    [IO.File]::WriteAllText($job.OutFile, '')
    $exe = (Get-Process -Id $PID).Path
    if ((Split-Path -Path $exe -Leaf) -match '^dotnet') { $exe = (Get-Command pwsh).Source }   # pwsh installed as a .NET tool
    & $exe -NoProfile -File (Join-Path $tmp 'Core/ElevatedRunner.ps1') -JobFile $jobFile
    $lines = @(Get-Content -LiteralPath $job.OutFile | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True (@($lines | Where-Object { $_.Text -eq 'secret length 6' -and $_.Color -eq 10 }).Count -eq 1) "decrypted secure input. Got: $(($lines | ForEach-Object { $_.Kind + ':' + $_.Text }) -join ' | ')"
    Assert-Equal 'End' $lines[-1].Kind
    Assert-Equal 'done' $lines[-1].Text
    Assert-True (-not (Test-Path -LiteralPath $jobFile)) 'job file deleted after reading'
    $res = @(Import-Clixml -LiteralPath $job.ResultFile)
    Assert-Equal 'hi' $res[0].Plain
}

# ---------------------------------------------------------------------------
Write-Host "`nGUI wiring (static, no WPF needed)" -ForegroundColor Cyan
# ---------------------------------------------------------------------------
$guiText = Get-Content -LiteralPath (Join-Path $Root 'TechKit.ps1') -Raw
$xamlNames = @{}
foreach ($x in Get-ChildItem -LiteralPath (Join-Path $Root 'Core/Gui') -Filter '*.xaml') {
    $xamlNames[$x.BaseName] = @([regex]::Matches((Get-Content -LiteralPath $x.FullName -Raw), 'x:Name="(\w+)"') | ForEach-Object { $_.Groups[1].Value })
}

Test-Case 'every $ui.<Control> used in TechKit.ps1 exists in MainWindow.xaml' {
    $used = @([regex]::Matches($guiText, '\$ui\.(\w+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    $missing = @($used | Where-Object { $_ -ne 'Window' -and $xamlNames['MainWindow'] -notcontains $_ })
    Assert-Equal 0 $missing.Count ($missing -join ', ')
}

Test-Case 'every dialog control used exists in some dialog XAML' {
    $dialogs = @($xamlNames.Keys | Where-Object { $_ -ne 'MainWindow' -and $_ -ne 'Theme' } | ForEach-Object { $xamlNames[$_] })
    $nonControls = @('Window', 'Result', 'Themes', 'Colors', 'Boxes', 'Existing', 'Shebang', 'SavedId', 'RoleConfig', 'Contains', 'Keys', 'Count')
    $used = @([regex]::Matches($guiText, '\$(?:d|dd|D)\.([A-Z]\w+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    $missing = @($used | Where-Object { $nonControls -notcontains $_ -and $dialogs -notcontains $_ })
    Assert-Equal 0 $missing.Count ($missing -join ', ')
}

Test-Case 'every resource key used in XAML and code is defined in Theme.xaml' {
    $theme = Get-Content -LiteralPath (Join-Path $Root 'Core/Gui/Theme.xaml') -Raw
    $defined = @([regex]::Matches($theme, 'x:Key="(\w+)"') | ForEach-Object { $_.Groups[1].Value })
    $used = [System.Collections.Generic.List[string]]::new()
    foreach ($x in Get-ChildItem -LiteralPath (Join-Path $Root 'Core/Gui') -Filter '*.xaml') {
        foreach ($m in [regex]::Matches((Get-Content -LiteralPath $x.FullName -Raw), '\{(?:Dynamic|Static)Resource (\w+)\}')) { $used.Add($m.Groups[1].Value) }
    }
    foreach ($m in [regex]::Matches($guiText, "Set-TKResourceRef [^\n]*'(\w+)'")) { $used.Add($m.Groups[1].Value) }
    foreach ($m in [regex]::Matches($guiText, "TryFindResource\('(\w+)'\)")) { $used.Add($m.Groups[1].Value) }
    $missing = @($used | Select-Object -Unique | Where-Object { $defined -notcontains $_ })
    Assert-Equal 0 $missing.Count ($missing -join ', ')
}

Test-Case 'every Tech Kit function called in the GUI is defined' {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($guiText, [ref]$tokens, [ref]$errors)
    $defined = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
    $defined += @((Get-Module TechKit.Core).ExportedFunctions.Keys)
    $called = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -match '-TK' } | Select-Object -Unique)
    $missing = @($called | Where-Object { $defined -notcontains $_ })
    Assert-Equal 0 $missing.Count ($missing -join ', ')
}

Test-Case 'every Tech Kit function called inside the core module and scripts is defined' {
    $defined = @((Get-Module TechKit.Core).ExportedFunctions.Keys)
    $files = @(Get-ChildItem -LiteralPath (Join-Path $Root 'Scripts') -Recurse -Filter '*.ps1') + @(Get-Item (Join-Path $Root 'Core/TechKit.Core.psm1'), (Join-Path $Root 'Core/ElevatedRunner.ps1'), (Join-Path $Root 'Core/TerminalProfile.ps1'))
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $files) {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
        $local = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
        foreach ($c in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -match '-TK' } | Select-Object -Unique)) {
            if ($defined -notcontains $c -and $local -notcontains $c) { $missing.Add("$($f.Name): $c") }
        }
    }
    Assert-Equal 0 $missing.Count ($missing -join ', ')
}

# ---------------------------------------------------------------------------
$script:Worker.Close()
$script:Worker.Dispose()
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host "$script:Pass passed, $script:Fail failed" -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
foreach ($f in $script:Failures) { Write-Host "  - $f" -ForegroundColor Red }
exit $script:Fail
