#  Tech Kit core module.
#  Loaded by the GUI, by the background worker runspace, by the elevated runner
#  and by the pop-out console. Must stay compatible with Windows PowerShell 5.1
#  and PowerShell 7 (no ternary, no ??, no ForEach-Object -Parallel).

Set-StrictMode -Off

$script:TKRoot = Split-Path -Path $PSScriptRoot -Parent
$script:MetaOrder = @('Name', 'Description', 'Admin', 'Changes', 'Target', 'Connect', 'Scopes', 'Modules', 'Shell', 'OS', 'Tags', 'Author', 'Version')

# ----------------------------------------------------------------------------
#  Paths and environment
# ----------------------------------------------------------------------------

function Get-TKRoot {
    $script:TKRoot
}

function Get-TKPath {
    param([ValidateSet('Scripts', 'Modules', 'Config', 'Reports', 'Runtimes', 'Templates', 'Certs', 'Core', 'Gui', 'Libraries', 'Logs')][string]$Name)
    switch ($Name) {
        'Gui' { Join-Path $script:TKRoot 'Core\Gui' }
        default { Join-Path $script:TKRoot $Name }
    }
}

function Initialize-TKEnvironment {
    # Scripts can find the kit (Config, Reports...) through this variable.
    $env:TECHKIT_ROOT = $script:TKRoot
    # Put the USB Modules folder first so modules carried on the drive win.
    $mods = Get-TKPath Modules
    if (-not (Test-Path -LiteralPath $mods)) { $null = New-Item -ItemType Directory -Path $mods -Force -ErrorAction SilentlyContinue }
    $sep = [IO.Path]::PathSeparator
    $parts = @($env:PSModulePath -split [regex]::Escape([string]$sep) | Where-Object { $_ })
    if ($parts -notcontains $mods) {
        $env:PSModulePath = (@($mods) + $parts) -join $sep
    }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }
}

function Import-TKHostType {
    if (-not ('TechKit.OutputSink' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'TechKit.Host.cs') -ErrorAction Stop
    }
}

function Test-TKAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        $false
    }
}

function Test-TKLocalName {
    param([string]$Name)
    $n = $Name.Trim().ToLowerInvariant()
    if ($n -in @('', '.', 'localhost', '127.0.0.1', '::1')) { return $true }
    $me = ([string]$env:COMPUTERNAME).ToLowerInvariant()
    if (-not $me) { $me = [Environment]::MachineName.ToLowerInvariant() }
    if ($n -eq $me) { return $true }
    if ($n.StartsWith($me + '.')) { return $true }
    $false
}

function Get-TKShellInfo {
    $current = (Get-Process -Id $PID).Path
    $pwsh = $null
    $candidates = @(
        (Join-Path $script:TKRoot 'Runtimes\pwsh\pwsh.exe'),
        (Join-TKPathSafe $env:ProgramFiles 'PowerShell\7\pwsh.exe')
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath $c)) { $pwsh = $c; break } }
    if (-not $pwsh) {
        $cmd = Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { $pwsh = $cmd.Source }
    }
    $winps = Join-TKPathSafe $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if ($winps -and -not (Test-Path -LiteralPath $winps)) { $winps = $null }
    [pscustomobject]@{
        Current        = $current
        Edition        = $PSVersionTable.PSEdition
        Version        = $PSVersionTable.PSVersion.ToString()
        Pwsh           = $pwsh
        WindowsPS      = $winps
        WindowsTerminal = (Get-Command wt.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
    }
}

function Unblock-TKFiles {
    # Files copied out of a downloaded zip are marked as "from the internet",
    # which stops .NET from loading module DLLs. Clear that mark once.
    param([switch]$Force)
    $marker = Join-Path (Get-TKPath Config) '.unblocked'
    $modules = Get-TKPath Modules
    $needed = $Force -or -not (Test-Path -LiteralPath $marker)
    if (-not $needed -and (Test-Path -LiteralPath $modules)) {
        $stamp = (Get-Item -LiteralPath $marker).LastWriteTime
        $newer = Get-ChildItem -LiteralPath $modules -Directory -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $stamp } | Select-Object -First 1
        if ($newer) { $needed = $true }
    }
    if (-not $needed) { return }
    if (-not (Get-Command Unblock-File -ErrorAction SilentlyContinue)) { return }
    Write-Host 'Preparing Tech Kit files (one-time unblock)...' -ForegroundColor DarkGray
    Get-ChildItem -LiteralPath $script:TKRoot -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
    try { Set-Content -LiteralPath $marker -Value (Get-Date -Format o) -ErrorAction Stop } catch { }
}

# ----------------------------------------------------------------------------
#  Settings and themes
# ----------------------------------------------------------------------------

function ConvertTo-TKHashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = [ordered]@{}
        foreach ($k in $InputObject.Keys) { $h[$k] = ConvertTo-TKHashtable $InputObject[$k] }
        return $h
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-TKHashtable $p.Value }
        return $h
    }
    if ($InputObject -is [array]) {
        return , @($InputObject | ForEach-Object { ConvertTo-TKHashtable $_ })
    }
    $InputObject
}

function Get-TKThemeKeys {
    @('Background', 'Panel', 'Card', 'Border', 'Text', 'SubText', 'Accent', 'AccentText',
      'OutputBackground', 'Output', 'Info', 'Success', 'Warning', 'Error', 'Verbose', 'Command')
}

function Get-TKThemes {
    $file = Join-Path (Get-TKPath Config) 'themes.json'
    $themes = [ordered]@{}
    if (Test-Path -LiteralPath $file) {
        try {
            $json = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $json.PSObject.Properties) { $themes[$p.Name] = ConvertTo-TKHashtable $p.Value }
        } catch {
            Write-Warning "themes.json could not be read: $($_.Exception.Message)"
        }
    }
    if ($themes.Count -eq 0) {
        $themes['Midnight'] = [ordered]@{
            Background = '#1B1D23'; Panel = '#15171C'; Card = '#23262E'; Border = '#343844'
            Text = '#E4E6EB'; SubText = '#9AA1AE'; Accent = '#4F9DFF'; AccentText = '#0B0D12'
            OutputBackground = '#0F1115'; Output = '#D7DAE0'; Info = '#5CC8E8'; Success = '#6BD28A'
            Warning = '#F2C35B'; Error = '#FF6B6B'; Verbose = '#7C8494'; Command = '#B794F6'
        }
    }
    $themes
}

function Get-TKDefaultSettings {
    [ordered]@{
        ThemeName          = 'Midnight'
        Colors             = $null
        FontFamily         = 'Cascadia Mono'
        FontSize           = 13
        PreferredShell     = 'Auto'
        UseWindowsTerminal = $true
        WordWrap           = $false
        OutputWidth        = 220
        ReportFolder       = ''
        Favorites          = @()
        DefaultScopes      = ''
        LastTenantProfile  = ''
        ConfirmChanges     = $true
        AuditChanges       = $true
        ActiveRole         = 'Administrator'
        RolePinHash        = ''
    }
}

function Get-TKSettings {
    $settings = Get-TKDefaultSettings
    $file = Join-Path (Get-TKPath Config) 'settings.json'
    if (Test-Path -LiteralPath $file) {
        try {
            $json = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $json.PSObject.Properties) { $settings[$p.Name] = ConvertTo-TKHashtable $p.Value }
        } catch {
            Write-Warning "settings.json could not be read, using defaults: $($_.Exception.Message)"
        }
    }
    $themes = Get-TKThemes
    $base = $themes[$settings.ThemeName]
    if (-not $base) { $base = $themes[@($themes.Keys)[0]] }
    if (-not $settings.Colors) { $settings.Colors = [ordered]@{} }
    foreach ($k in Get-TKThemeKeys) {
        if (-not $settings.Colors[$k]) { $settings.Colors[$k] = $base[$k] }
    }
    $settings.Favorites = @($settings.Favorites | Where-Object { $_ })
    $settings
}

function Save-TKSettings {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings)
    $file = Join-Path (Get-TKPath Config) 'settings.json'
    $Settings | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $file -Encoding UTF8 -ErrorAction Stop
}

function Get-TKTenantProfiles {
    $file = Join-Path (Get-TKPath Config) 'tenants.json'
    if (-not (Test-Path -LiteralPath $file)) { return @() }
    try {
        @(Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch { @() }
}

function Save-TKTenantProfiles {
    param([object[]]$Profiles)
    $file = Join-Path (Get-TKPath Config) 'tenants.json'
    ConvertTo-Json -InputObject @($Profiles) -Depth 4 | Set-Content -LiteralPath $file -Encoding UTF8
}

# ----------------------------------------------------------------------------
#  Script discovery and metadata
# ----------------------------------------------------------------------------

function ConvertTo-TKBool {
    param($Value)
    if ($null -eq $Value) { return $false }
    ([string]$Value).Trim() -match '^(y|yes|true|1|on)$'
}

function ConvertTo-TKList {
    param([string]$Value)
    if (-not $Value) { return @() }
    @($Value -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-TKAstValue {
    param($Ast)
    if ($null -eq $Ast) { return $null }
    if ($Ast -is [System.Management.Automation.Language.ConstantExpressionAst]) { return $Ast.Value }
    try { return $Ast.SafeGetValue() } catch { return $null }
}

function Read-TKHeader {
    # Reads "# @Key: value" lines from the top of a script (works for .ps1, .py and .sh).
    # Scripts without a Tech Kit header (for example from a downloaded library) fall back
    # to "Name:" / "Description:" lines or .SYNOPSIS in their opening comment.
    param([Parameter(Mandatory)][string]$Path)
    $meta = [ordered]@{}
    $params = [System.Collections.Generic.List[string]]::new()
    $choices = [ordered]@{}
    $lines = @(Get-Content -LiteralPath $Path -TotalCount 150 -Encoding UTF8 -ErrorAction Stop)
    foreach ($line in $lines) {
        if ($line -match '^\s*#\s*@([A-Za-z][\w-]*)\s*:\s?(.*)$') {
            $key = $Matches[1]
            $val = $Matches[2].Trim()
            if ($key -eq 'Param') { $params.Add($val) }
            elseif ($key -eq 'Choices') {
                if ($val -match '^\s*(\w+)\s*=\s*(.+)$') { $choices[$Matches[1]] = $Matches[2].Trim() }
            } else { $meta[$key] = $val }
        }
    }
    $hasHeader = $meta.Contains('Name')
    if (-not $hasHeader) {
        $limit = [Math]::Min($lines.Count, 60)
        for ($i = 0; $i -lt $limit; $i++) {
            $l = $lines[$i]
            if (-not $meta.Contains('Name') -and $l -match '^\s*(?:#\s*)?(?:Name|Title|Script Name)\s*:\s*(.{3,120})$') { $meta['Name'] = $Matches[1].Trim() }
            elseif (-not $meta.Contains('Description') -and $l -match '^\s*(?:#\s*)?Description\s*:\s*(.{3,})$') { $meta['Description'] = $Matches[1].Trim() }
            elseif (-not $meta.Contains('Description') -and $l -match '^\s*\.SYNOPSIS\s*$' -and ($i + 1) -lt $lines.Count) {
                $meta['Description'] = $lines[$i + 1].Trim()
            }
        }
    }
    [pscustomobject]@{ Meta = $meta; Params = $params.ToArray(); Choices = $choices; HasHeader = $hasHeader }
}

function Resolve-TKChoices {
    # Turns an @Choices spec into dropdown values:
    #   files:Identity\*.json            -> file names (without extension) under Config
    #   jsonkeys:Identity\*.json:Departments -> property names of that object in each file
    #   list:a, b, c                     -> a fixed list
    param([string]$Spec)
    $cfg = Get-TKPath Config
    $out = [System.Collections.Generic.List[string]]::new()
    try {
        if ($Spec -match '^files:(.+)$') {
            Get-ChildItem -Path (Join-Path $cfg $Matches[1].Trim()) -File -ErrorAction SilentlyContinue |
                Where-Object { -not $_.Name.StartsWith('_') } | ForEach-Object { $out.Add($_.BaseName) }
        } elseif ($Spec -match '^jsonkeys:(.+):(\w+)$') {
            $prop = $Matches[2]
            foreach ($f in @(Get-ChildItem -Path (Join-Path $cfg $Matches[1].Trim()) -File -ErrorAction SilentlyContinue)) {
                $json = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                $obj = $json.$prop
                if ($obj) { foreach ($pp in $obj.PSObject.Properties) { $out.Add($pp.Name) } }
            }
        } elseif ($Spec -match '^list:(.+)$') {
            foreach ($v in ($Matches[1] -split ',')) { if ($v.Trim()) { $out.Add($v.Trim()) } }
        }
    } catch {
        Write-Warning "Could not resolve choices '$Spec': $($_.Exception.Message)"
    }
    @($out | Select-Object -Unique)
}

function Get-TKPsParameters {
    # Uses the PowerShell parser to turn a script's param() block into GUI fields.
    param([Parameter(Mandatory)][string]$Path)
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $result = [ordered]@{
        Params         = @()
        SupportsWhatIf = $false
        Errors         = @($errors | ForEach-Object { "Line $($_.Extent.StartLineNumber): $($_.Message)" })
    }
    $pb = $ast.ParamBlock
    if (-not $pb) { return [pscustomobject]$result }

    foreach ($attr in $pb.Attributes) {
        if ($attr.TypeName.Name -eq 'CmdletBinding') {
            foreach ($na in $attr.NamedArguments) {
                if ($na.ArgumentName -eq 'SupportsShouldProcess') {
                    if ($na.ExpressionOmitted -or (Get-TKAstValue $na.Argument) -eq $true -or $na.Argument.Extent.Text -match 'true') {
                        $result.SupportsWhatIf = $true
                    }
                }
            }
        }
    }

    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $pb.Parameters) {
        $name = $p.Name.VariablePath.UserPath
        $typeName = 'string'
        $mandatory = $false
        $help = ''
        $choices = @()
        foreach ($a in $p.Attributes) {
            if ($a -is [System.Management.Automation.Language.TypeConstraintAst]) {
                $typeName = $a.TypeName.FullName
            } elseif ($a -is [System.Management.Automation.Language.AttributeAst]) {
                switch ($a.TypeName.Name) {
                    'Parameter' {
                        foreach ($na in $a.NamedArguments) {
                            if ($na.ArgumentName -eq 'Mandatory') {
                                if ($na.ExpressionOmitted -or (Get-TKAstValue $na.Argument) -eq $true -or $na.Argument.Extent.Text -match 'true') { $mandatory = $true }
                            } elseif ($na.ArgumentName -eq 'HelpMessage') {
                                $help = [string](Get-TKAstValue $na.Argument)
                            }
                        }
                    }
                    'ValidateSet' {
                        $choices = @($a.PositionalArguments | ForEach-Object { [string](Get-TKAstValue $_) })
                    }
                }
            }
        }
        $t = $typeName.ToLowerInvariant() -replace '^system\.', '' -replace '^management\.automation\.', ''
        $kind = 'String'
        if ($choices.Count -gt 0) { $kind = 'Choice' }
        elseif ($t -in @('switch', 'switchparameter')) { $kind = 'Switch' }
        elseif ($t -in @('bool', 'boolean')) { $kind = 'Bool' }
        elseif ($t -in @('int', 'int32', 'int64', 'long', 'uint32', 'byte', 'int16', 'double', 'decimal', 'single', 'float')) { $kind = 'Number' }
        elseif ($t -in @('securestring', 'security.securestring')) { $kind = 'Secure' }
        elseif ($t -in @('pscredential')) { $kind = 'Credential' }
        elseif ($t -in @('datetime')) { $kind = 'Date' }
        elseif ($t -match '\[\]$') { $kind = 'List' }

        $default = $null
        $defaultText = ''
        if ($p.DefaultValue) {
            $default = Get-TKAstValue $p.DefaultValue
            if ($null -eq $default) { $defaultText = $p.DefaultValue.Extent.Text }
            elseif ($default -is [array]) { $default = ($default -join ', ') }
        }
        $list.Add([pscustomobject]@{
            Name        = $name
            Kind        = $kind
            TypeName    = $typeName
            Mandatory   = $mandatory
            Help        = $help
            Choices     = $choices
            Default     = $default
            DefaultText = $defaultText
        })
    }
    $result.Params = $list.ToArray()
    [pscustomobject]$result
}

function ConvertFrom-TKParamLine {
    # "# @Param: Name | type | default | help"  (append ! to the type for mandatory)
    param([string]$Line)
    $parts = @($Line -split '\|' | ForEach-Object { $_.Trim() })
    $name = $parts[0]
    $type = 'string'
    if ($parts.Count -gt 1 -and $parts[1]) { $type = $parts[1] }
    $mandatory = $type.EndsWith('!')
    $type = $type.TrimEnd('!').ToLowerInvariant()
    $choices = @()
    $kind = 'String'
    if ($type -match '^choice\((.*)\)$') { $kind = 'Choice'; $choices = ConvertTo-TKList ($Matches[1] -replace '/', ',') }
    elseif ($type -in @('int', 'number')) { $kind = 'Number' }
    elseif ($type -in @('switch', 'flag')) { $kind = 'Switch' }
    elseif ($type -eq 'bool') { $kind = 'Bool' }
    elseif ($type -in @('secure', 'password')) { $kind = 'Secure' }
    elseif ($type -eq 'list') { $kind = 'List' }
    $default = $null
    if ($parts.Count -gt 2 -and $parts[2]) { $default = $parts[2] }
    $help = ''
    if ($parts.Count -gt 3) { $help = ($parts[3..($parts.Count - 1)] -join ' | ') }
    [pscustomobject]@{
        Name = $name; Kind = $kind; TypeName = $type; Mandatory = $mandatory; Help = $help
        Choices = $choices; Default = $default; DefaultText = ''
    }
}

function Get-TKCategoryName {
    param([string]$Folder)
    ($Folder -replace '^\d+\s*[-_.]?\s*', '').Trim()
}

function Get-TKLibraryRoots {
    # The built-in Scripts folder plus every folder under Libraries (downloaded repos).
    $list = [System.Collections.Generic.List[object]]::new()
    $list.Add([pscustomobject]@{ Root = (Get-TKPath Scripts); Prefix = 'Scripts'; Library = '' })
    $libs = Get-TKPath Libraries
    if (Test-Path -LiteralPath $libs) {
        foreach ($d in @(Get-ChildItem -LiteralPath $libs -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $list.Add([pscustomobject]@{ Root = $d.FullName; Prefix = "Libraries\$($d.Name)"; Library = $d.Name })
        }
    }
    $list.ToArray()
}

function Get-TKScript {
    [CmdletBinding()]
    param()
    $changeVerbs = '\b(Set|Remove|New|Add|Disable|Enable|Update|Grant|Revoke|Reset|Move|Restart|Stop|Uninstall|Clear)-(Mg|Mailbox|AD[A-Z]|Distribution|Unified|Recipient|CAS|InboxRule|SPO|PnP|Team|Cs[A-Z]|Az[A-Z]|Entra|Local|Service|ItemProperty|Computer|Printer|Smb|NetFirewall|Transport|Organization|Msol|AzureAD|User|Group|DynamicDistribution|MailContact|MailUser|ManagementRole|RoleGroup)'
    foreach ($lib in (Get-TKLibraryRoots)) {
        if (-not (Test-Path -LiteralPath $lib.Root)) { continue }
        $rootFull = (Resolve-Path -LiteralPath $lib.Root).Path.TrimEnd('\', '/')
        $files = @(Get-ChildItem -LiteralPath $rootFull -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @('.ps1', '.py', '.sh') -and -not $_.Name.StartsWith('_') -and $_.FullName -notmatch '[\\/]\.git[\\/]' })
        $perFolder = @{}
        foreach ($f in $files) { $perFolder[$f.DirectoryName] = 1 + [int]$perFolder[$f.DirectoryName] }

        foreach ($f in $files) {
            try {
                $rel = $f.FullName.Substring($rootFull.Length).TrimStart('\', '/')
                $segments = @($rel -split '[\\/]')
                $isLib = [bool]$lib.Library
                $folder = 'Uncategorized'
                if ($isLib) { $folder = "Library: $($lib.Library)" }
                elseif ($segments.Count -gt 1) { $folder = $segments[0] }
                $header = Read-TKHeader -Path $f.FullName
                $m = $header.Meta
                $language = switch ($f.Extension.ToLowerInvariant()) { '.ps1' { 'PowerShell' } '.py' { 'Python' } '.sh' { 'Bash' } }

                $params = @()
                $whatIf = $false
                $parseErrors = @()
                if ($language -eq 'PowerShell') {
                    $pinfo = Get-TKPsParameters -Path $f.FullName
                    $params = @($pinfo.Params)
                    $whatIf = [bool]$pinfo.SupportsWhatIf
                    $parseErrors = @($pinfo.Errors)
                } else {
                    $params = @($header.Params | ForEach-Object { ConvertFrom-TKParamLine $_ })
                }
                if ($m.Contains('WhatIf')) { $whatIf = ConvertTo-TKBool $m['WhatIf'] }

                $inferredM365 = $false
                if (-not $header.HasHeader) {
                    # Third-party script: guess the important flags from the code itself.
                    $text = [IO.File]::ReadAllText($f.FullName)
                    if (-not $m.Contains('Changes') -and $text -match $changeVerbs) { $m['Changes'] = 'Yes' }
                    if ($text -match '#Requires\s+-RunAsAdministrator') { $m['Admin'] = 'Yes' }
                    if ($text -match 'Connect-(MgGraph|ExchangeOnline|IPPSSession|MicrosoftTeams|PnPOnline|AzAccount|AzureAD|MsolService)') { $inferredM365 = $true }
                    if (-not $m['Name']) {
                        if ($perFolder[$f.DirectoryName] -eq 1 -and $f.DirectoryName -ne $rootFull) { $m['Name'] = Split-Path -Path $f.DirectoryName -Leaf }
                        else { $m['Name'] = ([IO.Path]::GetFileNameWithoutExtension($f.Name) -creplace '([a-z])([A-Z])', '$1 $2') -replace '[-_]', ' ' }
                    }
                }

                $targets = ConvertTo-TKList $m['Target']
                if ($targets.Count -eq 0) { $targets = @('Local') }
                $connect = ConvertTo-TKList $m['Connect']
                if ($connect.Count -gt 0 -and $targets -notcontains 'M365') { $targets = @($targets) + 'M365' }

                $category = $m['Category']
                if (-not $category) {
                    if ($isLib) { $category = $lib.Library } else { $category = Get-TKCategoryName $folder }
                }
                $name = $m['Name']
                if (-not $name) { $name = [IO.Path]::GetFileNameWithoutExtension($f.Name) }

                $admin = ConvertTo-TKBool $m['Admin']
                $changes = ConvertTo-TKBool $m['Changes']
                $remote = ($targets -contains 'Remote') -or ($targets -contains 'SSH')

                $badges = [System.Collections.Generic.List[string]]::new()
                if ($admin) { $badges.Add('ADMIN') }
                if ($changes) { $badges.Add('CHANGES') }
                if ($remote) { $badges.Add('REMOTE') }
                if ($connect.Count -gt 0 -or $inferredM365) { $badges.Add('M365') }
                if ($language -eq 'Python') { $badges.Add('PY') }
                if ($language -eq 'Bash') { $badges.Add('SH') }
                if ($isLib) { $badges.Add('LIB') }
                if ($parseErrors.Count -gt 0) { $badges.Add('ERROR') }

                $id = $rel
                if ($isLib) { $id = "$($lib.Prefix)\$rel" }
                [pscustomobject]@{
                    Id             = $id
                    RelPath        = "$($lib.Prefix)\$rel"
                    Path           = $f.FullName
                    FileName       = $f.Name
                    Language       = $language
                    Name           = $name
                    Description    = [string]$m['Description']
                    Category       = $category
                    CategoryFolder = $folder
                    Library        = $lib.Library
                    IsLibrary      = $isLib
                    HasHeader      = $header.HasHeader
                    Admin          = $admin
                    Changes        = $changes
                    WhatIf         = $whatIf
                    Targets        = $targets
                    SupportsRemote = $remote
                    Connect        = $connect
                    Scopes         = ConvertTo-TKList $m['Scopes']
                    Modules        = ConvertTo-TKList $m['Modules']
                    Shell          = ConvertTo-TKList $m['Shell']
                    OS             = [string]$m['OS']
                    Tags           = ConvertTo-TKList $m['Tags']
                    Author         = [string]$m['Author']
                    Version        = [string]$m['Version']
                    Params         = $params
                    Choices        = $header.Choices
                    ParseErrors    = $parseErrors
                    Badges         = $badges.ToArray()
                    Meta           = $m
                    ParamLines     = $header.Params
                    SearchText     = (($name, $m['Description'], $category, $m['Tags'], $f.Name) -join ' ').ToLowerInvariant()
                }
            } catch {
                Write-Warning "Skipped $($f.FullName): $($_.Exception.Message)"
            }
        }
    }
}

function Split-TKScriptFile {
    # Splits a script into shebang, header lines and body (used by the editor).
    param([Parameter(Mandatory)][string]$Path)
    $all = @(Get-Content -LiteralPath $Path -Encoding UTF8)
    $shebang = ''
    $i = 0
    if ($all.Count -gt 0 -and $all[0].StartsWith('#!')) { $shebang = $all[0]; $i = 1 }
    while ($i -lt $all.Count -and ($all[$i] -match '^\s*#\s*@[A-Za-z]' -or ($all[$i].Trim() -eq '' -and $i -lt 3))) { $i++ }
    while ($i -lt $all.Count -and $all[$i].Trim() -eq '') { $i++ }
    $body = ''
    if ($i -lt $all.Count) { $body = ($all[$i..($all.Count - 1)] -join "`r`n") }
    [pscustomobject]@{ Shebang = $shebang; Body = $body }
}

function Format-TKHeader {
    param(
        [System.Collections.IDictionary]$Meta,
        [string[]]$ParamLines = @(),
        [System.Collections.IDictionary]$Choices = @{}
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    $keys = @($script:MetaOrder) + @($Meta.Keys | Where-Object { $script:MetaOrder -notcontains $_ })
    foreach ($k in $keys) {
        if (-not $Meta.Contains($k)) { continue }
        $v = [string]$Meta[$k]
        if ($v.Trim() -eq '') { continue }
        $lines.Add(('# @{0,-13}{1}' -f ($k + ':'), $v.Trim()))
    }
    foreach ($p in $ParamLines) { if ($p.Trim()) { $lines.Add(('# @{0,-13}{1}' -f 'Param:', $p.Trim())) } }
    foreach ($k in $Choices.Keys) { $lines.Add(('# @{0,-13}{1} = {2}' -f 'Choices:', $k, $Choices[$k])) }
    $lines.ToArray()
}

function Set-TKScriptContent {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Meta,
        [string[]]$ParamLines = @(),
        [string]$Body = '',
        [string]$Shebang = '',
        [System.Collections.IDictionary]$Choices = @{}
    )
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    $out = [System.Collections.Generic.List[string]]::new()
    if ($Shebang) { $out.Add($Shebang) }
    elseif ($ext -eq '.sh') { $out.Add('#!/usr/bin/env bash') }
    elseif ($ext -eq '.py') { $out.Add('#!/usr/bin/env python3') }
    foreach ($l in (Format-TKHeader -Meta $Meta -ParamLines $ParamLines -Choices $Choices)) { $out.Add($l) }
    $out.Add('')
    $out.Add($Body.TrimEnd())
    $text = ($out -join "`n")
    if ($ext -eq '.ps1') {
        $text = $text -replace "`r?`n", "`r`n"
        # UTF-8 with BOM so Windows PowerShell 5.1 reads non-ASCII characters correctly
        [IO.File]::WriteAllText($Path, $text + "`r`n", (New-Object System.Text.UTF8Encoding($true)))
    } else {
        $text = $text -replace "`r`n", "`n"
        [IO.File]::WriteAllText($Path, $text + "`n", (New-Object System.Text.UTF8Encoding($false)))
    }
}

function Test-TKScriptSyntax {
    param([Parameter(Mandatory)][string]$Text)
    $tokens = $null
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    @($errors | ForEach-Object { "Line $($_.Extent.StartLineNumber): $($_.Message)" })
}

# ----------------------------------------------------------------------------
#  Running scripts (used inside the worker runspace and the elevated runner)
# ----------------------------------------------------------------------------

function New-TKRunspace {
    param(
        [Parameter(Mandatory)]$Sink,
        [string]$HostName = 'Tech Kit'
    )
    Import-TKHostType
    $hostObject = New-Object TechKit.Host -ArgumentList $Sink, $HostName
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    # Execution policy only exists on Windows (setting it elsewhere makes Open() fail)
    if ([IO.Path]::DirectorySeparatorChar -eq '\') {
        try { $iss.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass } catch { }
    }
    $iss.ImportPSModule([string[]]@((Join-Path $PSScriptRoot 'TechKit.Core.psm1')))
    $iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry('TKSink', $Sink, 'Tech Kit output sink')))
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($hostObject, $iss)
    # STA is needed on Windows for sign-in windows and dialogs; other platforms only support MTA
    if ([IO.Path]::DirectorySeparatorChar -eq '\') { $rs.ApartmentState = [System.Threading.ApartmentState]::STA }
    $rs.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $rs.Open()

    $init = [PowerShell]::Create()
    $init.Runspace = $rs
    $null = $init.AddScript({
        $global:TKResults = [System.Collections.Generic.List[object]]::new()
        $global:ProgressPreference = 'Continue'
        $global:ErrorActionPreference = 'Continue'
        $global:TKConnections = @{}
        Initialize-TKEnvironment
        Install-TKConnectShims
        Set-Location -LiteralPath $HOME
    })
    $null = $init.Invoke()
    $init.Dispose()
    $rs
}

function Get-TKOriginPrefix {
    param($Record)
    if (-not $global:TKShowOrigin) { return '' }
    $origin = $null
    if ($Record.PSObject.Properties['OriginInfo']) { $origin = $Record.OriginInfo }
    if ($origin -and $origin.PSComputerName) { return '[' + $origin.PSComputerName + '] ' }
    ''
}

function Write-TKErrorRecord {
    param($Sink, $Record)
    $prefix = Get-TKOriginPrefix $Record
    $Sink.Add('Error', $prefix + $Record.ToString())
    $ii = $Record.InvocationInfo
    if ($ii -and $ii.ScriptLineNumber -gt 0 -and $ii.ScriptName -and $global:TKCurrentScript -and $ii.ScriptName -eq $global:TKCurrentScript) {
        $Sink.Add('Verbose', ('    at line {0}: {1}' -f $ii.ScriptLineNumber, $ii.Line.Trim()))
    }
}

function Out-TKSink {
    # Final stage of every worker pipeline: turns records and objects into
    # colored lines for the GUI and keeps the objects for CSV/HTML export.
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true)]$InputObject,
        [switch]$NoCollect,
        [int]$Width = 0
    )
    begin {
        $sink = $global:TKSink
        if ($Width -le 0) {
            $Width = 220
            try { $Width = [Math]::Max(80, $Host.UI.RawUI.BufferSize.Width) } catch { }
        }
        if (-not $NoCollect) { $global:TKResults = [System.Collections.Generic.List[object]]::new() }
        $formatter = [scriptblock]::Create("Out-String -Stream -Width $Width").GetSteppablePipeline()
        $formatter.Begin($true)
    }
    process {
        $o = $InputObject
        if ($null -eq $o) { return }
        if ($o -is [System.Management.Automation.ErrorRecord]) {
            Write-TKErrorRecord -Sink $sink -Record $o
            return
        }
        if ($o -is [System.Management.Automation.WarningRecord]) {
            $sink.Add('Warning', (Get-TKOriginPrefix $o) + 'WARNING: ' + $o.Message)
            return
        }
        if ($o -is [System.Management.Automation.VerboseRecord]) {
            $sink.Add('Verbose', (Get-TKOriginPrefix $o) + 'VERBOSE: ' + $o.Message)
            return
        }
        if ($o -is [System.Management.Automation.DebugRecord]) {
            $sink.Add('Debug', (Get-TKOriginPrefix $o) + 'DEBUG: ' + $o.Message)
            return
        }
        if ($o -is [System.Management.Automation.InformationRecord]) {
            $prefix = Get-TKOriginPrefix $o
            $md = $o.MessageData
            if ($null -ne $md -and $md.PSObject.Properties['Message'] -and $md.PSObject.Properties['NoNewLine']) {
                $color = -1
                if ($null -ne $md.ForegroundColor) {
                    try { $color = [int][System.ConsoleColor]$md.ForegroundColor } catch { $color = -1 }
                }
                $sink.Add('Host', $prefix + [string]$md.Message, $color, (-not [bool]$md.NoNewLine))
            } else {
                $sink.Add('Info', $prefix + [string]$md)
            }
            return
        }
        if (-not $NoCollect) { $global:TKResults.Add($o) }
        foreach ($line in $formatter.Process($o)) { $sink.Add('Output', [string]$line) }
    }
    end {
        foreach ($line in $formatter.End()) { $sink.Add('Output', [string]$line) }
        try { $sink.Location = (Get-Location).Path } catch { }
    }
}

function Join-TKPathSafe {
    # Join-Path that returns $null instead of failing when the base is missing
    param([string]$Base, [string]$Child)
    if (-not $Base) { return $null }
    Join-Path $Base $Child
}

function Find-TKInterpreter {
    param([ValidateSet('python', 'bash', 'ssh')][string]$Name)
    $root = $script:TKRoot
    $candidates = @()
    switch ($Name) {
        'python' {
            $candidates = @(
                (Join-Path $root 'Runtimes\python\python.exe'),
                (Get-Command py.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source),
                (Get-Command python.exe -CommandType Application -ErrorAction SilentlyContinue |
                    Where-Object { $_.Source -notlike '*\WindowsApps\*' } | Select-Object -First 1 -ExpandProperty Source)
            )
        }
        'bash' {
            $candidates = @(
                (Join-Path $root 'Runtimes\git\bin\bash.exe'),
                (Join-TKPathSafe $env:ProgramFiles 'Git\bin\bash.exe'),
                (Join-TKPathSafe ${env:ProgramFiles(x86)} 'Git\bin\bash.exe'),
                (Join-TKPathSafe $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe'),
                (Join-TKPathSafe $env:WINDIR 'System32\bash.exe')
            )
        }
        'ssh' {
            $candidates = @(
                (Join-TKPathSafe $env:WINDIR 'System32\OpenSSH\ssh.exe'),
                (Get-Command ssh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
            )
        }
    }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    # Not on Windows (used by the test suite on Linux/macOS)
    if ([IO.Path]::DirectorySeparatorChar -eq '/') {
        $unix = @{ python = 'python3'; bash = 'bash'; ssh = 'ssh' }[$Name]
        $cmd = Get-Command $unix -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    }
    $null
}

function ConvertTo-TKShellQuote {
    param([string]$Value)
    "'" + ($Value -replace "'", "'\''") + "'"
}

function Invoke-TKNative {
    # Runs a native program, streaming stdout as output and stderr as red lines.
    param([string]$FilePath, [string[]]$ArgumentList = @(), [string]$StdIn)
    # Python, Git Bash and SSH speak UTF-8. Switch the console decoding only while
    # they run, so Windows tools (ipconfig, netsh) keep their normal code page.
    $sink = $global:TKSink
    $OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $oldEncoding = $null
    try { $oldEncoding = [Console]::OutputEncoding; [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
    try {
        if ($PSBoundParameters.ContainsKey('StdIn')) {
            $StdIn | & $FilePath @ArgumentList 2>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.ErrorRecord]) { if ($sink) { $sink.Add('Error', $_.ToString()) } else { Write-Warning $_.ToString() } } else { $_ }
            }
        } else {
            & $FilePath @ArgumentList 2>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.ErrorRecord]) { if ($sink) { $sink.Add('Error', $_.ToString()) } else { Write-Warning $_.ToString() } } else { $_ }
            }
        }
    } finally {
        if ($oldEncoding) { try { [Console]::OutputEncoding = $oldEncoding } catch { } }
    }
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        Write-Warning "$(Split-Path $FilePath -Leaf) exited with code $LASTEXITCODE"
    }
}

function Invoke-TKScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Parameters = @{},
        [string[]]$Arguments = @(),
        [string[]]$ComputerName = @(),
        [System.Management.Automation.PSCredential]$Credential,
        [switch]$DryRun
    )
    if (Test-Path -LiteralPath $Path) { $Path = (Resolve-Path -LiteralPath $Path).ProviderPath }
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    $localTargets = @()
    $remoteTargets = @()
    foreach ($c in $ComputerName) {
        if (-not $c -or -not $c.Trim()) { continue }
        if (Test-TKLocalName $c) { $localTargets += $c.Trim() } else { $remoteTargets += $c.Trim() }
    }
    $runLocal = ($remoteTargets.Count -eq 0) -or ($localTargets.Count -gt 0)
    $global:TKShowOrigin = ($remoteTargets.Count -gt 0)
    $global:TKCurrentScript = $Path

    switch ($ext) {
        '.ps1' {
            $p = @{}
            foreach ($k in $Parameters.Keys) { $p[$k] = $Parameters[$k] }
            if ($DryRun) { $p['WhatIf'] = $true }
            if ($runLocal) {
                try {
                    & $Path @p
                } catch {
                    # Re-emitting the error replaces its position, so keep the script line first
                    $pos = $_.InvocationInfo
                    Write-Error -ErrorRecord $_
                    if ($global:TKSink -and $pos -and $pos.ScriptName -eq $Path -and $pos.ScriptLineNumber -gt 0) {
                        $global:TKSink.Add('Verbose', ('    at line {0}: {1}' -f $pos.ScriptLineNumber, $pos.Line.Trim()))
                    }
                }
            }
            if ($remoteTargets.Count -gt 0) {
                $code = [IO.File]::ReadAllText($Path)
                $icm = @{
                    ComputerName = $remoteTargets
                    ScriptBlock  = { param($TKCode, $TKParams) $sb = [scriptblock]::Create($TKCode); & $sb @TKParams }
                    ArgumentList = @($code, $p)
                    ErrorAction  = 'Continue'
                }
                if ($Credential) { $icm.Credential = $Credential }
                try {
                    Invoke-Command @icm
                } catch {
                    Write-Error -ErrorRecord $_
                }
            }
        }
        '.py' {
            $py = Find-TKInterpreter -Name python
            if (-not $py) { throw 'Python was not found. Copy a portable Python into Runtimes\python on the USB, or install Python on this PC.' }
            if ($remoteTargets.Count -gt 0) { Write-Warning 'Python scripts run on this PC only. Remote targets were ignored.' }
            $env:PYTHONIOENCODING = 'utf-8'
            $env:PYTHONUNBUFFERED = '1'
            $a = @()
            if ((Split-Path $py -Leaf) -eq 'py.exe') { $a += '-3' }
            $a += @('-u', $Path) + @($Arguments)
            if ($DryRun) { $a += '--whatif' }
            Invoke-TKNative -FilePath $py -ArgumentList $a
        }
        '.sh' {
            $content = ([IO.File]::ReadAllText($Path) -replace "`r`n", "`n") + "`n#"
            $a = @($Arguments)
            if ($DryRun) { $a += '--whatif' }
            if ($runLocal) {
                $bash = Find-TKInterpreter -Name bash
                if (-not $bash) { throw 'Bash was not found. Install Git for Windows or WSL, or copy Git Bash into Runtimes\git on the USB.' }
                Invoke-TKNative -FilePath $bash -ArgumentList (@('-s', '--') + $a) -StdIn $content
            }
            if ($remoteTargets.Count -gt 0) {
                $ssh = Find-TKInterpreter -Name ssh
                if (-not $ssh) { throw 'ssh.exe was not found. Enable the Windows OpenSSH Client feature.' }
                $argText = ($a | ForEach-Object { ConvertTo-TKShellQuote $_ }) -join ' '
                foreach ($t in $remoteTargets) {
                    Write-Host "=== $t ===" -ForegroundColor Cyan
                    Invoke-TKNative -FilePath $ssh -ArgumentList @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', $t, "bash -s -- $argText") -StdIn $content
                }
            }
        }
        default { throw "Unsupported script type: $ext" }
    }
}

# ----------------------------------------------------------------------------
#  Results export
# ----------------------------------------------------------------------------

function ConvertTo-TKFlatObject {
    param($InputObject)
    $skip = @('RunspaceId', 'PSShowComputerName', 'PSSourceJobInstanceId')
    $h = [ordered]@{}
    foreach ($p in $InputObject.PSObject.Properties) {
        if ($skip -contains $p.Name) { continue }
        if ($p.MemberType -notin @('NoteProperty', 'Property', 'AliasProperty', 'ScriptProperty', 'CodeProperty')) { continue }
        $v = $null
        try { $v = $p.Value } catch { $v = $null }
        if ($null -ne $v -and $v -isnot [string] -and $v -is [System.Collections.IEnumerable] -and $v -isnot [System.Collections.IDictionary]) {
            $v = (@($v) | ForEach-Object { [string]$_ }) -join '; '
        } elseif ($v -is [datetime]) {
            $v = $v.ToString('yyyy-MM-dd HH:mm:ss')
        }
        $h[$p.Name] = $v
    }
    [pscustomobject]$h
}

function Get-TKReportPath {
    param([string]$Name, [string]$Extension, [string]$Folder)
    if (-not $Folder) { $Folder = Get-TKPath Reports }
    $day = Join-Path $Folder (Get-Date -Format 'yyyy-MM-dd')
    if (-not (Test-Path -LiteralPath $day)) { $null = New-Item -ItemType Directory -Path $day -Force }
    $safe = ($Name -replace '[^\w\- ]', '').Trim() -replace '\s+', '-'
    if (-not $safe) { $safe = 'TechKit' }
    Join-Path $day ('{0}_{1}_{2}.{3}' -f $safe, $env:COMPUTERNAME, (Get-Date -Format 'HHmmss'), $Extension)
}

function Export-TKResult {
    [CmdletBinding()]
    param(
        [ValidateSet('Csv', 'Html')][string]$Format = 'Csv',
        [string]$Title = 'Tech Kit report',
        [string]$Subtitle = '',
        [string]$OutputText = '',
        [string]$Folder = ''
    )
    $items = @($global:TKResults)
    $objects = @($items | Where-Object { $null -ne $_ -and $_ -isnot [string] -and $_ -isnot [ValueType] } | ForEach-Object { ConvertTo-TKFlatObject $_ })
    $path = Get-TKReportPath -Name $Title -Extension $Format.ToLowerInvariant() -Folder $Folder

    if ($Format -eq 'Csv') {
        if ($objects.Count -eq 0) {
            if (-not $OutputText) { throw 'This run produced no table data to export.' }
            $path = [IO.Path]::ChangeExtension($path, 'txt')
            Set-Content -LiteralPath $path -Value $OutputText -Encoding UTF8
            return $path
        }
        $objects | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8
        return $path
    }

    $enc = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
    $body = ''
    if ($objects.Count -gt 0) {
        $body = ($objects | ConvertTo-Html -Fragment) -join "`n"
        $body = $body -replace '<td>(PASS|OK|Healthy)</td>', '<td class="good">$1</td>'
        $body = $body -replace '<td>(FAIL|Critical)</td>', '<td class="bad">$1</td>'
        $body = $body -replace '<td>(WARN|Warning)</td>', '<td class="warn">$1</td>'
        $body = "<p class=""count"">$($objects.Count) row(s)</p>`n" + $body
    }
    if ($OutputText) {
        $body += "`n<h2>Output</h2>`n<pre>" + (& $enc $OutputText) + '</pre>'
    }
    $css = @'
body{font-family:"Segoe UI",Arial,sans-serif;margin:0;background:#f5f6f8;color:#1d2330}
header{background:#1b1d23;color:#fff;padding:22px 32px}
header h1{margin:0;font-size:22px;font-weight:600}
header p{margin:6px 0 0;color:#aab2c0;font-size:13px}
main{padding:20px 32px}
table{border-collapse:collapse;width:100%;background:#fff;font-size:13px;box-shadow:0 1px 2px rgba(0,0,0,.08)}
th{background:#2b3040;color:#fff;text-align:left;padding:8px 10px;position:sticky;top:0}
td{padding:6px 10px;border-bottom:1px solid #e6e8ec;vertical-align:top}
tr:nth-child(even) td{background:#fafbfc}
td.good{color:#137333;font-weight:600}td.bad{color:#c5221f;font-weight:600}td.warn{color:#b06000;font-weight:600}
pre{background:#0f1115;color:#d7dae0;padding:14px;border-radius:6px;overflow:auto;font-size:12px}
.count{color:#5f6878;font-size:12px}
footer{color:#8a93a3;font-size:11px;padding:10px 32px 24px}
'@
    $html = @"
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>$(& $enc $Title)</title><style>$css</style></head>
<body><header><h1>$(& $enc $Title)</h1><p>$(& $enc $Subtitle)</p></header>
<main>
$body
</main>
<footer>Generated by Tech Kit on $(Get-Date -Format 'yyyy-MM-dd HH:mm') from $(& $enc $env:COMPUTERNAME)</footer>
</body></html>
"@
    Set-Content -LiteralPath $path -Value $html -Encoding UTF8
    $path
}

function Import-TKResult {
    param([string]$Path)
    $global:TKResults = [System.Collections.Generic.List[object]]::new()
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        foreach ($o in (Import-Clixml -LiteralPath $Path)) { $global:TKResults.Add($o) }
    }
}

# ----------------------------------------------------------------------------
#  Modules
# ----------------------------------------------------------------------------

function Get-TKMissingModule {
    param([string[]]$Name)
    foreach ($n in $Name) {
        if (-not $n) { continue }
        if (-not (Get-Module -ListAvailable -Name $n -ErrorAction SilentlyContinue)) { $n }
    }
}

function Install-TKModule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Name,
        [ValidateSet('USB', 'CurrentUser')][string]$Destination = 'USB'
    )
    Initialize-TKEnvironment
    $rsat = @('ActiveDirectory', 'GroupPolicy', 'DnsServer', 'DhcpServer')
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue | Where-Object { $_.Version -ge [version]'2.8.5.201' })) {
            Write-Host 'Installing the NuGet package provider for the current user...' -ForegroundColor DarkGray
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
        }
    }
    foreach ($n in $Name) {
        if ($rsat -contains $n) {
            Write-Warning "$n comes with Windows RSAT, not the PowerShell Gallery. Run 'Install RSAT AD Tools' in the Active Directory category, or put a domain controller name in the Target box."
            continue
        }
        if ($Destination -eq 'USB') {
            Write-Host "Downloading $n to the USB Modules folder..." -ForegroundColor Cyan
            Save-Module -Name $n -Path (Get-TKPath Modules) -Repository PSGallery -Force -ErrorAction Stop
        } else {
            Write-Host "Installing $n for the current user..." -ForegroundColor Cyan
            Install-Module -Name $n -Scope CurrentUser -Repository PSGallery -Force -AllowClobber -ErrorAction Stop
        }
        Write-Host "  $n is ready." -ForegroundColor Green
    }
}

function Update-TKModules {
    # Refreshes every module listed in Config\modules.json on the USB.
    [CmdletBinding()]
    param()
    $file = Join-Path (Get-TKPath Config) 'modules.json'
    $list = @()
    if (Test-Path -LiteralPath $file) { $list = @((Get-Content -LiteralPath $file -Raw | ConvertFrom-Json).Modules) }
    if ($list.Count -eq 0) { $list = @('Microsoft.Graph.Authentication', 'ExchangeOnlineManagement') }
    Install-TKModule -Name $list -Destination USB
    Unblock-TKFiles -Force
    Write-Host 'Module update finished.' -ForegroundColor Green
}

# ----------------------------------------------------------------------------
#  Microsoft 365
# ----------------------------------------------------------------------------

function Select-TKSupportedParams {
    # Drops parameters that the installed module version does not have.
    param([string]$Command, [hashtable]$Params)
    $cmd = Get-Command $Command -ErrorAction Stop
    $names = @{}
    foreach ($p in $cmd.Parameters.Values) {
        $names[$p.Name] = $true
        foreach ($a in $p.Aliases) { $names[$a] = $true }
    }
    $out = @{}
    foreach ($k in $Params.Keys) {
        if ($names.ContainsKey($k)) { $out[$k] = $Params[$k] }
        else { Write-Verbose "$Command does not support -$k in this module version; skipped." }
    }
    $out
}

function Connect-TKM365 {
    [CmdletBinding()]
    param(
        [ValidateSet('Graph', 'Exchange', 'Compliance', 'Teams', 'SharePoint', 'Azure')][string[]]$Service = @('Graph'),
        [ValidateSet('Interactive', 'DeviceCode', 'Certificate', 'Secret')][string]$Method = 'Interactive',
        [string]$TenantId,
        [string]$ClientId,
        [string]$CertificateThumbprint,
        [string]$CertificatePath,
        [securestring]$CertificatePassword,
        [securestring]$ClientSecret,
        [string]$Organization,
        [string[]]$Scopes = @(),
        [string]$UserPrincipalName,
        [string]$SharePointUrl
    )
    if (-not $Organization -and $TenantId -and $TenantId -match '\.') { $Organization = $TenantId }
    if ($Method -in @('Certificate', 'Secret') -and (-not $ClientId -or -not $TenantId)) {
        throw 'App sign-in needs both a Tenant (ID or domain) and an App (client) ID.'
    }
    if ($Method -eq 'Certificate' -and -not $CertificateThumbprint -and -not $CertificatePath) {
        throw 'Certificate sign-in needs a certificate thumbprint or a .pfx file.'
    }
    if (-not $global:TKConnections) { $global:TKConnections = @{} }
    $cert = $null
    if ($Method -eq 'Certificate' -and -not $CertificateThumbprint) {
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CertificatePath, $CertificatePassword)
    }
    $failures = [System.Collections.Generic.List[string]]::new()

    # The real cmdlets are called by module-qualified name, because the Tech Kit session
    # also has "reuse the connection" wrappers with the plain names (see Install-TKConnectShims).
    if ($Service -contains 'Graph') {
        try {
            Write-Host 'Connecting to Microsoft Graph...' -ForegroundColor Cyan
            Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
            $g = @{ NoWelcome = $true; ContextScope = 'Process' }
            switch ($Method) {
                'Interactive' {
                    if (Get-Command Set-MgGraphOption -ErrorAction SilentlyContinue) {
                        try { Set-MgGraphOption -DisableLoginByWAM $true -ErrorAction Stop } catch { }
                    }
                    if ($Scopes.Count) { $g.Scopes = $Scopes }
                    if ($TenantId) { $g.TenantId = $TenantId }
                }
                'DeviceCode' {
                    $g.UseDeviceCode = $true
                    if ($Scopes.Count) { $g.Scopes = $Scopes }
                    if ($TenantId) { $g.TenantId = $TenantId }
                    Write-Host 'A sign-in code will appear below. Open https://microsoft.com/devicelogin on any device and enter it.' -ForegroundColor Yellow
                }
                'Certificate' {
                    $g.ClientId = $ClientId
                    $g.TenantId = $TenantId
                    if ($CertificateThumbprint) { $g.CertificateThumbprint = $CertificateThumbprint } else { $g.Certificate = $cert }
                }
                'Secret' {
                    $g.TenantId = $TenantId
                    $g.ClientSecretCredential = New-Object System.Management.Automation.PSCredential($ClientId, $ClientSecret)
                }
            }
            $g = Select-TKSupportedParams -Command 'Microsoft.Graph.Authentication\Connect-MgGraph' -Params $g
            Microsoft.Graph.Authentication\Connect-MgGraph @g -ErrorAction Stop
            $ctx = Microsoft.Graph.Authentication\Get-MgContext
            if ($ctx) {
                $who = $ctx.Account
                if (-not $who) { $who = 'app ' + $ctx.AppName }
                Write-Host "  Graph connected as $who (tenant $($ctx.TenantId))" -ForegroundColor Green
            }
        } catch { $failures.Add("Microsoft Graph: $($_.Exception.Message)") }
    }

    if ($Service -contains 'Exchange' -or $Service -contains 'Compliance') {
        $e = @{ ShowBanner = $false }
        $skip = $false
        switch ($Method) {
            'Interactive' {
                $e.DisableWAM = $true
                if ($UserPrincipalName) { $e.UserPrincipalName = $UserPrincipalName }
            }
            'DeviceCode' { $e.Device = $true }
            'Certificate' {
                if (-not $Organization) { $failures.Add('Exchange: app sign-in needs the tenant''s .onmicrosoft.com domain in the Tenant or Organization box.'); $skip = $true }
                $e.AppId = $ClientId
                $e.Organization = $Organization
                if ($CertificateThumbprint) { $e.CertificateThumbprint = $CertificateThumbprint }
                else { $e.CertificateFilePath = $CertificatePath; $e.CertificatePassword = $CertificatePassword }
            }
            'Secret' {
                Write-Warning 'Exchange Online and Security & Compliance do not accept client secrets. Use a certificate for app sign-in.'
                $skip = $true
            }
        }
        if (-not $skip) {
            try { Import-Module ExchangeOnlineManagement -ErrorAction Stop } catch { $failures.Add("Exchange: $($_.Exception.Message)"); $skip = $true }
        }
        if (-not $skip -and $Service -contains 'Exchange') {
            try {
                Write-Host 'Connecting to Exchange Online...' -ForegroundColor Cyan
                $p = Select-TKSupportedParams -Command 'ExchangeOnlineManagement\Connect-ExchangeOnline' -Params $e
                ExchangeOnlineManagement\Connect-ExchangeOnline @p -ErrorAction Stop
                Write-Host '  Exchange Online connected.' -ForegroundColor Green
            } catch { $failures.Add("Exchange Online: $($_.Exception.Message)") }
        }
        if (-not $skip -and $Service -contains 'Compliance') {
            try {
                Write-Host 'Connecting to Security & Compliance...' -ForegroundColor Cyan
                $p = Select-TKSupportedParams -Command 'ExchangeOnlineManagement\Connect-IPPSSession' -Params $e
                ExchangeOnlineManagement\Connect-IPPSSession @p -ErrorAction Stop
                Write-Host '  Security & Compliance connected.' -ForegroundColor Green
            } catch { $failures.Add("Security & Compliance: $($_.Exception.Message)") }
        }
    }

    if ($Service -contains 'Teams') {
        try {
            Write-Host 'Connecting to Microsoft Teams...' -ForegroundColor Cyan
            Import-Module MicrosoftTeams -ErrorAction Stop
            $t = @{}
            switch ($Method) {
                'Interactive' { if ($TenantId) { $t.TenantId = $TenantId } }
                'DeviceCode' { $t.UseDeviceAuthentication = $true; if ($TenantId) { $t.TenantId = $TenantId } }
                'Certificate' {
                    $t.ApplicationId = $ClientId
                    $t.TenantId = $TenantId
                    if ($CertificateThumbprint) { $t.CertificateThumbprint = $CertificateThumbprint } else { $t.Certificate = $cert }
                }
                'Secret' { throw 'Teams app sign-in needs a certificate.' }
            }
            $t = Select-TKSupportedParams -Command 'MicrosoftTeams\Connect-MicrosoftTeams' -Params $t
            $null = MicrosoftTeams\Connect-MicrosoftTeams @t -ErrorAction Stop
            $global:TKConnections['Teams'] = $true
            Write-Host '  Microsoft Teams connected.' -ForegroundColor Green
        } catch { $failures.Add("Teams: $($_.Exception.Message)") }
    }

    if ($Service -contains 'SharePoint') {
        try {
            Write-Host 'Connecting to SharePoint Online (PnP)...' -ForegroundColor Cyan
            if (-not $SharePointUrl) { throw 'Enter the SharePoint URL (for example https://contoso-admin.sharepoint.com).' }
            if ($PSVersionTable.PSEdition -ne 'Core') { throw 'PnP.PowerShell needs PowerShell 7. Switch Settings > PowerShell to PowerShell 7.' }
            if (-not $ClientId) { throw 'PnP.PowerShell needs your own Entra app (client) ID. Create one with "Create App Registration for Tech Kit".' }
            Import-Module PnP.PowerShell -ErrorAction Stop
            $s = @{ Url = $SharePointUrl; ClientId = $ClientId }
            switch ($Method) {
                'Interactive' { $s.Interactive = $true; if ($TenantId) { $s.Tenant = $TenantId } }
                'DeviceCode' { $s.DeviceLogin = $true; if ($TenantId) { $s.Tenant = $TenantId } }
                'Certificate' {
                    $s.Tenant = $TenantId
                    if ($CertificateThumbprint) { $s.Thumbprint = $CertificateThumbprint }
                    else { $s.CertificatePath = $CertificatePath; $s.CertificatePassword = $CertificatePassword }
                }
                'Secret' { $s.ClientSecret = (New-Object System.Net.NetworkCredential('', $ClientSecret)).Password }
            }
            $s = Select-TKSupportedParams -Command 'PnP.PowerShell\Connect-PnPOnline' -Params $s
            PnP.PowerShell\Connect-PnPOnline @s -ErrorAction Stop
            $global:TKConnections['SharePoint'] = $SharePointUrl
            Write-Host "  SharePoint connected to $SharePointUrl" -ForegroundColor Green
        } catch { $failures.Add("SharePoint: $($_.Exception.Message)") }
    }

    if ($Service -contains 'Azure') {
        try {
            Write-Host 'Connecting to Azure...' -ForegroundColor Cyan
            Import-Module Az.Accounts -ErrorAction Stop
            if ($Method -eq 'Interactive' -and (Get-Command Update-AzConfig -ErrorAction SilentlyContinue)) {
                try { $null = Update-AzConfig -EnableLoginByWam $false -Scope Process -ErrorAction Stop } catch { }
            }
            $a = @{}
            switch ($Method) {
                'Interactive' { if ($TenantId) { $a.Tenant = $TenantId } }
                'DeviceCode' { $a.UseDeviceAuthentication = $true; if ($TenantId) { $a.Tenant = $TenantId } }
                'Certificate' {
                    if (-not $CertificateThumbprint) { throw 'Azure app sign-in needs the certificate installed on this PC (thumbprint).' }
                    $a.ServicePrincipal = $true; $a.ApplicationId = $ClientId; $a.Tenant = $TenantId; $a.CertificateThumbprint = $CertificateThumbprint
                }
                'Secret' {
                    $a.ServicePrincipal = $true; $a.Tenant = $TenantId
                    $a.Credential = New-Object System.Management.Automation.PSCredential($ClientId, $ClientSecret)
                }
            }
            $a = Select-TKSupportedParams -Command 'Az.Accounts\Connect-AzAccount' -Params $a
            $ctx = Az.Accounts\Connect-AzAccount @a -ErrorAction Stop
            Write-Host "  Azure connected: $($ctx.Context.Account.Id), subscription $($ctx.Context.Subscription.Name)" -ForegroundColor Green
        } catch { $failures.Add("Azure: $($_.Exception.Message)") }
    }

    if ($failures.Count) {
        foreach ($f in $failures) { Write-Host "  FAILED  $f" -ForegroundColor Red }
        throw "$($failures.Count) connection(s) failed."
    }
}

function Get-TKM365Status {
    $s = [ordered]@{
        Graph = $false; GraphAccount = ''; GraphTenant = ''; GraphScopes = @(); GraphAuthType = ''
        Exchange = $false; ExchangeAccount = ''; Compliance = $false; Teams = $false; SharePoint = ''; Azure = ''; Tenant = ''
    }
    if (Get-Module -Name Microsoft.Graph.Authentication) {
        try {
            $ctx = Microsoft.Graph.Authentication\Get-MgContext
            if ($ctx) {
                $s.Graph = $true
                $s.GraphAccount = [string]$ctx.Account
                if (-not $s.GraphAccount) { $s.GraphAccount = 'App: ' + $ctx.AppName }
                $s.GraphTenant = [string]$ctx.TenantId
                $s.GraphScopes = @($ctx.Scopes)
                $s.GraphAuthType = [string]$ctx.AuthType
                $s.Tenant = $s.GraphTenant
            }
        } catch { }
    }
    if (Get-Module -Name ExchangeOnlineManagement) {
        try {
            $ci = @(ExchangeOnlineManagement\Get-ConnectionInformation -ErrorAction Stop | Where-Object { $_.State -eq 'Connected' })
            foreach ($c in $ci) {
                if ($c.IsEopSession) { $s.Compliance = $true }
                else {
                    $s.Exchange = $true
                    $s.ExchangeAccount = [string]$c.UserPrincipalName
                    if (-not $s.Tenant) { $s.Tenant = [string]$c.TenantID }
                }
            }
        } catch { }
    }
    if ($global:TKConnections) {
        if ($global:TKConnections['Teams'] -and (Get-Module -Name MicrosoftTeams)) { $s.Teams = $true }
        if ($global:TKConnections['SharePoint'] -and (Get-Module -Name PnP.PowerShell)) { $s.SharePoint = [string]$global:TKConnections['SharePoint'] }
    }
    if (Get-Module -Name Az.Accounts) {
        try { $az = Az.Accounts\Get-AzContext -ErrorAction Stop; if ($az -and $az.Account) { $s.Azure = [string]$az.Account.Id } } catch { }
    }
    [pscustomobject]$s
}

function Disconnect-TKM365 {
    if (Get-Module -Name Microsoft.Graph.Authentication) {
        try { Microsoft.Graph.Authentication\Disconnect-MgGraph -ErrorAction Stop | Out-Null; Write-Host 'Disconnected from Microsoft Graph.' -ForegroundColor Yellow } catch { }
    }
    if (Get-Module -Name ExchangeOnlineManagement) {
        try { ExchangeOnlineManagement\Disconnect-ExchangeOnline -Confirm:$false -ErrorAction Stop; Write-Host 'Disconnected from Exchange Online / Compliance.' -ForegroundColor Yellow } catch { }
    }
    if (Get-Module -Name MicrosoftTeams) {
        try { MicrosoftTeams\Disconnect-MicrosoftTeams -ErrorAction Stop; Write-Host 'Disconnected from Teams.' -ForegroundColor Yellow } catch { }
    }
    if (Get-Module -Name PnP.PowerShell) {
        try { PnP.PowerShell\Disconnect-PnPOnline -ErrorAction Stop; Write-Host 'Disconnected from SharePoint.' -ForegroundColor Yellow } catch { }
    }
    if (Get-Module -Name Az.Accounts) {
        try { $null = Az.Accounts\Disconnect-AzAccount -ErrorAction Stop; Write-Host 'Disconnected from Azure.' -ForegroundColor Yellow } catch { }
    }
    $global:TKConnections = @{}
}

function Install-TKConnectShims {
    # Third-party scripts usually call Connect-MgGraph / Connect-ExchangeOnline themselves.
    # Inside Tech Kit these wrappers reuse the connection you already made, so you are not
    # asked to sign in again, and they apply the Tech Kit sign-in settings when they do connect.
    function global:Connect-MgGraph {
        if (Get-Module -Name Microsoft.Graph.Authentication) {
            $ctx = $null
            try { $ctx = Microsoft.Graph.Authentication\Get-MgContext } catch { }
            if ($ctx) {
                $who = $ctx.Account
                if (-not $who) { $who = $ctx.AppName }
                Write-Host "Tech Kit: reusing the Microsoft Graph connection ($who). Reconnect from the Microsoft 365 button if this script needs other permissions." -ForegroundColor DarkGray
                return
            }
        }
        $extra = @{}
        $cmd = Get-Command -Name 'Microsoft.Graph.Authentication\Connect-MgGraph' -ErrorAction Stop
        if ($cmd.Parameters.ContainsKey('ContextScope') -and $args -notcontains '-ContextScope') { $extra.ContextScope = 'Process' }
        if (Get-Command Set-MgGraphOption -ErrorAction SilentlyContinue) { try { Set-MgGraphOption -DisableLoginByWAM $true -ErrorAction Stop } catch { } }
        Microsoft.Graph.Authentication\Connect-MgGraph @args @extra
    }
    function global:Connect-ExchangeOnline {
        if (Get-Module -Name ExchangeOnlineManagement) {
            $live = @()
            try { $live = @(ExchangeOnlineManagement\Get-ConnectionInformation | Where-Object { $_.State -eq 'Connected' -and -not $_.IsEopSession }) } catch { }
            if ($live.Count) {
                Write-Host "Tech Kit: reusing the Exchange Online connection ($($live[0].UserPrincipalName))." -ForegroundColor DarkGray
                return
            }
        }
        $extra = @{}
        $cmd = Get-Command -Name 'ExchangeOnlineManagement\Connect-ExchangeOnline' -ErrorAction Stop
        if ($cmd.Parameters.ContainsKey('DisableWAM') -and $args -notcontains '-DisableWAM') { $extra.DisableWAM = $true }
        ExchangeOnlineManagement\Connect-ExchangeOnline @args @extra
    }
}

function Get-TKAllScopes {
    # Union of the Graph scopes every script in the library declares.
    $all = @(Get-TKScript | ForEach-Object { $_.Scopes } | Where-Object { $_ } | Sort-Object -Unique)
    if ($all.Count -eq 0) { $all = @('User.Read.All') }
    $all
}

# ----------------------------------------------------------------------------
#  Delegation, approvals and audit (Adaxes-style)
# ----------------------------------------------------------------------------

function Get-TKRoles {
    # Roles live in Config\roles.json. They filter what a technician sees and can run in
    # the Tech Kit window. They do not grant or remove rights: scripts always run with the
    # signed-in account's own permissions.
    $file = Join-Path (Get-TKPath Config) 'roles.json'
    $roles = [ordered]@{}
    $approval = [ordered]@{ ApproverGroup = '' }
    if (Test-Path -LiteralPath $file) {
        try {
            $json = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $json.Roles.PSObject.Properties) { $roles[$p.Name] = ConvertTo-TKHashtable $p.Value }
            if ($json.Approval) { $approval = ConvertTo-TKHashtable $json.Approval }
        } catch {
            Write-Warning "roles.json could not be read: $($_.Exception.Message)"
        }
    }
    if (-not $roles.Contains('Administrator')) {
        $roles['Administrator'] = [ordered]@{
            Description = 'Everything'; Allow = @('*'); Deny = @(); AllowChanges = $true; AllowTerminal = $true
            AllowEditing = $true; RequireTicket = $false; RequireApproval = $false
        }
    }
    [pscustomobject]@{ Roles = $roles; Approval = $approval }
}

function Get-TKRoleValue {
    param($Role, [string]$Key, $Default)
    if ($Role -and $Role.Contains($Key) -and $null -ne $Role[$Key]) { return $Role[$Key] }
    $Default
}

function Test-TKRoleAllows {
    param($Role, $Script)
    if (-not $Role) { return $true }
    $keys = @($Script.Name, "$($Script.Category)\$($Script.Name)", $Script.Id)
    $ok = $false
    foreach ($pat in @(Get-TKRoleValue $Role 'Allow' @('*'))) { foreach ($k in $keys) { if ($k -like $pat) { $ok = $true } } }
    foreach ($pat in @(Get-TKRoleValue $Role 'Deny' @())) { foreach ($k in $keys) { if ($k -like $pat) { $ok = $false } } }
    if ($ok -and $Script.Changes -and -not (Get-TKRoleValue $Role 'AllowChanges' $true)) { $ok = $false }
    $ok
}

function Test-TKApprover {
    # Checks a second person's credentials and (optionally) membership of an approver group.
    # Works against the domain, or the local PC for .\user or PCNAME\user accounts.
    param([Parameter(Mandatory)][System.Management.Automation.PSCredential]$Credential, [string]$Group)
    Add-Type -AssemblyName System.DirectoryServices.AccountManagement
    $am = 'System.DirectoryServices.AccountManagement'
    $user = $Credential.UserName
    $pass = $Credential.GetNetworkCredential().Password
    $domain = $null
    $machine = $false
    if ($user -match '^(.+?)\\(.+)$') {
        $domain = $Matches[1]; $user = $Matches[2]
        if ($domain -eq '.' -or $domain -eq $env:COMPUTERNAME) { $machine = $true; $domain = $null }
    }
    try {
        if ($machine) { $ctx = New-Object "$am.PrincipalContext"([System.DirectoryServices.AccountManagement.ContextType]::Machine) }
        elseif ($domain) { $ctx = New-Object "$am.PrincipalContext"([System.DirectoryServices.AccountManagement.ContextType]::Domain, $domain) }
        else { $ctx = New-Object "$am.PrincipalContext"([System.DirectoryServices.AccountManagement.ContextType]::Domain) }
    } catch {
        return [pscustomobject]@{ Ok = $false; Approver = ''; Reason = "Cannot reach the domain to check the approver: $($_.Exception.Message)" }
    }
    if (-not $ctx.ValidateCredentials($user, $pass)) {
        return [pscustomobject]@{ Ok = $false; Approver = ''; Reason = 'Wrong user name or password.' }
    }
    $up = [System.DirectoryServices.AccountManagement.UserPrincipal]::FindByIdentity($ctx, $user)
    if (-not $up) { return [pscustomobject]@{ Ok = $false; Approver = ''; Reason = 'The approver account was not found.' } }
    if ($up.SamAccountName -eq $env:USERNAME) {
        return [pscustomobject]@{ Ok = $false; Approver = ''; Reason = 'The approver has to be a different person from the one running the script.' }
    }
    if ($Group) {
        $member = $false
        try {
            foreach ($g in $up.GetAuthorizationGroups()) { if ($g.SamAccountName -eq $Group -or $g.Name -eq $Group) { $member = $true; break } }
        } catch {
            foreach ($g in $up.GetGroups()) { if ($g.SamAccountName -eq $Group -or $g.Name -eq $Group) { $member = $true; break } }
        }
        if (-not $member) { return [pscustomobject]@{ Ok = $false; Approver = ''; Reason = "$($up.SamAccountName) is not in the approver group '$Group'." } }
    }
    [pscustomobject]@{ Ok = $true; Approver = "$($ctx.Name)\$($up.SamAccountName)"; Reason = '' }
}

function Write-TKAudit {
    # Appends one row to Logs\audit.csv on the USB.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Entry)
    $dir = Get-TKPath Logs
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    $file = Join-Path $dir 'audit.csv'
    [pscustomobject]$Entry | Export-Csv -LiteralPath $file -Append -NoTypeInformation -Encoding UTF8
}

function Get-TKIdentityRules {
    # Loads Config\Identity\<Profile>.json (naming conventions, departments, groups, licenses).
    param([Parameter(Mandatory)][string]$Name)
    $file = Join-Path (Get-TKPath Config) "Identity\$Name.json"
    if (-not (Test-Path -LiteralPath $file)) { throw "Rules file not found: $file. Copy Config\Identity\Example.json and edit it." }
    ConvertTo-TKHashtable (Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json)
}

# ----------------------------------------------------------------------------
#  Target helpers
# ----------------------------------------------------------------------------

function Get-TKADComputer {
    # Finds computers in Active Directory with plain LDAP (no RSAT needed).
    [CmdletBinding()]
    param(
        [string]$NameFilter = '*',
        [string]$SearchBase = '',
        [switch]$ServersOnly,
        [switch]$IncludeDisabled
    )
    Add-Type -AssemblyName System.DirectoryServices -ErrorAction SilentlyContinue
    $safe = ($NameFilter -replace '[^\w\-\*\.]', '')
    if (-not $safe) { $safe = '*' }
    $filter = "(&(objectCategory=computer)(name=$safe)"
    if (-not $IncludeDisabled) { $filter += '(!(userAccountControl:1.2.840.113556.1.4.803:=2))' }
    if ($ServersOnly) { $filter += '(operatingSystem=*Server*)' }
    $filter += ')'
    $root = if ($SearchBase) { New-Object System.DirectoryServices.DirectoryEntry("LDAP://$SearchBase") } else { New-Object System.DirectoryServices.DirectoryEntry }
    $searcher = New-Object System.DirectoryServices.DirectorySearcher($root, $filter)
    $searcher.PageSize = 1000
    foreach ($prop in @('name', 'dnshostname', 'operatingsystem')) { $null = $searcher.PropertiesToLoad.Add($prop) }
    $searcher.FindAll() | ForEach-Object {
        [pscustomobject]@{
            Name            = [string]($_.Properties['name'] | Select-Object -First 1)
            DnsHostName     = [string]($_.Properties['dnshostname'] | Select-Object -First 1)
            OperatingSystem = [string]($_.Properties['operatingsystem'] | Select-Object -First 1)
        }
    } | Sort-Object Name
}

Export-ModuleMember -Function *
