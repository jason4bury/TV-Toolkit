@echo off
rem TV Toolkit - double-click to start it.
rem Each time, this makes (or refreshes) the TV Toolkit shortcut in this folder and in the Start menu,
rem then starts TV Toolkit from it. After the first run you can use the shortcut, the Start menu or
rem a pinned taskbar button instead: they start TV Toolkit without a console window.
rem The execution-policy bypass applies to TV Toolkit's own run only; no Windows settings are changed.
rem If TV Toolkit doesn't open, run   "TV Toolkit.cmd" debug   to start it in this window and see any errors.
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if /i "%~1"=="debug" (
    "%PS%" -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0TV-Toolkit.ps1"
    pause
    exit /b
)
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0New-TVToolkitShortcut.ps1" -Launch
if errorlevel 1 pause
