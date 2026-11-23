# Tech Kit

A portable, graphical PowerShell toolkit for IT support, networks, security,
Active Directory, Microsoft 365 and servers. Copy the folder to a USB drive,
plug it into any Windows PC, double-click **TechKit.cmd**. Nothing is
installed on the PC.

- Runs on **Windows PowerShell 5.1** (built into every Windows 10/11 and
  Server 2016+) and **PowerShell 7** (from the USB or the PC).
- **61 scripts** in 8 categories, ready to use. Add your own by dropping a file
  in a folder or with the built-in editor.
- Runs scripts on **this PC**, on **remote computers** (WinRM, a typed list, a
  file, or an Active Directory search) and against **Microsoft 365** (Graph,
  Exchange Online, Security & Compliance).
- **Per-script elevation**: Tech Kit runs as a normal user and asks for UAC
  only when a script needs admin.
- **Confirm + What-If**: scripts that change things ask first and can do a dry
  run that shows what would change.
- **Built-in terminal** sharing the same session (your M365 sign-in carries
  over), plus pop-out consoles (normal or admin, Windows Terminal if present).
- **Dark theme with custom colors**: presets, every output color, accent,
  font and size.
- **Export** any result to CSV or a styled HTML report.
- **Bash and Python** scripts run too (local, or Bash over SSH to Linux).

---

## Quick start

1. Copy the `TechKit` folder to the root of a USB drive (exFAT or NTFS).
2. On a PC with internet, open Tech Kit and run, from the **Tech Kit**
   category:
   - **Update USB Modules**: downloads Microsoft Graph and Exchange Online
     modules onto the USB (about 300-500 MB) so they work on every PC you visit.
   - **Put PowerShell 7 on the USB** (optional): Tech Kit then runs on
     PowerShell 7 even where only 5.1 is installed.
   - **Check Script Library**: self-test. Tick *InstallAnalyzer* the first time.
3. On a client PC: plug in, double-click `TechKit.cmd`, pick a script, fill in
   its inputs, press **Run** (or F5).

If you downloaded Tech Kit as a zip, right-click the zip > Properties >
**Unblock** before extracting. Tech Kit also unblocks its own files on first
start, but doing it on the zip is faster.

## The window

```
+-------------------------------------------------------------------------+
| TK Tech Kit   [ search scripts...        ]  M365 | Console | Settings   |
+--------------+------------------+---------------------------------------+
| CATEGORIES   | SCRIPTS          | Script name           Favorite  Edit  |
|  Favorites   |  Disk Space ...  | description, badges, file, modules    |
|  All scripts |  Fix Print ...   | TARGET COMPUTERS  [ PC01, PC02 ]      |
|  Helpdesk    |  ...             | INPUTS            [ fields ]          |
|  Network     |                  | [ Run ] [ What-If ] [ Stop ]          |
|  ...         |                  +---------------------------------------+
|              |                  | Output | Terminal                     |
| + New script |                  | colored live output, export, copy     |
+--------------+------------------+---------------------------------------+
```

| Badge | Meaning |
|---|---|
| ADMIN | Needs admin rights. On this PC Tech Kit asks for UAC when you press Run. |
| CHANGES | Makes changes. You get a confirmation listing the target and inputs. |
| REMOTE | Can run on other computers. A Target box appears. |
| M365 | Needs a Microsoft 365 connection. Tech Kit offers to connect if needed. |
| PY / SH | Python or Bash script. |
| ERROR | The script has a syntax error and will not run until fixed. |

Keyboard: **F5** run, **Ctrl+F** search, **Ctrl+E** edit, **Ctrl+`** terminal.

## Running on other computers

Type names in the **Target** box (commas or new lines), **Load list from
file** (txt or CSV with a Name/ComputerName column), or **Find in Active
Directory** (plain LDAP, no RSAT needed). Remote runs use PowerShell
Remoting, which is on by default on Windows Server and needs
`Enable-PSRemoting` on desktops. **Run as** lets you use different
credentials (for example a domain admin); they stay in memory only.

Active Directory scripts need the ActiveDirectory module. If the PC does not
have it, either run **Install RSAT AD Tools** or put a domain controller in
the Target box so the script runs there.

## Microsoft 365

Click **Microsoft 365: not connected** in the top bar.

| Method | When to use |
|---|---|
| Interactive | Normal case. A Microsoft sign-in opens; sign in with the client's admin account. |
| Device code | Servers or locked-down PCs. Enter the code at microsoft.com/devicelogin on your phone. |
| App + certificate | Repeat visits without prompts. Needs an app registration in the tenant and a cert (thumbprint or a .pfx in `Certs`). Works for Graph and Exchange. |
| App + client secret | Graph only (Exchange does not accept secrets). |

The Graph permission list is pre-filled from what your scripts declare. Save
tenant details as a **profile** for next time (IDs only, never passwords or
secrets). Graph sign-ins are kept in memory for the session only, so nothing
is cached on the client's PC.

## Terminal

The **Terminal** tab runs commands in the same background session as your
scripts: after connecting to Microsoft 365 you can type `Get-MgUser -Top 5`
right there. Up/Down for history, Tab to complete, Esc to clear, `cls` to
clear the screen. **Console** in the top bar opens a real PowerShell window
(5.1 or 7, normal or admin) with Tech Kit loaded:

```powershell
tk dns                              # list scripts matching "dns"
tkrun "Disk Space" -WarnPercent 20  # run a script by name
tkconnect                           # connect to Graph + Exchange
```

## Settings

**Settings** stores everything in `Config\settings.json` on the USB:
color preset (Midnight, Terminal Green, Slate, Ember, High Contrast,
Daylight), each output color (normal, info, success, warning, error, dim,
commands) and window color, the output font and size, which PowerShell runs
the window, Windows Terminal for consoles, the report folder, and whether to
confirm changes. `Write-Host -ForegroundColor` in scripts follows your theme
(Green = success color, Yellow = warning, Red = error, Cyan = info).

## Folder layout

```
TechKit\
  TechKit.cmd          double-click to start
  TechKit.ps1          the app
  Core\                engine, host, runners, window layouts (XAML)
  Scripts\             the library: one folder per category
  Templates\           starting points for new PowerShell, Python, Bash scripts
  Config\              settings, color presets, module list, tenant profiles
  Modules\             PowerShell modules carried on the USB (git-ignored)
  Runtimes\            optional portable pwsh / python / git bash (git-ignored)
  Reports\             CSV and HTML exports (git-ignored)
  Certs\               optional .pfx files for M365 app sign-in (git-ignored)
  docs\                writing scripts, design notes
```

## Adding your own scripts

See **[docs/WRITING-SCRIPTS.md](docs/WRITING-SCRIPTS.md)** (and **[docs/SCRIPT-LIST.md](docs/SCRIPT-LIST.md)** for what is included). Short version:
click **+ New script**, or paste a script you found with **Paste from
clipboard** in the editor (it fills in the name, description and flags it can
detect), or drop a `.ps1` into a category folder and click **Reload library**.

## Requirements and limits

- Windows 10/11 or Windows Server 2016 or later. Older systems with Windows
  PowerShell 5.1 installed generally work.
- PowerShell must be in **FullLanguage** mode. PCs locked down with
  AppLocker/WDAC Constrained Language mode, or with a Group Policy that forces
  the AllSigned execution policy, will not run unsigned scripts. Sign the kit
  with your code-signing certificate for those environments.
- Remote targets need WinRM (TCP 5985) open and an account with admin rights
  on the target.
- Some antivirus/EDR products watch for unusual PowerShell activity. Tech Kit
  only runs the scripts you pick, but expect alerts on tightly monitored
  networks and agree on its use with the client first.
- Graph sign-in logs and last sign-in dates need Entra ID P1.
