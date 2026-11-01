@echo off
rem TV Toolkit launcher - keeps everything inside this folder (portable)
cd /d "%~dp0"
if not exist "%~dp0Data\Logs" mkdir "%~dp0Data\Logs"
echo [%date% %time%] cmd started>> "%~dp0Data\Logs\launch.log"
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0App\Launch.ps1"
if errorlevel 1 echo [%date% %time%] powershell exited with code %errorlevel%>> "%~dp0Data\Logs\launch.log"
