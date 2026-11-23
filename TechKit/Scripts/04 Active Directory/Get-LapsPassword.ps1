# @Name:        LAPS Password (Active Directory)
# @Description: Reads the local administrator password that LAPS stored in Active Directory for a computer: Windows LAPS (including encrypted passwords) or legacy Microsoft LAPS. Shows when it expires. You need LAPS read rights on the computer's OU.
# @Admin:       No
# @Changes:     No
# @Target:      Local, Remote
# @Tags:        laps, local admin, password, ad, computer

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Computer name (one per line for several)')]
    [string[]]$Computer,

    [Parameter(HelpMessage = 'Also show previous passwords (Windows LAPS history)')]
    [switch]$IncludeHistory
)

foreach ($c in $Computer) {
    $name = $c.Trim()
    if (-not $name) { continue }
    $done = $false
    if (Get-Command Get-LapsADPassword -ErrorAction SilentlyContinue) {
        try {
            $p = @{ Identity = $name; AsPlainText = $true; ErrorAction = 'Stop' }
            if ($IncludeHistory) { $p.IncludeHistory = $true }
            $res = @(Get-LapsADPassword @p)
            foreach ($r in $res) {
                if (-not $r.Password -and -not $r.Account) { continue }
                $done = $true
                [pscustomobject]@{
                    Computer = $r.ComputerName
                    Account  = $r.Account
                    Password = $r.Password
                    Updated  = $r.PasswordUpdateTime
                    Expires  = $r.ExpirationTimestamp
                    Source   = "Windows LAPS ($($r.Source))"
                }
            }
        } catch {
            Write-Host "$name : Windows LAPS lookup failed ($($_.Exception.Message)). Trying legacy LAPS..." -ForegroundColor DarkGray
        }
    }
    if ($done) { continue }

    # Legacy Microsoft LAPS (ms-Mcs-AdmPwd), read with plain LDAP
    try {
        $esc = $name -replace '[^\w\-\.]', ''
        $searcher = New-Object System.DirectoryServices.DirectorySearcher("(&(objectCategory=computer)(|(name=$esc)(dNSHostName=$esc)))")
        foreach ($prop in @('name', 'ms-mcs-admpwd', 'ms-mcs-admpwdexpirationtime', 'mslaps-passwordexpirationtime')) { $null = $searcher.PropertiesToLoad.Add($prop) }
        $hit = $searcher.FindOne()
        if (-not $hit) { Write-Host "$name : not found in Active Directory." -ForegroundColor Red; continue }
        $pwd = [string]($hit.Properties['ms-mcs-admpwd'] | Select-Object -First 1)
        $exp = $hit.Properties['ms-mcs-admpwdexpirationtime'] | Select-Object -First 1
        if (-not $pwd) {
            $winExp = $hit.Properties['mslaps-passwordexpirationtime'] | Select-Object -First 1
            if ($winExp) { Write-Host "$name : uses Windows LAPS but the password could not be read (rights, or the LAPS PowerShell module is missing on this PC; try targeting a DC)." -ForegroundColor Yellow }
            else { Write-Host "$name : no LAPS password in AD (LAPS not applied, or you lack read rights)." -ForegroundColor Yellow }
            continue
        }
        [pscustomobject]@{
            Computer = [string]($hit.Properties['name'] | Select-Object -First 1)
            Account  = '(local admin)'
            Password = $pwd
            Updated  = $null
            Expires  = $(if ($exp) { [datetime]::FromFileTime([int64]$exp) } else { $null })
            Source   = 'Legacy Microsoft LAPS'
        }
    } catch {
        Write-Host "$name : $($_.Exception.Message)" -ForegroundColor Red
    }
}
Write-Host 'Passwords are shown in the output. Clear the output and do not leave exports lying around.' -ForegroundColor Yellow
