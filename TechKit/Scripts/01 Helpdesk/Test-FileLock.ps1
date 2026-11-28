# @Name:        Who Has This File Open?
# @Description: Tells you whether a file (or the files in a folder) is locked and by what: local programs (via Windows Restart Manager) and, on a file server, which user and PC have it open over the network. Can close the network handles or stop the locking program.
# @Admin:       Yes
# @Changes:     Yes
# @Target:      Local, Remote
# @Tags:        file lock, locked, in use, smb, open files, file server

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'File or folder path as seen on this computer, for example D:\Shares\Sales\Budget.xlsx')]
    [string]$Path,

    [Parameter(HelpMessage = 'Close the network (SMB) handles found on this file server')]
    [switch]$CloseNetworkHandles,

    [Parameter(HelpMessage = 'Stop the local programs that have the file open (they may lose unsaved work)')]
    [switch]$StopLockingPrograms
)

if (-not (Test-Path -LiteralPath $Path)) { throw "Path not found on $env:COMPUTERNAME : $Path" }
$full = (Resolve-Path -LiteralPath $Path).Path
$isDir = Test-Path -LiteralPath $full -PathType Container
$files = @($full)
if ($isDir) { $files = @(Get-ChildItem -LiteralPath $full -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1000 -ExpandProperty FullName) }

# 1. Simple lock test
$locked = @()
foreach ($f in $files) {
    try { $s = [IO.File]::Open($f, 'Open', 'ReadWrite', 'None'); $s.Close() } catch { $locked += $f }
}
if ($locked.Count) { Write-Host "$($locked.Count) file(s) are in use." -ForegroundColor Yellow } else { Write-Host 'No locked files found.' -ForegroundColor Green }

# 2. Which local programs (Restart Manager)
if (-not ('TKRestartManager' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class TKRestartManager
{
    [StructLayout(LayoutKind.Sequential)]
    private struct RM_UNIQUE_PROCESS { public int dwProcessId; public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct RM_PROCESS_INFO
    {
        public RM_UNIQUE_PROCESS Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string strAppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string strServiceShortName;
        public int ApplicationType;
        public uint AppStatus;
        public uint TSSessionId;
        [MarshalAs(UnmanagedType.Bool)] public bool bRestartable;
    }
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    private static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, StringBuilder strSessionKey);
    [DllImport("rstrtmgr.dll")]
    private static extern int RmEndSession(uint pSessionHandle);
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    private static extern int RmRegisterResources(uint pSessionHandle, uint nFiles, string[] rgsFilenames, uint nApplications, RM_UNIQUE_PROCESS[] rgApplications, uint nServices, string[] rgsServiceNames);
    [DllImport("rstrtmgr.dll")]
    private static extern int RmGetList(uint dwSessionHandle, out uint pnProcInfoNeeded, ref uint pnProcInfo, [In, Out] RM_PROCESS_INFO[] rgAffectedApps, ref uint lpdwRebootReasons);

    public static int[] Lockers(string[] paths)
    {
        List<int> result = new List<int>();
        uint handle;
        StringBuilder key = new StringBuilder(64);
        int rc = RmStartSession(out handle, 0, key);
        if (rc != 0) throw new Exception("RmStartSession failed: " + rc);
        try
        {
            rc = RmRegisterResources(handle, (uint)paths.Length, paths, 0, null, 0, null);
            if (rc != 0) throw new Exception("RmRegisterResources failed: " + rc);
            uint needed = 0, count = 0, reasons = 0;
            rc = RmGetList(handle, out needed, ref count, null, ref reasons);
            if (rc == 234)
            {
                RM_PROCESS_INFO[] info = new RM_PROCESS_INFO[needed];
                count = needed;
                rc = RmGetList(handle, out needed, ref count, info, ref reasons);
                if (rc != 0) throw new Exception("RmGetList failed: " + rc);
                for (int i = 0; i < count; i++) result.Add(info[i].Process.dwProcessId);
            }
            else if (rc != 0) throw new Exception("RmGetList failed: " + rc);
        }
        finally { RmEndSession(handle); }
        return result.ToArray();
    }
}
'@
}
$check = @($locked)
if (-not $check.Count -and -not $isDir) { $check = @($full) }
if ($check.Count) {
    try {
        foreach ($procId in @([TKRestartManager]::Lockers([string[]]$check) | Select-Object -Unique)) {
            $proc = Get-Process -Id $procId -IncludeUserName -ErrorAction SilentlyContinue
            if (-not $proc) { $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue }
            $owner = ''
            if ($proc -and $proc.PSObject.Properties['UserName']) { $owner = $proc.UserName }
            Write-Host "Locked by $($proc.ProcessName) (PID $procId) $owner" -ForegroundColor Yellow
            [pscustomobject]@{ Kind = 'Local program'; Who = $owner; Where = $env:COMPUTERNAME; Program = $proc.ProcessName; Id = $procId; Path = ($check -join '; ') }
            if ($StopLockingPrograms -and $proc -and $PSCmdlet.ShouldProcess("$($proc.ProcessName) (PID $procId)", 'Stop process')) {
                Stop-Process -Id $procId -Force -ErrorAction Continue
                Write-Host "Stopped $($proc.ProcessName)." -ForegroundColor Green
            }
        }
    } catch {
        Write-Host "Restart Manager check failed: $($_.Exception.Message)" -ForegroundColor DarkGray
    }
}

# 3. Network opens on this file server
if (Get-Command Get-SmbOpenFile -ErrorAction SilentlyContinue) {
    $opens = @(Get-SmbOpenFile -ErrorAction SilentlyContinue | Where-Object { $_.Path -and ($_.Path -eq $full -or $_.Path -like "$full\*") })
    foreach ($o in $opens) {
        Write-Host "Open over the network by $($o.ClientUserName) from $($o.ClientComputerName)" -ForegroundColor Yellow
        [pscustomobject]@{ Kind = 'Network (SMB)'; Who = $o.ClientUserName; Where = $o.ClientComputerName; Program = ''; Id = $o.FileId; Path = $o.Path }
        if ($CloseNetworkHandles -and $PSCmdlet.ShouldProcess("$($o.Path) opened by $($o.ClientUserName)", 'Close network handle')) {
            Close-SmbOpenFile -FileId $o.FileId -Force -ErrorAction Continue
            Write-Host 'Handle closed.' -ForegroundColor Green
        }
    }
    if (-not $opens.Count) { Write-Host 'No network (SMB) opens for this path on this server.' -ForegroundColor DarkGray }
}
