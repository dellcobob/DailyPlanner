<#
    Tech Kit elevated runner.
    Started by the GUI with "Run as administrator" (UAC) when a script needs admin
    rights and the GUI itself is not elevated. Runs one script, streams its output
    to a JSON-lines file that the GUI reads live, and saves the result objects so
    they can be exported.
#>
param(
    [Parameter(Mandatory = $true)][string]$JobFile
)

$ErrorActionPreference = 'Stop'
$outFile = $null

function Write-RunnerLine {
    param([string]$Kind, [string]$Text)
    if (-not $outFile) { return }
    $line = (@{ Kind = $Kind; Text = $Text; Color = -1; NewLine = $true; Percent = -1; Activity = $null; Completed = $false } | ConvertTo-Json -Compress)
    Add-Content -LiteralPath $outFile -Value $line -Encoding UTF8
}

try {
    $job = Import-Clixml -LiteralPath $JobFile
    $outFile = $job.OutFile
    Remove-Item -LiteralPath $JobFile -Force -ErrorAction SilentlyContinue

    Import-Module (Join-Path $PSScriptRoot 'TechKit.Core.psm1') -Force -DisableNameChecking
    Initialize-TKEnvironment
    Import-TKHostType

    # Rebuild secure values that were protected with a one-time key
    $invoke = $job.Invoke
    $params = @{}
    foreach ($k in @($invoke.Parameters.Keys)) {
        $v = $invoke.Parameters[$k]
        if ($v -is [hashtable] -and $v.ContainsKey('__tkSecure')) {
            $v = ConvertTo-SecureString -String $v.__tkSecure -Key $job.Key
        } elseif ($v -is [hashtable] -and $v.ContainsKey('__tkCredUser')) {
            $v = New-Object System.Management.Automation.PSCredential($v.__tkCredUser, (ConvertTo-SecureString -String $v.__tkCredPass -Key $job.Key))
        }
        $params[$k] = $v
    }
    $invoke.Parameters = $params
    if ($invoke.Credential -is [hashtable] -and $invoke.Credential.ContainsKey('__tkCredUser')) {
        $invoke.Credential = New-Object System.Management.Automation.PSCredential($invoke.Credential.__tkCredUser, (ConvertTo-SecureString -String $invoke.Credential.__tkCredPass -Key $job.Key))
    }

    $sink = New-Object TechKit.OutputSink
    $sink.FilePath = $outFile
    $sink.Interactive = $false
    $rs = New-TKRunspace -Sink $sink -HostName 'Tech Kit (Admin)'

    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddCommand('Invoke-TKScript').AddParameters($invoke)
    $ps.Commands.Commands[0].MergeMyResults([System.Management.Automation.Runspaces.PipelineResultTypes]::All, [System.Management.Automation.Runspaces.PipelineResultTypes]::Output)
    $null = $ps.AddCommand('Out-TKSink')

    $handle = $ps.BeginInvoke()
    $stopped = $false
    while (-not $handle.IsCompleted) {
        if ($job.StopFile -and (Test-Path -LiteralPath $job.StopFile)) {
            $stopped = $true
            $ps.Stop()
            break
        }
        Start-Sleep -Milliseconds 200
    }
    try {
        $null = $ps.EndInvoke($handle)
    } catch {
        $msg = $_.Exception.Message
        if ($_.Exception.InnerException) { $msg = $_.Exception.InnerException.Message }
        if (-not $stopped) { $sink.Add('Error', $msg) }
    }
    foreach ($e in $ps.Streams.Error) { $sink.Add('Error', $e.ToString()) }

    $results = $rs.SessionStateProxy.GetVariable('TKResults')
    if ($results -and $results.Count -gt 0 -and $job.ResultFile) {
        try {
            $results | Export-Clixml -LiteralPath $job.ResultFile -Depth 3
        } catch {
            $sink.Add('Warning', "Results could not be saved for export: $($_.Exception.Message)")
        }
    }
    $ps.Dispose()
    $rs.Close()
    if ($stopped) { $sink.Add('End', 'stopped') } else { $sink.Add('End', 'done') }
} catch {
    Write-RunnerLine -Kind 'Error' -Text ("Elevated runner failed: " + $_.Exception.Message)
    Write-RunnerLine -Kind 'End' -Text 'failed'
}
