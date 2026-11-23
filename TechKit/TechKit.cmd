@echo off
rem ===========================================================
rem  Tech Kit launcher - double-click to start.
rem  Uses PowerShell 7 from the USB (Runtimes\pwsh) or the PC if
rem  available, otherwise Windows PowerShell 5.1. Nothing is
rem  installed on the PC.
rem ===========================================================
setlocal
set "TK=%~dp0"
set "PS="
if exist "%TK%Runtimes\pwsh\pwsh.exe" set "PS=%TK%Runtimes\pwsh\pwsh.exe"
if not defined PS if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PS=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PS set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
start "Tech Kit" "%PS%" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%TK%TechKit.ps1"
endlocal
