# Writing scripts for Tech Kit

Any normal PowerShell, Python or Bash script works. Tech Kit reads a few
comment lines at the top to show it nicely, and turns the script's inputs
into form fields. Scripts stay runnable on their own outside Tech Kit.

## Where scripts live

```
Scripts\
  01 Helpdesk\Get-SystemInfo.ps1
  02 Network\...
  09 My Category\My-Script.ps1     <- new folder = new category
```

- The first folder level is the category. The leading number sets the order
  and is hidden in the app.
- Files starting with `_` are ignored (use them for helpers).
- Click **Reload library** after adding files by hand.

## The header

Put these lines at the very top (Python and Bash: after the `#!` line).

```powershell
# @Name:        Disk Space Report
# @Description: One or two sentences. Shown in the list and the details pane.
# @Admin:       Yes        # needs admin on the target (UAC prompt on this PC)
# @Changes:     Yes        # makes changes (confirmation before running)
# @Target:      Local, Remote
# @Connect:     Graph, Exchange
# @Scopes:      User.Read.All, AuditLog.Read.All
# @Modules:     Microsoft.Graph.Users, ExchangeOnlineManagement
# @Shell:       5.1, 7
# @Tags:        disk, storage
# @Author:      where it came from
```

| Key | Values | Effect |
|---|---|---|
| Name | text | Display name. Defaults to the file name. |
| Description | text | Shown under the name. |
| Admin | Yes / No | ADMIN badge. Local runs get a UAC prompt if Tech Kit is not elevated. |
| Changes | Yes / No | CHANGES badge and a confirmation dialog before running. |
| Target | Local, Remote, M365 | Where it can run. `Remote` shows the Target box (WinRM for PowerShell, SSH for Bash). Without `Local` a target is required. |
| Connect | Graph, Exchange, Compliance | Microsoft 365 services it needs. Tech Kit checks the connection first. |
| Scopes | Graph permissions | Checked against your sign-in; also pre-filled in the connect dialog. |
| Modules | module names | Checked before running; Tech Kit offers to download missing ones to the USB. |
| Shell | 5.1, 7 | Warn if run on the other edition. |
| WhatIf | Yes / No | Override What-If detection (normally automatic). |
| OS, Tags, Author, Version | text | Shown and searchable. |
| Param | see Python/Bash | Inputs for non-PowerShell scripts. |

## PowerShell inputs

Tech Kit reads your `param()` block with the PowerShell parser:

```powershell
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Logon name or UPN')]
    [string]$Identity,                       # text box, required (*)

    [int]$Days = 30,                         # number box with default

    [ValidateSet('Users', 'Computers', 'Both')]
    [string]$Type = 'Both',                  # dropdown

    [switch]$IncludeDisabled,                # checkbox (off)
    [bool]$SendReport = $true,               # checkbox (on), always passed

    [string[]]$Computers,                    # multi-line list
    [securestring]$NewPassword,              # password box
    [pscredential]$Account                   # user name + password
)
```

- `HelpMessage` appears under the field.
- Defaults that are plain values are pre-filled. Computed defaults
  (`$env:COMPUTERNAME`) are shown as a hint and left to the script.
- Do not use `Read-Host` for normal inputs. It works (Tech Kit pops up a
  dialog) but parameters are clearer and work for remote and elevated runs.

## What-If

Add `SupportsShouldProcess` and wrap each change:

```powershell
if ($PSCmdlet.ShouldProcess($target, 'Delete 120 files')) {
    Remove-Item ...
}
```

Tech Kit then enables the **What-If** button, and the confirmation dialog
offers "What-If first". In a What-If run each `ShouldProcess` prints
`What if: Performing the operation "Delete 120 files" on target "..."` and
returns `$false`.

## Output

- **Return objects** (`[pscustomobject]@{...}`) for anything tabular. They show
  as a table and export to CSV / HTML.
- Use **`Write-Host -ForegroundColor`** for status lines. Colors follow the
  theme: Green = success, Yellow = warning, Red = error, Cyan = info,
  DarkGray = dim.
- `Write-Warning`, `Write-Error`, `Write-Verbose` and `Write-Progress` all
  show up (progress in the status bar).
- In the HTML report, cells that say PASS / OK / Healthy are green, FAIL /
  Critical red, WARN / Warning amber.

## Remote-friendly scripts

Remote runs send the script text to each computer with `Invoke-Command`, so:

- Use `$env:COMPUTERNAME` in output objects so multi-computer results are
  clear (Tech Kit also adds `PSComputerName`).
- Do not rely on `$PSScriptRoot` or files next to the script.
- Avoid `#Requires` lines; use the `@Modules` and `@Admin` header instead.
- Avoid `$script:` variables shared with functions; use a hashtable
  (`$state = @{}`) that functions modify.
- Prefer `Get-CimInstance` over `Get-WmiObject` (removed in PowerShell 7).

## Staying compatible with 5.1 and 7

Do not use PowerShell 7-only syntax: `? :` ternary, `??`, `?.`, `&&` / `||`,
`ForEach-Object -Parallel`, `Get-Error`. Run **Check Script Library** (Tech
Kit category) with PSScriptAnalyzer installed: it checks every script against
both versions.

## Python scripts

```python
#!/usr/bin/env python3
# @Name:        TLS Certificate Check
# @Description: ...
# @Target:      Local
# @Param:       Hosts | list! | | Host names, one per line
# @Param:       WarnDays | int | 30 | Warn when the certificate expires within this many days
# @Param:       Verbose | switch | | Show more detail
```

`@Param: Name | type | default | help`. Types: `string`, `int`, `switch`,
`bool`, `secure`, `list`, `choice(a/b/c)`. Add `!` after the type for
required. Values arrive as `--Name value` (lists comma-joined, switches as a
bare `--Name`), and a What-If run adds `--whatif`. Use `argparse`. Print
normally for output, to `stderr` for errors (shown red), and exit non-zero on
failure. Python is found in `Runtimes\python\python.exe`, then the `py`
launcher, then `python.exe` on the PATH.

## Bash scripts

Same header and `@Param` lines. Locally they run in Git Bash or WSL
(`Runtimes\git\bin\bash.exe` first). With `@Target: Remote` (or `Local,
Remote`) you can put `user@host` entries in the Target box and Tech Kit
streams the script over SSH (`ssh host 'bash -s'`). SSH must sign in with a
key (no password prompt), for example via `ssh-agent` or `~/.ssh/config`.

## Adding scripts from your sources

1. Click **+ New script** (or open an existing one and **Edit**).
2. **Paste from clipboard**: the editor keeps the code, fills in any Tech Kit
   header it finds, uses `.SYNOPSIS` for the description, and guesses Admin
   (`#Requires -RunAsAdministrator`), Changes (Set-/Remove-/... verbs),
   Graph and Exchange.
3. Check the flags, pick a category, **Check syntax**, **Save script**.
4. Run it once with **What-If** if it makes changes.

Review anything you paste from the internet before running it on a client's
network. Tech Kit runs scripts with your rights.
