# @Name:        Find Tenant ID
# @Description: Looks up a Microsoft 365 tenant from any of its domains without signing in: tenant ID, region, whether sign-in is cloud (managed) or federated (ADFS / third-party IdP), and the brand name. Handy before connecting to a new client.
# @Admin:       No
# @Changes:     No
# @Target:      Local
# @Tags:        m365, tenant id, domain, federation, entra, discovery

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Domain names or e-mail addresses, one per line')]
    [string[]]$Domain
)

try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

foreach ($raw in $Domain) {
    $d = ($raw.Trim() -replace '^.*@', '').ToLowerInvariant()
    if (-not $d) { continue }
    $row = [ordered]@{ Domain = $d; TenantId = ''; Region = ''; SignIn = ''; Brand = ''; FederationUrl = ''; Note = '' }
    try {
        $oidc = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$d/v2.0/.well-known/openid-configuration" -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
        if ($oidc.issuer -match '/([0-9a-f\-]{36})/') { $row.TenantId = $Matches[1] }
        $row.Region = [string]$oidc.tenant_region_scope
        if ($oidc.cloud_instance_name -and $oidc.cloud_instance_name -ne 'microsoftonline.com') { $row.Note = "Cloud: $($oidc.cloud_instance_name)" }
    } catch {
        $row.Note = 'No Microsoft 365 tenant found for this domain'
    }
    if ($row.TenantId) {
        try {
            $realm = Invoke-RestMethod -Uri "https://login.microsoftonline.com/getuserrealm.srf?login=user@$d&json=1" -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
            $row.SignIn = [string]$realm.NameSpaceType
            $row.Brand = [string]$realm.FederationBrandName
            if ($realm.AuthURL) { $row.FederationUrl = [string]$realm.AuthURL }
        } catch { }
    }
    $color = $(if ($row.TenantId) { 'Green' } else { 'Yellow' })
    Write-Host ("{0}: {1} {2}" -f $d, $(if ($row.TenantId) { $row.TenantId } else { 'not found' }), $(if ($row.SignIn -eq 'Federated') { '(federated sign-in)' } else { '' })) -ForegroundColor $color
    [pscustomobject]$row
}
