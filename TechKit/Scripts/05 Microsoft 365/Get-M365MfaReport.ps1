# @Name:        MFA Registration Report
# @Description: Shows which users have registered MFA, their default method and whether they are admins. Uses the Entra registration report, or checks each user if that report is not licensed.
# @Admin:       No
# @Changes:     No
# @Target:      M365
# @Connect:     Graph
# @Scopes:      AuditLog.Read.All, UserAuthenticationMethod.Read.All, User.Read.All
# @Modules:     Microsoft.Graph.Reports, Microsoft.Graph.Identity.SignIns, Microsoft.Graph.Users
# @Tags:        m365, mfa, security, report, entra

[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'Only list users without MFA')]
    [switch]$OnlyWithoutMfa,

    [Parameter(HelpMessage = 'Limit for the per-user fallback check')]
    [int]$MaxUsers = 500
)

if (-not (Get-MgContext)) { throw 'Not connected to Microsoft Graph. Click the Microsoft 365 button in Tech Kit first.' }

$rows = @()
try {
    $rows = @(Get-MgReportAuthenticationMethodUserRegistrationDetail -All -ErrorAction Stop | ForEach-Object {
        [pscustomobject]@{
            DisplayName   = $_.UserDisplayName
            UPN           = $_.UserPrincipalName
            MfaRegistered = [bool]$_.IsMfaRegistered
            MfaCapable    = [bool]$_.IsMfaCapable
            Passwordless  = [bool]$_.IsPasswordlessCapable
            SSPR          = [bool]$_.IsSsprRegistered
            DefaultMethod = $_.DefaultMfaMethod
            Methods       = (@($_.MethodsRegistered) -join ', ')
            IsAdmin       = [bool]$_.IsAdmin
            Type          = $_.UserType
        }
    })
    Write-Host 'Source: Entra authentication methods registration report.' -ForegroundColor DarkGray
} catch {
    Write-Host "Registration report not available ($($_.Exception.Message)). Checking users one by one (max $MaxUsers)..." -ForegroundColor Yellow
    $users = @(Get-MgUser -All -Filter "userType eq 'Member' and accountEnabled eq true" -Property 'id,displayName,userPrincipalName' | Select-Object -First $MaxUsers)
    $i = 0
    $rows = foreach ($u in $users) {
        $i++
        Write-Progress -Activity 'Checking MFA methods' -Status $u.UserPrincipalName -PercentComplete ([int](100 * $i / [Math]::Max(1, $users.Count)))
        $m = @()
        try { $m = @(Get-MgUserAuthenticationMethod -UserId $u.Id -ErrorAction Stop | ForEach-Object { ([string]$_.AdditionalProperties['@odata.type']) -replace '#microsoft.graph.', '' -replace 'AuthenticationMethod$', '' }) } catch { }
        $strong = @($m | Where-Object { $_ -notin @('password', 'email') })
        [pscustomobject]@{
            DisplayName = $u.DisplayName; UPN = $u.UserPrincipalName; MfaRegistered = ($strong.Count -gt 0); MfaCapable = ($strong.Count -gt 0)
            Passwordless = (@($strong | Where-Object { $_ -match 'fido2|windowsHello|passkey' }).Count -gt 0); SSPR = $null
            DefaultMethod = ''; Methods = ($m -join ', '); IsAdmin = $null; Type = 'member'
        }
    }
    Write-Progress -Activity 'Checking MFA methods' -Completed
    $rows = @($rows)
}

$members = @($rows | Where-Object { $_.Type -ne 'guest' })
$without = @($members | Where-Object { -not $_.MfaRegistered })
$adminsWithout = @($without | Where-Object { $_.IsAdmin })
$pct = 0
if ($members.Count) { $pct = [Math]::Round(100 * ($members.Count - $without.Count) / $members.Count) }
Write-Host "$pct% of $($members.Count) members have MFA registered. $($without.Count) without." -ForegroundColor $(if ($without.Count) { 'Yellow' } else { 'Green' })
if ($adminsWithout.Count) { Write-Host "ADMINS WITHOUT MFA: $(($adminsWithout | ForEach-Object { $_.UPN }) -join ', ')" -ForegroundColor Red }

if ($OnlyWithoutMfa) { $rows = $without }
$rows | Sort-Object MfaRegistered, DisplayName
