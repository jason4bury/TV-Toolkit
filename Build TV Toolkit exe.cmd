@echo off
rem Builds "TV Toolkit.exe". Execution policy is bypassed for this run only - nothing is changed permanently.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-Exe.ps1" %*
echo.
pause
