# TV Toolkit launcher, started by "Start TV Toolkit.cmd".
# Runs src\TV-Toolkit.ps1 and records anything that stops it starting (for example a script that
# won't load) in %APPDATA%\TV Toolkit\Logs\launch.log, with a message box so it never fails silently.
$appDir = $PSScriptRoot
$log = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'TV Toolkit\Logs\launch.log'
try { $d = Split-Path -Parent $log; if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } } catch { Write-Verbose $_.Exception.Message }
try { if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 200KB) { Remove-Item -LiteralPath $log -Force } } catch { Write-Verbose $_.Exception.Message }
function Write-LaunchLog([string]$t) { try { [IO.File]::AppendAllText($log, ("[{0}] pid {1}  {2}`r`n" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $PID, $t)) } catch { Write-Verbose $_.Exception.Message } }
Write-LaunchLog ("Launcher started - PowerShell {0}, STA={1}" -f $PSVersionTable.PSVersion, ([Threading.Thread]::CurrentThread.ApartmentState -eq 'STA'))
try {
    & (Join-Path $appDir 'TV-Toolkit.ps1') 2>&1 | ForEach-Object { Write-LaunchLog ("output: " + ($_ | Out-String).Trim()) }
    Write-LaunchLog 'App ended normally'
} catch {
    $msg = ($_ | Out-String).Trim()
    Write-LaunchLog "FAILED TO START: $msg"
    try {
        Add-Type -AssemblyName PresentationFramework
        [void][Windows.MessageBox]::Show("TV Toolkit couldn't start:`n`n$($_.Exception.Message)`n`nDetails are in:`n$log", 'TV Toolkit', 'OK', 'Error')
    } catch { Write-Verbose $_.Exception.Message }
}
