# Identity lifecycle, delegation, approvals and audit

Tech Kit borrows the main ideas of identity-management platforms like Adaxes and
fits them into a portable tool. Everything is driven by two files in `Config`.

| Adaxes idea | In Tech Kit |
|---|---|
| User lifecycle automation | **New User (Active Directory)**, **New User (Microsoft 365)**, **Offboard User (Microsoft 365)** and **Disable User (Offboarding)**, driven by a per-client rules file |
| Business rules | `Config\Identity\<Client>.json`: naming convention, OUs, groups, licenses, Teams/SharePoint, distribution lists and offboarding defaults per department |
| Role-based delegation | `Config\roles.json`: what each role can see and run (Settings > Role), locked with an admin PIN |
| Approval workflows | Per role: a ticket number or reason, and/or a second person from an approver group signs in before any change runs |
| Reporting and auditing | `Logs\audit.csv` records every run of a script that makes changes; **View Audit Log**, **AD Changes Report**, **Privileged Groups Audit** |
| Self-service portal | Not included: a portal needs a server that is always on, which a USB tool is not |

## Business rules: `Config\Identity\<Client>.json`

Copy `Config\Identity\Example.json` to `Config\Identity\Contoso.json` (the file
name is what you pick in the *RulesProfile* dropdown) and edit it.

```json
{
  "Domain": "contoso.com",
  "Company": "Contoso Ltd",
  "UsageLocation": "GB",
  "Naming": {
    "SamAccountName": "{first}.{last}",
    "DisplayName": "{First} {Last}",
    "UserPrincipalName": "{first}.{last}@{domain}",
    "Mail": "{first}.{last}@{domain}",
    "Conflict": "{first}.{last}{n}",
    "MaxSamLength": 20
  },
  "AD":    { "DefaultOU": "OU=Users,DC=contoso,DC=com", "Groups": ["All Staff"], "MustChangePassword": true },
  "Cloud": { "Licenses": ["SPB"], "Groups": ["All Company"], "DistributionLists": [] },
  "Departments": {
    "Sales": {
      "Title": "Sales Representative",
      "OU": "OU=Sales,OU=Users,DC=contoso,DC=com",
      "ADGroups": ["Sales"],
      "CloudGroups": ["Sales Team"],
      "SharePointSites": ["Sales Team"],
      "DistributionLists": ["sales@contoso.com"],
      "Licenses": []
    }
  },
  "Offboarding": { "ConvertToShared": true, "RemoveLicenses": true, "RemoveGroups": true,
                   "HideFromGAL": true, "GrantManagerAccess": true, "ForwardToManager": false,
                   "AutoReply": "{Name} no longer works at {Company}. Please contact {Manager} at {ManagerMail}." }
}
```

- `{first}` / `{last}` are lowercase with accents and symbols removed
  (Zoe O'Brien-Muller becomes `zoe.obrien-muller`). `{First}` / `{Last}` are as
  typed. `{f}` / `{l}` are the first letters. `{n}` is a number used when a name
  is taken (`Conflict` template).
- `SharePointSites` are the names of the Microsoft 365 groups behind the sites;
  adding the user to the group gives them access to the site and the Team.
- Licenses use part numbers (`SPB` = Business Premium, `ENTERPRISEPACK` = E3).
  Run **Tenant Overview** to see the ones in a tenant. Seats are checked before
  assigning.
- Hybrid tenants: create the user with **New User (Active Directory)**, tick a
  *SyncServer* to start a delta sync, then license through group-based licensing
  or **New User (Microsoft 365)** steps.
- Department dropdowns list the departments from every rules file; the script
  checks that the one you pick exists in the chosen client's file.

Client rules files stay on the USB and are not committed to git (only
`Example.json` is).

## Delegation: `Config\roles.json`

Pick a role in **Settings > Role**. Each role has:

| Setting | Meaning |
|---|---|
| `Allow` / `Deny` | Patterns matched against `Category\Script name`, `Script name` or the file path, `*` wildcards. Deny wins. |
| `AllowChanges` | `false` hides every script that makes changes (read-only auditor). |
| `AllowTerminal` | Shows the Terminal tab and pop-out consoles. Turn off for restricted roles, or they could type any command. |
| `AllowEditing` | Shows New script / Edit / Open Scripts folder. |
| `RequireTicket` | Asks for a ticket number or reason before every change. |
| `RequireApproval` | A second person signs in before every change. They must be in `Approval.ApproverGroup` (domain group, or a local group for `.\user` accounts) and cannot be the person running the script. |

Set an **admin PIN** in Settings before handing the USB to someone in a
restricted role: leaving the role (or turning off confirmations and the audit
log) then needs the PIN.

**What roles are not:** they do not give or take away rights. A script still
runs with the signed-in account's own permissions, and someone with access to
the files can edit `roles.json`. Real delegation (a helpdesk account that can
reset passwords but not much else) is set up in Active Directory / Entra ID;
roles keep the Tech Kit window in line with it and stop honest mistakes.

## Audit log: `Logs\audit.csv`

Written for every run of a script marked *Makes changes* (including What-If
runs, marked as such, and denied approvals):

`Time, Operator, Computer, Role, Script, File, Target, Inputs, WhatIf, Ticket, Approver, RunAs, Result, Errors, Seconds`

Passwords and other secret inputs are written as `********`. Open it with
**View Audit Log** (Tech Kit category) to filter and export it, for example as
an HTML report for the client. Turn it off in Settings if you must (it is on by
default).
