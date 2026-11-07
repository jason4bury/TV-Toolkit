@echo off
rem Starts TV Toolkit from the script. The execution-policy bypass applies to this run only;
rem no Windows settings are changed. Settings and data are kept in %APPDATA%\TV Toolkit.
cd /d "%~dp0"
if not exist "%APPDATA%\TV Toolkit\Logs" mkdir "%APPDATA%\TV Toolkit\Logs"
echo [%date% %time%] cmd started>> "%APPDATA%\TV Toolkit\Logs\launch.log"
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0src\Launch.ps1"
if errorlevel 1 echo [%date% %time%] powershell exited with code %errorlevel%>> "%APPDATA%\TV Toolkit\Logs\launch.log"
