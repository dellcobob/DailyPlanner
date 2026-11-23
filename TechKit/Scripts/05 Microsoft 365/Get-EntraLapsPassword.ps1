# @Name:        LAPS Password (Entra ID / Intune)
# @Description: Reads the local administrator password that Windows LAPS backed up to Entra ID for a cloud-joined or hybrid device, with the backup date. Needs the "Cloud Device Administrator" or "Intune Administrator" role (or a custom role with LAPS read).
# @Admin:       No
# @Changes:     No
# @Target:      M365
# @Connect:     Graph
# @Scopes:      DeviceLocalCredential.Read.All, Device.Read.All
# @Modules:     Microsoft.Graph.Authentication
# @Tags:        laps, entra, intune, local admin, password, device

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Device name (one per line for several)')]
    [string[]]$Device,

    [Parameter(HelpMessage = 'Show older backed-up passwords too')]
    [switch]$IncludeHistory
)

if (-not (Get-MgContext)) { throw 'Not connected to Microsoft Graph. Click the Microsoft 365 button in Tech Kit first.' }
# This API requires client name/version headers for auditing
$headers = @{ 'ocp-client-name' = 'TechKit'; 'ocp-client-version' = '1.0' }

foreach ($raw in $Device) {
    $name = $raw.Trim()
    if (-not $name) { continue }
    try {
        $esc = $name -replace "'", "''"
        $list = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/directory/deviceLocalCredentials?`$filter=deviceName eq '$esc'" -Headers $headers -ErrorAction Stop
        $items = @($list.value)
        if (-not $items.Count) { Write-Host "$name : no LAPS backup in Entra ID (not configured, or the device name is different)." -ForegroundColor Yellow; continue }
        foreach ($it in $items) {
            $detail = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/directory/deviceLocalCredentials/$($it.id)?`$select=credentials" -Headers $headers -ErrorAction Stop
            $creds = @($detail.credentials | Sort-Object { [datetime]$_.backupDateTime } -Descending)
            if (-not $IncludeHistory) { $creds = @($creds | Select-Object -First 1) }
            foreach ($c in $creds) {
                $pwd = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$c.passwordBase64))
                [pscustomobject]@{
                    Device     = $it.deviceName
                    Account    = $c.accountName
                    Password   = $pwd
                    BackedUp   = $c.backupDateTime
                    Rotates    = $it.refreshDateTime
                    DeviceId   = $it.id
                }
            }
        }
    } catch {
        $m = $_.Exception.Message
        if ($m -match '403|Forbidden') { Write-Host "$name : access denied. You need DeviceLocalCredential.Read.All and a role that can read LAPS passwords." -ForegroundColor Red }
        else { Write-Host "$name : $m" -ForegroundColor Red }
    }
}
Write-Host 'Passwords are shown in the output. Clear the output and do not leave exports lying around.' -ForegroundColor Yellow
