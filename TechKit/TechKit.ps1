<#
    Tech Kit - a portable, graphical PowerShell toolkit.
    Start it with TechKit.cmd (double-click). Works with Windows PowerShell 5.1
    and PowerShell 7 on Windows 10/11 and Windows Server.
#>
param(
    [switch]$NoRelaunch
)

$ErrorActionPreference = 'Stop'
$script:Root = $PSScriptRoot
$script:CoreDir = Join-Path $PSScriptRoot 'Core'
$script:GuiDir = Join-Path $script:CoreDir 'Gui'
$script:SelfPath = $PSCommandPath

function Show-TKFatal {
    param([string]$Message)
    try {
        $log = Join-Path $script:Root 'Config\startup-error.log'
        Add-Content -LiteralPath $log -Value ("[{0}] {1}" -f (Get-Date -Format s), $Message) -ErrorAction SilentlyContinue
    } catch { }
    try {
        Add-Type -AssemblyName PresentationFramework
        $null = [System.Windows.MessageBox]::Show($Message, 'Tech Kit', 'OK', 'Error')
    } catch {
        Write-Host $Message -ForegroundColor Red
    }
}

# ---------------------------------------------------------------------------
#  Startup checks
# ---------------------------------------------------------------------------
try {
    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
        throw "PowerShell is running in $($ExecutionContext.SessionState.LanguageMode) mode on this PC (usually AppLocker or WDAC policy). Tech Kit needs FullLanguage mode to show its window."
    }
    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        $exe = (Get-Process -Id $PID).Path
        Start-Process -FilePath $exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`" -NoRelaunch"
        return
    }

    Import-Module (Join-Path $script:CoreDir 'TechKit.Core.psm1') -Force -DisableNameChecking
    Initialize-TKEnvironment
    $script:Settings = Get-TKSettings
    $script:Shell = Get-TKShellInfo

    if (-not $NoRelaunch) {
        $want = $null
        $pref = [string]$script:Settings.PreferredShell
        $isCore = $PSVersionTable.PSEdition -eq 'Core'
        if ($pref -eq 'Windows PowerShell 5.1') {
            if ($isCore -and $script:Shell.WindowsPS) { $want = $script:Shell.WindowsPS }
        } elseif (-not $isCore -and $script:Shell.Pwsh) {
            # Auto and "PowerShell 7" both prefer PowerShell 7 when it is available
            $want = $script:Shell.Pwsh
        }
        if ($want) {
            Start-Process -FilePath $want -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`" -NoRelaunch"
            return
        }
    }

    Import-TKHostType
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
} catch {
    Show-TKFatal ("Tech Kit could not start.`n`n" + $_.Exception.Message)
    return
}

$script:IsAdmin = Test-TKAdmin
$script:Scripts = @()
$script:Selected = $null
$script:Job = $null
$script:RunAsCred = $null
$script:ParamControls = [ordered]@{}
$script:History = New-Object System.Collections.Generic.List[string]
$script:HistoryIndex = -1
$script:Completion = $null
$script:LastRun = $null
$script:RunText = New-Object System.Text.StringBuilder
$script:RunErrors = 0
$script:KindBrush = @{}
$script:ConsoleBrush = @{}
$script:CurrentCategory = 'all'

# ---------------------------------------------------------------------------
#  WPF helpers
# ---------------------------------------------------------------------------

function Read-TKWindow {
    param([string]$Name)
    $path = Join-Path $script:GuiDir $Name
    $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    $window = [System.Windows.Markup.XamlReader]::Parse($text)
    $controls = @{ Window = $window }
    foreach ($m in [regex]::Matches($text, 'x:Name="(\w+)"')) {
        $n = $m.Groups[1].Value
        $controls[$n] = $window.FindName($n)
    }
    $controls
}

function New-TKThickness {
    param([double]$Left, [double]$Top, [double]$Right, [double]$Bottom)
    New-Object System.Windows.Thickness($Left, $Top, $Right, $Bottom)
}

function ConvertTo-TKColor {
    param([string]$Hex, [string]$Fallback = '#808080')
    try { return [System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString($Hex) }
    catch { return [System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString($Fallback) }
}

function New-TKBrush {
    param([System.Windows.Media.Color]$Color)
    $b = New-Object System.Windows.Media.SolidColorBrush($Color)
    $b.Freeze()
    $b
}

function Join-TKColor {
    param([System.Windows.Media.Color]$A, [System.Windows.Media.Color]$B, [double]$T)
    [System.Windows.Media.Color]::FromRgb(
        [byte]([Math]::Round($A.R + ($B.R - $A.R) * $T)),
        [byte]([Math]::Round($A.G + ($B.G - $A.G) * $T)),
        [byte]([Math]::Round($A.B + ($B.B - $A.B) * $T)))
}

function Set-TKResourceRef {
    param($Element, [System.Windows.DependencyProperty]$Property, [string]$Key)
    $Element.SetResourceReference($Property, $Key)
}

function Update-TKRender {
    # Lets WPF repaint before a short blocking operation.
    try { $null = $script:Win.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Background, [Action] { }) } catch { }
}

function Set-TKTheme {
    param([System.Collections.IDictionary]$Colors)
    $map = [ordered]@{
        BgBrush = 'Background'; PanelBrush = 'Panel'; CardBrush = 'Card'; LineBrush = 'Border'
        TextBrush = 'Text'; SubTextBrush = 'SubText'; AccentBrush = 'Accent'; AccentTextBrush = 'AccentText'
        OutBgBrush = 'OutputBackground'; OutputBrush = 'Output'; InfoBrush = 'Info'; SuccessBrush = 'Success'
        WarningBrush = 'Warning'; ErrorBrush = 'Error'; VerboseBrush = 'Verbose'; CommandBrush = 'Command'
    }
    $c = @{}
    foreach ($key in $map.Keys) {
        $c[$map[$key]] = ConvertTo-TKColor ([string]$Colors[$map[$key]])
        $script:ThemeDict[$key] = New-TKBrush $c[$map[$key]]
    }
    $script:ThemeDict['HoverBrush'] = New-TKBrush (Join-TKColor $c.Card $c.Accent 0.12)
    $script:ThemeDict['SelectBrush'] = New-TKBrush (Join-TKColor $c.Card $c.Accent 0.26)

    $b = @{}
    foreach ($k in @('Output', 'Info', 'Success', 'Warning', 'Error', 'Verbose', 'Command')) { $b[$k] = New-TKBrush $c[$k] }
    $script:KindBrush = @{
        Output = $b.Output; Host = $b.Output; Error = $b.Error; Warning = $b.Warning; Verbose = $b.Verbose
        Debug = $b.Verbose; Info = $b.Info; Success = $b.Success; System = $b.Command; Command = $b.Command
    }
    # ConsoleColor -> theme color, so Write-Host -ForegroundColor follows your theme
    $script:ConsoleBrush = @{
        0 = $b.Verbose; 1 = $b.Info; 2 = $b.Success; 3 = $b.Info; 4 = $b.Error; 5 = $b.Command; 6 = $b.Warning; 7 = $b.Output
        8 = $b.Verbose; 9 = $b.Info; 10 = $b.Success; 11 = $b.Info; 12 = $b.Error; 13 = $b.Command; 14 = $b.Warning; 15 = $b.Output
    }
}

function Get-TKMonoFont {
    param([string]$Name)
    if (-not $Name) { $Name = 'Cascadia Mono' }
    New-Object System.Windows.Media.FontFamily("$Name, Cascadia Mono, Consolas, Courier New")
}

function Set-TKFonts {
    $font = Get-TKMonoFont $script:Settings.FontFamily
    $size = [double]$script:Settings.FontSize
    if ($size -lt 8) { $size = 13 }
    foreach ($box in @($script:Boxes.output, $script:Boxes.terminal)) {
        $box.Rtb.FontFamily = $font
        $box.Rtb.FontSize = $size
        $box.Rtb.Document.FontFamily = $font
        $box.Rtb.Document.FontSize = $size
    }
    $ui.TxtTermInput.FontFamily = $font
    $ui.TxtTermInput.FontSize = $size
    $ui.TxtPrompt.FontFamily = $font
    $ui.TxtPrompt.FontSize = $size
}

# ---------------------------------------------------------------------------
#  Output panes
# ---------------------------------------------------------------------------

function New-TKOutputBox {
    param($Rtb)
    $doc = New-Object System.Windows.Documents.FlowDocument
    $doc.PagePadding = New-TKThickness 0 0 0 0
    $para = New-Object System.Windows.Documents.Paragraph
    $para.Margin = New-TKThickness 0 0 0 0
    $doc.Blocks.Add($para)
    $Rtb.Document = $doc
    @{ Rtb = $Rtb; Para = $para; Lines = 0 }
}

function Set-TKWrap {
    param([bool]$Wrap)
    foreach ($box in @($script:Boxes.output, $script:Boxes.terminal)) {
        if ($Wrap) {
            $box.Rtb.Document.PageWidth = [double]::NaN
            $box.Rtb.HorizontalScrollBarVisibility = 'Disabled'
        } else {
            $box.Rtb.Document.PageWidth = 4200
            $box.Rtb.HorizontalScrollBarVisibility = 'Auto'
        }
    }
}

function Clear-TKBox {
    param($Box)
    $Box.Para.Inlines.Clear()
    $Box.Lines = 0
}

function Add-TKText {
    param($Box, [string]$Text, $Brush, [bool]$NewLine = $true)
    if ($null -eq $Text) { $Text = '' }
    $Text = $Text.Replace("`r`n", "`n").Replace("`r", '')
    $parts = $Text.Split("`n")
    for ($i = 0; $i -lt $parts.Length; $i++) {
        if ($parts[$i].Length -gt 0) {
            $run = [System.Windows.Documents.Run]::new($parts[$i])
            $run.Foreground = $Brush
            $Box.Para.Inlines.Add($run)
        }
        if ($i -lt $parts.Length - 1) {
            $Box.Para.Inlines.Add([System.Windows.Documents.LineBreak]::new())
            $Box.Lines++
        }
    }
    if ($NewLine) {
        $Box.Para.Inlines.Add([System.Windows.Documents.LineBreak]::new())
        $Box.Lines++
    }
    if ($Box.Lines -gt 30000) {
        $removed = 0
        while ($removed -lt 6000 -and $Box.Para.Inlines.Count -gt 0) {
            $first = $Box.Para.Inlines.FirstInline
            if ($first -is [System.Windows.Documents.LineBreak]) { $removed++ }
            $null = $Box.Para.Inlines.Remove($first)
        }
        $Box.Lines -= $removed
    }
}

function Add-TKLink {
    param($Box, [string]$Label, [string]$Target)
    $link = New-Object System.Windows.Documents.Hyperlink
    $null = $link.Inlines.Add((New-Object System.Windows.Documents.Run($Label)))
    $link.Foreground = $script:KindBrush.Info
    $link.Tag = $Target
    $link.Cursor = [System.Windows.Input.Cursors]::Hand
    $link.Add_Click({ param($sender, $e) try { Start-Process -FilePath ([string]$sender.Tag) } catch { } })
    $Box.Para.Inlines.Add($link)
    $Box.Para.Inlines.Add((New-Object System.Windows.Documents.LineBreak))
    $Box.Lines++
}

function Write-TKLine {
    # Writes a line from the GUI itself (not from a script).
    param([string]$Text, [string]$Kind = 'Output', [string]$Channel = 'output', [switch]$NoNewLine)
    $box = $script:Boxes[$Channel]
    $brush = $script:KindBrush[$Kind]
    if (-not $brush) { $brush = $script:KindBrush.Output }
    $atEnd = Test-TKAtEnd $box
    Add-TKText -Box $box -Text $Text -Brush $brush -NewLine (-not $NoNewLine)
    if ($Channel -eq 'output') { $null = $script:RunText.Append($Text); if (-not $NoNewLine) { $null = $script:RunText.Append("`r`n") } }
    if ($atEnd) { $box.Rtb.ScrollToEnd() }
}

function Test-TKAtEnd {
    param($Box)
    $r = $Box.Rtb
    if ($r.ExtentHeight -le $r.ViewportHeight) { return $true }
    ($r.VerticalOffset + $r.ViewportHeight) -ge ($r.ExtentHeight - 40)
}

function Get-TKItemBrush {
    param($Item)
    $kind = [string]$Item.Kind
    $color = [int]$Item.Color
    if (($kind -eq 'Host' -or $kind -eq 'Output') -and $color -ge 0 -and $color -ne 7) {
        $b = $script:ConsoleBrush[$color]
        if ($b) { return $b }
    }
    $b = $script:KindBrush[$kind]
    if ($b) { return $b }
    $script:KindBrush.Output
}

function Write-TKItems {
    param($Items)
    if (-not $Items) { return }
    $touched = @{}
    $atEnd = @{ output = (Test-TKAtEnd $script:Boxes.output); terminal = (Test-TKAtEnd $script:Boxes.terminal) }
    foreach ($it in $Items) {
        $channel = [string]$it.Channel
        if ($channel -ne 'terminal') { $channel = 'output' }
        $kind = [string]$it.Kind
        if ($kind -eq 'Progress') {
            Update-TKProgress $it
        } elseif ($kind -eq 'Clear') {
            Clear-TKBox $script:Boxes[$channel]
        } elseif ($kind -eq 'End') {
            # handled by Read-TKElevatedOutput
        } else {
            $box = $script:Boxes[$channel]
            Add-TKText -Box $box -Text ([string]$it.Text) -Brush (Get-TKItemBrush $it) -NewLine ([bool]$it.NewLine)
            $touched[$channel] = $true
            if ($channel -eq 'output') {
                $null = $script:RunText.Append([string]$it.Text)
                if ($it.NewLine) { $null = $script:RunText.Append("`r`n") }
                if ($kind -eq 'Error') { $script:RunErrors++ }
            }
        }
    }
    foreach ($ch in $touched.Keys) {
        if ($atEnd[$ch]) { $script:Boxes[$ch].Rtb.ScrollToEnd() }
    }
}

function Update-TKProgress {
    param($Item)
    if ($Item.Completed) {
        $ui.PrgStatus.Visibility = 'Collapsed'
        $ui.TxtProgress.Text = ''
        return
    }
    $ui.PrgStatus.Visibility = 'Visible'
    if ([int]$Item.Percent -ge 0) {
        $ui.PrgStatus.IsIndeterminate = $false
        $ui.PrgStatus.Value = [Math]::Min(100, [int]$Item.Percent)
    } else {
        $ui.PrgStatus.IsIndeterminate = $true
    }
    $t = [string]$Item.Activity
    if ($Item.Text) { $t = "$t - $($Item.Text)" }
    if ($t.Length -gt 90) { $t = $t.Substring(0, 87) + '...' }
    $ui.TxtProgress.Text = $t
}

function Get-TKBoxText {
    param($Box)
    $doc = $Box.Rtb.Document
    (New-Object System.Windows.Documents.TextRange($doc.ContentStart, $doc.ContentEnd)).Text
}

# ---------------------------------------------------------------------------
#  Dialogs
# ---------------------------------------------------------------------------

function New-TKWindowBase {
    param([string]$Title, [double]$Width = 480)
    $w = New-Object System.Windows.Window
    $w.Title = $Title
    $w.Width = $Width
    $w.SizeToContent = 'Height'
    $w.ResizeMode = 'NoResize'
    $w.ShowInTaskbar = $false
    $w.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI')
    $w.FontSize = 13
    Set-TKResourceRef $w ([System.Windows.Controls.Control]::BackgroundProperty) 'BgBrush'
    Set-TKResourceRef $w ([System.Windows.Controls.Control]::ForegroundProperty) 'TextBrush'
    if ($script:Win -and $script:Win.IsLoaded) {
        $w.Owner = $script:Win
        $w.WindowStartupLocation = 'CenterOwner'
    } else {
        $w.WindowStartupLocation = 'CenterScreen'
    }
    $w
}

function Show-TKDialog {
    param(
        [string]$Title = 'Tech Kit',
        [string]$Message = '',
        [string]$Detail = '',
        [string[]]$Buttons = @('OK'),
        [int]$Default = 0,
        [ValidateSet('None', 'Text', 'Password', 'Credential')][string]$InputKind = 'None',
        [string]$InputDefault = '',
        [string]$UserName = '',
        [double]$Width = 500
    )
    $w = New-TKWindowBase -Title $Title -Width $Width
    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = New-TKThickness 22 18 22 16

    $head = New-Object System.Windows.Controls.TextBlock
    $head.Text = $Title
    $head.FontSize = 16
    $head.FontWeight = [System.Windows.FontWeights]::SemiBold
    $head.TextWrapping = 'Wrap'
    $null = $panel.Children.Add($head)

    if ($Message) {
        $msg = New-Object System.Windows.Controls.TextBlock
        $msg.Text = $Message
        $msg.TextWrapping = 'Wrap'
        $msg.Margin = New-TKThickness 0 10 0 0
        $msg.LineHeight = 19
        $null = $panel.Children.Add($msg)
    }
    if ($Detail) {
        $det = New-Object System.Windows.Controls.TextBox
        $det.Text = $Detail
        $det.IsReadOnly = $true
        $det.TextWrapping = 'Wrap'
        $det.MaxHeight = 220
        $det.VerticalScrollBarVisibility = 'Auto'
        $det.FontFamily = Get-TKMonoFont $script:Settings.FontFamily
        $det.Margin = New-TKThickness 0 10 0 0
        $null = $panel.Children.Add($det)
    }

    $txt = $null; $pwd = $null; $usr = $null
    if ($InputKind -eq 'Text') {
        $txt = New-Object System.Windows.Controls.TextBox
        $txt.Text = $InputDefault
        $txt.Margin = New-TKThickness 0 12 0 0
        $null = $panel.Children.Add($txt)
    } elseif ($InputKind -eq 'Password') {
        $pwd = New-Object System.Windows.Controls.PasswordBox
        $pwd.Margin = New-TKThickness 0 12 0 0
        $null = $panel.Children.Add($pwd)
    } elseif ($InputKind -eq 'Credential') {
        $l1 = New-Object System.Windows.Controls.TextBlock
        $l1.Text = 'User name  (DOMAIN\user or user@domain)'
        $l1.Margin = New-TKThickness 0 12 0 4
        $null = $panel.Children.Add($l1)
        $usr = New-Object System.Windows.Controls.TextBox
        $usr.Text = $UserName
        $null = $panel.Children.Add($usr)
        $l2 = New-Object System.Windows.Controls.TextBlock
        $l2.Text = 'Password'
        $l2.Margin = New-TKThickness 0 10 0 4
        $null = $panel.Children.Add($l2)
        $pwd = New-Object System.Windows.Controls.PasswordBox
        $null = $panel.Children.Add($pwd)
    }

    $row = New-Object System.Windows.Controls.WrapPanel
    $row.HorizontalAlignment = 'Right'
    $row.Margin = New-TKThickness 0 18 0 0
    for ($i = 0; $i -lt $Buttons.Count; $i++) {
        $b = New-Object System.Windows.Controls.Button
        $b.Content = $Buttons[$i]
        $b.Tag = $Buttons[$i]
        $b.MinWidth = 84
        $b.Margin = New-TKThickness 6 0 0 0
        if ($i -eq $Default) {
            $accent = [System.Windows.Application]::Current.TryFindResource('AccentButton')
            if ($accent) { $b.Style = $accent }
            $b.IsDefault = $true
        }
        if ($Buttons[$i] -in @('Cancel', 'No', 'Close')) { $b.IsCancel = $true }
        $b.Add_Click({
            param($sender, $e)
            $win = [System.Windows.Window]::GetWindow($sender)
            $win.Tag = [string]$sender.Tag
            $win.Close()
        })
        $null = $row.Children.Add($b)
    }
    $null = $panel.Children.Add($row)
    $w.Content = $panel
    $w.Add_ContentRendered({
        param($sender, $e)
        $first = $null
        foreach ($c in $sender.Content.Children) {
            if ($c -is [System.Windows.Controls.TextBox] -and -not $c.IsReadOnly) { $first = $c; break }
            if ($c -is [System.Windows.Controls.PasswordBox]) { $first = $c; break }
        }
        if ($first) { $null = $first.Focus() }
    })
    $null = $w.ShowDialog()

    $result = @{ Button = $w.Tag; Text = $null; Secure = $null; Credential = $null; UserName = $null }
    if ($txt) { $result.Text = $txt.Text }
    if ($pwd) { $result.Secure = $pwd.SecurePassword }
    if ($usr) {
        $result.UserName = $usr.Text.Trim()
        if ($result.UserName) {
            $result.Credential = New-Object System.Management.Automation.PSCredential($result.UserName, $pwd.SecurePassword)
        }
    }
    $result
}

function Show-TKMessage {
    param([string]$Message, [string]$Title = 'Tech Kit', [string]$Detail = '')
    $null = Show-TKDialog -Title $Title -Message $Message -Detail $Detail -Buttons @('OK')
}

function Show-TKPromptRequest {
    # Answers Read-Host / Get-Credential / choice prompts coming from a running script.
    param($Request)
    try {
        switch ($Request.Type) {
            'ReadLine' {
                $r = Show-TKDialog -Title $Request.Caption -Message ("The script is asking for input:`n" + $Request.Message) -InputKind Text -Buttons @('OK', 'Cancel')
                if ($r.Button -eq 'OK') { $Request.Response = [string]$r.Text } else { $Request.Cancelled = $true }
            }
            'Secure' {
                $r = Show-TKDialog -Title $Request.Caption -Message ("The script is asking for a secret:`n" + $Request.Message) -InputKind Password -Buttons @('OK', 'Cancel')
                if ($r.Button -eq 'OK') { $Request.Response = $r.Secure } else { $Request.Cancelled = $true }
            }
            'Credential' {
                $r = Show-TKDialog -Title $Request.Caption -Message $Request.Message -InputKind Credential -UserName $Request.UserName -Buttons @('OK', 'Cancel')
                if ($r.Button -eq 'OK' -and $r.Credential) { $Request.Response = $r.Credential } else { $Request.Cancelled = $true }
            }
            'Choice' {
                $labels = @($Request.Choices | ForEach-Object { ([string]$_).Replace('&', '') })
                $help = @()
                for ($i = 0; $i -lt $labels.Count; $i++) {
                    if ($Request.ChoiceHelp[$i]) { $help += ('{0}: {1}' -f $labels[$i], $Request.ChoiceHelp[$i]) }
                }
                $def = [Math]::Max(0, $Request.DefaultChoice)
                $r = Show-TKDialog -Title $Request.Caption -Message $Request.Message -Detail ($help -join "`n") -Buttons $labels -Default $def -Width 560
                $idx = [array]::IndexOf($labels, [string]$r.Button)
                if ($idx -ge 0) { $Request.Response = $idx } else { $Request.Cancelled = $true }
            }
            default { $Request.Cancelled = $true }
        }
    } catch {
        $Request.Cancelled = $true
    } finally {
        $null = $Request.Done.Set()
    }
}

# ---------------------------------------------------------------------------
#  Background work
# ---------------------------------------------------------------------------

function Set-TKBusy {
    param([bool]$Busy, [string]$Label = '')
    $script:IsBusy = $Busy
    $ui.BtnStop.IsEnabled = $Busy
    $ui.BtnRun.IsEnabled = (-not $Busy) -and ($null -ne $script:Selected)
    $ui.BtnWhatIf.IsEnabled = (-not $Busy) -and $script:Selected -and $script:Selected.WhatIf
    if ($Busy) {
        $ui.TxtStatus.Text = "Running: $Label"
    } else {
        $ui.PrgStatus.Visibility = 'Collapsed'
        $ui.TxtProgress.Text = ''
        Update-TKStatusText
    }
}

function Update-TKStatusText {
    $count = @($script:Visible).Count
    $cats = @($script:Visible | Select-Object -ExpandProperty CategoryFolder -Unique).Count
    $roleText = ''
    if ($script:RoleName -and $script:RoleName -ne 'Administrator') { $roleText = "  |  Role: $script:RoleName" }
    $ui.TxtStatus.Text = "Ready  |  $count scripts in $cats categories$roleText  |  Library: $(Get-TKPath Scripts)"
}

function Start-TKWorker {
    param(
        [Parameter(Mandatory)][string]$Script,
        [object[]]$Arguments = @(),
        [string]$Channel = 'output',
        [switch]$GlobalScope,
        [switch]$NoCollect,
        [scriptblock]$OnComplete,
        [string]$Label = 'task',
        $Context = $null
    )
    if ($script:Job) {
        Write-TKLine -Text 'Something is already running. Wait for it to finish or press Stop.' -Kind Warning -Channel $Channel
        return $false
    }
    $ps = [PowerShell]::Create()
    $ps.Runspace = $script:Worker
    $null = $ps.AddScript($Script, (-not $GlobalScope))
    foreach ($a in $Arguments) { $null = $ps.AddArgument($a) }
    $ps.Commands.Commands[0].MergeMyResults([System.Management.Automation.Runspaces.PipelineResultTypes]::All, [System.Management.Automation.Runspaces.PipelineResultTypes]::Output)
    $null = $ps.AddCommand('Out-TKSink')
    if ($NoCollect) { $null = $ps.AddParameter('NoCollect', $true) }
    $script:Sink.Channel = $Channel
    $script:Job = @{
        Kind = 'worker'; PS = $ps; Handle = $null; OnComplete = $OnComplete; Started = [DateTime]::Now
        Channel = $Channel; Label = $Label; Context = $Context; Stopped = $false
    }
    $script:Job.Handle = $ps.BeginInvoke()
    Set-TKBusy $true $Label
    $true
}

function Invoke-TKWorkerSync {
    # Quick call into the worker session while it is idle (status checks, exports).
    param([string]$Script, [object[]]$Arguments = @())
    if ($script:Job -and $script:Job.Kind -eq 'worker') { throw 'The background session is busy.' }
    $ps = [PowerShell]::Create()
    $ps.Runspace = $script:Worker
    try {
        $null = $ps.AddScript($Script)
        foreach ($a in $Arguments) { $null = $ps.AddArgument($a) }
        $out = $ps.Invoke()
        if ($ps.Streams.Error.Count -gt 0) { throw $ps.Streams.Error[0].Exception }
        , $out
    } finally {
        $ps.Dispose()
    }
}

function Stop-TKJob {
    $job = $script:Job
    if (-not $job) { return }
    $job.Stopped = $true
    if ($job.Kind -eq 'worker') {
        Write-TKLine -Text 'Stopping...' -Kind Warning -Channel $job.Channel
        $null = $job.PS.BeginStop($null, $null)
    } elseif ($job.Kind -eq 'elevated') {
        Write-TKLine -Text 'Stopping the elevated script...' -Kind Warning
        try { Set-Content -LiteralPath $job.StopFile -Value 'stop' } catch { }
    }
}

function Complete-TKJob {
    $job = $script:Job
    $script:Job = $null
    $ok = $true
    if ($job.Kind -eq 'worker') {
        try {
            $null = $job.PS.EndInvoke($job.Handle)
        } catch {
            $ex = $_.Exception
            while ($ex.InnerException -and $ex -is [System.Management.Automation.MethodInvocationException]) { $ex = $ex.InnerException }
            if (-not $job.Stopped -and $ex -isnot [System.Management.Automation.PipelineStoppedException]) {
                $ok = $false
                $script:Sink.Add('Error', $ex.Message)
            }
        }
        foreach ($e in $job.PS.Streams.Error) { $script:Sink.Add('Error', $e.ToString()) }
        try { $job.PS.Dispose() } catch { }
        try { $script:Sink.Channel = 'output' } catch { }
    } elseif ($job.Kind -eq 'elevated') {
        Read-TKElevatedOutput $job
        if (-not $job.Ended) {
            $script:Sink.Add('Warning', 'The elevated window closed without finishing.')
            $ok = $false
        }
        if ($job.EndState -eq 'failed') { $ok = $false }
        if (Test-Path -LiteralPath $job.ResultFile) {
            try { $null = Invoke-TKWorkerSync -Script 'param($p) Import-TKResult -Path $p' -Arguments @($job.ResultFile) } catch { }
        } else {
            try { $null = Invoke-TKWorkerSync -Script 'Import-TKResult -Path $null' } catch { }
        }
        try { Remove-Item -LiteralPath $job.Dir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
    Write-TKItems ($script:Sink.Drain(1000000))
    Set-TKBusy $false
    if ($job.OnComplete) {
        try { & $job.OnComplete $ok $job } catch { Write-TKLine -Text ("Tech Kit: " + $_.Exception.Message) -Kind Error }
    }
}

function Start-TKElevatedRun {
    param([hashtable]$InvokeArgs, [string]$Label, [scriptblock]$OnComplete, $Context)
    $dir = Join-Path $env:TEMP ('TechKit\' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $dir -Force
    $key = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($key)

    $protect = {
        param($v)
        if ($v -is [securestring]) { return @{ __tkSecure = (ConvertFrom-SecureString -SecureString $v -Key $key) } }
        if ($v -is [System.Management.Automation.PSCredential]) {
            return @{ __tkCredUser = $v.UserName; __tkCredPass = (ConvertFrom-SecureString -SecureString $v.Password -Key $key) }
        }
        $v
    }
    $params = @{}
    foreach ($k in $InvokeArgs.Parameters.Keys) { $params[$k] = & $protect $InvokeArgs.Parameters[$k] }
    $inv = @{}
    foreach ($k in $InvokeArgs.Keys) { if ($k -ne 'Credential') { $inv[$k] = $InvokeArgs[$k] } }
    $inv.Parameters = $params
    if ($InvokeArgs.Credential) { $inv.Credential = & $protect $InvokeArgs.Credential }

    $job = @{
        Invoke = $inv; OutFile = (Join-Path $dir 'out.jsonl'); ResultFile = (Join-Path $dir 'results.xml')
        StopFile = (Join-Path $dir 'stop'); Key = $key
    }
    $jobFile = Join-Path $dir 'job.xml'
    Export-Clixml -InputObject $job -LiteralPath $jobFile
    [IO.File]::WriteAllText($job.OutFile, '')

    $exe = (Get-Process -Id $PID).Path
    $runner = Join-Path $script:CoreDir 'ElevatedRunner.ps1'
    $argLine = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$runner`" -JobFile `"$jobFile`""
    try {
        $proc = Start-Process -FilePath $exe -ArgumentList $argLine -Verb RunAs -WindowStyle Hidden -PassThru
    } catch {
        Write-TKLine -Text 'Administrator approval was cancelled, so the script did not run.' -Kind Warning
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        return $false
    }
    $script:Job = @{
        Kind = 'elevated'; Process = $proc; Dir = $dir; OutFile = $job.OutFile; ResultFile = $job.ResultFile
        StopFile = $job.StopFile; Position = [long]0; Started = [DateTime]::Now; OnComplete = $OnComplete
        Ended = $false; EndState = ''; Label = $Label; Context = $Context; Stopped = $false; Channel = 'output'
    }
    Set-TKBusy $true "$Label (as administrator)"
    $true
}

function Read-TKElevatedOutput {
    param($Job)
    if (-not $Job -or -not (Test-Path -LiteralPath $Job.OutFile)) { return }
    $items = New-Object System.Collections.Generic.List[object]
    $fs = $null
    try {
        $fs = [IO.File]::Open($Job.OutFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $len = $fs.Length - $Job.Position
        if ($len -le 0) { return }
        $null = $fs.Seek($Job.Position, [IO.SeekOrigin]::Begin)
        $buf = New-Object byte[] $len
        $read = $fs.Read($buf, 0, [int]$len)
        $text = [Text.Encoding]::UTF8.GetString($buf, 0, $read)
        $cut = $text.LastIndexOf("`n")
        if ($cut -lt 0) { return }
        $complete = $text.Substring(0, $cut + 1)
        $Job.Position += [Text.Encoding]::UTF8.GetByteCount($complete)
        foreach ($line in $complete.Split("`n")) {
            $l = $line.Trim().Trim([char]0xFEFF)
            if (-not $l) { continue }
            try {
                $o = $l | ConvertFrom-Json
                if ([string]$o.Kind -eq 'End') {
                    $Job.Ended = $true
                    $Job.EndState = [string]$o.Text
                    continue
                }
                $items.Add([pscustomobject]@{
                    Kind = [string]$o.Kind; Text = [string]$o.Text; Color = [int]$o.Color; NewLine = [bool]$o.NewLine
                    Channel = 'output'; Percent = [int]$o.Percent; Activity = [string]$o.Activity; Completed = [bool]$o.Completed
                })
            } catch { }
        }
    } catch {
    } finally {
        if ($fs) { $fs.Dispose() }
    }
    if ($items.Count) { Write-TKItems $items.ToArray() }
}

function Invoke-TKPump {
    # Runs ten times a second on the UI thread.
    $items = $script:Sink.Drain(4000)
    if ($items.Length -gt 0) { Write-TKItems $items }

    $job = $script:Job
    if ($job -and $job.Kind -eq 'elevated') {
        Read-TKElevatedOutput $job
        $exited = $false
        try { $exited = $job.Process.HasExited } catch { $exited = $false }
        if ($job.Ended -or $exited) { Complete-TKJob; return }
    }

    $pr = $script:Sink.PendingPrompt
    if ($pr -and -not $pr.Taken) {
        $pr.Taken = $true
        Show-TKPromptRequest $pr
    }

    $job = $script:Job
    if ($job -and $job.Kind -eq 'worker' -and $job.Handle -and $job.Handle.IsCompleted -and -not $script:Sink.HasItems) {
        Complete-TKJob
        return
    }
    if ($job) {
        $sec = [int]([DateTime]::Now - $job.Started).TotalSeconds
        $ui.TxtStatus.Text = "Running: $($job.Label)   ($sec s)"
    }
}

# ---------------------------------------------------------------------------
#  Library and selection
# ---------------------------------------------------------------------------

function Import-TKLibrary {
    param([string]$SelectId)
    $script:Scripts = @(Get-TKScript | Sort-Object CategoryFolder, Name)
    # The active role decides which scripts are visible
    $script:Visible = @($script:Scripts | Where-Object { Test-TKRoleAllows $script:Role $_ })
    $favs = @($script:Settings.Favorites)
    $cats = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    if ($favs.Count -gt 0) {
        $n = @($script:Visible | Where-Object { $favs -contains $_.Id }).Count
        $cats.Add([pscustomobject]@{ Label = [string][char]0x2605 + '  Favorites'; Count = $n; Key = 'fav' })
    }
    $cats.Add([pscustomobject]@{ Label = 'All scripts'; Count = $script:Visible.Count; Key = 'all' })
    foreach ($g in ($script:Visible | Group-Object CategoryFolder | Sort-Object Name)) {
        $cats.Add([pscustomobject]@{ Label = $g.Group[0].Category; Count = $g.Count; Key = $g.Name })
    }
    $script:Categories = $cats
    $ui.LstCategories.ItemsSource = $cats
    $pick = $cats | Where-Object { $_.Key -eq $script:CurrentCategory } | Select-Object -First 1
    if (-not $pick) { $pick = $cats | Where-Object { $_.Key -eq 'all' } | Select-Object -First 1 }
    $script:SuppressCategoryEvent = $true
    $ui.LstCategories.SelectedItem = $pick
    $script:SuppressCategoryEvent = $false
    $script:CurrentCategory = $pick.Key
    Update-TKScriptList -SelectId $SelectId
    if (-not $script:IsBusy) { Update-TKStatusText }
}

function Update-TKScriptList {
    param([string]$SelectId)
    $search = ''
    if ($ui.TxtSearch.Text) { $search = $ui.TxtSearch.Text.Trim().ToLowerInvariant() }
    $favs = @($script:Settings.Favorites)
    $list = $script:Visible
    $header = 'ALL SCRIPTS'
    if ($script:CurrentCategory -eq 'fav') {
        $list = @($list | Where-Object { $favs -contains $_.Id })
        $header = 'FAVORITES'
    } elseif ($script:CurrentCategory -ne 'all') {
        $list = @($list | Where-Object { $_.CategoryFolder -eq $script:CurrentCategory })
        if ($list.Count) { $header = $list[0].Category.ToUpperInvariant() }
    }
    if ($search) {
        foreach ($word in ($search -split '\s+')) {
            $list = @($list | Where-Object { $_.SearchText -like "*$word*" })
        }
        $header = "SEARCH: $($ui.TxtSearch.Text.Trim())"
    }
    $items = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    $selectItem = $null
    foreach ($s in $list) {
        $star = ''
        if ($favs -contains $s.Id) { $star = [string][char]0x2605 }
        $item = [pscustomobject]@{ Name = $s.Name; Description = $s.Description; Badges = [string[]]@($s.Badges); Star = $star; Script = $s }
        $items.Add($item)
        if ($SelectId -and $s.Id -eq $SelectId) { $selectItem = $item }
    }
    $ui.TxtListHeader.Text = "$header  ($($items.Count))"
    $ui.LstScripts.ItemsSource = $items
    if ($selectItem) {
        $ui.LstScripts.SelectedItem = $selectItem
        $ui.LstScripts.ScrollIntoView($selectItem)
    }
}

function Get-TKFriendlyBadges {
    param($S)
    $b = New-Object System.Collections.Generic.List[string]
    $b.Add($S.Language)
    if ($S.Admin) { $b.Add('Needs admin') }
    if ($S.Changes) { $b.Add('Makes changes') } else { $b.Add('Read-only') }
    if ($S.WhatIf) { $b.Add('Supports What-If') }
    if ($S.SupportsRemote) { $b.Add('Runs on remote computers') }
    foreach ($c in $S.Connect) {
        switch ($c) { 'Graph' { $b.Add('Microsoft Graph') } 'Exchange' { $b.Add('Exchange Online') } 'Compliance' { $b.Add('Security & Compliance') } default { $b.Add($c) } }
    }
    if ($S.Shell.Count) { $b.Add('PowerShell ' + ($S.Shell -join ' / ')) }
    if ($S.OS) { $b.Add($S.OS) }
    $b.ToArray()
}

function Show-TKScriptDetails {
    param($S)
    $script:Selected = $S
    if (-not $S) {
        $ui.PnlDetails.Visibility = 'Collapsed'
        $ui.PnlEmpty.Visibility = 'Visible'
        Set-TKBusy ([bool]$script:Job) $(if ($script:Job) { $script:Job.Label } else { '' })
        return
    }
    $ui.PnlEmpty.Visibility = 'Collapsed'
    $ui.PnlDetails.Visibility = 'Visible'
    $ui.TxtName.Text = $S.Name
    $ui.IcBadges.ItemsSource = @(Get-TKFriendlyBadges $S)
    $ui.TxtDesc.Text = $S.Description
    $meta = New-Object System.Collections.Generic.List[string]
    $meta.Add("File: $($S.RelPath)")
    if ($S.IsLibrary -and -not $S.HasHeader) { $meta.Add('Library script without a Tech Kit header: flags are guessed from the code') }
    if ($S.Modules.Count) { $meta.Add('Modules: ' + ($S.Modules -join ', ')) }
    if ($S.Scopes.Count) { $meta.Add('Graph scopes: ' + ($S.Scopes -join ', ')) }
    if ($S.Author) { $meta.Add('Author: ' + $S.Author) }
    if ($S.Version) { $meta.Add('Version: ' + $S.Version) }
    $ui.TxtMeta.Text = $meta -join '   |   '

    $warn = New-Object System.Collections.Generic.List[string]
    if ($S.ParseErrors.Count) { $warn.Add('This script has syntax errors and cannot run: ' + ($S.ParseErrors -join '; ')) }
    if ($S.Admin -and -not $script:IsAdmin) { $warn.Add('Needs admin: Tech Kit will ask for administrator approval (UAC) when it runs on this PC.') }
    if ($S.Language -eq 'Python' -and -not (Find-TKInterpreter -Name python)) { $warn.Add('Python was not found on this PC or in Runtimes\python.') }
    if ($S.Language -eq 'Bash' -and -not (Find-TKInterpreter -Name bash)) { $warn.Add('Bash was not found (Git Bash, WSL or Runtimes\git). Remote targets use SSH.') }
    if ($warn.Count) {
        $ui.TxtWarn.Text = $warn -join "`n"
        $ui.TxtWarn.Visibility = 'Visible'
    } else {
        $ui.TxtWarn.Visibility = 'Collapsed'
    }

    if ($S.SupportsRemote) { $ui.PnlTarget.Visibility = 'Visible' } else { $ui.PnlTarget.Visibility = 'Collapsed' }
    $remoteOnly = $S.Targets -notcontains 'Local'
    if ($S.Language -eq 'Bash') {
        $ui.TxtTargetHint.Text = 'Enter user@host for each Linux machine (SSH with key sign-in).'
        if (-not $remoteOnly) { $ui.TxtTargetHint.Text += ' Leave empty to run here with Git Bash or WSL.' }
        $ui.BtnFromAD.Visibility = 'Collapsed'
        $ui.BtnRunAs.Visibility = 'Collapsed'
    } else {
        $ui.TxtTargetHint.Text = 'Enter computer names separated by commas or new lines to run over PowerShell Remoting (WinRM).'
        if ($remoteOnly) { $ui.TxtTargetHint.Text = 'This script runs on remote computers only. ' + $ui.TxtTargetHint.Text }
        else { $ui.TxtTargetHint.Text = 'Leave empty to run on this PC. ' + $ui.TxtTargetHint.Text }
        $ui.BtnFromAD.Visibility = 'Visible'
        $ui.BtnRunAs.Visibility = 'Visible'
    }
    if (@($script:Settings.Favorites) -contains $S.Id) {
        $ui.BtnFav.Content = [string][char]0x2605 + ' Favorite'
    } else {
        $ui.BtnFav.Content = [string][char]0x2606 + ' Favorite'
    }
    New-TKParamControls $S
    Set-TKBusy ([bool]$script:Job) $(if ($script:Job) { $script:Job.Label } else { '' })
}

function New-TKParamControls {
    param($S)
    $ui.PnlParams.Children.Clear()
    $script:ParamControls = [ordered]@{}
    if (-not $S.Params -or @($S.Params).Count -eq 0) {
        $ui.TxtParamsHeader.Text = 'INPUTS'
        $none = New-Object System.Windows.Controls.TextBlock
        $none.Text = 'This script has no inputs. Just press Run.'
        Set-TKResourceRef $none ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'SubTextBrush'
        $null = $ui.PnlParams.Children.Add($none)
        return
    }
    $ui.TxtParamsHeader.Text = 'INPUTS   (* = required)'
    foreach ($p in $S.Params) {
        $wrap = New-Object System.Windows.Controls.StackPanel
        $wrap.Margin = New-TKThickness 0 0 0 10
        $label = New-Object System.Windows.Controls.TextBlock
        $label.Text = $p.Name + $(if ($p.Mandatory) { ' *' } else { '' })
        $label.FontWeight = [System.Windows.FontWeights]::SemiBold
        $label.Margin = New-TKThickness 0 0 0 4
        $ctl = $null
        $ctl2 = $null
        # "# @Choices: Name = spec" turns a text input into a dropdown filled at run time
        $kind = $p.Kind
        $choiceList = @($p.Choices)
        if ($S.Choices -and $S.Choices.Contains($p.Name)) {
            $kind = 'Choice'
            $choiceList = @(Resolve-TKChoices -Spec ([string]$S.Choices[$p.Name]))
        }
        switch ($kind) {
            { $_ -in @('Switch', 'Bool') } {
                $ctl = New-Object System.Windows.Controls.CheckBox
                $ctl.Content = $p.Name
                $ctl.IsChecked = [bool](ConvertTo-TKBool $p.Default)
                if ($p.Default -is [bool]) { $ctl.IsChecked = $p.Default }
                $label = $null
            }
            'Choice' {
                $ctl = New-Object System.Windows.Controls.ComboBox
                $opts = @($choiceList)
                if (-not $p.Mandatory -and -not $p.Default) { $opts = @('') + $opts }
                foreach ($o in $opts) { $null = $ctl.Items.Add($o) }
                if ($p.Default -and $opts -contains [string]$p.Default) { $ctl.SelectedItem = [string]$p.Default } else { $ctl.SelectedIndex = 0 }
                $ctl.MaxWidth = 420
                $ctl.HorizontalAlignment = 'Left'
                $ctl.MinWidth = 220
            }
            'Secure' {
                $ctl = New-Object System.Windows.Controls.PasswordBox
                $ctl.MaxWidth = 420
                $ctl.HorizontalAlignment = 'Left'
                $ctl.MinWidth = 260
            }
            'Credential' {
                $grid = New-Object System.Windows.Controls.StackPanel
                $grid.Orientation = 'Horizontal'
                $ctl = New-Object System.Windows.Controls.TextBox
                $ctl.Width = 220
                $ctl.ToolTip = 'User name'
                $ctl2 = New-Object System.Windows.Controls.PasswordBox
                $ctl2.Width = 200
                $ctl2.Margin = New-TKThickness 8 0 0 0
                $ctl2.ToolTip = 'Password'
                $null = $grid.Children.Add($ctl)
                $null = $grid.Children.Add($ctl2)
            }
            'List' {
                $ctl = New-Object System.Windows.Controls.TextBox
                $ctl.AcceptsReturn = $true
                $ctl.TextWrapping = 'Wrap'
                $ctl.Height = 56
                $ctl.VerticalContentAlignment = 'Top'
                $ctl.VerticalScrollBarVisibility = 'Auto'
                if ($null -ne $p.Default) { $ctl.Text = [string]$p.Default }
            }
            default {
                $ctl = New-Object System.Windows.Controls.TextBox
                if ($null -ne $p.Default) { $ctl.Text = [string]$p.Default }
                if ($p.Kind -eq 'Number') { $ctl.MaxWidth = 200; $ctl.HorizontalAlignment = 'Left'; $ctl.MinWidth = 120 }
            }
        }
        if ($label) { $null = $wrap.Children.Add($label) }
        if ($kind -eq 'Credential') { $null = $wrap.Children.Add($grid) } else { $null = $wrap.Children.Add($ctl) }

        $hintParts = @()
        if ($p.Help) { $hintParts += $p.Help }
        if ($p.DefaultText) { $hintParts += "Default if empty: $($p.DefaultText)" }
        if ($kind -eq 'List') { $hintParts += 'One per line or comma separated.' }
        if ($hintParts.Count) {
            $hint = New-Object System.Windows.Controls.TextBlock
            $hint.Text = $hintParts -join '  '
            $hint.FontSize = 11
            $hint.TextWrapping = 'Wrap'
            $hint.Margin = New-TKThickness 0 3 0 0
            Set-TKResourceRef $hint ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'SubTextBrush'
            $null = $wrap.Children.Add($hint)
        }
        $null = $ui.PnlParams.Children.Add($wrap)
        $script:ParamControls[$p.Name] = @{ Def = $p; Kind = $kind; Control = $ctl; Control2 = $ctl2 }
    }
}

function Get-TKParamValues {
    param($S)
    $values = @{}
    $cliArgs = New-Object System.Collections.Generic.List[string]
    $summary = New-Object System.Collections.Generic.List[string]
    $problems = New-Object System.Collections.Generic.List[string]
    foreach ($name in $script:ParamControls.Keys) {
        $entry = $script:ParamControls[$name]
        $p = $entry.Def
        $c = $entry.Control
        $has = $false
        $value = $null
        $shown = ''
        switch ($entry.Kind) {
            'Switch' {
                if ($c.IsChecked) { $has = $true; $value = $true; $shown = 'on' }
            }
            'Bool' {
                $has = $true; $value = [bool]$c.IsChecked; $shown = [string]$value
            }
            'Choice' {
                if ($c.SelectedItem) { $has = $true; $value = [string]$c.SelectedItem; $shown = $value }
            }
            'Secure' {
                if ($c.SecurePassword.Length -gt 0) { $has = $true; $value = $c.SecurePassword; $shown = '********' }
            }
            'Credential' {
                if ($c.Text.Trim()) {
                    $has = $true
                    $value = New-Object System.Management.Automation.PSCredential($c.Text.Trim(), $entry.Control2.SecurePassword)
                    $shown = $c.Text.Trim() + ' / ********'
                }
            }
            'List' {
                $parts = @($c.Text -split '[\r\n,;]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                if ($parts.Count) { $has = $true; $value = [string[]]$parts; $shown = $parts -join ', ' }
            }
            'Number' {
                $t = $c.Text.Trim()
                if ($t) {
                    $d = 0.0
                    if (-not [double]::TryParse($t, [ref]$d)) { $problems.Add("$name must be a number.") }
                    $has = $true; $value = $t; $shown = $t
                }
            }
            default {
                $t = $c.Text
                if ($t -and $t.Trim()) { $has = $true; $value = $t.Trim(); $shown = $value }
            }
        }
        if (-not $has) {
            if ($p.Mandatory) { $problems.Add("$name is required.") }
            continue
        }
        $values[$name] = $value
        $summary.Add("$name = $shown")
        # Command-line form for Python and Bash scripts
        if ($entry.Kind -eq 'Switch') {
            $cliArgs.Add("--$name")
        } elseif ($value -is [securestring]) {
            $cliArgs.Add("--$name"); $cliArgs.Add((New-Object System.Net.NetworkCredential('', $value)).Password)
        } elseif ($value -is [System.Management.Automation.PSCredential]) {
            $cliArgs.Add("--$name"); $cliArgs.Add($value.UserName)
        } elseif ($value -is [array]) {
            $cliArgs.Add("--$name"); $cliArgs.Add(($value -join ','))
        } else {
            $cliArgs.Add("--$name"); $cliArgs.Add([string]$value)
        }
    }
    @{ Ok = ($problems.Count -eq 0); Problems = $problems.ToArray(); Values = $values; Args = $cliArgs.ToArray(); Summary = $summary.ToArray() }
}

function Get-TKTargets {
    @($ui.TxtTargets.Text -split '[\s,;]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
}

# ---------------------------------------------------------------------------
#  Microsoft 365 helpers
# ---------------------------------------------------------------------------

function Get-TKM365StatusSafe {
    try {
        $r = Invoke-TKWorkerSync -Script 'Get-TKM365Status'
        if ($r -and $r.Count) { return $r[0] }
    } catch { }
    $null
}

function Update-TKM365Indicator {
    $st = Get-TKM365StatusSafe
    $script:M365Status = $st
    if ($st -and ($st.Graph -or $st.Exchange -or $st.Compliance -or $st.Teams -or $st.SharePoint -or $st.Azure)) {
        $svc = @()
        if ($st.Graph) { $svc += 'Graph' }
        if ($st.Exchange) { $svc += 'Exchange' }
        if ($st.Compliance) { $svc += 'Compliance' }
        if ($st.Teams) { $svc += 'Teams' }
        if ($st.SharePoint) { $svc += 'SharePoint' }
        if ($st.Azure) { $svc += 'Azure' }
        $who = $st.GraphAccount
        if (-not $who) { $who = $st.ExchangeAccount }
        if (-not $who) { $who = $st.Azure }
        if (-not $who) { $who = 'connected' }
        $ui.TxtM365.Text = "M365: $who  ($($svc -join ', '))"
        Set-TKResourceRef $ui.DotM365 ([System.Windows.Shapes.Shape]::FillProperty) 'SuccessBrush'
    } else {
        $ui.TxtM365.Text = 'Microsoft 365: not connected'
        Set-TKResourceRef $ui.DotM365 ([System.Windows.Shapes.Shape]::FillProperty) 'VerboseBrush'
    }
}

function Test-TKM365Ready {
    param($S)
    $st = Get-TKM365StatusSafe
    $missing = @()
    if ($S.Connect -contains 'Graph' -and -not ($st -and $st.Graph)) { $missing += 'Microsoft Graph' }
    if ($S.Connect -contains 'Exchange' -and -not ($st -and $st.Exchange)) { $missing += 'Exchange Online' }
    if ($S.Connect -contains 'Compliance' -and -not ($st -and $st.Compliance)) { $missing += 'Security & Compliance' }
    if ($S.Connect -contains 'Teams' -and -not ($st -and $st.Teams)) { $missing += 'Microsoft Teams' }
    if ($S.Connect -contains 'SharePoint' -and -not ($st -and $st.SharePoint)) { $missing += 'SharePoint Online' }
    if ($S.Connect -contains 'Azure' -and -not ($st -and $st.Azure)) { $missing += 'Azure' }
    if ($missing.Count) {
        $r = Show-TKDialog -Title 'Connect to Microsoft 365 first' -Message ("This script needs: " + ($missing -join ', ') + ".`n`nConnect now? After you sign in, press Run again.") -Buttons @('Connect now', 'Cancel')
        if ($r.Button -eq 'Connect now') { Show-TKConnectDialog -Services $S.Connect }
        return $false
    }
    if ($S.Connect -contains 'Graph' -and $S.Scopes.Count -and $st.GraphAuthType -ne 'AppOnly') {
        $have = @($st.GraphScopes)
        $lack = @($S.Scopes | Where-Object { $have -notcontains $_ -and $have -notcontains ($_ -replace '\.Read\.', '.ReadWrite.') })
        if ($lack.Count) {
            $r = Show-TKDialog -Title 'More Graph permissions needed' -Message ("Your current sign-in does not include: " + ($lack -join ', ') + ".`n`nReconnect with these added? The script may fail without them.") -Buttons @('Reconnect', 'Run anyway', 'Cancel')
            if ($r.Button -eq 'Reconnect') {
                $scopes = @(@($have) + @($S.Scopes) + @(Get-TKAllScopes) | Where-Object { $_ } | Sort-Object -Unique)
                $null = Start-TKWorker -Script 'param($a) Connect-TKM365 @a' -Arguments @(@{ Service = @('Graph'); Method = 'Interactive'; Scopes = $scopes; TenantId = $st.GraphTenant }) -Label 'Reconnecting to Microsoft Graph' -NoCollect -OnComplete { param($ok, $job) Update-TKM365Indicator; if ($ok) { Write-TKLine -Text 'Reconnected. Press Run again.' -Kind Success } }
                return $false
            }
            if ($r.Button -ne 'Run anyway') { return $false }
        }
    }
    $true
}

function Show-TKConnectDialog {
    param([string[]]$Services = @())
    $d = Read-TKWindow 'ConnectWindow.xaml'
    $d.Window.Owner = $script:Win
    $profiles = @(Get-TKTenantProfiles)
    $null = $d.CmbProfile.Items.Add('(new connection)')
    foreach ($p in $profiles) { $null = $d.CmbProfile.Items.Add([string]$p.Name) }
    $d.CmbProfile.SelectedIndex = 0
    $d.TxtScopes.Text = (Get-TKAllScopes) -join ', '
    if ($Services.Count) {
        $d.ChkGraph.IsChecked = $Services -contains 'Graph'
        $d.ChkExchange.IsChecked = $Services -contains 'Exchange'
        $d.ChkCompliance.IsChecked = $Services -contains 'Compliance'
        $d.ChkTeams.IsChecked = $Services -contains 'Teams'
        $d.ChkSharePoint.IsChecked = $Services -contains 'SharePoint'
        $d.ChkAzure.IsChecked = $Services -contains 'Azure'
    }
    $d.Window.Tag = $d

    $refresh = {
        param($sender, $e)
        $dd = [System.Windows.Window]::GetWindow($sender).Tag
        if (-not $dd) { return }
        $app = $dd.RbCert.IsChecked -or $dd.RbSecret.IsChecked
        $dd.PnlApp.Visibility = $(if ($app -or $dd.ChkSharePoint.IsChecked) { 'Visible' } else { 'Collapsed' })
        $dd.PnlSpo.Visibility = $(if ($dd.ChkSharePoint.IsChecked) { 'Visible' } else { 'Collapsed' })
        $dd.PnlCert.Visibility = $(if ($dd.RbCert.IsChecked) { 'Visible' } else { 'Collapsed' })
        $dd.PnlSecret.Visibility = $(if ($dd.RbSecret.IsChecked) { 'Visible' } else { 'Collapsed' })
        $dd.PnlUpn.Visibility = $(if ($dd.RbInteractive.IsChecked) { 'Visible' } else { 'Collapsed' })
        $dd.PnlScopes.Visibility = $(if ($app) { 'Collapsed' } else { 'Visible' })
    }
    foreach ($rb in @($d.RbInteractive, $d.RbDevice, $d.RbCert, $d.RbSecret)) { $rb.Add_Checked($refresh) }
    $d.ChkSharePoint.Add_Checked($refresh)
    $d.ChkSharePoint.Add_Unchecked($refresh)
    if ($d.ChkSharePoint.IsChecked) { $d.PnlSpo.Visibility = 'Visible'; $d.PnlApp.Visibility = 'Visible' }

    $d.CmbProfile.Add_SelectionChanged({
        param($sender, $e)
        $dd = [System.Windows.Window]::GetWindow($sender).Tag
        $name = [string]$sender.SelectedItem
        $p = @(Get-TKTenantProfiles) | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if (-not $p) { return }
        $dd.TxtProfileName.Text = $p.Name
        $dd.TxtTenant.Text = [string]$p.TenantId
        $dd.TxtClientId.Text = [string]$p.ClientId
        $dd.TxtThumb.Text = [string]$p.Thumbprint
        $dd.TxtPfx.Text = [string]$p.PfxPath
        $dd.TxtOrg.Text = [string]$p.Organization
        $dd.TxtUpn.Text = [string]$p.UserPrincipalName
        $dd.TxtSpoUrl.Text = [string]$p.SharePointUrl
        if ($p.Scopes) { $dd.TxtScopes.Text = [string]$p.Scopes }
        switch ([string]$p.Method) {
            'DeviceCode' { $dd.RbDevice.IsChecked = $true }
            'Certificate' { $dd.RbCert.IsChecked = $true }
            'Secret' { $dd.RbSecret.IsChecked = $true }
            default { $dd.RbInteractive.IsChecked = $true }
        }
        $svc = @([string]$p.Services -split ',')
        if ($svc.Count -and $svc[0]) {
            $dd.ChkGraph.IsChecked = $svc -contains 'Graph'
            $dd.ChkExchange.IsChecked = $svc -contains 'Exchange'
            $dd.ChkCompliance.IsChecked = $svc -contains 'Compliance'
            $dd.ChkTeams.IsChecked = $svc -contains 'Teams'
            $dd.ChkSharePoint.IsChecked = $svc -contains 'SharePoint'
            $dd.ChkAzure.IsChecked = $svc -contains 'Azure'
        }
    })

    $d.BtnBrowsePfx.Add_Click({
        param($sender, $e)
        $dd = [System.Windows.Window]::GetWindow($sender).Tag
        $ofd = New-Object Microsoft.Win32.OpenFileDialog
        $ofd.Filter = 'Certificate (*.pfx;*.p12)|*.pfx;*.p12|All files (*.*)|*.*'
        $certs = Get-TKPath Certs
        if (Test-Path -LiteralPath $certs) { $ofd.InitialDirectory = $certs }
        if ($ofd.ShowDialog()) { $dd.TxtPfx.Text = $ofd.FileName }
    })

    $d.BtnSaveProfile.Add_Click({
        param($sender, $e)
        $dd = [System.Windows.Window]::GetWindow($sender).Tag
        $name = $dd.TxtProfileName.Text.Trim()
        if (-not $name) { $name = $dd.TxtTenant.Text.Trim() }
        if (-not $name) { Show-TKMessage 'Type a profile name (for example the client name) first.'; return }
        $method = Get-TKConnectMethod $dd
        $svc = @()
        if ($dd.ChkGraph.IsChecked) { $svc += 'Graph' }
        if ($dd.ChkExchange.IsChecked) { $svc += 'Exchange' }
        if ($dd.ChkCompliance.IsChecked) { $svc += 'Compliance' }
        if ($dd.ChkTeams.IsChecked) { $svc += 'Teams' }
        if ($dd.ChkSharePoint.IsChecked) { $svc += 'SharePoint' }
        if ($dd.ChkAzure.IsChecked) { $svc += 'Azure' }
        $list = @(Get-TKTenantProfiles | Where-Object { $_.Name -ne $name })
        $list += [pscustomobject]@{
            Name = $name; TenantId = $dd.TxtTenant.Text.Trim(); ClientId = $dd.TxtClientId.Text.Trim(); Thumbprint = $dd.TxtThumb.Text.Trim()
            PfxPath = $dd.TxtPfx.Text.Trim(); Organization = $dd.TxtOrg.Text.Trim(); UserPrincipalName = $dd.TxtUpn.Text.Trim()
            Method = $method; Services = ($svc -join ','); Scopes = $dd.TxtScopes.Text.Trim(); SharePointUrl = $dd.TxtSpoUrl.Text.Trim()
        }
        Save-TKTenantProfiles -Profiles $list
        if (-not $dd.CmbProfile.Items.Contains($name)) { $null = $dd.CmbProfile.Items.Add($name) }
        Show-TKMessage "Profile '$name' saved (no passwords or secrets are stored)."
    })

    $d.BtnDeleteProfile.Add_Click({
        param($sender, $e)
        $dd = [System.Windows.Window]::GetWindow($sender).Tag
        $name = [string]$dd.CmbProfile.SelectedItem
        if (-not $name -or $dd.CmbProfile.SelectedIndex -eq 0) { return }
        Save-TKTenantProfiles -Profiles @(Get-TKTenantProfiles | Where-Object { $_.Name -ne $name })
        $dd.CmbProfile.Items.Remove($name)
        $dd.CmbProfile.SelectedIndex = 0
    })

    $d.BtnDisconnect.Add_Click({
        param($sender, $e)
        $w = [System.Windows.Window]::GetWindow($sender)
        $w.Tag.Result = 'disconnect'
        $w.Close()
    })
    $d.BtnConnect.Add_Click({
        param($sender, $e)
        $w = [System.Windows.Window]::GetWindow($sender)
        $w.Tag.Result = 'connect'
        $w.Close()
    })

    $null = $d.Window.ShowDialog()

    if ($d.Result -eq 'disconnect') {
        $null = Start-TKWorker -Script 'Disconnect-TKM365' -Label 'Disconnecting Microsoft 365' -NoCollect -OnComplete { param($ok, $job) Update-TKM365Indicator }
        return
    }
    if ($d.Result -ne 'connect') { return }

    $svc = @()
    if ($d.ChkGraph.IsChecked) { $svc += 'Graph' }
    if ($d.ChkExchange.IsChecked) { $svc += 'Exchange' }
    if ($d.ChkCompliance.IsChecked) { $svc += 'Compliance' }
    if ($d.ChkTeams.IsChecked) { $svc += 'Teams' }
    if ($d.ChkSharePoint.IsChecked) { $svc += 'SharePoint' }
    if ($d.ChkAzure.IsChecked) { $svc += 'Azure' }
    if (-not $svc.Count) { Show-TKMessage 'Pick at least one service to connect to.'; return }

    $method = Get-TKConnectMethod $d
    $a = @{ Service = $svc; Method = $method }
    $tenant = $d.TxtTenant.Text.Trim()
    if ($tenant) { $a.TenantId = $tenant }
    if ($d.TxtClientId.Text.Trim()) { $a.ClientId = $d.TxtClientId.Text.Trim() }
    if ($d.TxtThumb.Text.Trim()) { $a.CertificateThumbprint = $d.TxtThumb.Text.Trim() }
    if ($d.TxtPfx.Text.Trim()) { $a.CertificatePath = $d.TxtPfx.Text.Trim() }
    if ($d.PwdPfx.SecurePassword.Length) { $a.CertificatePassword = $d.PwdPfx.SecurePassword }
    if ($d.PwdSecret.SecurePassword.Length) { $a.ClientSecret = $d.PwdSecret.SecurePassword }
    if ($d.TxtOrg.Text.Trim()) { $a.Organization = $d.TxtOrg.Text.Trim() }
    if ($d.TxtUpn.Text.Trim() -and $method -eq 'Interactive') { $a.UserPrincipalName = $d.TxtUpn.Text.Trim() }
    if ($d.TxtSpoUrl.Text.Trim()) { $a.SharePointUrl = $d.TxtSpoUrl.Text.Trim() }
    $scopes = @($d.TxtScopes.Text -split '[\s,;]+' | Where-Object { $_ })
    if ($scopes.Count) { $a.Scopes = $scopes }

    $missing = @()
    if ($svc -contains 'Graph') { $missing += @(Get-TKMissingModule -Name 'Microsoft.Graph.Authentication') }
    if ($svc -contains 'Exchange' -or $svc -contains 'Compliance') { $missing += @(Get-TKMissingModule -Name 'ExchangeOnlineManagement') }
    if ($svc -contains 'Teams') { $missing += @(Get-TKMissingModule -Name 'MicrosoftTeams') }
    if ($svc -contains 'SharePoint') { $missing += @(Get-TKMissingModule -Name 'PnP.PowerShell') }
    if ($svc -contains 'Azure') { $missing += @(Get-TKMissingModule -Name 'Az.Accounts') }
    if ($missing.Count) {
        $null = Request-TKModuleInstall -Missing $missing
        return
    }

    $ui.TabOutput.SelectedItem = $ui.TabItemOutput
    Write-TKLine -Text ''
    Write-TKLine -Text ("{0} Connecting to Microsoft 365 ({1}, {2})" -f [char]0x25B6, ($svc -join ', '), $method) -Kind Command
    if ($method -eq 'Interactive') { Write-TKLine -Text 'A Microsoft sign-in window or browser tab will open. It can appear behind this window.' -Kind Verbose }
    $null = Start-TKWorker -Script 'param($a) Connect-TKM365 @a' -Arguments @($a) -Label 'Connecting to Microsoft 365' -NoCollect -OnComplete {
        param($ok, $job)
        Update-TKM365Indicator
        if (-not $ok) { Write-TKLine -Text 'Connection failed. Check the messages above.' -Kind Error }
    }
}

function Get-TKConnectMethod {
    param($D)
    if ($D.RbDevice.IsChecked) { return 'DeviceCode' }
    if ($D.RbCert.IsChecked) { return 'Certificate' }
    if ($D.RbSecret.IsChecked) { return 'Secret' }
    'Interactive'
}

# ---------------------------------------------------------------------------
#  Modules
# ---------------------------------------------------------------------------

function Request-TKModuleInstall {
    param([string[]]$Missing)
    $rsatNames = @('ActiveDirectory', 'GroupPolicy', 'DnsServer', 'DhcpServer')
    $rsat = @($Missing | Where-Object { $rsatNames -contains $_ })
    $gallery = @($Missing | Where-Object { $rsatNames -notcontains $_ })
    $msg = "This script needs modules that are not on this PC or the USB:`n  " + ($Missing -join "`n  ")
    if ($rsat.Count) {
        $msg += "`n`n" + ($rsat -join ', ') + " comes with Windows RSAT tools, not the PowerShell Gallery. Run 'Install RSAT AD Tools' (Active Directory category) on this PC, or put a domain controller's name in the Target box so the script runs there."
    }
    if (-not $gallery.Count) {
        Show-TKMessage -Title 'Module needed' -Message $msg
        return $false
    }
    $msg += "`n`nDownload to the USB so it works on every PC you visit, or install it just for this Windows user? Both need internet access to the PowerShell Gallery."
    $r = Show-TKDialog -Title 'Modules needed' -Message $msg -Buttons @('Download to USB', 'Install for this user', 'Cancel') -Width 560
    $dest = $null
    if ($r.Button -eq 'Download to USB') { $dest = 'USB' }
    elseif ($r.Button -eq 'Install for this user') { $dest = 'CurrentUser' }
    else { return $false }
    $ui.TabOutput.SelectedItem = $ui.TabItemOutput
    $workerArgs = @(, $gallery) + @($dest)
    $null = Start-TKWorker -Script 'param($n, $d) Install-TKModule -Name $n -Destination $d; if ($d -eq "USB") { Unblock-TKFiles -Force }' -Arguments $workerArgs -Label 'Installing modules' -NoCollect -OnComplete {
        param($ok, $job)
        if ($ok) { Write-TKLine -Text 'Modules are ready. Press Run (or Connect) again.' -Kind Success }
    }
    $false
}

# ---------------------------------------------------------------------------
#  Running a script
# ---------------------------------------------------------------------------

function Invoke-TKRun {
    param([switch]$DryRun)
    $s = $script:Selected
    if (-not $s) { return }
    if ($script:Job) { Write-TKLine -Text 'Something is already running. Wait for it or press Stop.' -Kind Warning; return }
    if ($s.ParseErrors.Count) { Show-TKMessage -Title 'Script has errors' -Message 'Fix the syntax errors in this script before running it (Edit > Check syntax).' -Detail ($s.ParseErrors -join "`n"); return }
    if (-not (Test-Path -LiteralPath $s.Path)) { Show-TKMessage 'The script file is gone. Reloading the library.'; Import-TKLibrary; return }
    if (-not (Test-TKRoleAllows $script:Role $s)) { Show-TKMessage -Title 'Not allowed' -Message "The '$script:RoleName' role cannot run this script."; return }

    $pv = Get-TKParamValues $s
    if (-not $pv.Ok) { Show-TKMessage -Title 'Check the inputs' -Message ($pv.Problems -join "`n"); return }

    $targets = @()
    if ($s.SupportsRemote) { $targets = Get-TKTargets }
    $remote = @($targets | Where-Object { -not (Test-TKLocalName $_) })
    $runsLocal = ($remote.Count -eq 0) -or (@($targets | Where-Object { Test-TKLocalName $_ }).Count -gt 0)
    if ($s.SupportsRemote -and $s.Targets -notcontains 'Local' -and $remote.Count -eq 0) {
        $what = $(if ($s.Language -eq 'Bash') { 'user@host' } else { 'computer name' })
        Show-TKMessage -Title 'Target needed' -Message "This script only runs on remote machines. Enter at least one $what in the Target box."
        return
    }

    if ($s.Shell.Count) {
        $ed = $(if ($PSVersionTable.PSEdition -eq 'Core') { '7' } else { '5.1' })
        if ($s.Shell -notcontains $ed) {
            $r = Show-TKDialog -Title 'Different PowerShell version' -Message "This script is marked for PowerShell $($s.Shell -join ' / ') and Tech Kit is running on PowerShell $($PSVersionTable.PSVersion). Run anyway?" -Buttons @('Run anyway', 'Cancel')
            if ($r.Button -ne 'Run anyway') { return }
        }
    }

    if ($s.Connect.Count -and -not (Test-TKM365Ready $s)) { return }

    if ($s.Modules.Count -and ($runsLocal -or $s.Connect.Count)) {
        $missing = @(Get-TKMissingModule -Name $s.Modules)
        if ($missing.Count) {
            $onlyRsat = @($missing | Where-Object { @('ActiveDirectory', 'GroupPolicy') -notcontains $_ }).Count -eq 0
            if (-not ($onlyRsat -and $remote.Count)) {
                $null = Request-TKModuleInstall -Missing $missing
                return
            }
        }
    }

    $where = 'this PC'
    if ($s.Connect.Count) {
        $where = 'Microsoft 365'
        if ($script:M365Status -and $script:M365Status.Tenant) { $where = "Microsoft 365 tenant $($script:M365Status.Tenant)" }
    } elseif ($targets.Count) {
        $where = ($targets -join ', ')
    }

    if ($s.Changes -and -not $DryRun -and $script:Settings.ConfirmChanges) {
        $detail = "Script:  $($s.Name)`nTarget:  $where"
        if ($pv.Summary.Count) { $detail += "`n`nInputs:`n  " + ($pv.Summary -join "`n  ") }
        $buttons = @('Run it', 'Cancel')
        if ($s.WhatIf) { $buttons = @('Run it', 'What-If first', 'Cancel') }
        $r = Show-TKDialog -Title 'This script makes changes' -Message 'Check the target and inputs before you continue.' -Detail $detail -Buttons $buttons -Default ($buttons.Count - 1) -Width 560
        if ($r.Button -eq 'What-If first') { $DryRun = $true }
        elseif ($r.Button -ne 'Run it') { return }
    }

    # Adaxes-style controls from Config\roles.json: ticket/reason and a second-person approval
    $ticket = ''
    $approver = ''
    if ($s.Changes -and -not $DryRun) {
        if (Get-TKRoleValue $script:Role 'RequireTicket' $false) {
            $r = Show-TKDialog -Title 'Ticket or reason needed' -Message "The '$script:RoleName' role needs a ticket number or a short reason for changes. It goes into the audit log." -InputKind Text -Buttons @('Continue', 'Cancel')
            if ($r.Button -ne 'Continue') { return }
            if (-not $r.Text -or -not $r.Text.Trim()) { Show-TKMessage 'A ticket number or reason is required.'; return }
            $ticket = $r.Text.Trim()
        }
        if (Get-TKRoleValue $script:Role 'RequireApproval' $false) {
            $group = [string]$script:RoleConfig.Approval.ApproverGroup
            $msg = 'A second person has to approve this change by signing in here.'
            if ($group) { $msg += " They must be in the '$group' group." }
            $r = Show-TKDialog -Title 'Approval needed' -Message $msg -Detail "Script:  $($s.Name)`nTarget:  $where`n$($pv.Summary -join "`n")" -InputKind Credential -Buttons @('Approve', 'Cancel') -Width 560
            if ($r.Button -ne 'Approve' -or -not $r.Credential) { return }
            $check = $null
            try { $check = Test-TKApprover -Credential $r.Credential -Group $group } catch { $check = [pscustomobject]@{ Ok = $false; Reason = $_.Exception.Message } }
            if (-not $check.Ok) {
                Write-TKAuditSafe ([ordered]@{ Script = $s; Where = $where; Inputs = $pv.Summary; DryRun = $false; Ticket = $ticket; Approver = $r.Credential.UserName; Result = "Approval denied: $($check.Reason)"; Errors = 0; Seconds = 0 })
                Show-TKMessage -Title 'Not approved' -Message $check.Reason
                return
            }
            $approver = $check.Approver
        }
    }

    $invoke = @{ Path = $s.Path; Parameters = $pv.Values; Arguments = $pv.Args; ComputerName = [string[]]$targets; DryRun = [bool]$DryRun }
    if ($script:RunAsCred -and $remote.Count) { $invoke.Credential = $script:RunAsCred }

    $needElevate = $s.Admin -and $runsLocal -and -not $script:IsAdmin
    $mode = ''
    if ($DryRun) { $mode = '   [WHAT-IF: nothing will be changed]' }
    $ui.TabOutput.SelectedItem = $ui.TabItemOutput
    $null = $script:RunText.Clear()
    $script:RunErrors = 0
    Write-TKLine -Text ''
    Write-TKLine -Text ('{0} {1}   on {2}   {3}{4}' -f [char]0x25B6, $s.Name, $where, (Get-Date -Format 'HH:mm:ss'), $mode) -Kind Command
    if ($pv.Summary.Count) { Write-TKLine -Text ('   ' + ($pv.Summary -join '   ')) -Kind Verbose }
    if ($script:RunAsCred -and $remote.Count) { Write-TKLine -Text "   Remote connections use $($script:RunAsCred.UserName)" -Kind Verbose }

    $runAs = ''
    if ($script:RunAsCred -and $remote.Count) { $runAs = $script:RunAsCred.UserName }
    $script:LastRun = @{ Script = $s; Where = $where; Time = Get-Date; DryRun = [bool]$DryRun; Inputs = $pv.Summary; Ticket = $ticket; Approver = $approver; RunAs = $runAs }
    if ($ticket) { Write-TKLine -Text "   Ticket / reason: $ticket" -Kind Verbose }
    if ($approver) { Write-TKLine -Text "   Approved by $approver" -Kind Verbose }
    $done = {
        param($ok, $job)
        $secs = [Math]::Round(([DateTime]::Now - $job.Started).TotalSeconds, 1)
        if ($job.Stopped) {
            Write-TKLine -Text ("{0} Stopped after {1} s" -f [char]0x25A0, $secs) -Kind Warning
        } elseif ($ok -and $script:RunErrors -eq 0) {
            Write-TKLine -Text ("{0} Done in {1} s" -f [char]0x2714, $secs) -Kind Success
        } else {
            Write-TKLine -Text ("{0} Finished with {1} error(s) in {2} s" -f [char]0x2716, [Math]::Max(1, $script:RunErrors), $secs) -Kind Error
        }
        $script:LastRun.Text = $script:RunText.ToString()
        if ($script:LastRun.Script.Changes) {
            $result = 'Done'
            if ($job.Stopped) { $result = 'Stopped' } elseif (-not $ok -or $script:RunErrors -gt 0) { $result = 'Finished with errors' }
            $entry = [ordered]@{
                Script = $script:LastRun.Script; Where = $script:LastRun.Where; Inputs = $script:LastRun.Inputs; DryRun = $script:LastRun.DryRun
                Ticket = $script:LastRun.Ticket; Approver = $script:LastRun.Approver; RunAs = $script:LastRun.RunAs
                Result = $result; Errors = $script:RunErrors; Seconds = $secs; Time = $script:LastRun.Time
            }
            Write-TKAuditSafe $entry
        }
    }
    if ($needElevate) {
        Write-TKLine -Text '   Asking Windows for administrator approval (UAC)...' -Kind Verbose
        $null = Start-TKElevatedRun -InvokeArgs $invoke -Label $s.Name -OnComplete $done
    } else {
        $null = Start-TKWorker -Script 'param($a) Invoke-TKScript @a' -Arguments @($invoke) -Label $s.Name -OnComplete $done
    }
}

function Export-TKLastRun {
    param([ValidateSet('Csv', 'Html')][string]$Format)
    if (-not $script:LastRun) { Show-TKMessage 'Run a script first, then export its results.'; return }
    if ($script:Job) { Show-TKMessage 'Wait for the current run to finish.'; return }
    $lr = $script:LastRun
    $title = $lr.Script.Name
    $sub = "Target: $($lr.Where)   |   Run $($lr.Time.ToString('yyyy-MM-dd HH:mm'))"
    if ($lr.DryRun) { $sub += '   |   What-If (no changes made)' }
    $text = [string]$lr.Text
    try {
        $r = Invoke-TKWorkerSync -Script 'param($f, $t, $s, $o, $d) Export-TKResult -Format $f -Title $t -Subtitle $s -OutputText $o -Folder $d' -Arguments @($Format, $title, $sub, $text, [string]$script:Settings.ReportFolder)
        $path = [string]$r[0]
        Write-TKLine -Text "Saved $Format report: " -Kind Success -NoNewLine
        Add-TKLink -Box $script:Boxes.output -Label $path -Target $path
        $script:Boxes.output.Rtb.ScrollToEnd()
    } catch {
        $m = $_.Exception.Message
        if ($_.Exception.InnerException) { $m = $_.Exception.InnerException.Message }
        Show-TKMessage -Title 'Export failed' -Message $m
    }
}

# ---------------------------------------------------------------------------
#  Terminal
# ---------------------------------------------------------------------------

function Update-TKPrompt {
    $loc = $script:Sink.Location
    if (-not $loc) { $loc = '~' }
    if ($loc.Length -gt 48) { $loc = '...' + $loc.Substring($loc.Length - 45) }
    $ui.TxtPrompt.Text = "PS $loc>"
}

function Invoke-TKTerminalCommand {
    $cmd = $ui.TxtTermInput.Text
    $ui.TxtTermInput.Text = ''
    $script:Completion = $null
    Write-TKLine -Text ("{0} {1}" -f $ui.TxtPrompt.Text, $cmd) -Kind Command -Channel terminal
    $trim = $cmd.Trim()
    if (-not $trim) { return }
    if ($script:History.Count -eq 0 -or $script:History[$script:History.Count - 1] -ne $cmd) { $script:History.Add($cmd) }
    $script:HistoryIndex = $script:History.Count
    if ($trim -in @('cls', 'clear', 'Clear-Host')) { Clear-TKBox $script:Boxes.terminal; return }
    if ($script:Job) { Write-TKLine -Text '(busy: a script is running; wait or press Stop)' -Kind Warning -Channel terminal; return }
    $null = Start-TKWorker -Script $cmd -GlobalScope -NoCollect -Channel terminal -Label 'Terminal command' -OnComplete { param($ok, $job) Update-TKPrompt }
}

function Invoke-TKTabComplete {
    if ($script:Job) { return }
    $box = $ui.TxtTermInput
    $c = $script:Completion
    if ($c -and $box.Text -eq $c.LastText -and $c.Matches.Count -gt 0) {
        $c.Index = ($c.Index + 1) % $c.Matches.Count
    } else {
        $text = $box.Text
        $ps = [PowerShell]::Create()
        $ps.Runspace = $script:Worker
        try {
            $res = [System.Management.Automation.CommandCompletion]::CompleteInput($text, $box.CaretIndex, $null, $ps)
        } catch { return } finally { $ps.Dispose() }
        if (-not $res -or $res.CompletionMatches.Count -eq 0) { return }
        $c = @{ Original = $text; Matches = $res.CompletionMatches; Index = 0; Start = $res.ReplacementIndex; Length = $res.ReplacementLength; LastText = '' }
        $script:Completion = $c
    }
    $m = $c.Matches[$c.Index].CompletionText
    $new = $c.Original.Substring(0, $c.Start) + $m + $c.Original.Substring($c.Start + $c.Length)
    $box.Text = $new
    $box.CaretIndex = $c.Start + $m.Length
    $c.LastText = $new
}

function Open-TKConsole {
    param([string]$Exe, [switch]$Admin)
    if (-not $Exe) { return }
    $profilePath = Join-Path $script:CoreDir 'TerminalProfile.ps1'
    $psArgs = "-NoExit -NoProfile -ExecutionPolicy Bypass -File `"$profilePath`""
    $wt = $script:Shell.WindowsTerminal
    try {
        if ($script:Settings.UseWindowsTerminal -and $wt) {
            $wtArgs = "new-tab --title `"Tech Kit`" `"$Exe`" $psArgs"
            if ($Admin) { Start-Process -FilePath $wt -ArgumentList $wtArgs -Verb RunAs } else { Start-Process -FilePath $wt -ArgumentList $wtArgs }
        } else {
            if ($Admin) { Start-Process -FilePath $Exe -ArgumentList $psArgs -Verb RunAs } else { Start-Process -FilePath $Exe -ArgumentList $psArgs }
        }
    } catch {
        Write-TKLine -Text "Could not open the console: $($_.Exception.Message)" -Kind Warning
    }
}

function Show-TKConsoleMenu {
    param($Anchor)
    $menu = New-Object System.Windows.Controls.ContextMenu
    $entries = @()
    if ($script:Shell.Pwsh) {
        $entries += @{ Label = 'PowerShell 7'; Exe = $script:Shell.Pwsh; Admin = $false }
        $entries += @{ Label = 'PowerShell 7  (as administrator)'; Exe = $script:Shell.Pwsh; Admin = $true }
    }
    if ($script:Shell.WindowsPS) {
        $entries += @{ Label = 'Windows PowerShell 5.1'; Exe = $script:Shell.WindowsPS; Admin = $false }
        $entries += @{ Label = 'Windows PowerShell 5.1  (as administrator)'; Exe = $script:Shell.WindowsPS; Admin = $true }
    }
    foreach ($en in $entries) {
        $mi = New-Object System.Windows.Controls.MenuItem
        $mi.Header = $en.Label
        $mi.Tag = $en
        $mi.Add_Click({ param($sender, $e) Open-TKConsole -Exe $sender.Tag.Exe -Admin:([bool]$sender.Tag.Admin) })
        $null = $menu.Items.Add($mi)
    }
    $menu.PlacementTarget = $Anchor
    $menu.Placement = 'Bottom'
    $menu.IsOpen = $true
}

# ---------------------------------------------------------------------------
#  Targets
# ---------------------------------------------------------------------------

function Import-TKTargetList {
    $ofd = New-Object Microsoft.Win32.OpenFileDialog
    $ofd.Filter = 'Computer lists (*.txt;*.csv)|*.txt;*.csv|All files (*.*)|*.*'
    if (-not $ofd.ShowDialog()) { return }
    $names = @()
    try {
        if ($ofd.FileName -like '*.csv') {
            $rows = @(Import-Csv -LiteralPath $ofd.FileName)
            if ($rows.Count) {
                $cols = @($rows[0].PSObject.Properties.Name)
                $col = @('ComputerName', 'Name', 'DNSHostName', 'HostName', 'Computer', 'Device') | Where-Object { $cols -contains $_ } | Select-Object -First 1
                if (-not $col) { $col = $cols[0] }
                $names = @($rows | ForEach-Object { [string]$_.$col })
            }
        } else {
            $names = @(Get-Content -LiteralPath $ofd.FileName | Where-Object { $_ -and $_.Trim() -and -not $_.Trim().StartsWith('#') })
        }
    } catch {
        Show-TKMessage -Title 'Could not read the list' -Message $_.Exception.Message
        return
    }
    $names = @($names | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
    $ui.TxtTargets.Text = $names -join "`r`n"
    Write-TKLine -Text "Loaded $($names.Count) computer name(s) from $($ofd.FileName)" -Kind Info
}

function Find-TKADTargets {
    $r = Show-TKDialog -Title 'Find computers in Active Directory' -Message 'Name filter (wildcards allowed), for example PC-* or SRV*. Leave * for all enabled computers. Uses plain LDAP, so RSAT is not needed.' -InputKind Text -InputDefault '*' -Buttons @('All computers', 'Servers only', 'Cancel')
    if ($r.Button -notin @('All computers', 'Servers only')) { return }
    $ui.TxtStatus.Text = 'Searching Active Directory...'
    Update-TKRender
    try {
        $found = @(Get-TKADComputer -NameFilter $r.Text -ServersOnly:($r.Button -eq 'Servers only'))
    } catch {
        Show-TKMessage -Title 'Active Directory search failed' -Message ("Is this PC joined to a domain and can it reach a domain controller?`n`n" + $_.Exception.Message)
        Update-TKStatusText
        return
    }
    Update-TKStatusText
    if (-not $found.Count) { Show-TKMessage 'No matching computers were found.'; return }
    $names = @($found | ForEach-Object { if ($_.DnsHostName) { $_.DnsHostName } else { $_.Name } })
    $r2 = Show-TKDialog -Title "Found $($names.Count) computer(s)" -Message 'Put these in the Target box?' -Detail ($names -join "`n") -Buttons @('Replace', 'Add to list', 'Cancel')
    if ($r2.Button -eq 'Replace') { $ui.TxtTargets.Text = $names -join "`r`n" }
    elseif ($r2.Button -eq 'Add to list') {
        $all = @(Get-TKTargets) + $names | Select-Object -Unique
        $ui.TxtTargets.Text = $all -join "`r`n"
    }
}

function Set-TKRunAs {
    if ($script:RunAsCred) {
        $script:RunAsCred = $null
        $ui.BtnRunAs.Content = 'Run as: current user'
        return
    }
    $r = Show-TKDialog -Title 'Run remote scripts as...' -Message 'Credentials for remote computers (for example a domain admin). Kept in memory only until you close Tech Kit or click the button again.' -InputKind Credential -Buttons @('Use these', 'Cancel')
    if ($r.Button -eq 'Use these' -and $r.Credential) {
        $script:RunAsCred = $r.Credential
        $ui.BtnRunAs.Content = "Run as: $($r.Credential.UserName)  (click to clear)"
    }
}

# ---------------------------------------------------------------------------
#  Roles, PIN and audit
# ---------------------------------------------------------------------------

function Write-TKAuditSafe {
    param([System.Collections.IDictionary]$Info)
    if (-not $script:Settings.AuditChanges) { return }
    $time = $Info.Time
    if (-not $time) { $time = Get-Date }
    try {
        Write-TKAudit -Entry ([ordered]@{
            Time     = $time.ToString('yyyy-MM-dd HH:mm:ss')
            Operator = "$env:USERDOMAIN\$env:USERNAME"
            Computer = $env:COMPUTERNAME
            Role     = $script:RoleName
            Script   = $Info.Script.Name
            File     = $Info.Script.RelPath
            Target   = $Info.Where
            Inputs   = (@($Info.Inputs) -join '; ')
            WhatIf   = [bool]$Info.DryRun
            Ticket   = [string]$Info.Ticket
            Approver = [string]$Info.Approver
            RunAs    = [string]$Info.RunAs
            Result   = [string]$Info.Result
            Errors   = [int]$Info.Errors
            Seconds  = $Info.Seconds
        })
    } catch {
        Write-TKLine -Text "The audit log could not be written: $($_.Exception.Message)" -Kind Warning
    }
}

function Get-TKPinHash {
    param([securestring]$Pin)
    $plain = (New-Object System.Net.NetworkCredential('', $Pin)).Password
    $sha = [System.Security.Cryptography.SHA256]::Create()
    ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('TechKit:' + $plain)))) -replace '-', ''
}

function Test-TKPinGate {
    # Leaving a restricted role (or changing its settings) needs the admin PIN, if one is set.
    if ($script:RoleName -eq 'Administrator' -or -not $script:Settings.RolePinHash) { return $true }
    $r = Show-TKDialog -Title 'Admin PIN' -Message "The '$script:RoleName' role is locked. Enter the admin PIN to change roles or safety settings." -InputKind Password -Buttons @('OK', 'Cancel')
    if ($r.Button -ne 'OK') { return $false }
    if ((Get-TKPinHash $r.Secure) -eq $script:Settings.RolePinHash) { return $true }
    Show-TKMessage 'Wrong PIN.'
    $false
}

function Set-TKActiveRole {
    $script:RoleConfig = Get-TKRoles
    $name = [string]$script:Settings.ActiveRole
    if (-not $name -or -not $script:RoleConfig.Roles.Contains($name)) { $name = 'Administrator' }
    $script:RoleName = $name
    $script:Role = $script:RoleConfig.Roles[$name]
    $edit = [bool](Get-TKRoleValue $script:Role 'AllowEditing' $true)
    $term = [bool](Get-TKRoleValue $script:Role 'AllowTerminal' $true)
    $vis = { param($b) if ($b) { 'Visible' } else { 'Collapsed' } }
    $ui.BtnNewScript.Visibility = & $vis $edit
    $ui.BtnOpenScripts.Visibility = & $vis $edit
    $ui.BtnEdit.Visibility = & $vis $edit
    $ui.BtnConsole.Visibility = & $vis $term
    $ui.TabItemTerminal.Visibility = & $vis $term
    if (-not $term) { $ui.TabOutput.SelectedItem = $ui.TabItemOutput }
    $edition = $(if ($PSVersionTable.PSEdition -eq 'Core') { 'PowerShell' } else { 'Windows PowerShell' })
    $who = $(if ($script:IsAdmin) { 'Administrator' } else { 'Standard user (UAC per script)' })
    $roleText = ''
    if ($name -ne 'Administrator') { $roleText = "  |  Role: $name" }
    $ui.TxtShellInfo.Text = "$edition $($PSVersionTable.PSVersion)  |  $who  |  $env:COMPUTERNAME$roleText"
}

# ---------------------------------------------------------------------------
#  Favorites, files
# ---------------------------------------------------------------------------

function Switch-TKFavorite {
    $s = $script:Selected
    if (-not $s) { return }
    $favs = New-Object System.Collections.Generic.List[string]
    foreach ($f in @($script:Settings.Favorites)) { if ($f) { $favs.Add([string]$f) } }
    if ($favs.Contains($s.Id)) { $null = $favs.Remove($s.Id) } else { $favs.Add($s.Id) }
    $script:Settings.Favorites = $favs.ToArray()
    try { Save-TKSettings -Settings $script:Settings } catch { Write-TKLine -Text "Could not save settings: $($_.Exception.Message)" -Kind Warning }
    Import-TKLibrary -SelectId $s.Id
}

function Show-TKInFolder {
    param([string]$Path)
    try { Start-Process -FilePath explorer.exe -ArgumentList "/select,`"$Path`"" } catch { }
}

# ---------------------------------------------------------------------------
#  Settings dialog
# ---------------------------------------------------------------------------

function Show-TKSettingsDialog {
    $d = Read-TKWindow 'SettingsWindow.xaml'
    $d.Window.Owner = $script:Win
    $d.Window.Tag = $d
    $d.Themes = Get-TKThemes
    $d.Colors = [ordered]@{}
    foreach ($k in Get-TKThemeKeys) { $d.Colors[$k] = [string]$script:Settings.Colors[$k] }
    $d.Boxes = @{}

    foreach ($name in $d.Themes.Keys) { $null = $d.CmbPreset.Items.Add($name) }
    if ($d.Themes.Contains([string]$script:Settings.ThemeName)) { $d.CmbPreset.SelectedItem = [string]$script:Settings.ThemeName }

    $labels = [ordered]@{
        Output = 'Normal output'; Info = 'Info (cyan)'; Success = 'Success (green)'; Warning = 'Warnings (yellow)'
        Error = 'Errors (red)'; Verbose = 'Dim / verbose (gray)'; Command = 'Commands and headers'; OutputBackground = 'Output background'
    }
    $uiLabels = [ordered]@{
        Background = 'Window background'; Panel = 'Side panels'; Card = 'Cards and inputs'; Border = 'Borders'
        Text = 'Main text'; SubText = 'Secondary text'; Accent = 'Accent'; AccentText = 'Text on accent'
    }
    foreach ($pair in @(@{ Grid = $d.GridOutputColors; Labels = $labels }, @{ Grid = $d.GridUiColors; Labels = $uiLabels })) {
        foreach ($key in $pair.Labels.Keys) {
            $row = New-Object System.Windows.Controls.DockPanel
            $row.Margin = New-TKThickness 0 0 14 8
            $sw = New-Object System.Windows.Controls.Button
            $sw.Width = 30
            $sw.Height = 24
            $sw.Padding = New-TKThickness 0 0 0 0
            $sw.Margin = New-TKThickness 0 0 8 0
            $sw.Tag = $key
            $sw.ToolTip = 'Pick a color'
            [System.Windows.Controls.DockPanel]::SetDock($sw, 'Left')
            $tb = New-Object System.Windows.Controls.TextBox
            $tb.Width = 92
            $tb.Tag = $key
            $tb.Text = $d.Colors[$key]
            [System.Windows.Controls.DockPanel]::SetDock($tb, 'Left')
            $lb = New-Object System.Windows.Controls.TextBlock
            $lb.Text = $pair.Labels[$key]
            $lb.Margin = New-TKThickness 8 0 0 0
            $lb.VerticalAlignment = 'Center'
            $null = $row.Children.Add($sw)
            $null = $row.Children.Add($tb)
            $null = $row.Children.Add($lb)
            $null = $pair.Grid.Children.Add($row)
            $d.Boxes[$key] = @{ Swatch = $sw; Text = $tb }
            $sw.Add_Click({
                param($sender, $e)
                $dd = [System.Windows.Window]::GetWindow($sender).Tag
                $k = [string]$sender.Tag
                $cd = New-Object System.Windows.Forms.ColorDialog
                $cd.FullOpen = $true
                try { $cd.Color = [System.Drawing.ColorTranslator]::FromHtml($dd.Colors[$k]) } catch { }
                if ($cd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                    $dd.Boxes[$k].Text.Text = ('#{0:X2}{1:X2}{2:X2}' -f $cd.Color.R, $cd.Color.G, $cd.Color.B)
                }
            })
            $tb.Add_TextChanged({
                param($sender, $e)
                $dd = [System.Windows.Window]::GetWindow($sender).Tag
                if (-not $dd) { return }
                $k = [string]$sender.Tag
                $t = $sender.Text.Trim()
                if ($t -match '^#[0-9A-Fa-f]{6}$') {
                    $dd.Colors[$k] = $t
                    Update-TKSettingsPreview $dd
                }
            })
        }
    }

    # Fonts: monospaced families installed on this PC
    $known = @('Cascadia Mono', 'Cascadia Code', 'Consolas', 'Lucida Console', 'Courier New', 'JetBrains Mono', 'Fira Code', 'Fira Mono',
        'Source Code Pro', 'Hack', 'DejaVu Sans Mono', 'IBM Plex Mono', 'Ubuntu Mono', 'Roboto Mono', 'Inconsolata', 'Noto Sans Mono')
    $installed = @([System.Windows.Media.Fonts]::SystemFontFamilies | ForEach-Object { $_.Source })
    $fonts = @($installed | Where-Object { $known -contains $_ -or $_ -match 'Mono|Code|Console' } | Sort-Object -Unique)
    if (-not $fonts.Count) { $fonts = @('Consolas') }
    foreach ($f in $fonts) { $null = $d.CmbFont.Items.Add($f) }
    if ($fonts -contains [string]$script:Settings.FontFamily) { $d.CmbFont.SelectedItem = [string]$script:Settings.FontFamily } else { $d.CmbFont.SelectedIndex = 0 }
    $d.SldSize.Value = [double]$script:Settings.FontSize
    $d.TxtSize.Text = "$([int]$d.SldSize.Value) pt"

    foreach ($o in @('Auto', 'PowerShell 7', 'Windows PowerShell 5.1')) { $null = $d.CmbShell.Items.Add($o) }
    $d.CmbShell.SelectedItem = [string]$script:Settings.PreferredShell
    if ($d.CmbShell.SelectedIndex -lt 0) { $d.CmbShell.SelectedIndex = 0 }
    $d.ChkWT.IsChecked = [bool]$script:Settings.UseWindowsTerminal
    $d.TxtReports.Text = [string]$script:Settings.ReportFolder
    $d.ChkConfirm.IsChecked = [bool]$script:Settings.ConfirmChanges
    $d.ChkAudit.IsChecked = [bool]$script:Settings.AuditChanges
    $d.RoleConfig = Get-TKRoles
    foreach ($rn in $d.RoleConfig.Roles.Keys) { $null = $d.CmbRole.Items.Add($rn) }
    $d.CmbRole.SelectedItem = $script:RoleName
    $d.TxtRoleInfo.Text = [string]$d.RoleConfig.Roles[$script:RoleName]['Description']
    $d.CmbRole.Add_SelectionChanged({
        param($sender, $e)
        $dd = [System.Windows.Window]::GetWindow($sender).Tag
        if ($dd) { $dd.TxtRoleInfo.Text = [string]$dd.RoleConfig.Roles[[string]$sender.SelectedItem]['Description'] }
    })
    if ($script:RoleName -ne 'Administrator' -and $script:Settings.RolePinHash) {
        $d.ChkConfirm.IsEnabled = $false
        $d.ChkAudit.IsEnabled = $false
    }
    Update-TKSettingsPreview $d

    $d.CmbPreset.Add_SelectionChanged({
        param($sender, $e)
        $dd = [System.Windows.Window]::GetWindow($sender).Tag
        $preset = $dd.Themes[[string]$sender.SelectedItem]
        if (-not $preset) { return }
        foreach ($k in @($dd.Boxes.Keys)) { if ($preset[$k]) { $dd.Boxes[$k].Text.Text = [string]$preset[$k] } }
    })
    $d.BtnResetColors.Add_Click({
        param($sender, $e)
        $dd = [System.Windows.Window]::GetWindow($sender).Tag
        $preset = $dd.Themes[[string]$dd.CmbPreset.SelectedItem]
        if (-not $preset) { return }
        foreach ($k in @($dd.Boxes.Keys)) { if ($preset[$k]) { $dd.Boxes[$k].Text.Text = [string]$preset[$k] } }
    })
    $d.CmbFont.Add_SelectionChanged({ param($sender, $e) $dd = [System.Windows.Window]::GetWindow($sender).Tag; if ($dd) { Update-TKSettingsPreview $dd } })
    $d.SldSize.Add_ValueChanged({ param($sender, $e) $dd = [System.Windows.Window]::GetWindow($sender).Tag; if ($dd) { $dd.TxtSize.Text = "$([int]$sender.Value) pt"; Update-TKSettingsPreview $dd } })
    $d.BtnBrowseReports.Add_Click({
        param($sender, $e)
        $dd = [System.Windows.Window]::GetWindow($sender).Tag
        $fb = New-Object System.Windows.Forms.FolderBrowserDialog
        $fb.Description = 'Folder for CSV and HTML exports'
        if ($fb.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $dd.TxtReports.Text = $fb.SelectedPath }
    })
    $d.BtnSave.Add_Click({
        param($sender, $e)
        $w = [System.Windows.Window]::GetWindow($sender)
        $w.Tag.Result = 'save'
        $w.Close()
    })

    $null = $d.Window.ShowDialog()
    if ($d.Result -ne 'save') { return }

    $oldShell = [string]$script:Settings.PreferredShell
    $script:Settings.ThemeName = [string]$d.CmbPreset.SelectedItem
    $script:Settings.Colors = $d.Colors
    $script:Settings.FontFamily = [string]$d.CmbFont.SelectedItem
    $script:Settings.FontSize = [int]$d.SldSize.Value
    $script:Settings.PreferredShell = [string]$d.CmbShell.SelectedItem
    $script:Settings.UseWindowsTerminal = [bool]$d.ChkWT.IsChecked
    $script:Settings.ReportFolder = $d.TxtReports.Text.Trim()
    $script:Settings.ConfirmChanges = [bool]$d.ChkConfirm.IsChecked
    $script:Settings.AuditChanges = [bool]$d.ChkAudit.IsChecked
    $newRole = [string]$d.CmbRole.SelectedItem
    if (-not $newRole) { $newRole = $script:RoleName }
    $pinChanged = $d.PwdPin.SecurePassword.Length -gt 0
    if ($newRole -ne $script:RoleName -or $pinChanged) {
        if (Test-TKPinGate) {
            $script:Settings.ActiveRole = $newRole
            if ($pinChanged) { $script:Settings.RolePinHash = Get-TKPinHash $d.PwdPin.SecurePassword }
            if ($newRole -ne 'Administrator' -and -not $script:Settings.RolePinHash) {
                Show-TKMessage "Role set to '$newRole'. No admin PIN is set, so anyone can switch back in Settings. Set a PIN to lock it."
            }
        }
    }
    try { Save-TKSettings -Settings $script:Settings } catch { Show-TKMessage -Title 'Settings not saved' -Message "Could not write Config\settings.json (is the USB read-only?)`n`n$($_.Exception.Message)" }
    Set-TKTheme $script:Settings.Colors
    Set-TKFonts
    Set-TKActiveRole
    $keep = $null
    if ($script:Selected) { $keep = $script:Selected.Id }
    Import-TKLibrary -SelectId $keep
    if ($oldShell -ne $script:Settings.PreferredShell) {
        Show-TKMessage 'The PowerShell choice takes effect the next time you start Tech Kit.'
    }
}

function Update-TKSettingsPreview {
    param($D)
    foreach ($k in @($D.Boxes.Keys)) {
        $D.Boxes[$k].Swatch.Background = New-TKBrush (ConvertTo-TKColor $D.Colors[$k])
    }
    $D.BrdPreview.Background = New-TKBrush (ConvertTo-TKColor $D.Colors.OutputBackground)
    $D.PnlPreview.Children.Clear()
    $font = Get-TKMonoFont ([string]$D.CmbFont.SelectedItem)
    $size = [double]$D.SldSize.Value
    $lines = @(
        @('Command', 'PS C:\> Get-NetworkConfig'),
        @('Output', 'Name    IPv4Address     Gateway       DNS'),
        @('Output', 'Wi-Fi   192.168.1.42    192.168.1.1   1.1.1.1'),
        @('Info', 'Checking DNS resolution...'),
        @('Success', 'PASS  Internet reachable (18 ms)'),
        @('Warning', 'WARNING: Disk C: is 91% full'),
        @('Error', 'ERROR: Access is denied'),
        @('Verbose', 'VERBOSE: Querying WMI on PC-042')
    )
    foreach ($l in $lines) {
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = $l[1]
        $t.FontFamily = $font
        $t.FontSize = $size
        $t.Foreground = New-TKBrush (ConvertTo-TKColor $D.Colors[$l[0]])
        $null = $D.PnlPreview.Children.Add($t)
    }
}

# ---------------------------------------------------------------------------
#  Script editor
# ---------------------------------------------------------------------------

function Get-TKCategoryFolders {
    $root = Get-TKPath Scripts
    @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -ExpandProperty Name)
}

function ConvertTo-TKFileName {
    param([string]$Name, [string]$Extension)
    $words = @(($Name -replace '[^\w\s-]', ' ') -split '[\s_-]+' | Where-Object { $_ })
    $base = ($words | ForEach-Object { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1) }) -join '-'
    if (-not $base) { $base = 'New-Script' }
    $base + $Extension
}

function Get-TKTemplateBody {
    param([string]$Language)
    $file = switch ($Language) { 'Python' { 'New-Script.py' } 'Bash' { 'New-Script.sh' } default { 'New-Script.ps1' } }
    $path = Join-Path (Get-TKPath Templates) $file
    if (Test-Path -LiteralPath $path) { return (Split-TKScriptFile -Path $path).Body }
    ''
}

function Show-TKEditor {
    param($Existing)
    $d = Read-TKWindow 'EditorWindow.xaml'
    $d.Window.Owner = $script:Win
    $d.Window.Tag = $d
    $d.Existing = $Existing
    $d.TxtBody.FontFamily = Get-TKMonoFont $script:Settings.FontFamily
    $d.TxtBody.FontSize = [double]$script:Settings.FontSize

    $folders = @(Get-TKCategoryFolders)
    foreach ($f in $folders) { $null = $d.CmbCategory.Items.Add($f) }
    foreach ($l in @('PowerShell', 'Python', 'Bash')) { $null = $d.CmbLanguage.Items.Add($l) }

    if ($Existing) {
        $d.Window.Title = "Edit script - $($Existing.Name)"
        $m = $Existing.Meta
        $d.TxtName.Text = $Existing.Name
        $d.TxtDesc.Text = $Existing.Description
        $d.CmbCategory.SelectedItem = $Existing.CategoryFolder
        $d.CmbLanguage.SelectedItem = $Existing.Language
        $d.CmbLanguage.IsEnabled = $false
        $d.TxtFile.Text = $Existing.FileName
        $d.ChkAdmin.IsChecked = $Existing.Admin
        $d.ChkChanges.IsChecked = $Existing.Changes
        $d.ChkLocal.IsChecked = ($Existing.Targets -contains 'Local') -or -not $Existing.SupportsRemote
        $d.ChkRemote.IsChecked = $Existing.SupportsRemote
        $d.ChkGraph.IsChecked = $Existing.Connect -contains 'Graph'
        $d.ChkExchange.IsChecked = $Existing.Connect -contains 'Exchange'
        $d.ChkCompliance.IsChecked = $Existing.Connect -contains 'Compliance'
        $d.TxtScopes.Text = $Existing.Scopes -join ', '
        $d.TxtModules.Text = $Existing.Modules -join ', '
        $d.TxtTags.Text = $Existing.Tags -join ', '
        $d.TxtAuthor.Text = $Existing.Author
        $d.TxtParamLines.Text = @($Existing.ParamLines) -join "`r`n"
        $parts = Split-TKScriptFile -Path $Existing.Path
        $d.Shebang = $parts.Shebang
        $d.TxtBody.Text = $parts.Body
    } else {
        $d.Window.Title = 'New script'
        $sel = $null
        if ($script:CurrentCategory -notin @('all', 'fav')) { $sel = $script:CurrentCategory }
        if ($sel -and $folders -contains $sel) { $d.CmbCategory.SelectedItem = $sel } elseif ($folders.Count) { $d.CmbCategory.SelectedIndex = 0 }
        $d.CmbLanguage.SelectedItem = 'PowerShell'
        $d.TxtBody.Text = Get-TKTemplateBody 'PowerShell'
        $d.Shebang = ''
    }

    $updateHint = {
        param($dd)
        $lang = [string]$dd.CmbLanguage.SelectedItem
        if ($lang -eq 'PowerShell') {
            $dd.TxtHint.Text = 'PowerShell: inputs come from the param() block. [switch] = checkbox, [ValidateSet()] = dropdown, [securestring] = password box, [string[]] = list. Use [CmdletBinding(SupportsShouldProcess)] and $PSCmdlet.ShouldProcess() to support What-If. Write-Host -ForegroundColor colors follow your theme.'
            $dd.PnlParamLines.Visibility = 'Collapsed'
        } else {
            $dd.TxtHint.Text = "${lang}: inputs are defined on the left (one per line) and arrive as --Name value arguments. A What-If run adds --whatif. Exit with a non-zero code to report failure."
            $dd.PnlParamLines.Visibility = 'Visible'
        }
    }
    & $updateHint $d

    $d.CmbLanguage.Add_SelectionChanged({
        param($sender, $e)
        $dd = [System.Windows.Window]::GetWindow($sender).Tag
        if (-not $dd -or $dd.Existing) { return }
        $lang = [string]$sender.SelectedItem
        $dd.TxtBody.Text = Get-TKTemplateBody $lang
        $ext = switch ($lang) { 'Python' { '.py' } 'Bash' { '.sh' } default { '.ps1' } }
        if ($dd.TxtFile.Text) { $dd.TxtFile.Text = [IO.Path]::ChangeExtension($dd.TxtFile.Text, $ext) }
        if ($lang -eq 'PowerShell') {
            $dd.TxtHint.Text = 'PowerShell: inputs come from the param() block.'
            $dd.PnlParamLines.Visibility = 'Collapsed'
        } else {
            $dd.TxtHint.Text = "${lang}: inputs are defined on the left (one per line) and arrive as --Name value arguments. A What-If run adds --whatif."
            $dd.PnlParamLines.Visibility = 'Visible'
        }
    })
    $d.TxtName.Add_TextChanged({
        param($sender, $e)
        $dd = [System.Windows.Window]::GetWindow($sender).Tag
        if (-not $dd -or $dd.Existing) { return }
        $ext = switch ([string]$dd.CmbLanguage.SelectedItem) { 'Python' { '.py' } 'Bash' { '.sh' } default { '.ps1' } }
        $dd.TxtFile.Text = ConvertTo-TKFileName $sender.Text $ext
    })
    $d.BtnCheck.Add_Click({
        param($sender, $e)
        $dd = [System.Windows.Window]::GetWindow($sender).Tag
        if ([string]$dd.CmbLanguage.SelectedItem -ne 'PowerShell') { $dd.TxtCheck.Text = 'Syntax checking is available for PowerShell scripts.'; return }
        $errs = @(Test-TKScriptSyntax -Text $dd.TxtBody.Text)
        if ($errs.Count) {
            $dd.TxtCheck.Text = 'Syntax errors: ' + ($errs -join '   ')
            Set-TKResourceRef $dd.TxtCheck ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'ErrorBrush'
        } else {
            $dd.TxtCheck.Text = 'No syntax errors found.'
            Set-TKResourceRef $dd.TxtCheck ([System.Windows.Controls.TextBlock]::ForegroundProperty) 'SuccessBrush'
        }
    })
    $d.BtnPaste.Add_Click({
        param($sender, $e)
        $dd = [System.Windows.Window]::GetWindow($sender).Tag
        $clip = ''
        try { $clip = [System.Windows.Clipboard]::GetText() } catch { }
        if (-not $clip) { $dd.TxtCheck.Text = 'The clipboard has no text.'; return }
        Import-TKPastedScript -D $dd -Text $clip
    })
    $d.BtnExternal.Add_Click({
        param($sender, $e)
        $dd = [System.Windows.Window]::GetWindow($sender).Tag
        if (-not $dd.Existing) { $dd.TxtCheck.Text = 'Save the script first, then open it in an external editor.'; return }
        $code = Get-Command code.cmd -ErrorAction SilentlyContinue | Select-Object -First 1
        try {
            if ($code) { Start-Process -FilePath $code.Source -ArgumentList "`"$($dd.Existing.Path)`"" }
            else { Start-Process -FilePath notepad.exe -ArgumentList "`"$($dd.Existing.Path)`"" }
            $dd.TxtCheck.Text = 'Opened externally. Click Reload library in Tech Kit after you save there (and close this editor without saving).'
        } catch { $dd.TxtCheck.Text = $_.Exception.Message }
    })
    $d.BtnSave.Add_Click({
        param($sender, $e)
        $w = [System.Windows.Window]::GetWindow($sender)
        if (Save-TKEditor $w.Tag) { $w.Tag.Result = 'saved'; $w.Close() }
    })

    $null = $d.Window.ShowDialog()
    if ($d.Result -eq 'saved') {
        Import-TKLibrary -SelectId $d.SavedId
        Write-TKLine -Text "Saved script: $($d.SavedId)" -Kind Success
    }
}

function Import-TKPastedScript {
    # Pasting a script you found (or one with a Tech Kit header) fills the form.
    param($D, [string]$Text)
    $lines = $Text -split "`r?`n"
    $meta = [ordered]@{}
    $params = @()
    $bodyLines = New-Object System.Collections.Generic.List[string]
    $inHeader = $true
    foreach ($l in $lines) {
        if ($inHeader -and $l -match '^\s*#\s*@([A-Za-z][\w-]*)\s*:\s?(.*)$') {
            if ($Matches[1] -eq 'Param') { $params += $Matches[2].Trim() } else { $meta[$Matches[1]] = $Matches[2].Trim() }
            continue
        }
        if ($inHeader -and $l.StartsWith('#!')) { continue }
        if ($l.Trim()) { $inHeader = $false }
        if (-not $inHeader) { $bodyLines.Add($l) }
    }
    $D.TxtBody.Text = ($bodyLines -join "`r`n")
    if ($meta['Name']) { $D.TxtName.Text = $meta['Name'] }
    if ($meta['Description']) { $D.TxtDesc.Text = $meta['Description'] }
    if ($meta.Contains('Admin')) { $D.ChkAdmin.IsChecked = ConvertTo-TKBool $meta['Admin'] }
    if ($meta.Contains('Changes')) { $D.ChkChanges.IsChecked = ConvertTo-TKBool $meta['Changes'] }
    if ($meta['Target']) { $D.ChkRemote.IsChecked = $meta['Target'] -match 'Remote|SSH' }
    if ($meta['Connect']) {
        $D.ChkGraph.IsChecked = $meta['Connect'] -match 'Graph'
        $D.ChkExchange.IsChecked = $meta['Connect'] -match 'Exchange'
        $D.ChkCompliance.IsChecked = $meta['Connect'] -match 'Compliance'
    }
    if ($meta['Scopes']) { $D.TxtScopes.Text = $meta['Scopes'] }
    if ($meta['Modules']) { $D.TxtModules.Text = $meta['Modules'] }
    if ($meta['Tags']) { $D.TxtTags.Text = $meta['Tags'] }
    if ($meta['Author']) { $D.TxtAuthor.Text = $meta['Author'] }
    if ($params.Count) { $D.TxtParamLines.Text = $params -join "`r`n" }

    # Comment-based help (.SYNOPSIS / .DESCRIPTION) fills empty name and description
    if (-not $D.TxtDesc.Text -and $Text -match '(?s)\.SYNOPSIS\s*\r?\n(.+?)(\r?\n\s*\r?\n|\r?\n\s*\.[A-Z])') {
        $D.TxtDesc.Text = ($Matches[1] -replace '\s+', ' ').Trim()
    }
    # Guess a few flags from the code itself
    if ($Text -match '#Requires\s+-RunAsAdministrator') { $D.ChkAdmin.IsChecked = $true }
    if ($Text -match 'Connect-MgGraph|Get-Mg\w+|Update-Mg\w+') { $D.ChkGraph.IsChecked = $true }
    if ($Text -match 'Connect-ExchangeOnline|Get-EXO\w+|Get-Mailbox') { $D.ChkExchange.IsChecked = $true }
    if ($Text -match '(?m)^\s*(Remove|Set|Disable|Enable|Restart|Stop|Reset|Clear|Update|New)-\w+') { if (-not $meta.Contains('Changes')) { $D.ChkChanges.IsChecked = $true } }
    if ($Text -match '#!/.*python' -or $Text -match '(?m)^\s*(import|from)\s+\w+') {
        if (-not $D.Existing -and $Text -notmatch '(?m)^\s*param\s*\(') { $D.CmbLanguage.SelectedItem = 'Python'; $D.TxtBody.Text = ($bodyLines -join "`r`n") }
    } elseif ($Text -match '#!/.*(ba)?sh') {
        if (-not $D.Existing) { $D.CmbLanguage.SelectedItem = 'Bash'; $D.TxtBody.Text = ($bodyLines -join "`r`n") }
    }
    $D.TxtCheck.Text = 'Pasted. Review the details on the left, then Save.'
}

function Save-TKEditor {
    param($D)
    $name = $D.TxtName.Text.Trim()
    if (-not $name) { Show-TKMessage 'Give the script a name.'; return $false }
    $lang = [string]$D.CmbLanguage.SelectedItem
    $ext = switch ($lang) { 'Python' { '.py' } 'Bash' { '.sh' } default { '.ps1' } }
    $fileName = $D.TxtFile.Text.Trim()
    if (-not $fileName) { $fileName = ConvertTo-TKFileName $name $ext }
    if ([IO.Path]::GetExtension($fileName) -ne $ext) { $fileName = [IO.Path]::ChangeExtension($fileName, $ext) }
    $fileName = ($fileName -replace '[\\/:*?"<>|]', '')

    $scriptsRoot = Get-TKPath Scripts
    $folder = [string]$D.CmbCategory.SelectedItem
    $newCat = $D.TxtNewCategory.Text.Trim() -replace '[\\/:*?"<>|]', ''
    if ($newCat) {
        $existing = @(Get-TKCategoryFolders)
        $match = $existing | Where-Object { (Get-TKCategoryName $_) -eq $newCat } | Select-Object -First 1
        if ($match) { $folder = $match }
        else {
            $nums = @($existing | ForEach-Object { if ($_ -match '^(\d+)') { [int]$Matches[1] } })
            $next = 1
            if ($nums.Count) { $next = ($nums | Measure-Object -Maximum).Maximum + 1 }
            $folder = ('{0:D2} {1}' -f $next, $newCat)
        }
    }
    if ($D.Existing -and $D.Existing.IsLibrary) {
        # Library scripts stay where they are
        $target = $D.Existing.Path
    } else {
        if (-not $folder) { Show-TKMessage 'Pick a category or type a new one.'; return $false }
        $dir = Join-Path $scriptsRoot $folder
        if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
        $target = Join-Path $dir $fileName
    }

    $body = $D.TxtBody.Text
    if ($lang -eq 'PowerShell') {
        $errs = @(Test-TKScriptSyntax -Text $body)
        if ($errs.Count) {
            $r = Show-TKDialog -Title 'Syntax errors' -Message 'The script has syntax errors. Save anyway? It will show as ERROR and will not run until fixed.' -Detail ($errs -join "`n") -Buttons @('Save anyway', 'Cancel') -Default 1
            if ($r.Button -ne 'Save anyway') { return $false }
        }
    }

    $meta = [ordered]@{}
    if ($D.Existing) { foreach ($k in $D.Existing.Meta.Keys) { $meta[$k] = $D.Existing.Meta[$k] } }
    $meta['Name'] = $name
    $meta['Description'] = ($D.TxtDesc.Text -replace '\s*\r?\n\s*', ' ').Trim()
    $meta['Admin'] = $(if ($D.ChkAdmin.IsChecked) { 'Yes' } else { 'No' })
    $meta['Changes'] = $(if ($D.ChkChanges.IsChecked) { 'Yes' } else { 'No' })
    $t = @()
    if ($D.ChkLocal.IsChecked -or -not $D.ChkRemote.IsChecked) { $t += 'Local' }
    if ($D.ChkRemote.IsChecked) { $t += 'Remote' }
    $c = @()
    if ($D.ChkGraph.IsChecked) { $c += 'Graph' }
    if ($D.ChkExchange.IsChecked) { $c += 'Exchange' }
    if ($D.ChkCompliance.IsChecked) { $c += 'Compliance' }
    if ($c.Count) { $t = @('M365') }
    $meta['Target'] = $t -join ', '
    $meta['Connect'] = $c -join ', '
    $meta['Scopes'] = $D.TxtScopes.Text.Trim()
    $meta['Modules'] = $D.TxtModules.Text.Trim()
    $meta['Tags'] = $D.TxtTags.Text.Trim()
    $meta['Author'] = $D.TxtAuthor.Text.Trim()
    $paramLines = @()
    if ($lang -ne 'PowerShell') { $paramLines = @($D.TxtParamLines.Text -split "`r?`n" | Where-Object { $_.Trim() }) }

    if (-not $D.Existing -and (Test-Path -LiteralPath $target)) {
        $r = Show-TKDialog -Title 'File exists' -Message "Scripts\$folder\$fileName already exists. Overwrite it?" -Buttons @('Overwrite', 'Cancel') -Default 1
        if ($r.Button -ne 'Overwrite') { return $false }
    }
    try {
        $choices = @{}
        if ($D.Existing -and $D.Existing.Choices) { $choices = $D.Existing.Choices }
        Set-TKScriptContent -Path $target -Meta $meta -ParamLines $paramLines -Body $body -Shebang ([string]$D.Shebang) -Choices $choices
        if ($D.Existing -and $D.Existing.Path -ne $target -and (Test-Path -LiteralPath $D.Existing.Path)) {
            Remove-Item -LiteralPath $D.Existing.Path -Force
        }
    } catch {
        Show-TKMessage -Title 'Could not save' -Message $_.Exception.Message
        return $false
    }
    if ($D.Existing -and $D.Existing.IsLibrary) { $D.SavedId = $D.Existing.Id } else { $D.SavedId = "$folder\$fileName" }
    $true
}

# ---------------------------------------------------------------------------
#  Build the window
# ---------------------------------------------------------------------------

try {
    $app = [System.Windows.Application]::Current
    if (-not $app) {
        $app = New-Object System.Windows.Application
    }
    $app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
    $themeText = [IO.File]::ReadAllText((Join-Path $script:GuiDir 'Theme.xaml'), [Text.Encoding]::UTF8)
    $script:ThemeDict = [System.Windows.Markup.XamlReader]::Parse($themeText)
    $app.Resources.MergedDictionaries.Add($script:ThemeDict)
    Set-TKTheme $script:Settings.Colors

    $ui = Read-TKWindow 'MainWindow.xaml'
    $script:Win = $ui.Window
    $script:Boxes = @{ output = (New-TKOutputBox $ui.RtbOutput); terminal = (New-TKOutputBox $ui.RtbTerminal) }
    Set-TKFonts
    $ui.ChkWrap.IsChecked = [bool]$script:Settings.WordWrap
    Set-TKWrap ([bool]$script:Settings.WordWrap)

    $edition = $(if ($PSVersionTable.PSEdition -eq 'Core') { 'PowerShell' } else { 'Windows PowerShell' })
    $role = $(if ($script:IsAdmin) { 'Administrator' } else { 'Standard user (UAC per script)' })
    $ui.TxtShellInfo.Text = "$edition $($PSVersionTable.PSVersion)  |  $role  |  $env:COMPUTERNAME"
    if ($script:IsAdmin) { $ui.BtnElevate.Visibility = 'Collapsed' }
    Set-TKActiveRole
    $script:Win.Title = "Tech Kit  -  $env:COMPUTERNAME"
} catch {
    Show-TKFatal ("Tech Kit could not build its window.`n`n" + $_.Exception.Message)
    return
}

# Keep the app alive if an event handler throws
[System.Windows.Threading.Dispatcher]::CurrentDispatcher.Add_UnhandledException({
    param($sender, $e)
    $e.Handled = $true
    try { Write-TKLine -Text ("Tech Kit error: " + $e.Exception.Message) -Kind Error } catch { }
})
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
#  Events
# ---------------------------------------------------------------------------

$ui.TxtSearch.Add_TextChanged({
    if ($ui.TxtSearch.Text) { $ui.TxtSearchHint.Visibility = 'Collapsed' } else { $ui.TxtSearchHint.Visibility = 'Visible' }
    $keep = $null
    if ($script:Selected) { $keep = $script:Selected.Id }
    Update-TKScriptList -SelectId $keep
})

$ui.LstCategories.Add_SelectionChanged({
    if ($script:SuppressCategoryEvent) { return }
    $c = $ui.LstCategories.SelectedItem
    if (-not $c) { return }
    $script:CurrentCategory = $c.Key
    Update-TKScriptList
})

$ui.LstScripts.Add_SelectionChanged({
    $item = $ui.LstScripts.SelectedItem
    if ($item) { Show-TKScriptDetails $item.Script }
})
$ui.LstScripts.Add_MouseDoubleClick({ if ($ui.LstScripts.SelectedItem -and -not $script:Job) { Invoke-TKRun } })

$ui.BtnRun.Add_Click({ Invoke-TKRun })
$ui.BtnWhatIf.Add_Click({ Invoke-TKRun -DryRun })
$ui.BtnStop.Add_Click({ Stop-TKJob })
$ui.BtnFav.Add_Click({ Switch-TKFavorite })
$ui.BtnEdit.Add_Click({ if ($script:Selected) { Show-TKEditor -Existing $script:Selected } })
$ui.BtnOpenFile.Add_Click({ if ($script:Selected) { Show-TKInFolder $script:Selected.Path } })
$ui.BtnNewScript.Add_Click({ Show-TKEditor })
$ui.BtnOpenScripts.Add_Click({ Start-Process -FilePath explorer.exe -ArgumentList "`"$(Get-TKPath Scripts)`"" })
$ui.BtnReload.Add_Click({
    $keep = $null
    if ($script:Selected) { $keep = $script:Selected.Id }
    Import-TKLibrary -SelectId $keep
    Write-TKLine -Text "Library reloaded: $(@($script:Scripts).Count) scripts." -Kind Info
})

$ui.BtnLoadList.Add_Click({ Import-TKTargetList })
$ui.BtnFromAD.Add_Click({ Find-TKADTargets })
$ui.BtnRunAs.Add_Click({ Set-TKRunAs })

$ui.BtnM365.Add_Click({
    if ($script:Job) { Show-TKMessage 'Wait for the current task to finish first.'; return }
    Show-TKConnectDialog
})
$ui.BtnConsole.Add_Click({ Show-TKConsoleMenu $ui.BtnConsole })
$ui.BtnTermPopOut.Add_Click({ Show-TKConsoleMenu $ui.BtnTermPopOut })
$ui.BtnSettings.Add_Click({ Show-TKSettingsDialog })
$ui.BtnElevate.Add_Click({
    if ($script:Job) { Show-TKMessage 'Wait for the current task to finish first.'; return }
    $exe = (Get-Process -Id $PID).Path
    try {
        Start-Process -FilePath $exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$script:SelfPath`" -NoRelaunch" -Verb RunAs
        $script:Win.Close()
    } catch {
        Write-TKLine -Text 'Administrator approval was cancelled.' -Kind Warning
    }
})

$ui.BtnClear.Add_Click({ Clear-TKBox $script:Boxes.output })
$ui.BtnCopy.Add_Click({ try { [System.Windows.Clipboard]::SetText((Get-TKBoxText $script:Boxes.output)) } catch { } })
$ui.BtnTermClear.Add_Click({ Clear-TKBox $script:Boxes.terminal })
$ui.BtnTermCopy.Add_Click({ try { [System.Windows.Clipboard]::SetText((Get-TKBoxText $script:Boxes.terminal)) } catch { } })
$ui.BtnSaveText.Add_Click({
    $sfd = New-Object Microsoft.Win32.SaveFileDialog
    $sfd.Filter = 'Text file (*.txt)|*.txt'
    $name = 'TechKit-output'
    if ($script:LastRun) { $name = ConvertTo-TKFileName $script:LastRun.Script.Name '' }
    $sfd.FileName = "$name-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
    $folder = [string]$script:Settings.ReportFolder
    if (-not $folder) { $folder = Get-TKPath Reports }
    if (Test-Path -LiteralPath $folder) { $sfd.InitialDirectory = $folder }
    if ($sfd.ShowDialog()) {
        Set-Content -LiteralPath $sfd.FileName -Value (Get-TKBoxText $script:Boxes.output) -Encoding UTF8
        Write-TKLine -Text "Saved output: " -Kind Success -NoNewLine
        Add-TKLink -Box $script:Boxes.output -Label $sfd.FileName -Target $sfd.FileName
    }
})
$ui.BtnExportCsv.Add_Click({ Export-TKLastRun -Format Csv })
$ui.BtnExportHtml.Add_Click({ Export-TKLastRun -Format Html })
$ui.BtnOpenReports.Add_Click({
    $folder = [string]$script:Settings.ReportFolder
    if (-not $folder) { $folder = Get-TKPath Reports }
    if (-not (Test-Path -LiteralPath $folder)) { $null = New-Item -ItemType Directory -Path $folder -Force }
    Start-Process -FilePath explorer.exe -ArgumentList "`"$folder`""
})
$ui.ChkWrap.Add_Click({
    $script:Settings.WordWrap = [bool]$ui.ChkWrap.IsChecked
    Set-TKWrap $script:Settings.WordWrap
    try { Save-TKSettings -Settings $script:Settings } catch { }
})

$ui.TxtTermInput.Add_PreviewKeyDown({
    param($sender, $e)
    $key = $e.Key
    if ($key -eq [System.Windows.Input.Key]::Enter) {
        $e.Handled = $true
        Invoke-TKTerminalCommand
    } elseif ($key -eq [System.Windows.Input.Key]::Up) {
        $e.Handled = $true
        if ($script:History.Count -gt 0) {
            $script:HistoryIndex = [Math]::Max(0, $script:HistoryIndex - 1)
            $ui.TxtTermInput.Text = $script:History[$script:HistoryIndex]
            $ui.TxtTermInput.CaretIndex = $ui.TxtTermInput.Text.Length
        }
    } elseif ($key -eq [System.Windows.Input.Key]::Down) {
        $e.Handled = $true
        if ($script:History.Count -gt 0) {
            $script:HistoryIndex = [Math]::Min($script:History.Count, $script:HistoryIndex + 1)
            if ($script:HistoryIndex -ge $script:History.Count) { $ui.TxtTermInput.Text = '' }
            else { $ui.TxtTermInput.Text = $script:History[$script:HistoryIndex] }
            $ui.TxtTermInput.CaretIndex = $ui.TxtTermInput.Text.Length
        }
    } elseif ($key -eq [System.Windows.Input.Key]::Tab) {
        $e.Handled = $true
        Invoke-TKTabComplete
    } elseif ($key -eq [System.Windows.Input.Key]::Escape) {
        $e.Handled = $true
        $ui.TxtTermInput.Text = ''
        $script:Completion = $null
    } else {
        $script:Completion = $null
    }
})

$ui.TabOutput.Add_SelectionChanged({
    param($sender, $e)
    if ($e.OriginalSource -ne $ui.TabOutput) { return }
    if ($ui.TabOutput.SelectedItem -eq $ui.TabItemTerminal) {
        $null = $ui.Window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Input, [Action] { $null = $ui.TxtTermInput.Focus() })
    }
})

$script:Win.Add_PreviewKeyDown({
    param($sender, $e)
    $ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
    if ($ctrl -and $e.Key -eq [System.Windows.Input.Key]::F) {
        $null = $ui.TxtSearch.Focus(); $ui.TxtSearch.SelectAll(); $e.Handled = $true
    } elseif ($e.Key -eq [System.Windows.Input.Key]::F5 -and -not $script:Job) {
        $e.Handled = $true
        Invoke-TKRun
    } elseif ($ctrl -and $e.Key -eq [System.Windows.Input.Key]::E -and $script:Selected -and (Get-TKRoleValue $script:Role 'AllowEditing' $true)) {
        $e.Handled = $true
        Show-TKEditor -Existing $script:Selected
    } elseif ($ctrl -and $e.Key -eq [System.Windows.Input.Key]::OemTilde -and (Get-TKRoleValue $script:Role 'AllowTerminal' $true)) {
        $e.Handled = $true
        $ui.TabOutput.SelectedItem = $ui.TabItemTerminal
    }
})

$script:Win.Add_Closing({
    param($sender, $e)
    if ($script:Job -and $script:Job.Kind -eq 'worker') {
        $r = Show-TKDialog -Title 'Still running' -Message 'A task is still running. Stop it and close Tech Kit?' -Buttons @('Stop and close', 'Cancel') -Default 1
        if ($r.Button -ne 'Stop and close') { $e.Cancel = $true; return }
        try { $script:Job.PS.Stop() } catch { }
    }
    try { $script:Timer.Stop() } catch { }
})

$script:Win.Add_ContentRendered({
    # Runs once, after the window first appears, so startup feels quick.
    if ($script:Started) { return }
    $script:Started = $true
    $ui.TxtStatus.Text = 'Starting the background PowerShell session...'
    Update-TKRender
    try {
        $script:Sink = New-Object TechKit.OutputSink
        $script:Worker = New-TKRunspace -Sink $script:Sink -HostName 'Tech Kit'
    } catch {
        Show-TKMessage -Title 'Background session failed' -Message ("Scripts cannot run until this is fixed.`n`n" + $_.Exception.Message)
        return
    }
    try { Import-TKLibrary } catch { Write-TKLine -Text "Could not load the script library: $($_.Exception.Message)" -Kind Error }

    $script:Timer = New-Object System.Windows.Threading.DispatcherTimer
    $script:Timer.Interval = [TimeSpan]::FromMilliseconds(100)
    $script:Timer.Add_Tick({
        try { Invoke-TKPump } catch { try { $ui.TxtStatus.Text = "Tech Kit: $($_.Exception.Message)" } catch { } }
    })
    $script:Timer.Start()

    Write-TKLine -Text 'Tech Kit is ready.' -Kind Success
    Write-TKLine -Text ("PowerShell {0} ({1})  |  {2} scripts  |  USB modules: {3}" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition, @($script:Scripts).Count, (Get-TKPath Modules)) -Kind Verbose
    Write-TKLine -Text 'Pick a script, fill in its inputs and press Run (F5). The Terminal tab shares the same session.' -Kind Verbose
    Write-TKLine -Text 'Tech Kit terminal. Commands run in the same session as your scripts, so Microsoft 365 connections carry over.' -Kind Verbose -Channel terminal
    Update-TKPrompt
    $null = Start-TKWorker -Script 'Unblock-TKFiles' -NoCollect -Label 'Preparing Tech Kit' -OnComplete { param($ok, $job) Update-TKPrompt }
})

# ---------------------------------------------------------------------------
#  Show
# ---------------------------------------------------------------------------

$null = $script:Win.ShowDialog()

try { $script:Timer.Stop() } catch { }
try { if ($script:Worker) { $script:Worker.Close(); $script:Worker.Dispose() } } catch { }
