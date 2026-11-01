<#
.SYNOPSIS
    Builds "TV Toolkit.exe" from App\TV-Toolkit.ps1, with the TV Toolkit icon.

.DESCRIPTION
    Uses the PS2EXE module to wrap the PowerShell app in a Windows program.
    It checks everything it needs first and tells you what's missing:
      - Windows, and Windows PowerShell 5.1 (it switches to it if you start it from PowerShell 7)
      - execution policy: bypassed for this run only (nothing changed permanently), and a check
        that Group Policy / Intune isn't enforcing Restricted or AllSigned
      - files downloaded from GitHub are unblocked
      - .NET Framework 4.7.2 or later
      - App\TV-Toolkit.ps1 (and that it has no syntax errors) and App\TV-Toolkit.ico
      - the PS2EXE module (offers to install it for your user account from the PowerShell Gallery)
      - that TV Toolkit.exe isn't running, so it can be replaced

    The exe is written next to "Start TV Toolkit.cmd", so both use the same Data folder.

.PARAMETER Install
    Install PS2EXE without asking if it's missing.

.PARAMETER Run
    Start TV Toolkit.exe when the build finishes.

.PARAMETER CheckOnly
    Only check the requirements, don't build.

.EXAMPLE
    .\Build-Exe.ps1
    .\Build-Exe.ps1 -Install -Run
    .\Build-Exe.ps1 -CheckOnly
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Run,
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
$Root    = $PSScriptRoot
$Source  = Join-Path $Root 'App\TV-Toolkit.ps1'
$Icon    = Join-Path $Root 'App\TV-Toolkit.ico'
$Output  = Join-Path $Root 'TV Toolkit.exe'

function Write-Step([string]$Text) { Write-Host ''; Write-Host "== $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host "   [ OK ] $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "   [WARN] $Text" -ForegroundColor Yellow }
function Write-Bad([string]$Text)  { Write-Host "   [FAIL] $Text" -ForegroundColor Red }

Write-Host 'TV Toolkit - build exe' -ForegroundColor White

# ---------------------------------------------------------------- requirements
Write-Step 'Checking requirements'
$problems = New-Object System.Collections.Generic.List[string]

# 1. Windows
if ($env:OS -ne 'Windows_NT') {
    Write-Bad 'This needs Windows - TV Toolkit is a Windows (WPF) app.'
    exit 1
}
Write-Ok ("Windows {0}" -f [Environment]::OSVersion.Version)

# 2. Windows PowerShell 5.1 - PS2EXE builds for .NET Framework, same as TV Toolkit runs on.
#    If started from PowerShell 7, run this script again in Windows PowerShell.
if ($PSVersionTable.PSEdition -eq 'Core') {
    Write-Warn "Running in PowerShell $($PSVersionTable.PSVersion) - switching to Windows PowerShell 5.1..."
    $winPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $winPs)) { Write-Bad 'Windows PowerShell 5.1 (powershell.exe) was not found.'; exit 1 }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    if ($Install)   { $argList += '-Install' }
    if ($Run)       { $argList += '-Run' }
    if ($CheckOnly) { $argList += '-CheckOnly' }
    & $winPs @argList
    exit $LASTEXITCODE
}
if ($PSVersionTable.PSVersion -lt [version]'5.1') {
    $problems.Add("Windows PowerShell 5.1 is needed (this is $($PSVersionTable.PSVersion)). Install Windows Management Framework 5.1.")
    Write-Bad "PowerShell $($PSVersionTable.PSVersion) - 5.1 needed"
} else {
    Write-Ok "Windows PowerShell $($PSVersionTable.PSVersion)"
}

# 3. Execution policy - this run only. Nothing is changed permanently: 'Process' scope ends when this window closes.
#    A policy set by Group Policy / Intune (MachinePolicy or UserPolicy) wins over that, so check for one.
try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction Stop } catch {}
$gpo = Get-ExecutionPolicy -List | Where-Object { $_.Scope -in 'MachinePolicy', 'UserPolicy' -and "$($_.ExecutionPolicy)" -ne 'Undefined' }
$blocking = @($gpo | Where-Object { "$($_.ExecutionPolicy)" -in 'Restricted', 'AllSigned' })
if ($blocking.Count -gt 0) {
    $b = $blocking[0]
    $problems.Add("Execution policy '$($b.ExecutionPolicy)' is enforced by $($b.Scope) (Group Policy / Intune), so unsigned scripts can't run here. Build on a PC without that policy, or ask for an exception.")
    Write-Bad "Execution policy $($b.ExecutionPolicy) enforced by $($b.Scope)"
} else {
    Write-Ok ("Execution policy for this run: {0}{1}" -f (Get-ExecutionPolicy), $(if ($gpo) { " (policy-set: $(($gpo | ForEach-Object { "$($_.Scope)=$($_.ExecutionPolicy)" }) -join ', '))" } else { '' }))
}

# Files downloaded from GitHub carry an 'internet' mark that can stop them running - clear it on ours
$marked = 0
foreach ($f in @($PSCommandPath, $Source, $Icon, (Join-Path $Root 'App\Launch.ps1'), (Join-Path $Root 'Start TV Toolkit.cmd'), (Join-Path $Root 'Build TV Toolkit exe.cmd'))) {
    if ($f -and (Test-Path -LiteralPath $f)) {
        if (Get-Item -LiteralPath $f -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue) { try { Unblock-File -LiteralPath $f; $marked++ } catch {} }
    }
}
if ($marked) { Write-Ok "Unblocked $marked downloaded file(s)" } else { Write-Ok 'No downloaded files needed unblocking' }

# 4. .NET Framework 4.7.2 or later (release key 461808+)
$release = 0
try { $release = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release -ErrorAction Stop).Release } catch {}
if ($release -ge 461808) {
    Write-Ok ".NET Framework 4.7.2 or later (release $release)"
} else {
    $problems.Add('.NET Framework 4.7.2 or later is needed - install it from Microsoft, or run Windows Update.')
    Write-Bad '.NET Framework 4.7.2 or later not found'
}

# 5. The app script, and that it has no syntax errors
if (Test-Path -LiteralPath $Source) {
    $tokens = $null; $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Source, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        $first = $parseErrors[0]
        $problems.Add("App\TV-Toolkit.ps1 has $($parseErrors.Count) syntax error(s). First: line $($first.Extent.StartLineNumber): $($first.Message)")
        Write-Bad "App\TV-Toolkit.ps1 has syntax errors"
    } else {
        Write-Ok ("App\TV-Toolkit.ps1 ({0:N0} KB, no syntax errors)" -f ((Get-Item -LiteralPath $Source).Length / 1KB))
    }
} else {
    $problems.Add("App\TV-Toolkit.ps1 is missing - run this script from the TV Toolkit folder.")
    Write-Bad 'App\TV-Toolkit.ps1 not found'
}

# 6. The icon
if (Test-Path -LiteralPath $Icon) {
    $bytes = [IO.File]::ReadAllBytes($Icon)
    if ($bytes.Length -gt 6 -and $bytes[0] -eq 0 -and $bytes[1] -eq 0 -and $bytes[2] -eq 1 -and $bytes[3] -eq 0) {
        Write-Ok ("App\TV-Toolkit.ico ({0} sizes)" -f [BitConverter]::ToUInt16($bytes, 4))
    } else {
        $problems.Add('App\TV-Toolkit.ico is not a valid .ico file.')
        Write-Bad 'App\TV-Toolkit.ico is not a valid icon'
    }
} else {
    $problems.Add('App\TV-Toolkit.ico is missing.')
    Write-Bad 'App\TV-Toolkit.ico not found'
}

# 7. The PS2EXE module
$ps2exe = Get-Module -ListAvailable -Name ps2exe | Sort-Object Version -Descending | Select-Object -First 1
if (-not $ps2exe) {
    Write-Warn 'The PS2EXE module is not installed.'
    $doInstall = [bool]$Install
    if (-not $doInstall -and -not $CheckOnly) {
        $answer = Read-Host '   Install PS2EXE for your user account from the PowerShell Gallery now? (Y/N)'
        $doInstall = ($answer -match '^(y|yes)$')
    }
    if ($doInstall) {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue | Where-Object { $_.Version -ge [version]'2.8.5.201' })) {
                Write-Host '   Installing the NuGet package provider...'
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
            }
            Write-Host '   Installing PS2EXE...'
            Install-Module -Name ps2exe -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
            $ps2exe = Get-Module -ListAvailable -Name ps2exe | Sort-Object Version -Descending | Select-Object -First 1
        } catch {
            $problems.Add("Couldn't install PS2EXE: $($_.Exception.Message)")
        }
    }
    if ($ps2exe) { Write-Ok "PS2EXE $($ps2exe.Version) installed" }
    elseif (-not $doInstall) { $problems.Add('PS2EXE is needed. Install it with:  Install-Module ps2exe -Scope CurrentUser   (or run this script with -Install)') }
} else {
    Write-Ok "PS2EXE $($ps2exe.Version)"
}

# 8. The exe isn't running (it can't be replaced while it is)
$running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path -eq $Output })
if ($running.Count -gt 0) {
    $problems.Add('TV Toolkit.exe is running - close it, then build again.')
    Write-Bad 'TV Toolkit.exe is running'
} else {
    Write-Ok 'TV Toolkit.exe is not running'
}

if ($problems.Count -gt 0) {
    Write-Host ''
    Write-Host 'Can''t build yet:' -ForegroundColor Red
    foreach ($p in $problems) { Write-Host "  - $p" -ForegroundColor Red }
    exit 1
}
if ($CheckOnly) {
    Write-Host ''
    Write-Host 'Everything needed is in place.' -ForegroundColor Green
    exit 0
}

# ---------------------------------------------------------------- build
Write-Step 'Building'
$scriptText = [IO.File]::ReadAllText($Source)
$appVersion = '1.0.0'
if ($scriptText -match "\`$AppVersion\s*=\s*'([0-9.]+)'") { $appVersion = $Matches[1] }
$fileVersion = (($appVersion.Split('.') + @('0', '0', '0', '0'))[0..3]) -join '.'
Write-Host "   Version $appVersion"

Import-Module ps2exe -ErrorAction Stop
$tmp = "$Output.tmp.exe"
if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }

$params = @{
    inputFile    = $Source
    outputFile   = $tmp
    iconFile     = $Icon
    title        = 'TV Toolkit'
    description  = 'TV Toolkit - desktop companion for the TV programmes on your NAS'
    product      = 'TV Toolkit'
    company      = 'Jason Rhodes'
    copyright    = "Copyright (c) $((Get-Date).Year) Jason Rhodes. MIT License."
    version      = $fileVersion
    noConsole    = $true     # a window app, no black console box
    noOutput     = $true     # don't turn stray output into message boxes
    noError      = $true     # errors go to Data\Logs\crash.log, not pop-ups
    STA          = $true     # WPF needs a single-threaded apartment
    noConfigFile = $true     # no extra .exe.config file next to the exe
}
try {
    Invoke-ps2exe @params | Out-Null
} catch {
    Write-Bad "PS2EXE failed: $($_.Exception.Message)"
    exit 1
}
if (-not (Test-Path -LiteralPath $tmp)) { Write-Bad 'PS2EXE finished but no exe was made.'; exit 1 }
Move-Item -LiteralPath $tmp -Destination $Output -Force

# ---------------------------------------------------------------- check the result
Write-Step 'Checking the exe'
$info = Get-Item -LiteralPath $Output
$vi = $info.VersionInfo
Write-Ok ("{0}  ({1:N1} MB)" -f $info.FullName, ($info.Length / 1MB))
Write-Ok ("Version {0} - {1}" -f $vi.FileVersion, $vi.FileDescription)
try {
    Add-Type -AssemblyName System.Drawing
    $ic = [Drawing.Icon]::ExtractAssociatedIcon($Output)
    if ($ic) { Write-Ok 'TV Toolkit icon embedded'; $ic.Dispose() }
} catch { Write-Warn "Couldn't read the icon back: $($_.Exception.Message)" }

Write-Host ''
Write-Host 'Done. TV Toolkit.exe uses the same Data folder as Start TV Toolkit.cmd,' -ForegroundColor Green
Write-Host 'so your settings, matches and cache carry over. Keep it in this folder.' -ForegroundColor Green
Write-Host 'Some antivirus programs are wary of new PS2EXE programs; if yours blocks it,' -ForegroundColor DarkGray
Write-Host 'allow "TV Toolkit.exe" or keep using Start TV Toolkit.cmd.' -ForegroundColor DarkGray

if ($Run) { Start-Process -FilePath $Output -WorkingDirectory $Root }
