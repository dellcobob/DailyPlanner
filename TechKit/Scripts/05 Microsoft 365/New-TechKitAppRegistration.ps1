# @Name:        Create App Registration for Tech Kit
# @Description: Creates an Entra app registration so you can sign in to a client tenant without prompts next time: Graph application permissions with admin consent, a self-signed certificate (saved as a .pfx in Certs), optional client secret, Exchange Online and other admin roles, and a saved Tech Kit tenant profile. Run once per tenant as a Global Admin.
# @Admin:       No
# @Changes:     Yes
# @Target:      M365
# @Connect:     Graph
# @Scopes:      Application.ReadWrite.All, AppRoleAssignment.ReadWrite.All, RoleManagement.ReadWrite.Directory, Organization.Read.All
# @Modules:     Microsoft.Graph.Applications, Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.Identity.Governance
# @Tags:        entra, app registration, certificate, service principal, automation, setup

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Name = 'Tech Kit',

    [Parameter(HelpMessage = 'Microsoft Graph application permissions, one per line')]
    [string[]]$GraphPermissions = @('User.ReadWrite.All', 'Group.ReadWrite.All', 'GroupMember.ReadWrite.All', 'Directory.Read.All', 'Organization.Read.All',
        'AuditLog.Read.All', 'Reports.Read.All', 'UserAuthenticationMethod.Read.All', 'Policy.Read.All', 'DeviceManagementManagedDevices.Read.All',
        'DeviceLocalCredential.Read.All', 'Mail.Send'),

    [Parameter(HelpMessage = 'Add Exchange Online app access (Exchange.ManageAsApp + Exchange Administrator role)')]
    [bool]$AddExchange = $true,

    [Parameter(HelpMessage = 'Extra Entra roles for the app, one per line (for example Teams Administrator, SharePoint Administrator)')]
    [string[]]$EntraRoles = @(),

    [Parameter(HelpMessage = 'Create a self-signed certificate and upload it (recommended)')]
    [bool]$AddCertificate = $true,

    [Parameter(HelpMessage = 'Password for the exported .pfx file (needed on other PCs)')]
    [securestring]$PfxPassword,

    [ValidateSet('1', '2', '3')]
    [string]$CertificateYears = '2',

    [Parameter(HelpMessage = 'Also create a client secret (Graph only; shown once)')]
    [switch]$AddClientSecret,

    [Parameter(HelpMessage = 'Allow interactive PnP / SharePoint sign-in with this app (adds http://localhost and SharePoint delegated access)')]
    [switch]$EnableInteractiveSharePoint,

    [Parameter(HelpMessage = 'Save a Tech Kit tenant profile for this app')]
    [bool]$SaveProfile = $true
)

if (-not (Get-MgContext)) { throw 'Not connected to Microsoft Graph. Click the Microsoft 365 button in Tech Kit first.' }
if ($AddCertificate -and (-not $PfxPassword -or $PfxPassword.Length -eq 0)) { throw 'Enter a PfxPassword so the certificate can be saved to the USB.' }
if (-not (Get-Command Get-TKPath -ErrorAction SilentlyContinue)) { Import-Module (Join-Path $PSScriptRoot '..\..\Core\TechKit.Core.psm1') -DisableNameChecking }

$org = Get-MgOrganization | Select-Object -First 1
$tenantId = $org.Id
$initial = ($org.VerifiedDomains | Where-Object { $_.IsInitial } | Select-Object -First 1).Name
Write-Host "Tenant: $($org.DisplayName) ($tenantId, $initial)" -ForegroundColor Cyan

$graphAppId = '00000003-0000-0000-c000-000000000000'
$exoAppId = '00000002-0000-0ff1-ce00-000000000000'
$spoAppId = '00000003-0000-0ff1-ce00-000000000000'
$graphSp = Get-MgServicePrincipal -Filter "appId eq '$graphAppId'" -ErrorAction Stop

$access = New-Object System.Collections.Generic.List[object]
$graphRoles = New-Object System.Collections.Generic.List[object]
$graphAccess = New-Object System.Collections.Generic.List[object]
foreach ($perm in ($GraphPermissions | ForEach-Object { $_ -split '[,;\s]+' } | Where-Object { $_ } | Select-Object -Unique)) {
    $role = $graphSp.AppRoles | Where-Object { $_.Value -eq $perm -and $_.AllowedMemberTypes -contains 'Application' } | Select-Object -First 1
    if (-not $role) { Write-Host "Unknown Graph application permission '$perm', skipped." -ForegroundColor Yellow; continue }
    $graphRoles.Add($role)
    $graphAccess.Add(@{ Id = $role.Id; Type = 'Role' })
}
if ($EnableInteractiveSharePoint) {
    $userRead = $graphSp.Oauth2PermissionScopes | Where-Object { $_.Value -eq 'User.Read' } | Select-Object -First 1
    if ($userRead) { $graphAccess.Add(@{ Id = $userRead.Id; Type = 'Scope' }) }
}
$access.Add(@{ ResourceAppId = $graphAppId; ResourceAccess = $graphAccess.ToArray() })

$exoSp = $null
$exoRole = $null
if ($AddExchange) {
    $exoSp = Get-MgServicePrincipal -Filter "appId eq '$exoAppId'" -ErrorAction Stop
    $exoRole = $exoSp.AppRoles | Where-Object { $_.Value -eq 'Exchange.ManageAsApp' } | Select-Object -First 1
    if ($exoRole) { $access.Add(@{ ResourceAppId = $exoAppId; ResourceAccess = @(@{ Id = $exoRole.Id; Type = 'Role' }) }) }
    if ($EntraRoles -notcontains 'Exchange Administrator') { $EntraRoles = @($EntraRoles) + 'Exchange Administrator' }
}
$spoSp = $null
if ($EnableInteractiveSharePoint) {
    $spoSp = Get-MgServicePrincipal -Filter "appId eq '$spoAppId'" -ErrorAction SilentlyContinue
    $spoScope = $spoSp.Oauth2PermissionScopes | Where-Object { $_.Value -eq 'AllSites.FullControl' } | Select-Object -First 1
    if ($spoScope) { $access.Add(@{ ResourceAppId = $spoAppId; ResourceAccess = @(@{ Id = $spoScope.Id; Type = 'Scope' }) }) }
}

# Certificate
$cert = $null
$pfxPath = ''
if ($AddCertificate -and $PSCmdlet.ShouldProcess('Cert:\CurrentUser\My', "Create self-signed certificate CN=$Name ($initial)")) {
    $subject = "CN=$Name ($initial)"
    $years = [int]$CertificateYears
    $certDir = Get-TKPath Certs
    if (-not (Test-Path -LiteralPath $certDir)) { $null = New-Item -ItemType Directory -Path $certDir -Force }
    $pfxPath = Join-Path $certDir ("{0}-{1}.pfx" -f ($initial -replace '\.onmicrosoft\.com$', ''), ($Name -replace '[^\w]', ''))
    try {
        # .NET certificate request: works the same in Windows PowerShell 5.1 (.NET 4.7.2+) and PowerShell 7
        $rsa = [System.Security.Cryptography.RSA]::Create(2048)
        $req = New-Object System.Security.Cryptography.X509Certificates.CertificateRequest($subject, $rsa, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $temp = $req.CreateSelfSigned([DateTimeOffset]::Now.AddDays(-1), [DateTimeOffset]::Now.AddYears($years))
        $bytes = $temp.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $PfxPassword)
        [IO.File]::WriteAllBytes($pfxPath, $bytes)
        $flags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]'UserKeySet, PersistKeySet, Exportable'
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($bytes, $PfxPassword, $flags)
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('My', 'CurrentUser')
        $store.Open('ReadWrite')
        $store.Add($cert)
        $store.Close()
    } catch {
        Write-Host "Using New-SelfSignedCertificate instead ($($_.Exception.Message))" -ForegroundColor DarkGray
        $cert = New-SelfSignedCertificate -Subject $subject -CertStoreLocation 'Cert:\CurrentUser\My' -KeyExportPolicy Exportable -KeySpec Signature -KeyLength 2048 -KeyAlgorithm RSA -HashAlgorithm SHA256 -NotAfter (Get-Date).AddYears($years)
        $null = Export-PfxCertificate -Cert ("Cert:\CurrentUser\My\" + $cert.Thumbprint) -FilePath $pfxPath -Password $PfxPassword
    }
    Write-Host "Certificate $($cert.Thumbprint) saved to $pfxPath and to your certificate store (expires $($cert.NotAfter.ToString('yyyy-MM-dd')))." -ForegroundColor Green
}

$appParams = @{
    DisplayName            = $Name
    SignInAudience         = 'AzureADMyOrg'
    RequiredResourceAccess = $access.ToArray()
    Notes                  = "Created by Tech Kit on $(Get-Date -Format 'yyyy-MM-dd') by $((Get-MgContext).Account)"
}
if ($cert) { $appParams.KeyCredentials = @(@{ Type = 'AsymmetricX509Cert'; Usage = 'Verify'; Key = $cert.RawData; DisplayName = $cert.Subject }) }
if ($EnableInteractiveSharePoint) {
    $appParams.PublicClient = @{ RedirectUris = @('http://localhost') }
    $appParams.IsFallbackPublicClient = $true
}

if (-not $PSCmdlet.ShouldProcess($Name, 'Create app registration, service principal, consent and role assignments')) {
    Write-Host "Would create '$Name' with $($graphRoles.Count) Graph permission(s)$(if ($AddExchange) { ', Exchange.ManageAsApp' }) and roles: $($EntraRoles -join ', ')" -ForegroundColor Cyan
    return
}

$app = New-MgApplication @appParams -ErrorAction Stop
Write-Host "App registration created: $($app.DisplayName) (client ID $($app.AppId))" -ForegroundColor Green
Start-Sleep -Seconds 5
$sp = New-MgServicePrincipal -AppId $app.AppId -ErrorAction Stop
Start-Sleep -Seconds 5

$results = New-Object System.Collections.Generic.List[object]
foreach ($r in $graphRoles) {
    try {
        $null = New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -PrincipalId $sp.Id -ResourceId $graphSp.Id -AppRoleId $r.Id -ErrorAction Stop
        $results.Add([pscustomobject]@{ Item = "Graph $($r.Value)"; Result = 'Consented' })
    } catch { $results.Add([pscustomobject]@{ Item = "Graph $($r.Value)"; Result = "FAIL: $($_.Exception.Message)" }) }
}
if ($exoRole) {
    try {
        $null = New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -PrincipalId $sp.Id -ResourceId $exoSp.Id -AppRoleId $exoRole.Id -ErrorAction Stop
        $results.Add([pscustomobject]@{ Item = 'Exchange.ManageAsApp'; Result = 'Consented' })
    } catch { $results.Add([pscustomobject]@{ Item = 'Exchange.ManageAsApp'; Result = "FAIL: $($_.Exception.Message)" }) }
}
foreach ($roleName in ($EntraRoles | Where-Object { $_ } | Select-Object -Unique)) {
    try {
        $esc = $roleName -replace "'", "''"
        $def = Get-MgRoleManagementDirectoryRoleDefinition -Filter "displayName eq '$esc'" -ErrorAction Stop | Select-Object -First 1
        if (-not $def) { throw 'role not found' }
        $null = New-MgRoleManagementDirectoryRoleAssignment -PrincipalId $sp.Id -RoleDefinitionId $def.Id -DirectoryScopeId '/' -ErrorAction Stop
        $results.Add([pscustomobject]@{ Item = "Entra role $roleName"; Result = 'Assigned' })
    } catch { $results.Add([pscustomobject]@{ Item = "Entra role $roleName"; Result = "FAIL: $($_.Exception.Message)" }) }
}

$secretText = $null
$secretEnd = $null
if ($AddClientSecret) {
    $sec = Add-MgApplicationPassword -ApplicationId $app.Id -PasswordCredential @{ DisplayName = 'Tech Kit'; EndDateTime = (Get-Date).AddYears(1) } -ErrorAction Stop
    $secretText = $sec.SecretText
    $secretEnd = $sec.EndDateTime
    Write-Host "Client secret (shown once, expires $secretEnd): $secretText" -ForegroundColor Yellow
}

if ($SaveProfile) {
    $profiles = @(Get-TKTenantProfiles | Where-Object { $_.Name -ne $org.DisplayName })
    $profiles += [pscustomobject]@{
        Name = $org.DisplayName; TenantId = $tenantId; ClientId = $app.AppId; Thumbprint = $(if ($cert) { $cert.Thumbprint } else { '' })
        PfxPath = $pfxPath; Organization = $initial; UserPrincipalName = ''; Method = $(if ($cert) { 'Certificate' } else { 'Secret' })
        Services = $(if ($AddExchange) { 'Graph,Exchange' } else { 'Graph' }); Scopes = ''; SharePointUrl = ''
    }
    Save-TKTenantProfiles -Profiles $profiles
    $results.Add([pscustomobject]@{ Item = 'Tech Kit tenant profile'; Result = "Saved as '$($org.DisplayName)'" })
}

foreach ($r in $results) { Write-Host ("  {0,-40} {1}" -f $r.Item, $r.Result) -ForegroundColor $(if ($r.Result -like 'FAIL*') { 'Red' } else { 'Green' }) }
Write-Host 'Role assignments can take up to 30 minutes to work for Exchange. On another PC, use the saved profile with the .pfx file and its password.' -ForegroundColor Cyan
[pscustomobject]@{
    Tenant       = $org.DisplayName
    TenantId     = $tenantId
    Organization = $initial
    App          = $app.DisplayName
    ClientId     = $app.AppId
    Thumbprint   = $(if ($cert) { $cert.Thumbprint } else { '' })
    PfxFile      = $pfxPath
    CertExpires  = $(if ($cert) { $cert.NotAfter } else { $null })
    SecretExpires = $secretEnd
}
$results
