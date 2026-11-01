# TV Toolkit launcher - starts the app and records anything that stops it starting.
$appDir = $PSScriptRoot
$log = Join-Path (Split-Path -Parent $appDir) 'Data\Logs\launch.log'
try { $d = Split-Path -Parent $log; if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } } catch {}
try { if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 200KB) { Remove-Item -LiteralPath $log -Force } } catch {}
function Write-LaunchLog([string]$t) { try { [IO.File]::AppendAllText($log, ("[{0}] pid {1}  {2}`r`n" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $PID, $t)) } catch {} }
Write-LaunchLog ("Launcher started - PowerShell {0}, STA={1}" -f $PSVersionTable.PSVersion, ([Threading.Thread]::CurrentThread.ApartmentState -eq 'STA'))
try {
    & (Join-Path $appDir 'TV-Toolkit.ps1') 2>&1 | ForEach-Object { Write-LaunchLog ("output: " + ($_ | Out-String).Trim()) }
    Write-LaunchLog 'App ended normally'
} catch {
    $msg = ($_ | Out-String).Trim()
    Write-LaunchLog "FAILED TO START: $msg"
    try {
        Add-Type -AssemblyName PresentationFramework
        [void][Windows.MessageBox]::Show("TV Toolkit couldn't start:`n`n$($_.Exception.Message)`n`nDetails are in Data\Logs\launch.log", 'TV Toolkit', 'OK', 'Error')
    } catch {}
}
