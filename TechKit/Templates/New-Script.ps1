# @Name:        My New Script
# @Description: One sentence about what this script does and when to use it.
# @Admin:       No
# @Changes:     No
# @Target:      Local, Remote
# @Tags:        example

<#
  Tech Kit reads the "# @" lines above. Inputs come from the param() block:
    [string]            text box
    [int]               number box
    [switch]            checkbox
    [ValidateSet()]     dropdown
    [string[]]          list (one per line)
    [securestring]      password box
    [pscredential]      user name + password
  HelpMessage shows under the field. Mandatory adds a * and must be filled in.

  For What-If support keep SupportsShouldProcess and wrap each change in
  $PSCmdlet.ShouldProcess(target, action).

  Write-Host colors follow your theme: Green = success, Yellow = warning,
  Red = error, Cyan = info. Output objects ([pscustomobject]) show as a table
  and can be exported to CSV/HTML.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(HelpMessage = 'What to look for')]
    [string]$Name = '*',

    [Parameter(HelpMessage = 'How many days back to look')]
    [int]$Days = 7,

    [switch]$Detailed
)

Write-Host "Running on $env:COMPUTERNAME" -ForegroundColor Cyan

# Example: return objects, Tech Kit turns them into a table
Get-Service -Name $Name -ErrorAction SilentlyContinue |
    Select-Object -First 10 Name, Status, StartType

# Example change guarded by What-If
if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Do the thing')) {
    Write-Host 'Change made.' -ForegroundColor Green
}
