<#
    TV Toolkit
    Desktop companion for the TV programmes on your NAS.
    PowerShell + WPF. Run with "Start TV Toolkit.cmd".
#>
$AppVersion = '1.9.0'

$CoreScript = {
# ===================== TV Toolkit core (shared by UI and background workers) =====================
# Everything in here must run without WPF so it can be loaded into background runspaces.

$script:VideoExt = @('.mkv','.mp4','.avi','.m4v','.ts','.wmv','.mov','.mpg','.mpeg','.webm','.divx','.flv','.m2ts')
$script:SkipDirs = @('#recycle','@eadir','$recycle.bin','system volume information','.trash','.ds_store','#snapshot','@recycle')
# Extras folders inside a show (theme music, trailers, featurettes...) - not episodes
$script:ExtrasDirs = @('backdrops','extras','extra','featurettes','behind the scenes','deleted scenes','interviews','scenes','shorts','trailers','other','others','samples','sample','theme-music','themes')

function Initialize-Net {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 } catch {}
}

function Set-Progress([string]$Text, [double]$Pct = -1) {
    if ($TVT -and $TVT.Sync) { $TVT.Sync.Status = $Text; $TVT.Sync.Pct = $Pct }
}

# ---------- small file helpers ----------
function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { return $null }
}
function Write-JsonFile([string]$Path, $Object) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllText($tmp, ($Object | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}
function Read-TsvMap([string]$Path) {
    # key<TAB>rest  ->  hashtable key => string[] (remaining columns)
    $map = @{}
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)) {
            if (-not $line) { continue }
            $p = $line.Split("`t")
            $map[$p[0]] = $p
        }
    }
    return $map
}
function Write-TsvLines([string]$Path, [string[]]$Lines) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllLines($tmp, $Lines, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}
function Clean-Field([string]$s) { if ($null -eq $s) { return '' } return ($s -replace "[`t`r`n]", ' ') }

# ---------- text helpers ----------
function Get-NormKey([string]$s) {
    if (-not $s) { return '' }
    $t = $s.ToLowerInvariant()
    $t = $t -replace '\(\d{4}\)', ''
    $t = $t -replace '&', 'and'
    $t = $t -replace '[''`\u2019]', ''
    $t = $t -replace '[^a-z0-9]', ''
    return $t
}
function Get-NameAndYear([string]$folder) {
    $m = [regex]::Match($folder, '^(?<n>.*?)\s*\((?<y>\d{4})\)\s*$')
    if ($m.Success) { return @($m.Groups['n'].Value.Trim(), [int]$m.Groups['y'].Value) }
    return @($folder.Trim(), 0)
}
function Get-SafeFileName([string]$s) {
    if ($null -eq $s) { return '' }
    $t = $s -replace '[\\/\*]', '-'
    $t = $t -replace '[:"<>\|\?]', ''
    $t = $t -replace '\s{2,}', ' '
    return $t.Trim().TrimEnd('.')
}
function Format-Ep([int]$s, [int]$e) { return ('{0}x{1:D2}' -f $s, $e) }
function Format-Size([double]$bytes) {
    if ($bytes -ge 1TB) { return ('{0:N2} TB' -f ($bytes / 1TB)) }
    if ($bytes -ge 1GB) { return ('{0:N2} GB' -f ($bytes / 1GB)) }
    if ($bytes -ge 1MB) { return ('{0:N0} MB' -f ($bytes / 1MB)) }
    if ($bytes -gt 0)   { return ('{0:N0} KB' -f ($bytes / 1KB)) }
    return ''
}
function Get-ResolutionTag([string]$name) {
    $n = $name.ToLowerInvariant()
    if ($n -match '2160p|\b4k\b|uhd') { return '2160p' }
    if ($n -match '1080[pi]') { return '1080p' }
    if ($n -match '720p') { return '720p' }
    if ($n -match '576[pi]|480p|\bsdtv\b|\bdvdrip\b|\bxvid\b|\bdvd\b') { return 'SD' }
    return '?'
}

# ---------- filename parsing ----------
function Get-SeasonFromFolder([string]$name) {
    if ($name -match '^(?i)specials?$') { return 0 }
    $m = [regex]::Match($name, '^(?i)(?:s|season|series)\s*0*(\d{1,3})$')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return $null
}
function ConvertFrom-EpisodeName([string]$baseName) {
    # Returns @{ S; Eps (int[]); Show; Title } or $null
    $m = [regex]::Match($baseName, '(?i)(?<![0-9a-z])(\d{1,3})x(\d{2,4})((?:(?:-|x|-\d{1,3}x)\d{2,4})*)(?![0-9])')
    $style = 'x'
    if (-not $m.Success) {
        $m = [regex]::Match($baseName, '(?i)(?<![a-z0-9])s(\d{1,3})[ ._-]?e(\d{2,4})((?:-?e\d{2,4}|-\d{2,4})*)(?![0-9])')
        $style = 'se'
    }
    if (-not $m.Success) {
        # "Show - Special 13 - Title" (usually in S00 / Specials) -> season 0
        $sp = [regex]::Match($baseName, '(?i)(?<![a-z0-9])special\s*0*(\d{1,3})(?![0-9])')
        if ($sp.Success) {
            return [pscustomobject]@{ S = 0; Eps = [int[]]@([int]$sp.Groups[1].Value); Show = $baseName.Substring(0, $sp.Index).Trim(' ', '-', '.', '_'); Title = $baseName.Substring($sp.Index + $sp.Length).Trim(' ', '-', '.', '_') }
        }
        return $null
    }
    $s = [int]$m.Groups[1].Value
    $eps = New-Object System.Collections.Generic.List[int]
    $eps.Add([int]$m.Groups[2].Value)
    $more = $m.Groups[3].Value
    if ($more) {
        if ($style -eq 'x') { $rx = '(?:-|x)(?:\d{1,3}x)?(\d{2,4})' } else { $rx = '(?i)-?e?(\d{2,4})' }
        foreach ($mm in [regex]::Matches($more, $rx)) { $v = [int]$mm.Groups[1].Value; if (-not $eps.Contains($v)) { $eps.Add($v) } }
        # A range like 01-03 means 01,02,03
        if ($eps.Count -eq 2 -and ($eps[1] - $eps[0]) -gt 1 -and ($eps[1] - $eps[0]) -lt 10) {
            $a = $eps[0]; $b = $eps[1]; $eps.Clear(); for ($i = $a; $i -le $b; $i++) { $eps.Add($i) }
        }
    }
    $show = $baseName.Substring(0, $m.Index).Trim(' ', '-', '.', '_')
    $title = $baseName.Substring($m.Index + $m.Length).Trim(' ', '-', '.', '_')
    if ($style -eq 'se' -or ($title -match '\.' -and $title -notmatch ' ')) {
        $title = ($title -replace '[\._]', ' ').Trim()
        $q = [regex]::Match($title, '(?i)\b(\d{3,4}[pi]|hdtv|pdtv|sdtv|web|webdl|web-dl|webrip|bluray|blu-ray|bdrip|brrip|dvdrip|x26[45]|h ?26[45]|hevc|xvid|proper|repack|internal|amzn|nf|iplayer|aac|ac3|dd5)\b')
        if ($q.Success) { $title = $title.Substring(0, $q.Index).Trim(' ', '-') }
        if ($show -match '\.' -and $show -notmatch ' ') { $show = ($show -replace '[\._]', ' ').Trim() }
    }
    return [pscustomobject]@{ S = $s; Eps = [int[]]$eps.ToArray(); Show = $show; Title = $title }
}

# ---------- library scan ----------
function Get-FilesSafe([string]$dir, [System.Collections.Generic.List[IO.FileInfo]]$into) {
    try {
        $di = New-Object IO.DirectoryInfo($dir)
        foreach ($f in $di.GetFiles()) { $into.Add($f) }
        foreach ($d in $di.GetDirectories()) {
            $ln = $d.Name.ToLowerInvariant()
            if ($script:SkipDirs -contains $ln -or $script:ExtrasDirs -contains $ln -or $d.Name.StartsWith('.')) { continue }
            Get-FilesSafe $d.FullName $into
        }
    } catch {}
}
function Get-NfoTvdbId([string]$showPath) {
    $nfo = Join-Path $showPath 'tvshow.nfo'
    if (-not (Test-Path -LiteralPath $nfo)) { return 0 }
    try {
        $txt = [IO.File]::ReadAllText($nfo)
        $m = [regex]::Match($txt, '(?is)<uniqueid[^>]*type="tvdb"[^>]*>\s*(\d+)\s*<')
        if ($m.Success) { return [int]$m.Groups[1].Value }
        $m = [regex]::Match($txt, '(?is)<tvdbid>\s*(\d+)\s*<')
        if ($m.Success) { return [int]$m.Groups[1].Value }
        $m = [regex]::Match($txt, '(?is)<id>\s*(\d+)\s*</id>')
        if ($m.Success) { return [int]$m.Groups[1].Value }
        $m = [regex]::Match($txt, 'thetvdb\.com/\?tab=series&(?:amp;)?id=(\d+)')
        if ($m.Success) { return [int]$m.Groups[1].Value }
    } catch {}
    return 0
}

function Invoke-LibraryScan([string[]]$Roots) {
    # Writes Data\library.tsv : ShowFolder  Root  RelPath  Size  Ticks
    # and Data\shows.tsv      : ShowFolder  Root  NfoTvdb  LocalPoster  DirTicks
    $files = New-Object System.Collections.Generic.List[string]
    $shows = New-Object System.Collections.Generic.List[string]
    $hold = ''
    if ($TVT.Settings.HoldFolder) { $hold = (Split-Path -Leaf $TVT.Settings.HoldFolder).ToLowerInvariant() }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($root in $Roots) {
        if (-not $root) { continue }
        if (-not (Test-Path -LiteralPath $root)) { Set-Progress "Can't reach $root"; continue }
        try { foreach ($d in (New-Object IO.DirectoryInfo($root)).GetDirectories()) { $list.Add(@($root, $d)) } } catch {}
    }
    $i = 0
    foreach ($pair in $list) {
        $i++
        $root = $pair[0]; $d = $pair[1]
        $lname = $d.Name.ToLowerInvariant()
        if ($script:SkipDirs -contains $lname -or $d.Name.StartsWith('.') -or ($hold -and $lname -eq $hold)) { continue }
        Set-Progress ("Scanning {0} ({1} of {2})" -f $d.Name, $i, $list.Count) ($i / [math]::Max(1, $list.Count) * 100)
        $fl = New-Object System.Collections.Generic.List[IO.FileInfo]
        Get-FilesSafe $d.FullName $fl
        $poster = ''
        foreach ($p in 'poster.jpg','folder.jpg','show.jpg','poster.png','folder.png') {
            if (Test-Path -LiteralPath (Join-Path $d.FullName $p)) { $poster = $p; break }
        }
        $nfo = Get-NfoTvdbId $d.FullName
        $shows.Add(($d.Name + "`t" + $root + "`t" + $nfo + "`t" + $poster + "`t" + $d.LastWriteTimeUtc.Ticks))
        $prefix = $d.FullName.Length + 1
        foreach ($f in $fl) {
            if ($script:VideoExt -notcontains $f.Extension.ToLowerInvariant()) { continue }
            if ($f.Name -match '(?i)(^|[ ._-])sample([ ._-]|$)') { continue }
            if ($f.BaseName -match '(?i)^(theme|backdrop|trailer)\d*$' -or $f.BaseName -match '(?i)-(trailer|featurette|behindthescenes|deleted|interview|scene|short|other)$') { continue }
            $rel = $f.FullName.Substring($prefix)
            $files.Add(($d.Name + "`t" + $root + "`t" + $rel + "`t" + $f.Length + "`t" + $f.LastWriteTimeUtc.Ticks + "`t" + $f.CreationTimeUtc.Ticks))
        }
    }
    Write-TsvLines (Join-Path $TVT.DataDir 'library.tsv') $files.ToArray()
    Write-TsvLines (Join-Path $TVT.DataDir 'shows.tsv') $shows.ToArray()
    Set-Progress ("Scan finished: {0} shows, {1} video files" -f $shows.Count, $files.Count) 100
    return $shows.Count
}

# ---------- real video details (resolution / length) ----------
function Get-MediaCachePath { return (Join-Path $TVT.DataDir 'mediainfo.tsv') }
function Import-MediaInfo { return (Read-TsvMap (Get-MediaCachePath)) }   # path -> [path, size, ticks, width, height, seconds, source]
function Get-VideoClass([int]$w, [int]$h) {
    if ($w -le 0 -and $h -le 0) { return '?' }
    if ($w -ge 3000 -or $h -ge 1800) { return '2160p' }
    if ($w -ge 1800 -or $h -ge 1000) { return '1080p' }
    if ($w -ge 1200 -or $h -ge 700) { return '720p' }
    return 'SD'
}
function Find-FFprobe {
    $c = Get-Command ffprobe.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    foreach ($p in @("$env:LOCALAPPDATA\Microsoft\WinGet\Links\ffprobe.exe", "$env:ProgramFiles\ffmpeg\bin\ffprobe.exe", 'C:\ffmpeg\bin\ffprobe.exe', "$env:USERPROFILE\scoop\shims\ffprobe.exe", "$env:ProgramData\chocolatey\bin\ffprobe.exe")) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    $wg = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if (Test-Path -LiteralPath $wg) {
        $hit = Get-ChildItem -LiteralPath $wg -Filter 'ffprobe.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}
function Invoke-MediaProbe($items, [switch]$All) {
    # items: arrays of @(path, size, ticks). Reads width/height/length via Windows' property system, then ffprobe as a fallback.
    $cache = Import-MediaInfo
    $todo = @($items | Where-Object { $All -or -not $cache.ContainsKey($_[0]) -or [int64]$cache[$_[0]][1] -ne [int64]$_[1] })
    $ff = Find-FFprobe
    $shell = $null; try { $shell = New-Object -ComObject Shell.Application } catch {}
    $ok = 0; $viaFf = 0; $failed = 0; $i = 0
    $byDir = $todo | Group-Object { [IO.Path]::GetDirectoryName($_[0]) }
    foreach ($g in $byDir) {
        $ns = $null; if ($shell) { try { $ns = $shell.Namespace($g.Name) } catch {} }
        foreach ($it in $g.Group) {
            $i++
            Set-Progress ("Reading video details {0}/{1}" -f $i, $todo.Count) ($i / [math]::Max(1, $todo.Count) * 100)
            $w = 0; $h = 0; $sec = 0; $src = ''
            if ($ns) {
                try {
                    $fi = $ns.ParseName([IO.Path]::GetFileName($it[0]))
                    if ($fi) {
                        $w = [int]("0" + $fi.ExtendedProperty('System.Video.FrameWidth'))
                        $h = [int]("0" + $fi.ExtendedProperty('System.Video.FrameHeight'))
                        $d = $fi.ExtendedProperty('System.Media.Duration'); if ($d) { $sec = [int]([double]$d / 10000000) }
                        if ($w -gt 0) { $src = 'windows' }
                    }
                } catch {}
            }
            if ($w -le 0 -and $ff) {
                try {
                    $out = & $ff -v error -select_streams v:0 -show_entries stream=width,height:format=duration -of default=noprint_wrappers=1 -- "$($it[0])" 2>$null
                    foreach ($line in @($out)) {
                        if ($line -match '^width=(\d+)') { $w = [int]$Matches[1] }
                        elseif ($line -match '^height=(\d+)') { $h = [int]$Matches[1] }
                        elseif ($line -match '^duration=([\d\.]+)') { $sec = [int][double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture) }
                    }
                    if ($w -gt 0) { $src = 'ffprobe'; $viaFf++ }
                } catch {}
            }
            if ($w -gt 0) { $ok++ } else { $failed++ }
            $cache[$it[0]] = @($it[0], "$($it[1])", "$($it[2])", "$w", "$h", "$sec", $src)
        }
    }
    if ($shell) { try { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) } catch {} }
    if ($todo.Count -gt 0) { Write-TsvLines (Get-MediaCachePath) @($cache.Values | ForEach-Object { $_ -join "`t" }) }
    Set-Progress ("Video details: {0} read, {1} couldn't be read" -f $ok, $failed) 100
    return [pscustomobject]@{ Checked = $todo.Count; Ok = $ok; ViaFfprobe = $viaFf; Failed = $failed; FFprobe = [bool]$ff }
}

function Import-Library {
    # Builds the in-memory library from the TSV files. Returns hashtable folder => show object.
    $lib = [ordered]@{}
    $media = Import-MediaInfo
    $showsPath = Join-Path $TVT.DataDir 'shows.tsv'
    $libPath = Join-Path $TVT.DataDir 'library.tsv'
    if (Test-Path -LiteralPath $showsPath) {
        foreach ($line in [IO.File]::ReadAllLines($showsPath, [Text.Encoding]::UTF8)) {
            if (-not $line) { continue }
            $p = $line.Split("`t")
            $ny = Get-NameAndYear $p[0]
            $lib[$p[0]] = [pscustomobject]@{
                Folder = $p[0]; Root = $p[1]; Path = [IO.Path]::Combine($p[1], $p[0]); Name = $ny[0]; Year = $ny[1]
                NfoTvdb = [int]$p[2]; LocalPoster = $p[3]; DirTicks = [int64]$p[4]
                Files = New-Object System.Collections.Generic.List[object]
                EpKeys = @{}; Seasons = @(); EpisodeCount = 0; Size = [int64]0; NewestTicks = [int64]0
            }
        }
    }
    if (Test-Path -LiteralPath $libPath) {
        foreach ($line in [IO.File]::ReadAllLines($libPath, [Text.Encoding]::UTF8)) {
            if (-not $line) { continue }
            $p = $line.Split("`t")
            $show = $lib[$p[0]]
            if (-not $show) { continue }
            $rel = $p[2]
            $name = [IO.Path]::GetFileName($rel)
            $base = [IO.Path]::GetFileNameWithoutExtension($rel)
            $parent = [IO.Path]::GetDirectoryName($rel)
            $folderSeason = $null
            if ($parent) { $folderSeason = Get-SeasonFromFolder ([IO.Path]::GetFileName($parent)) }
            $parsed = ConvertFrom-EpisodeName $base
            $f = [pscustomobject]@{
                Path = [IO.Path]::Combine($show.Path, $rel); Rel = $rel; Name = $name; Base = $base; Ext = [IO.Path]::GetExtension($rel)
                Size = [int64]$p[3]; Ticks = [int64]$p[4]; FolderSeason = $folderSeason
                Added = $(if ($p.Count -gt 5 -and [int64]$p[5] -gt [int64]$p[4]) { [int64]$p[5] } else { [int64]$p[4] })
                S = $(if ($parsed) { $parsed.S } else { $null }); Eps = $(if ($parsed) { $parsed.Eps } else { @() })
                ShowPart = $(if ($parsed) { $parsed.Show } else { '' }); TitlePart = $(if ($parsed) { $parsed.Title } else { '' })
                Res = (Get-ResolutionTag $name); ResSource = 'name'; Width = 0; Height = 0; Seconds = 0
            }
            $mi = $media[$f.Path]
            if ($mi -and [int64]$mi[1] -eq $f.Size) {
                $f.Width = [int]$mi[3]; $f.Height = [int]$mi[4]; $f.Seconds = [int]$mi[5]
                if ($f.Width -gt 0) { $f.Res = Get-VideoClass $f.Width $f.Height; $f.ResSource = 'file' }
            }
            $show.Files.Add($f)
            $show.Size += $f.Size
            if ($f.Added -gt $show.NewestTicks) { $show.NewestTicks = $f.Added }
            if ($parsed) { foreach ($e in $parsed.Eps) { $show.EpKeys["$($parsed.S)|$e"] = $f } }
        }
    }
    foreach ($show in $lib.Values) {
        $show.EpisodeCount = $show.EpKeys.Count
        $show.Seasons = @($show.EpKeys.Keys | ForEach-Object { [int]($_.Split('|')[0]) } | Sort-Object -Unique)
    }
    return $lib
}

# ---------- matches ----------
function Import-Matches { $h = @{}; foreach ($kv in (Read-TsvMap (Join-Path $TVT.DataDir 'matches.tsv')).GetEnumerator()) { $v = $kv.Value; if ($v.Count -lt 4) { continue }; $h[$kv.Key] = [pscustomobject]@{ Id = [int]$v[1]; How = $v[2]; Tvdb = [int]("0" + $v[3]) } }; return $h }
function Save-Matches($map) {
    $lines = foreach ($kv in $map.GetEnumerator()) { "$($kv.Key)`t$($kv.Value.Id)`t$($kv.Value.How)`t$([int]$kv.Value.Tvdb)" }
    Write-TsvLines (Join-Path $TVT.DataDir 'matches.tsv') @($lines)
}

# ---------- TV information: TVmaze (free, no key) ----------
function Write-InfoLog([string]$Line) {
    try {
        $p = Join-Path $TVT.DataDir 'Logs\tvinfo.log'
        $dir = Split-Path -Parent $p
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if ((Test-Path -LiteralPath $p) -and (Get-Item -LiteralPath $p).Length -gt 2MB) { Move-Item -LiteralPath $p -Destination "$p.old" -Force }
        [IO.File]::AppendAllText($p, ("[{0}] {1}`r`n" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Line))
    } catch {}
}
function Get-HttpErrorText($err) {
    $code = ''; $body = ''
    try { $code = [int]$err.Exception.Response.StatusCode } catch {}
    try { if ($err.ErrorDetails -and $err.ErrorDetails.Message) { $body = $err.ErrorDetails.Message } } catch {}
    if (-not $body) {
        try {
            $st = $err.Exception.Response.GetResponseStream()
            if ($st) { $rd = New-Object IO.StreamReader($st); $body = $rd.ReadToEnd() }
        } catch {}
    }
    $msg = $err.Exception.Message
    if ($body) { $b = ($body -replace '\s+', ' '); if ($b.Length -gt 300) { $b = $b.Substring(0, 300) + '...' }; $msg += " | $b" }
    if ($code) { return "HTTP $code - $msg" }
    return $msg
}
$script:MazeLast = [datetime]::MinValue
function Invoke-Maze([string]$PathAndQuery) {
    Initialize-Net
    for ($try = 1; $try -le 4; $try++) {
        $wait = 520 - ((Get-Date) - $script:MazeLast).TotalMilliseconds
        if ($wait -gt 0) { Start-Sleep -Milliseconds ([int]$wait) }
        $script:MazeLast = Get-Date
        try { return Invoke-RestMethod -Uri ("https://api.tvmaze.com/" + $PathAndQuery) -Headers @{ 'User-Agent' = 'TV Toolkit (PowerShell)' } -TimeoutSec 40 }
        catch {
            $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch {}
            if ($code -eq 404) { return $null }
            if ($code -eq 429 -and $try -lt 4) { Write-InfoLog "TVmaze busy (429) on $PathAndQuery - waiting"; Start-Sleep -Seconds (5 * $try); continue }
            Write-InfoLog ("GET {0} FAILED: {1}" -f $PathAndQuery, (Get-HttpErrorText $_))
            throw
        }
    }
}
function ConvertFrom-Html([string]$s) {
    if (-not $s) { return '' }
    $t = $s -replace '<br\s*/?>', "`n" -replace '</p>\s*<p>', "`n`n" -replace '<[^>]+>', ''
    return ([System.Net.WebUtility]::HtmlDecode($t)).Trim()
}
function ConvertTo-StatusText([string]$s) {
    switch -regex ($s) { '^Running$' { 'Continuing'; break } '^To Be Determined$' { 'Continuing'; break } '^In Development$' { 'Upcoming'; break } default { $s } }
}
function ConvertFrom-MazeShow($sh) {
    $y = ''; if ("$($sh.premiered)" -match '^(\d{4})') { $y = $Matches[1] }
    $net = ''; if ($sh.network) { $net = "$($sh.network.name)" } elseif ($sh.webChannel) { $net = "$($sh.webChannel.name)" }
    $tvdb = 0; try { if ($sh.externals.thetvdb) { $tvdb = [int]$sh.externals.thetvdb } } catch {}
    $img = ''; if ($sh.image) { $img = "$($sh.image.medium)"; if (-not $img) { $img = "$($sh.image.original)" } }
    return [pscustomobject]@{ Id = [int]$sh.id; Tvdb = $tvdb; Name = "$($sh.name)"; Year = $y; Network = $net; Status = (ConvertTo-StatusText "$($sh.status)"); Overview = (ConvertFrom-Html "$($sh.summary)"); Image = $img }
}
function Get-PersonWebExtras([string]$Url) {
    # TVmaze's API has no biography, so read it (and 'Also known as') from the person's page on tvmaze.com
    $out = [pscustomobject]@{ Bio = ''; Aka = @() }
    if ($Url -notmatch '^https://www\.tvmaze\.com/people/\d+') { return $out }
    try {
        $wait = 520 - ((Get-Date) - $script:MazeLast).TotalMilliseconds
        if ($wait -gt 0) { Start-Sleep -Milliseconds ([int]$wait) }
        $script:MazeLast = Get-Date
        Initialize-Net
        $html = (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 40 -Headers @{ 'User-Agent' = 'TV Toolkit (PowerShell)' }).Content
        $m = [regex]::Match($html, '(?is)<section[^>]*id="general-information".*?<article[^>]*>(.*?)</article>')
        if ($m.Success) {
            $t = $m.Groups[1].Value -replace '(?i)</p>\s*<p[^>]*>', "`n`n" -replace '(?i)<br\s*/?>', "`n" -replace '<[^>]+>', ''
            $t = [System.Net.WebUtility]::HtmlDecode($t)
            $t = ($t -replace "[ \t\u00A0]+", ' ' -replace "\s*\n\s*\n\s*", "`n`n").Trim()
            $out.Bio = $t
        }
        $k = [regex]::Match($html, '(?is)Also known as\s*</strong>\s*<ul>(.*?)</ul>')
        if ($k.Success) {
            $out.Aka = @([regex]::Matches($k.Groups[1].Value, '(?is)<li[^>]*>(.*?)</li>') | ForEach-Object { [System.Net.WebUtility]::HtmlDecode(($_.Groups[1].Value -replace '<[^>]+>', '')).Trim() } | Where-Object { $_ })
        }
    } catch { Write-InfoLog "Bio page $Url FAILED: $($_.Exception.Message)" }
    return $out
}

function Get-PersonFull([int]$Id, [string]$Name, [switch]$Force) {
    if ($Id -le 0 -and $Name) {
        $r = @((Invoke-Maze ("search/people?q=" + [uri]::EscapeDataString($Name))) | ForEach-Object { $_ })
        $hit = @($r | Where-Object { $_ -and "$($_.person.name)" -eq $Name } | Select-Object -First 1)
        if (-not $hit) { $hit = @($r | Where-Object { $_ } | Select-Object -First 1) }
        if ($hit) { $Id = [int]$hit[0].person.id }
    }
    if ($Id -le 0) { throw "TVmaze has nobody called '$Name'" }
    $path = Join-Path $TVT.DataDir "Cache\people-info\$Id.json"
    $cached = Read-JsonFile $path
    if ($cached -and -not $Force -and ($cached.PSObject.Properties.Name -contains 'Bio')) {
        $age = 999; try { $age = ((Get-Date) - [datetime]::Parse($cached.Fetched)).TotalDays } catch {}
        if ($age -lt 30) { return $cached }
    }
    try {
        $p = Invoke-Maze "people/$Id"
        if (-not $p) { throw "TVmaze has no person with id $Id" }
        $cr = @((Invoke-Maze "people/$Id/castcredits?embed%5B%5D=show&embed%5B%5D=character") | ForEach-Object { $_ })
    } catch { if ($cached) { return $cached }; throw }
    $byShow = [ordered]@{}
    foreach ($x in $cr) {
        if (-not $x -or -not $x._embedded -or -not $x._embedded.show) { continue }
        $sh = $x._embedded.show
        $ch = ''; if ($x._embedded.character) { $ch = "$($x._embedded.character.name)" }
        if ($x.voice) { $ch = "$ch (voice)".Trim() }
        $k = "$($sh.id)"
        if ($byShow.Contains($k)) { if ($ch -and $byShow[$k].Character -notlike "*$ch*") { $byShow[$k].Character += " / $ch" }; continue }
        $y = ''; if ("$($sh.premiered)" -match '^(\d{4})') { $y = $Matches[1] }
        $ye = ''; if ("$($sh.ended)" -match '^(\d{4})') { $ye = $Matches[1] }
        $years = $y; if ($ye -and $ye -ne $y) { $years = "$y-$ye" } elseif (-not $ye -and $y -and "$($sh.status)" -eq 'Running') { $years = "$y-" }
        $net = ''; if ($sh.network) { $net = "$($sh.network.name)" } elseif ($sh.webChannel) { $net = "$($sh.webChannel.name)" }
        $byShow[$k] = [ordered]@{ ShowId = [int]$sh.id; Show = "$($sh.name)"; Character = $ch; Year = $y; Years = $years; Network = $net; Status = (ConvertTo-StatusText "$($sh.status)"); Url = "$($sh.url)" }
    }
    $img = ''; if ($p.image) { $img = "$($p.image.original)"; if (-not $img) { $img = "$($p.image.medium)" } }
    $country = ''; if ($p.country) { $country = "$($p.country.name)" }
    $web = Get-PersonWebExtras "$($p.url)"
    $info = [ordered]@{ Id = $Id; Name = "$($p.name)"; Birthday = "$($p.birthday)"; Deathday = "$($p.deathday)"; Gender = "$($p.gender)"; Country = $country
        Image = $img; Url = "$($p.url)"; Bio = $web.Bio; AlsoKnownAs = @($web.Aka); Credits = @($byShow.Values | Sort-Object { $_.Year } -Descending); Fetched = (Get-Date).ToString('o') }
    Write-JsonFile $path $info
    $big = Join-Path $TVT.DataDir "Cache\people-large\$Id.jpg"
    if ($img -and -not (Test-Path -LiteralPath $big)) { Save-WebFile $img $big | Out-Null }
    return (Read-JsonFile $path)
}

function Get-ShowBackdrop([int]$Id) {
    # Downloads the show's wide background picture from TVmaze. Returns the cached path, or '' if there isn't one.
    $dir = Join-Path $TVT.DataDir 'Cache\backdrops'
    $path = Join-Path $dir "$Id.jpg"; $none = Join-Path $dir "$Id.none"
    if (Test-Path -LiteralPath $path) { return $path }
    if (Test-Path -LiteralPath $none) { return '' }
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $imgs = @((Invoke-Maze "shows/$Id/images") | ForEach-Object { $_ } | Where-Object { $_ -and "$($_.type)" -eq 'background' })
    $pick = @($imgs | Where-Object { $_.main } | Select-Object -First 1); if (-not $pick) { $pick = @($imgs | Select-Object -First 1) }
    $url = ''
    if ($pick) { $r = $pick[0].resolutions; if ($r.original) { $url = "$($r.original.url)" } elseif ($r.medium) { $url = "$($r.medium.url)" } }
    if ($url -and (Save-WebFile $url $path)) { return $path }
    [IO.File]::WriteAllText($none, '')
    return ''
}

function Search-Shows([string]$Name) {
    $r = @((Invoke-Maze ("search/shows?q=" + [uri]::EscapeDataString($Name))) | ForEach-Object { $_ })
    $out = @(foreach ($it in $r) { if ($it -and $it.show) { ConvertFrom-MazeShow $it.show } })
    if ($out.Count -eq 0) { Write-InfoLog "Search '$Name': 0 results" }
    return $out
}
function Get-MazeShowFull([int]$Id) {
    $r = Invoke-Maze "shows/$($Id)?embed%5B%5D=episodes&embed%5B%5D=cast"
    if (-not $r) { throw "TVmaze has no show with id $Id" }
    $b = ConvertFrom-MazeShow $r
    $s = [ordered]@{ Id = $Id; Tvdb = $b.Tvdb; Name = $b.Name; Year = $b.Year; Overview = $b.Overview; Status = $b.Status; Network = $b.Network
        Genres = @($r.genres); Poster = $b.Image; Cast = @(); Episodes = @(); Fetched = (Get-Date).ToString('o') }
    $s.Cast = @(@($r._embedded.cast) | ForEach-Object { $_ } | Where-Object { $_ } | Select-Object -First 30 | ForEach-Object {
        $img = ''; if ($_.person.image) { $img = "$($_.person.image.medium)" } elseif ($_.character.image) { $img = "$($_.character.image.medium)" }
        $perId = 0; try { $perId = [int]$_.person.id } catch {}
        [ordered]@{ Name = "$($_.person.name)"; Role = "$($_.character.name)"; Image = $img; PersonId = $perId } })
    $s.Episodes = @($r._embedded.episodes | Where-Object { $_ -and $null -ne $_.number -and $null -ne $_.season } | ForEach-Object {
        $st = ''; if ($_.airstamp -is [datetime]) { $st = $_.airstamp.ToUniversalTime().ToString('o') } elseif ($_.airstamp) { $st = "$($_.airstamp)" }
        $img = ''; if ($_.image) { $img = "$($_.image.medium)" }
        [ordered]@{ S = [int]$_.season; E = [int]$_.number; Title = "$($_.name)"; Aired = "$($_.airdate)"; Stamp = $st; Runtime = "$($_.runtime)"; Img = $img; Overview = (ConvertFrom-Html "$($_.summary)") } } | Sort-Object { $_.S }, { $_.E })
    return [pscustomobject]$s
}

function Get-SeriesCachePath([int]$Id) { return (Join-Path $TVT.DataDir "Cache\series\$Id.json") }
function Get-PosterCachePath([int]$Id) { return (Join-Path $TVT.DataDir "Cache\posters\$Id.jpg") }

function Save-WebFile([string]$Url, [string]$Path) {
    if (-not $Url) { return $false }
    try {
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Initialize-Net
        $wc = New-Object Net.WebClient
        $wc.DownloadFile($Url, "$Path.part")
        Move-Item -LiteralPath "$Path.part" -Destination $Path -Force
        return $true
    } catch { return $false }
}

function Update-SeriesIndex($info) {
    $path = Join-Path $TVT.DataDir 'series-index.tsv'
    $map = Read-TsvMap $path
    $next = ''
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $airedCount = 0
    foreach ($e in $info.Episodes) {
        if ($e.Aired -and $e.Aired -ge $today -and -not $next) { $next = "$($e.Aired)|$($e.S)|$($e.E)" }
        if ($e.S -gt 0 -and $e.Aired -and $e.Aired -le $today) { $airedCount++ }
    }
    $map["$($info.Id)"] = @("$($info.Id)", (Clean-Field $info.Name), (Clean-Field $info.Status), $next, (Clean-Field $info.Network), "$($info.Year)", (Clean-Field (($info.Genres) -join ', ')), "$airedCount", "$($info.Fetched)", "$($info.Tvdb)")
    $lines = foreach ($v in $map.Values) { $v -join "`t" }
    Write-TsvLines $path @($lines)
}
function Import-SeriesIndex {
    $h = @{}
    foreach ($kv in (Read-TsvMap (Join-Path $TVT.DataDir 'series-index.tsv')).GetEnumerator()) {
        $v = $kv.Value
        $h[[int]$kv.Key] = [pscustomobject]@{ Id = [int]$v[0]; Name = $v[1]; Status = $v[2]; Next = $v[3]; Network = $v[4]; Year = $v[5]; Genres = $v[6]; Aired = [int]("0" + $v[7]); Fetched = $v[8]; Tvdb = [int]("0" + $v[9]) }
    }
    return $h
}

function Get-SeriesInfo([int]$Id, [switch]$Force, [switch]$CacheOnly) {
    $path = Get-SeriesCachePath $Id
    $cached = Read-JsonFile $path
    if ($cached -and -not $Force) {
        if ($CacheOnly) { return $cached }
        $days = 3; if ($cached.Status -match 'Ended') { $days = 30 }
        try { $age = ((Get-Date) - [datetime]::Parse($cached.Fetched)).TotalDays } catch { $age = 999 }
        $maxDays = [int]$TVT.Settings.RefreshDays; if ($maxDays -gt 0 -and $cached.Status -notmatch 'Ended') { $days = $maxDays }
        if ($age -lt $days) { return $cached }
    }
    if ($CacheOnly) { return $null }
    try {
        $info = Get-MazeShowFull $Id
    } catch {
        if ($cached) { return $cached }
        throw
    }
    Write-JsonFile $path $info
    Update-SeriesIndex $info
    $pp = Get-PosterCachePath $Id
    if (-not (Test-Path -LiteralPath $pp) -and $info.Poster) { Save-WebFile $info.Poster $pp | Out-Null }
    return (Read-JsonFile $path)
}

function Find-ShowMatch($show) {
    # Returns @{Id (TVmaze); Tvdb; How} or $null
    if ($show.NfoTvdb -gt 0) {
        $sh = Invoke-Maze "lookup/shows?thetvdb=$($show.NfoTvdb)"
        if ($sh) { return [pscustomobject]@{ Id = [int]$sh.id; Tvdb = [int]$show.NfoTvdb; How = 'nfo' } }
    }
    $results = @(Search-Shows $show.Name)
    if (-not $results) { return $null }
    $key = Get-NormKey $show.Name
    $exact = @($results | Where-Object { (Get-NormKey $_.Name) -eq $key })
    $pick = $null; $how = 'auto'
    if ($show.Year -gt 0) {
        $y = @($exact | Where-Object { $_.Year -eq "$($show.Year)" })
        if (-not $y) { $y = @($results | Where-Object { $_.Year -eq "$($show.Year)" -and (Get-NormKey $_.Name) -like "$key*" }) }
        if ($y) { $pick = $y[0] }
    }
    if (-not $pick -and $exact) {
        # Several shows with the same name: prefer the newest one that is still running, else the first
        $pick = $exact[0]
    }
    if (-not $pick) { $pick = $results[0]; $how = 'guess' }
    return [pscustomobject]@{ Id = $pick.Id; Tvdb = $pick.Tvdb; How = $how }
}

# ---------- checks ----------
function Get-MissingEpisodes($lib, $MatchMap, [switch]$Specials, [switch]$OwnedSeasonsOnly, [switch]$ContinuingOnly, [string[]]$IgnoreShows) {
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $out = New-Object System.Collections.Generic.List[object]
    $shows = @($lib.Values)
    $i = 0
    foreach ($show in $shows) {
        $i++
        if ($IgnoreShows -contains $show.Folder) { continue }
        $m = $MatchMap[$show.Folder]; if (-not $m -or $m.Id -le 0) { continue }
        Set-Progress ("Checking {0} ({1}/{2})" -f $show.Name, $i, $shows.Count) ($i / $shows.Count * 100)
        try { $info = Get-SeriesInfo $m.Id } catch { continue }
        if (-not $info) { continue }
        if ($ContinuingOnly -and $info.Status -match 'Ended') { continue }
        foreach ($e in @($info.Episodes)) {
            if ($e.S -eq 0 -and -not $Specials) { continue }
            if (-not $e.Aired -or $e.Aired -gt $today) { continue }
            if ($OwnedSeasonsOnly -and ($show.Seasons -notcontains [int]$e.S)) { continue }
            if (-not $show.EpKeys.ContainsKey("$($e.S)|$($e.E)")) {
                $out.Add([pscustomobject]@{ Show = $show.Name; Folder = $show.Folder; InfoId = $m.Id; S = [int]$e.S; E = [int]$e.E; Ep = (Format-Ep $e.S $e.E); Title = $e.Title; Aired = $e.Aired })
            }
        }
    }
    return $out.ToArray()
}

function Get-FilenameIssues($lib, $MatchMap, [switch]$CheckTitles) {
    $out = New-Object System.Collections.Generic.List[object]
    $shows = @($lib.Values); $i = 0
    foreach ($show in $shows) {
        $i++
        Set-Progress ("Checking names: {0} ({1}/{2})" -f $show.Name, $i, $shows.Count) ($i / $shows.Count * 100)
        $info = $null
        $m = $MatchMap[$show.Folder]
        if ($CheckTitles -and $m -and $m.Id -gt 0) { try { $info = Get-SeriesInfo $m.Id } catch {} }
        $epTitles = @{}
        if ($info) { foreach ($e in @($info.Episodes)) { $epTitles["$($e.S)|$($e.E)"] = $e.Title } }
        $showKey = Get-NormKey $show.Folder
        $showKey2 = Get-NormKey $show.Name
        foreach ($f in $show.Files) {
            $issues = New-Object System.Collections.Generic.List[string]
            $proposed = ''
            if ($null -eq $f.S) {
                $out.Add([pscustomobject]@{ Show = $show.Name; Issue = "Can't read season/episode"; Current = $f.Rel; Proposed = ''; Path = $f.Path; Folder = $show.Folder })
                continue
            }
            $fsk = Get-NormKey $f.ShowPart
            if ($fsk -ne $showKey -and $fsk -ne $showKey2) { $issues.Add('Show name differs') }
            if ($null -ne $f.FolderSeason -and $f.FolderSeason -ne $f.S) { $issues.Add("In S$('{0:D2}' -f $f.FolderSeason) folder but is season $($f.S)") }
            $epPart = Format-Ep $f.S $f.Eps[0]
            if ($f.Eps.Count -gt 1) { $epPart = $epPart + (($f.Eps | Select-Object -Skip 1 | ForEach-Object { '-{0:D2}' -f $_ }) -join '') }
            $title = $f.TitlePart
            $tv = $null
            if ($f.Eps.Count -eq 1 -and $epTitles.ContainsKey("$($f.S)|$($f.Eps[0])")) { $tv = $epTitles["$($f.S)|$($f.Eps[0])"] }
            if (-not $f.TitlePart) { $issues.Add('No episode title') }
            if ($tv) {
                if ((Get-NormKey $f.TitlePart) -ne (Get-NormKey $tv) -and (Get-NormKey (Get-SafeFileName $tv)) -ne (Get-NormKey $f.TitlePart)) {
                    if ($f.TitlePart) { $issues.Add('Title differs from TVmaze') }
                }
                $title = Get-SafeFileName $tv
            } elseif ($CheckTitles -and $info -and $f.S -gt 0 -and $f.Eps.Count -eq 1 -and -not $epTitles.ContainsKey("$($f.S)|$($f.Eps[0])")) {
                $issues.Add('Episode not listed on TVmaze')
            }
            $expectBase = "$($show.Folder) - $epPart"
            if ($title) { $expectBase += " - $title" }
            if ($f.Base -cne $expectBase -and $issues.Count -eq 0) {
                # Only formatting differences (case, dots, spacing)
                $issues.Add('Formatting differs')
            }
            if ($issues.Count -gt 0) {
                if ($f.Base -cne $expectBase -and $f.Eps.Count -eq 1) { $proposed = $expectBase + $f.Ext }
                $out.Add([pscustomobject]@{ Show = $show.Name; Issue = ($issues -join '; '); Current = $f.Rel; Proposed = $proposed; Path = $f.Path; Folder = $show.Folder })
            }
        }
    }
    return $out.ToArray()
}

function Invoke-RenameEpisode([string]$Path, [string]$NewFileName) {
    # Renames the video and any sidecar files sharing its base name (.srt, .nfo, -thumb.jpg ...). Returns list of "old`tnew".
    $dir = Split-Path -Parent $Path
    $oldBase = [IO.Path]::GetFileNameWithoutExtension($Path)
    $newBase = [IO.Path]::GetFileNameWithoutExtension($NewFileName)
    $done = New-Object System.Collections.Generic.List[string]
    if ($oldBase -ceq $newBase) { return $done }
    $target = Join-Path $dir $NewFileName
    if ((Test-Path -LiteralPath $target) -and ($oldBase -ne $newBase)) { throw "A file called '$NewFileName' already exists." }
    foreach ($f in [IO.Directory]::GetFiles($dir)) {
        $n = [IO.Path]::GetFileName($f)
        if ($n.StartsWith($oldBase, [StringComparison]::OrdinalIgnoreCase)) {
            $rest = $n.Substring($oldBase.Length)
            if ($rest -and -not ($rest.StartsWith('.') -or $rest.StartsWith('-'))) { continue }
            $newPath = Join-Path $dir ($newBase + $rest)
            if ($n -ieq ($newBase + $rest)) {
                # case-only change: go via a temp name
                $tmp = Join-Path $dir ("~tvt~" + [guid]::NewGuid().ToString('N') + $rest)
                [IO.File]::Move($f, $tmp); [IO.File]::Move($tmp, $newPath)
            } else { [IO.File]::Move($f, $newPath) }
            $done.Add("$f`t$newPath")
        }
    }
    return $done
}

function Get-Duplicates($lib) {
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($show in $lib.Values) {
        $groups = @{}
        foreach ($f in $show.Files) {
            if ($null -eq $f.S) { continue }
            foreach ($e in $f.Eps) { $k = "$($f.S)|$e"; if (-not $groups[$k]) { $groups[$k] = New-Object System.Collections.Generic.List[object] }; $groups[$k].Add($f) }
        }
        foreach ($k in ($groups.Keys | Sort-Object { [int]$_.Split('|')[0] }, { [int]$_.Split('|')[1] })) {
            if ($groups[$k].Count -lt 2) { continue }
            $p = $k.Split('|')
            foreach ($f in ($groups[$k] | Sort-Object Size -Descending)) {
                $out.Add([pscustomobject]@{ Show = $show.Name; Ep = (Format-Ep ([int]$p[0]) ([int]$p[1])); File = $f.Name; SizeText = (Format-Size $f.Size); Size = $f.Size; Res = $f.Res; Folder = (Split-Path -Parent $f.Rel); Path = $f.Path })
            }
        }
    }
    return $out.ToArray()
}

function Get-QualitySummary($lib) {
    $out = foreach ($show in $lib.Values) {
        $c = @{ '2160p' = 0; '1080p' = 0; '720p' = 0; 'SD' = 0; '?' = 0 }
        foreach ($f in $show.Files) { $c[$f.Res]++ }
        [pscustomobject]@{ Show = $show.Name; Files = $show.Files.Count; Episodes = $show.EpisodeCount; SizeText = (Format-Size $show.Size); Size = $show.Size
            UHD = $c['2160p']; FHD = $c['1080p']; HD = $c['720p']; SD = $c['SD']; Unknown = $c['?'] }
    }
    return @($out | Sort-Object Size -Descending)
}

function Get-LocalAirTime($e) {
    # Returns local [datetime] from TVmaze's airstamp, or $null
    $st = $e.Stamp
    if (-not $st) { return $null }
    if ($st -is [datetime]) { return $st.ToLocalTime() }
    try { return ([DateTimeOffset]::Parse("$st", [Globalization.CultureInfo]::InvariantCulture)).LocalDateTime } catch { return $null }
}
function Get-CalendarEpisodes($lib, $MatchMap, [switch]$Refresh) {
    $from = (Get-Date).Date.AddDays(-42).ToString('yyyy-MM-dd'); $to = (Get-Date).Date.AddDays(91).ToString('yyyy-MM-dd')
    $list = New-Object System.Collections.Generic.List[object]
    $shows = @($lib.Values); $i = 0
    foreach ($show in $shows) {
        $i++
        $m = $MatchMap[$show.Folder]; if (-not $m -or $m.Id -le 0) { continue }
        $info = $null
        try { $info = Get-SeriesInfo $m.Id -CacheOnly } catch {}
        $ended = ($info -and "$($info.Status)" -match 'Ended')
        if ($Refresh -and -not $ended) {
            Set-Progress ("Airing info: {0} ({1}/{2})" -f $show.Name, $i, $shows.Count) ($i / [math]::Max(1, $shows.Count) * 100)
            $old = $false
            $eps0 = @($info.Episodes | Where-Object { $_ } | Select-Object -First 1)
            if ($info -and $eps0 -and -not ($eps0[0].PSObject.Properties.Name -contains 'Stamp')) { $old = $true }
            try { $info = Get-SeriesInfo $m.Id -Force:$old } catch {}
        }
        if (-not $info) { continue }
        foreach ($e in @($info.Episodes)) {
            if (-not $e) { continue }
            $lt = Get-LocalAirTime $e
            if ($lt) { $d = $lt.ToString('yyyy-MM-dd'); $t = $lt.ToString('HH:mm') } else { $d = "$($e.Aired)"; $t = '' }
            if (-not $d) { continue }
            if ($d.Length -gt 10) { $d = $d.Substring(0, 10) }
            if ($d -lt $from -or $d -gt $to) { continue }
            $list.Add([pscustomobject]@{ Date = $d; Time = $t; Folder = $show.Folder; Show = $show.Folder; S = [int]$e.S; E = [int]$e.E; Ep = (Format-Ep $e.S $e.E)
                Title = "$($e.Title)"; Network = "$($info.Network)"; Runtime = "$($e.Runtime)"; Have = $show.EpKeys.ContainsKey("$($e.S)|$($e.E)") })
        }
    }
    Set-Progress 'Airing info ready' 100
    return $list.ToArray()
}

# ---------- problem files ----------
$script:JunkExt = @('.txt', '.url', '.lnk', '.exe', '.bat', '.cmd', '.torrent', '.nzb', '.sfv', '.md5', '.sha1', '.par2', '.website', '.htm', '.html', '.ini', '.db')
$script:PartialExt = @('.part', '.tmp', '.!qb', '.!ut', '.crdownload', '.partial', '.download', '.aria2')
$script:SubExt = @('.srt', '.sub', '.idx', '.ass', '.ssa', '.vtt', '.sup')
function Get-ProblemFiles($lib) {
    $media = Import-MediaInfo
    $out = New-Object System.Collections.Generic.List[object]
    $shows = @($lib.Values); $i = 0
    foreach ($show in $shows) {
        $i++
        Set-Progress ("Checking {0} ({1}/{2})" -f $show.Name, $i, $shows.Count) ($i / [math]::Max(1, $shows.Count) * 100)
        if (-not (Test-Path -LiteralPath $show.Path)) { continue }
        $all = New-Object System.Collections.Generic.List[IO.FileInfo]
        Get-FilesSafe $show.Path $all
        $byDir = @{}
        foreach ($f in $all) { $d = $f.DirectoryName; if (-not $byDir[$d]) { $byDir[$d] = New-Object System.Collections.Generic.List[IO.FileInfo] }; $byDir[$d].Add($f) }
        $add = {
            param($type, $file, $detail, $kind, $target)
            $rel = $file
            if ($file.StartsWith($show.Path, [StringComparison]::OrdinalIgnoreCase)) { $rel = $file.Substring($show.Path.Length).TrimStart('\', '/') }
            $out.Add([pscustomobject]@{ Show = $show.Folder; Folder = $show.Folder; Type = $type; File = $(if ($rel) { $rel } else { '(show folder)' }); Detail = $detail; Path = $file; Kind = $kind; Target = $target })
        }
        foreach ($d in $byDir.Keys) {
            $files = $byDir[$d]
            $videoBases = @{}
            foreach ($f in $files) { if ($script:VideoExt -contains $f.Extension.ToLowerInvariant()) { $videoBases[$f.BaseName.ToLowerInvariant()] = $true } }
            $folderName = [IO.Path]::GetFileName($d)
            $inSeason = ($null -ne (Get-SeasonFromFolder $folderName))
            foreach ($f in $files) {
                $ext = $f.Extension.ToLowerInvariant(); $name = $f.Name
                if ($script:VideoExt -contains $ext) {
                    if ($f.Length -lt 300MB -and $name -match '(?i)(^|[ ._-])sample([ ._-]|$)') { & $add 'Sample file' $f.FullName (Format-Size $f.Length) 'file' ''; continue }
                    if ($f.Length -eq 0) { & $add 'Empty file (0 bytes)' $f.FullName '0 KB' 'file' ''; continue }
                    if ($f.Length -lt 5MB) { & $add 'Very small - may be incomplete' $f.FullName (Format-Size $f.Length) 'file' ''; continue }
                    $mi = $media[$f.FullName]
                    if ($mi -and [int64]$mi[1] -eq $f.Length -and [int]$mi[3] -le 0) { & $add "Couldn't read the video - may be damaged or incomplete" $f.FullName (Format-Size $f.Length) 'file' '' }
                    if (-not $inSeason) {
                        $p = ConvertFrom-EpisodeName $f.BaseName
                        $t = ''
                        if ($p) {
                            $t = ('S{0:D2}' -f [int]$p.S)
                            try { foreach ($sd in [IO.Directory]::GetDirectories($show.Path)) { $sn = Get-SeasonFromFolder ([IO.Path]::GetFileName($sd)); if ($null -ne $sn -and [int]$sn -eq [int]$p.S) { $t = [IO.Path]::GetFileName($sd); break } } } catch {}
                        }
                        & $add 'Not in a season folder' $f.FullName $(if ($t) { "belongs in $t" } else { "season unknown" }) 'file' $t
                    }
                    continue
                }
                if ($script:PartialExt -contains $ext) { & $add 'Unfinished download' $f.FullName (Format-Size $f.Length) 'file' ''; continue }
                if ($script:JunkExt -contains $ext -and $name -ne 'desktop.ini') { & $add 'Junk file' $f.FullName (Format-Size $f.Length) 'file' ''; continue }
                if ($script:SubExt -contains $ext) {
                    $b = $f.BaseName.ToLowerInvariant()
                    $ok = $false
                    foreach ($vb in $videoBases.Keys) { if ($b -eq $vb -or $b.StartsWith("$vb.")) { $ok = $true; break } }
                    if (-not $ok) { & $add 'Subtitle with no matching episode' $f.FullName (Format-Size $f.Length) 'file' '' }
                    continue
                }
                if ($ext -eq '.nfo' -and $name -notin @('tvshow.nfo', 'season.nfo')) {
                    if (-not $videoBases.ContainsKey($f.BaseName.ToLowerInvariant())) { & $add '.nfo with no matching episode' $f.FullName (Format-Size $f.Length) 'file' '' }
                }
            }
        }
        # empty folders
        try {
            foreach ($dir in [IO.Directory]::GetDirectories($show.Path, '*', [IO.SearchOption]::AllDirectories)) {
                $ln = [IO.Path]::GetFileName($dir).ToLowerInvariant()
                if ($script:SkipDirs -contains $ln -or $ln.StartsWith('.') -or $dir -match '\\(@eadir|#recycle)\\') { continue }
                if (@([IO.Directory]::GetFileSystemEntries($dir)).Count -eq 0) { & $add 'Empty folder' $dir '' 'dir' '' }
            }
        } catch {}
    }
    Set-Progress ("Problem check finished: {0} item(s)" -f $out.Count) 100
    return $out.ToArray()
}

# ---------- utilities ----------
function New-ShowListHtml($lib, $MatchMap, $index, [switch]$Episodes) {
    $sb = New-Object Text.StringBuilder
    $enc = { param($s) [System.Net.WebUtility]::HtmlEncode("$s") }
    [void]$sb.Append('<!doctype html><html><head><meta charset="utf-8"><title>TV Shows</title><style>body{font-family:Segoe UI,Arial,sans-serif;font-size:11pt;margin:24px;color:#111}h1{font-size:20pt;margin:0 0 4px}p.sub{color:#555;margin:0 0 18px}table{border-collapse:collapse;width:100%}th,td{text-align:left;padding:5px 8px;border-bottom:1px solid #ccc;vertical-align:top}th{background:#eee}td.n{text-align:right;white-space:nowrap}.eps{font-size:9pt;color:#444}@media print{body{margin:0}tr{page-break-inside:avoid}}</style></head><body>')
    $total = 0; foreach ($s in $lib.Values) { $total += $s.EpisodeCount }
    [void]$sb.Append("<h1>TV Shows</h1><p class=""sub"">$($lib.Count) shows &middot; $total episodes &middot; printed $(Get-Date -Format 'd MMMM yyyy')</p>")
    [void]$sb.Append('<table><tr><th>Show</th><th>Seasons</th><th class="n">Episodes</th><th>Status</th><th class="n">Size</th></tr>')
    foreach ($s in ($lib.Values | Sort-Object Name)) {
        $st = ''; $m = $MatchMap[$s.Folder]; if ($m -and $index[[int]$m.Id]) { $st = $index[[int]$m.Id].Status }
        $seas = ($s.Seasons | ForEach-Object { if ($_ -eq 0) { 'Specials' } else { $_ } }) -join ', '
        [void]$sb.Append("<tr><td><b>$(& $enc $s.Folder)</b>")
        if ($Episodes) {
            $eps = @($s.EpKeys.Keys | Sort-Object { [int]$_.Split('|')[0] }, { [int]$_.Split('|')[1] } | ForEach-Object { $p = $_.Split('|'); Format-Ep ([int]$p[0]) ([int]$p[1]) })
            [void]$sb.Append("<div class=""eps"">$($eps -join ', ')</div>")
        }
        [void]$sb.Append("</td><td>$(& $enc $seas)</td><td class=""n"">$($s.EpisodeCount)</td><td>$(& $enc $st)</td><td class=""n"">$(Format-Size $s.Size)</td></tr>")
    }
    [void]$sb.Append('</table></body></html>')
    return $sb.ToString()
}

}

# ===================== UI =====================
$ErrorActionPreference = 'Continue'
$AppDir = $PSScriptRoot
if (-not $AppDir) { $AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$RootDir = Split-Path -Parent $AppDir
$DataDir = Join-Path $RootDir 'Data'
$StartLog = Join-Path $DataDir 'Logs\startup.log'
$StartClock = [Diagnostics.Stopwatch]::StartNew()
function Write-StartLog([string]$Text) {
    try {
        $dir = Split-Path -Parent $StartLog
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [IO.File]::AppendAllText($StartLog, ("[{0}] +{1,5:N1}s  pid {2}  {3}`r`n" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $StartClock.Elapsed.TotalSeconds, $PID, $Text))
    } catch {}
}
try { if ((Test-Path -LiteralPath $StartLog) -and (Get-Item -LiteralPath $StartLog).Length -gt 200KB) { Remove-Item -LiteralPath $StartLog -Force } } catch {}
Write-StartLog "Starting v$AppVersion (PowerShell $($PSVersionTable.PSVersion), STA=$([Threading.Thread]::CurrentThread.ApartmentState -eq 'STA'))"

trap {
    $msg = ($_ | Out-String) + "`n" + $_.Exception.ToString() + "`nScript stack:`n" + $_.ScriptStackTrace
    Write-StartLog "CRASH: $($_.Exception.Message)"
    try { Add-Content -LiteralPath (Join-Path $DataDir 'Logs\crash.log') -Value ("[{0}] {1}" -f (Get-Date), $msg) } catch {}
    try { [void][Windows.MessageBox]::Show("TV Toolkit hit a problem and has to close:`n`n$($_.Exception.Message)`n`nDetails were saved to Data\Logs\crash.log", 'TV Toolkit', 'OK', 'Error') } catch {}
    break
}
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.IO.Compression.FileSystem

# ---------- one copy at a time ----------
# A second launch asks the running copy to come to the front, then quits. If the running copy
# doesn't answer within a few seconds (stuck), this launch carries on and starts normally.
$script:ShowEvent = $null; $script:AckEvent = $null; $script:Mutex = $null
try {
    $created = $false
    $script:Mutex = New-Object Threading.Mutex($true, 'Local\TVToolkit_Running', [ref]$created)
    $script:ShowEvent = New-Object Threading.EventWaitHandle($false, 'AutoReset', 'Local\TVToolkit_Show')
    $script:AckEvent = New-Object Threading.EventWaitHandle($false, 'AutoReset', 'Local\TVToolkit_Ack')
    if (-not $created) {
        Write-StartLog 'Another copy is already running - asking it to come to the front'
        [void]$script:AckEvent.Reset()
        [void]$script:ShowEvent.Set()
        if ($script:AckEvent.WaitOne(6000)) { Write-StartLog 'Running copy answered - exiting'; exit }
        Write-StartLog 'Running copy did not answer - starting anyway'
    }
} catch { Write-StartLog "Single-instance check skipped: $($_.Exception.Message)" }

# ---------- splash while the main window is built ----------
$Splash = $null
try {
    $splashXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" WindowStyle="None" ResizeMode="NoResize" AllowsTransparency="True" Background="Transparent"
        Width="360" Height="150" WindowStartupLocation="CenterScreen" ShowInTaskbar="True" Topmost="True" Title="TV Toolkit">
    <Border Background="#171B22" BorderBrush="#2C333F" BorderThickness="1" CornerRadius="8">
        <Grid>
            <UniformGrid Rows="1" VerticalAlignment="Top" Height="4">
                <Rectangle Fill="#C9CBCF"/><Rectangle Fill="#F4C542"/><Rectangle Fill="#35C2D6"/><Rectangle Fill="#5CC98A"/><Rectangle Fill="#C55BC9"/><Rectangle Fill="#E5566B"/><Rectangle Fill="#4A79E0"/>
            </UniformGrid>
            <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                    <Border Background="#F4C542" CornerRadius="5" Padding="7,1" Margin="0,0,9,0"><TextBlock Text="TV" FontFamily="Bahnschrift SemiBold, Segoe UI" FontSize="20" Foreground="#101318"/></Border>
                    <TextBlock Text="Toolkit" FontFamily="Bahnschrift SemiLight, Segoe UI" FontSize="22" Foreground="#E9ECF2" VerticalAlignment="Center"/>
                </StackPanel>
                <TextBlock Name="SplashText" Text="Starting..." Foreground="#98A2B3" FontFamily="Segoe UI" FontSize="12" HorizontalAlignment="Center" Margin="0,14,0,0"/>
            </StackPanel>
        </Grid>
    </Border>
</Window>
'@
    $Splash = [Windows.Markup.XamlReader]::Parse($splashXaml.Replace('Starting...', "Starting version $AppVersion..."))
    $Splash.Show()
    [Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Background)
    Write-StartLog 'Splash shown'
} catch { Write-StartLog "Splash skipped: $($_.Exception.Message)" }

foreach ($d in @($DataDir, (Join-Path $DataDir 'Cache\series'), (Join-Path $DataDir 'Cache\posters'), (Join-Path $DataDir 'Cache\people'), (Join-Path $DataDir 'Cache\people-large'), (Join-Path $DataDir 'Cache\people-info'), (Join-Path $DataDir 'Cache\backdrops'), (Join-Path $DataDir 'Cache\epthumbs'), (Join-Path $DataDir 'Backups'), (Join-Path $DataDir 'Logs'), (Join-Path $DataDir 'Exports'))) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$Sync = [hashtable]::Synchronized(@{ Status = ''; Pct = -1 })
$TVT = @{ DataDir = $DataDir; Settings = @{}; Sync = $Sync }
. $CoreScript
$CoreText = $CoreScript.ToString()
Initialize-Net

$DOT = [string][char]0x00B7

# ---------- settings ----------
$SettingsPath = Join-Path $DataDir 'settings.json'
function Get-DefaultSettings {
    return @{ Roots = @('T:\'); HoldFolder = 'T:\_TV Toolkit holding'; RefreshDays = 3
              NewDays = 14; LibView = 'posters'; IgnoreMissing = @()
              MissOwned = $false; MissSpecials = $false; MissContinuing = $false; LibFilter = 0; LibSort = 0 }
}
function Load-Settings {
    $s = Get-DefaultSettings
    $j = Read-JsonFile $SettingsPath
    if ($j) { foreach ($p in $j.PSObject.Properties) { if ($s.ContainsKey($p.Name)) { $s[$p.Name] = $p.Value } } }   # unknown/old keys are dropped
    $s.Roots = @($s.Roots | Where-Object { $_ })
    $s.IgnoreMissing = @($s.IgnoreMissing | Where-Object { $_ })
    $TVT.Settings = $s
}
function Save-Settings { Write-JsonFile $SettingsPath $TVT.Settings; $script:TvdbAuth = $null }
Load-Settings

# ---------- window ----------
$ThemeXaml = @'
        <!-- ===== "Test Card" theme ===== -->
        <SolidColorBrush x:Key="Panel" Color="#171B22"/>
        <SolidColorBrush x:Key="Panel2" Color="#1F242D"/>
        <SolidColorBrush x:Key="Panel3" Color="#262C37"/>
        <SolidColorBrush x:Key="Line" Color="#2C333F"/>
        <SolidColorBrush x:Key="Text" Color="#E9ECF2"/>
        <SolidColorBrush x:Key="Sub" Color="#98A2B3"/>
        <SolidColorBrush x:Key="Accent" Color="#35C2D6"/>
        <SolidColorBrush x:Key="AccentDim" Color="#1C4F58"/>
        <SolidColorBrush x:Key="Accent2" Color="#F4C542"/>
        <SolidColorBrush x:Key="Good" Color="#5CC98A"/>
        <SolidColorBrush x:Key="Warn" Color="#F0A04B"/>
        <SolidColorBrush x:Key="Bad" Color="#E5566B"/>

        <Style TargetType="TextBlock"><Setter Property="Foreground" Value="{StaticResource Text}"/></Style>
        <Style TargetType="ToolTip">
            <Setter Property="Background" Value="{StaticResource Panel3}"/><Setter Property="Foreground" Value="{StaticResource Text}"/>
            <Setter Property="BorderBrush" Value="{StaticResource Line}"/><Setter Property="Padding" Value="8,5"/>
        </Style>

        <Style TargetType="Button">
            <Setter Property="Foreground" Value="{StaticResource Text}"/>
            <Setter Property="Background" Value="{StaticResource Panel3}"/>
            <Setter Property="Padding" Value="14,7"/>
            <Setter Property="Margin" Value="0,0,8,0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="B" Background="{TemplateBinding Background}" CornerRadius="4" Padding="{TemplateBinding Padding}" BorderBrush="{StaticResource Line}" BorderThickness="1">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
                            <Trigger Property="IsPressed" Value="True"><Setter TargetName="B" Property="Background" Value="{StaticResource AccentDim}"/></Trigger>
                            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Opacity" Value="0.4"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="AccentButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="{StaticResource Accent}"/>
            <Setter Property="Foreground" Value="#0C1014"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
        </Style>
        <Style x:Key="Tile" TargetType="Button">
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Foreground" Value="{StaticResource Text}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="B" Background="Transparent" CornerRadius="6" Padding="4" BorderThickness="2" BorderBrush="Transparent">
                            <ContentPresenter/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="BorderBrush" Value="{StaticResource Accent}"/><Setter TargetName="B" Property="Background" Value="{StaticResource Panel2}"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="TextBox">
            <Setter Property="Background" Value="{StaticResource Panel2}"/><Setter Property="Foreground" Value="{StaticResource Text}"/>
            <Setter Property="BorderBrush" Value="{StaticResource Line}"/><Setter Property="CaretBrush" Value="{StaticResource Accent}"/>
            <Setter Property="Padding" Value="8,6"/><Setter Property="FontSize" Value="13"/>
            <Setter Property="SelectionBrush" Value="{StaticResource Accent}"/>
        </Style>
        <Style TargetType="PasswordBox">
            <Setter Property="Background" Value="{StaticResource Panel2}"/><Setter Property="Foreground" Value="{StaticResource Text}"/>
            <Setter Property="BorderBrush" Value="{StaticResource Line}"/><Setter Property="CaretBrush" Value="{StaticResource Accent}"/>
            <Setter Property="Padding" Value="8,6"/><Setter Property="FontSize" Value="13"/>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="{StaticResource Text}"/><Setter Property="Margin" Value="0,0,16,0"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
        </Style>
        <Style TargetType="ProgressBar">
            <Setter Property="Background" Value="{StaticResource Panel3}"/><Setter Property="Foreground" Value="{StaticResource Accent}"/>
            <Setter Property="BorderThickness" Value="0"/>
        </Style>

        <Style TargetType="ComboBoxItem">
            <Setter Property="Foreground" Value="{StaticResource Text}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBoxItem">
                        <Border x:Name="B" Padding="10,6" Background="Transparent"><ContentPresenter/></Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="B" Property="Background" Value="{StaticResource AccentDim}"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="ComboBox">
            <Setter Property="Foreground" Value="{StaticResource Text}"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="MinHeight" Value="32"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <ToggleButton Focusable="False" ClickMode="Press" IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                                <ToggleButton.Template>
                                    <ControlTemplate TargetType="ToggleButton">
                                        <Border x:Name="B" Background="{StaticResource Panel2}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="4">
                                            <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,10,0" Data="M0,0 L4,4 L8,0" Stroke="{StaticResource Sub}" StrokeThickness="1.5"/>
                                        </Border>
                                        <ControlTemplate.Triggers>
                                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
                                        </ControlTemplate.Triggers>
                                    </ControlTemplate>
                                </ToggleButton.Template>
                            </ToggleButton>
                            <ContentPresenter IsHitTestVisible="False" Margin="10,5,28,5" VerticalAlignment="Center" Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"/>
                            <Popup IsOpen="{TemplateBinding IsDropDownOpen}" Placement="Bottom" AllowsTransparency="True" Focusable="False">
                                <Border Background="{StaticResource Panel2}" BorderBrush="{StaticResource Line}" BorderThickness="1" MinWidth="{TemplateBinding ActualWidth}" MaxHeight="380" CornerRadius="4">
                                    <ScrollViewer><ItemsPresenter/></ScrollViewer>
                                </Border>
                            </Popup>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="ScrollBar">
            <Setter Property="Width" Value="10"/><Setter Property="MinWidth" Value="10"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ScrollBar">
                        <Grid Background="Transparent">
                            <Track x:Name="PART_Track" IsDirectionReversed="True">
                                <Track.Thumb><Thumb><Thumb.Template><ControlTemplate><Border CornerRadius="4" Background="#3A4250" Margin="2"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
                            </Track>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="Orientation" Value="Horizontal">
                    <Setter Property="Width" Value="Auto"/><Setter Property="MinWidth" Value="0"/>
                    <Setter Property="Height" Value="10"/><Setter Property="MinHeight" Value="10"/>
                    <Setter Property="Template">
                        <Setter.Value>
                            <ControlTemplate TargetType="ScrollBar">
                                <Grid Background="Transparent">
                                    <Track x:Name="PART_Track" IsDirectionReversed="False">
                                        <Track.Thumb><Thumb><Thumb.Template><ControlTemplate><Border CornerRadius="4" Background="#3A4250" Margin="2"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
                                    </Track>
                                </Grid>
                            </ControlTemplate>
                        </Setter.Value>
                    </Setter>
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style TargetType="DataGrid">
            <Setter Property="Background" Value="{StaticResource Panel}"/>
            <Setter Property="Foreground" Value="{StaticResource Text}"/>
            <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
            <Setter Property="RowBackground" Value="{StaticResource Panel}"/>
            <Setter Property="AlternatingRowBackground" Value="#1A1F27"/>
            <Setter Property="HorizontalGridLinesBrush" Value="{StaticResource Line}"/>
            <Setter Property="GridLinesVisibility" Value="Horizontal"/>
            <Setter Property="HeadersVisibility" Value="Column"/>
            <Setter Property="AutoGenerateColumns" Value="False"/>
            <Setter Property="IsReadOnly" Value="True"/>
            <Setter Property="CanUserAddRows" Value="False"/>
            <Setter Property="CanUserDeleteRows" Value="False"/>
            <Setter Property="SelectionMode" Value="Extended"/>
            <Setter Property="RowHeight" Value="30"/>
            <Setter Property="FontSize" Value="13"/>
        </Style>
        <Style TargetType="DataGridColumnHeader">
            <Setter Property="Background" Value="{StaticResource Panel2}"/>
            <Setter Property="Foreground" Value="{StaticResource Sub}"/>
            <Setter Property="Padding" Value="8,7"/>
            <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
            <Setter Property="BorderThickness" Value="0,0,1,1"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
        </Style>
        <Style TargetType="DataGridRow">
            <Style.Triggers>
                <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="{StaticResource AccentDim}"/></Trigger>
            </Style.Triggers>
        </Style>
        <Style TargetType="DataGridCell">
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="DataGridCell">
                        <Border Background="Transparent" Padding="8,0"><ContentPresenter VerticalAlignment="Center"/></Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsSelected" Value="True"><Setter Property="Foreground" Value="#FFFFFF"/></Trigger>
            </Style.Triggers>
        </Style>

        <Style x:Key="Chip" TargetType="ListBoxItem">
            <Setter Property="Foreground" Value="{StaticResource Sub}"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ListBoxItem">
                        <Border x:Name="B" Background="{StaticResource Panel2}" CornerRadius="14" Padding="12,5" Margin="0,0,6,6" BorderBrush="{StaticResource Line}" BorderThickness="1">
                            <ContentPresenter/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
                            <Trigger Property="IsSelected" Value="True"><Setter TargetName="B" Property="Background" Value="{StaticResource Accent}"/><Setter Property="Foreground" Value="#0C1014"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="Nav" TargetType="TabItem">
            <Setter Property="Foreground" Value="{StaticResource Sub}"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TabItem">
                        <Border x:Name="B" Padding="20,11" Background="Transparent" BorderThickness="3,0,0,0" BorderBrush="Transparent">
                            <ContentPresenter ContentSource="Header"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="{StaticResource Panel2}"/></Trigger>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="B" Property="Background" Value="{StaticResource Panel2}"/>
                                <Setter TargetName="B" Property="BorderBrush" Value="{StaticResource Accent}"/>
                                <Setter Property="Foreground" Value="{StaticResource Text}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="H1" TargetType="TextBlock"><Setter Property="FontFamily" Value="Bahnschrift SemiBold, Segoe UI"/><Setter Property="FontSize" Value="24"/><Setter Property="Foreground" Value="{StaticResource Text}"/></Style>
        <Style x:Key="H2" TargetType="TextBlock"><Setter Property="FontFamily" Value="Bahnschrift SemiBold, Segoe UI"/><Setter Property="FontSize" Value="16"/><Setter Property="Foreground" Value="{StaticResource Text}"/><Setter Property="Margin" Value="0,0,0,8"/></Style>
        <Style x:Key="Hint" TargetType="TextBlock"><Setter Property="Foreground" Value="{StaticResource Sub}"/><Setter Property="TextWrapping" Value="Wrap"/><Setter Property="FontSize" Value="12.5"/></Style>
        <Style x:Key="Card" TargetType="Border"><Setter Property="Background" Value="{StaticResource Panel}"/><Setter Property="BorderBrush" Value="{StaticResource Line}"/><Setter Property="BorderThickness" Value="1"/><Setter Property="CornerRadius" Value="6"/><Setter Property="Padding" Value="18"/></Style>
        <Style x:Key="BareText" TargetType="TextBox">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="{StaticResource Text}"/>
            <Setter Property="CaretBrush" Value="{StaticResource Accent}"/>
            <Setter Property="SelectionBrush" Value="{StaticResource Accent}"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <ScrollViewer x:Name="PART_ContentHost" VerticalAlignment="Center" Focusable="False" HorizontalScrollBarVisibility="Hidden" VerticalScrollBarVisibility="Hidden"/>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
'@
$MainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="TV Toolkit" WindowState="Maximized" MinWidth="1100" MinHeight="700" Width="1400" Height="860"
        Background="#101318" Foreground="#E9ECF2" FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
    <Window.Resources>
<!--THEME-->
    </Window.Resources>
    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="5"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- colour bars -->
        <UniformGrid Grid.Row="0" Rows="1">
            <Rectangle Fill="#C9CBCF"/><Rectangle Fill="#F4C542"/><Rectangle Fill="#35C2D6"/><Rectangle Fill="#5CC98A"/>
            <Rectangle Fill="#C55BC9"/><Rectangle Fill="#E5566B"/><Rectangle Fill="#4A79E0"/>
        </UniformGrid>

        <!-- header -->
        <Border Grid.Row="1" Background="#13171D" BorderBrush="{StaticResource Line}" BorderThickness="0,0,0,1" Padding="20,12">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="240"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                    <Border Background="{StaticResource Accent2}" CornerRadius="5" Padding="7,1" Margin="0,0,9,0">
                        <TextBlock Text="TV" FontFamily="Bahnschrift SemiBold, Segoe UI" FontSize="20" Foreground="#101318"/>
                    </Border>
                    <TextBlock Text="Toolkit" FontFamily="Bahnschrift SemiLight, Segoe UI" FontSize="22" VerticalAlignment="Center"/>
                    <TextBlock x:Name="txtHeaderVersion" Foreground="{StaticResource Sub}" FontSize="12" VerticalAlignment="Bottom" Margin="8,0,0,4"/>
                </StackPanel>
                <Border Grid.Column="1" x:Name="bdSearch" MaxWidth="560" Height="38" HorizontalAlignment="Stretch" Margin="10,0,24,0" VerticalAlignment="Center"
                        Background="{StaticResource Panel2}" BorderBrush="{StaticResource Line}" BorderThickness="1.5" CornerRadius="19" Cursor="IBeam">
                    <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                        <Canvas Width="16" Height="16" Margin="15,0,10,0" VerticalAlignment="Center" IsHitTestVisible="False">
                            <Ellipse x:Name="elSearchIcon" Width="11.5" Height="11.5" Stroke="{StaticResource Sub}" StrokeThickness="1.8"/>
                            <Line x:Name="lnSearchIcon" X1="10" Y1="10" X2="15.2" Y2="15.2" Stroke="{StaticResource Sub}" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                        </Canvas>
                        <Grid Grid.Column="1">
                            <TextBox x:Name="txtSearch" Style="{StaticResource BareText}" ToolTip="Search show names, channels and genres (Ctrl+F). Esc clears."/>
                            <TextBlock x:Name="txtSearchHint" Text="Search shows, channels, genres..." IsHitTestVisible="False" Foreground="{StaticResource Sub}" FontSize="14" Margin="2,0,0,0" VerticalAlignment="Center"/>
                        </Grid>
                        <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center" Margin="6,0,8,0">
                            <TextBlock x:Name="txtSearchCount" Foreground="{StaticResource Sub}" FontSize="12" VerticalAlignment="Center" Margin="0,0,8,0" Visibility="Collapsed"/>
                            <Border x:Name="bdSearchKey" Background="{StaticResource Panel3}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="4" Padding="6,1" IsHitTestVisible="False">
                                <TextBlock Text="Ctrl+F" Foreground="{StaticResource Sub}" FontSize="11"/>
                            </Border>
                            <Button x:Name="btnSearchClear" Content="&#x2715;" Visibility="Collapsed" Padding="0" Margin="0" Width="24" Height="24" FontSize="11" ToolTip="Clear search (Esc)" Cursor="Hand">
                                <Button.Template>
                                    <ControlTemplate TargetType="Button">
                                        <Border x:Name="B" Background="{StaticResource Panel3}" CornerRadius="12"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
                                        <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="{StaticResource AccentDim}"/></Trigger></ControlTemplate.Triggers>
                                    </ControlTemplate>
                                </Button.Template>
                            </Button>
                        </StackPanel>
                    </Grid>
                </Border>
                <StackPanel Grid.Column="2" Orientation="Horizontal">
                    <ItemsControl x:Name="icHeadStats" VerticalAlignment="Center" Margin="0,0,14,0">
                        <ItemsControl.ItemsPanel><ItemsPanelTemplate><StackPanel Orientation="Horizontal"/></ItemsPanelTemplate></ItemsControl.ItemsPanel>
                        <ItemsControl.ItemTemplate>
                            <DataTemplate>
                                <Button Tag="{Binding Go}" ToolTip="{Binding Tip}" Cursor="Hand" Margin="0,0,4,0">
                                    <Button.Template>
                                        <ControlTemplate TargetType="Button">
                                            <Border x:Name="B" Background="Transparent" CornerRadius="6" Padding="10,3">
                                                <StackPanel>
                                                    <TextBlock Text="{Binding Value}" Foreground="{Binding Brush}" FontSize="15" FontWeight="SemiBold" HorizontalAlignment="Center"/>
                                                    <TextBlock Text="{Binding Label}" Foreground="{StaticResource Sub}" FontSize="10.5" HorizontalAlignment="Center"/>
                                                </StackPanel>
                                            </Border>
                                            <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="{StaticResource Panel3}"/></Trigger></ControlTemplate.Triggers>
                                        </ControlTemplate>
                                    </Button.Template>
                                </Button>
                            </DataTemplate>
                        </ItemsControl.ItemTemplate>
                    </ItemsControl>
                    <Button x:Name="btnScan" ToolTip="Read the TV folders again (F5)" Background="Transparent" Padding="12,4" Margin="0" VerticalAlignment="Center">
                        <StackPanel>
                            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                                <TextBlock Text="&#x21BB;" Foreground="{StaticResource Accent}" FontWeight="SemiBold" Margin="0,0,6,0"/>
                                <TextBlock Text="Rescan" FontWeight="SemiBold"/>
                            </StackPanel>
                            <TextBlock x:Name="txtLastScan" FontSize="10" Foreground="{StaticResource Sub}" HorizontalAlignment="Center"/>
                        </StackPanel>
                    </Button>
                </StackPanel>
            </Grid>
        </Border>

        <TabControl x:Name="tabMain" Grid.Row="2" BorderThickness="0" Background="Transparent" Padding="0">
            <TabControl.Template>
                <ControlTemplate TargetType="TabControl">
                    <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="200"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        <Border Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}" BorderThickness="0,0,1,0">
                            <StackPanel IsItemsHost="True" Margin="0,14,0,0"/>
                        </Border>
                        <ContentPresenter Grid.Column="1" ContentSource="SelectedContent"/>
                    </Grid>
                </ControlTemplate>
            </TabControl.Template>

            <!-- ================= LIBRARY ================= -->
            <TabItem Header="Library" Style="{StaticResource Nav}" x:Name="tLibrary">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <Grid Margin="20,16,10,0">
                        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                        <StackPanel Orientation="Horizontal" Margin="4,0,0,10">
                            <TextBlock Text="Show" Foreground="{StaticResource Sub}" VerticalAlignment="Center" Margin="0,0,8,0"/>
                            <ComboBox x:Name="cmbLibFilter" Width="200" Margin="0,0,16,0"/>
                            <TextBlock Text="Sort" Foreground="{StaticResource Sub}" VerticalAlignment="Center" Margin="0,0,8,0"/>
                            <ComboBox x:Name="cmbLibSort" Width="180" Margin="0,0,16,0"/>
                            <TextBlock x:Name="txtLibCount" Foreground="{StaticResource Sub}" VerticalAlignment="Center" Margin="0,0,16,0"/>
                            <Button x:Name="btnViewPosters" Content="&#x25A6;  Posters" Padding="12,5" Margin="0,0,4,0" ToolTip="Show the library as a poster wall"/>
                            <Button x:Name="btnViewList" Content="&#x2630;  List" Padding="12,5" Margin="0" ToolTip="Show the library as a sortable list"/>
                        </StackPanel>
                        <DataGrid Grid.Row="1" x:Name="dgLibList" Visibility="Collapsed" SelectionMode="Single" IsReadOnly="True" CanUserSortColumns="True" RowHeight="40" Margin="4,0,0,10">
                            <DataGrid.Columns>
                                <DataGridTemplateColumn Header="" Width="34" CanUserSort="False">
                                    <DataGridTemplateColumn.CellTemplate><DataTemplate><Image Source="{Binding Poster}" Width="24" Height="36" Stretch="UniformToFill"/></DataTemplate></DataGridTemplateColumn.CellTemplate>
                                </DataGridTemplateColumn>
                                <DataGridTextColumn Header="Show" Binding="{Binding Title}" SortMemberPath="SortName" Width="3*"/>
                                <DataGridTextColumn Header="Channel" Binding="{Binding Channel}" SortMemberPath="Channel" Width="1.4*"/>
                                <DataGridTextColumn Header="Status" Binding="{Binding Status}" SortMemberPath="Status" Width="100"/>
                                <DataGridTextColumn Header="Seasons" Binding="{Binding SeasonsN}" SortMemberPath="SeasonsN" Width="80"/>
                                <DataGridTextColumn Header="Latest season" Binding="{Binding DoneText}" SortMemberPath="DoneText" Width="110"/>
                                <DataGridTextColumn Header="Episodes" Binding="{Binding Eps}" SortMemberPath="Eps" Width="84"/>
                                <DataGridTextColumn Header="Size" Binding="{Binding SizeText}" SortMemberPath="Size" Width="90"/>
                                <DataGridTextColumn Header="Quality" Binding="{Binding Quality}" SortMemberPath="Quality" Width="80"/>
                                <DataGridTextColumn Header="Newest episode" Binding="{Binding NewestText}" SortMemberPath="Newest" Width="120"/>
                                <DataGridTextColumn Header="New" Binding="{Binding NewText}" SortMemberPath="NewCount" Width="60"/>
                                <DataGridTextColumn Header="Next airing" Binding="{Binding NextText}" SortMemberPath="Next" Width="120"/>
                            </DataGrid.Columns>
                        </DataGrid>
                        <ScrollViewer Grid.Row="1" x:Name="svShows" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                            <Grid>
                                <ItemsControl x:Name="icShows">
                                    <ItemsControl.ItemsPanel><ItemsPanelTemplate><WrapPanel/></ItemsPanelTemplate></ItemsControl.ItemsPanel>
                                    <ItemsControl.ItemTemplate>
                                        <DataTemplate>
                                            <Button Tag="{Binding Folder}" Style="{StaticResource Tile}" Margin="4,4,4,10" Width="158" ToolTip="{Binding Tip}">
                                                <StackPanel>
                                                    <Grid Width="146" Height="215">
                                                        <Border Background="#232935" CornerRadius="4">
                                                            <TextBlock Text="{Binding Title}" TextWrapping="Wrap" Foreground="{StaticResource Sub}" FontSize="15" Margin="12" VerticalAlignment="Center" TextAlignment="Center" FontFamily="Bahnschrift, Segoe UI"/>
                                                        </Border>
                                                        <Image Source="{Binding Poster}" Stretch="UniformToFill"/>
                                                        <Border VerticalAlignment="Bottom" HorizontalAlignment="Right" Width="24" Height="24" CornerRadius="12" Margin="6" Background="#5CC98A" BorderBrush="#101318" BorderThickness="2" Visibility="{Binding DoneVis}" ToolTip="{Binding DoneTip}">
                                                            <TextBlock Text="&#x2713;" Foreground="#101318" FontWeight="Bold" FontSize="12" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                                        </Border>
                                                        <Border VerticalAlignment="Top" HorizontalAlignment="Right" Background="{Binding BadgeBrush}" CornerRadius="3" Margin="6" Padding="6,2" Visibility="{Binding BadgeVis}">
                                                            <TextBlock Text="{Binding Badge}" Foreground="#101318" FontSize="10.5" FontWeight="Bold"/>
                                                        </Border>
                                                    </Grid>
                                                    <TextBlock Text="{Binding Title}" FontWeight="SemiBold" Margin="2,7,2,0" TextTrimming="CharacterEllipsis"/>
                                                    <TextBlock Text="{Binding Sub}" Foreground="{StaticResource Sub}" FontSize="11.5" Margin="2,2,2,0" TextTrimming="CharacterEllipsis"/>
                                                </StackPanel>
                                            </Button>
                                        </DataTemplate>
                                    </ItemsControl.ItemTemplate>
                                </ItemsControl>
                                <StackPanel x:Name="spEmpty" VerticalAlignment="Center" HorizontalAlignment="Center" Margin="0,120,0,0" Visibility="Collapsed">
                                    <TextBlock Text="No shows yet" Style="{StaticResource H1}" HorizontalAlignment="Center"/>
                                    <TextBlock x:Name="txtEmpty" Style="{StaticResource Hint}" TextAlignment="Center" Margin="0,8,0,0" MaxWidth="420" Text="Check your TV folder in Settings, then press Rescan library."/>
                                </StackPanel>
                            </Grid>
                        </ScrollViewer>
                    </Grid>

                    <!-- detail panel -->
                    <Border Grid.Column="1" x:Name="bdDetail" Width="740" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}" BorderThickness="1,0,0,0" Visibility="Collapsed">
                        <Grid Margin="20,16,20,14">
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>
                            <Image x:Name="imgBackdrop" Grid.RowSpan="3" Margin="-20,-16,-20,0" Height="330" VerticalAlignment="Top" Stretch="UniformToFill" Opacity="0.30" IsHitTestVisible="False">
                                <Image.OpacityMask>
                                    <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                                        <GradientStop Color="#FF000000" Offset="0"/>
                                        <GradientStop Color="#99000000" Offset="0.55"/>
                                        <GradientStop Color="#00000000" Offset="1"/>
                                    </LinearGradientBrush>
                                </Image.OpacityMask>
                            </Image>
                            <Grid>
                                <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                <Border Width="120" Height="177" Background="#232935" CornerRadius="4" VerticalAlignment="Top">
                                    <Image x:Name="imgDetail" Stretch="UniformToFill"/>
                                </Border>
                                <StackPanel Grid.Column="1" Margin="16,0,8,0">
                                    <TextBlock x:Name="txtDetailTitle" Style="{StaticResource H1}" TextWrapping="Wrap"/>
                                    <TextBlock x:Name="txtDetailMeta" Foreground="{StaticResource Sub}" Margin="0,4,0,0" TextWrapping="Wrap"/>
                                    <TextBlock x:Name="txtDetailNext" Foreground="{StaticResource Accent2}" Margin="0,4,0,0" TextWrapping="Wrap"/>
                                    <ScrollViewer MaxHeight="88" VerticalScrollBarVisibility="Auto" Margin="0,8,0,0">
                                        <TextBlock x:Name="txtDetailOverview" TextWrapping="Wrap" Foreground="#C9CFDA" LineHeight="19"/>
                                    </ScrollViewer>
                                </StackPanel>
                                <Button Grid.Column="2" x:Name="btnCloseDetail" Content="&#x2715;" Padding="9,4" Margin="0" VerticalAlignment="Top" ToolTip="Close"/>
                            </Grid>
                            <WrapPanel Grid.Row="1" Margin="0,12,0,0">
                                <Button x:Name="btnShowFolder" Content="Open folder" Margin="0,0,6,6"/>
                                <Button x:Name="btnShowConfirm" Content="&#x2714;  Confirm match" Style="{StaticResource AccentButton}" Margin="0,0,6,6" ToolTip="This best guess is right - stop flagging it" Visibility="Collapsed"/>
                                <Button x:Name="btnShowMatch" Content="Fix match..." Margin="0,0,6,6" ToolTip="Choose which show this folder is"/>
                                <Button x:Name="btnShowRefresh" Content="Refresh info" Margin="0,0,6,6"/>
                            </WrapPanel>
                            <StackPanel Grid.Row="2" Margin="0,4,0,0">
                                <TextBlock x:Name="txtCastHead" Text="Cast" Style="{StaticResource H2}" Margin="0,2,0,6"/>
                                <ScrollViewer x:Name="svCast" HorizontalScrollBarVisibility="Auto" VerticalScrollBarVisibility="Disabled">
                                    <ItemsControl x:Name="icCast">
                                        <ItemsControl.ItemsPanel><ItemsPanelTemplate><StackPanel Orientation="Horizontal"/></ItemsPanelTemplate></ItemsControl.ItemsPanel>
                                        <ItemsControl.ItemTemplate>
                                            <DataTemplate>
                                                <Button Tag="{Binding Key}" Style="{StaticResource Tile}" Margin="0,0,2,4" ToolTip="{Binding Tip}">
                                                <StackPanel Width="84">
                                                    <Grid Width="64" Height="64">
                                                        <Grid.Clip><EllipseGeometry Center="32,32" RadiusX="32" RadiusY="32"/></Grid.Clip>
                                                        <Ellipse Fill="#262C37"/>
                                                        <TextBlock Text="{Binding Initials}" Foreground="{StaticResource Sub}" HorizontalAlignment="Center" VerticalAlignment="Center" FontSize="16"/>
                                                        <Image Source="{Binding Photo}" Stretch="Uniform" Width="64" VerticalAlignment="Top" Margin="0,-2,0,0"/>
                                                        <Ellipse Stroke="{StaticResource Line}" StrokeThickness="1.5"/>
                                                    </Grid>
                                                    <TextBlock Text="{Binding Name}" FontSize="11.5" TextAlignment="Center" TextTrimming="CharacterEllipsis" Margin="0,4,0,0"/>
                                                    <TextBlock Text="{Binding Role}" FontSize="10.5" Foreground="{StaticResource Sub}" TextAlignment="Center" TextTrimming="CharacterEllipsis"/>
                                                </StackPanel>
                                                </Button>
                                            </DataTemplate>
                                        </ItemsControl.ItemTemplate>
                                    </ItemsControl>
                                </ScrollViewer>
                                <ListBox x:Name="lbSeasons" Background="Transparent" BorderThickness="0" Margin="0,8,0,4" ItemContainerStyle="{StaticResource Chip}" DisplayMemberPath="Label" ScrollViewer.HorizontalScrollBarVisibility="Disabled">
                                    <ListBox.ItemsPanel><ItemsPanelTemplate><WrapPanel/></ItemsPanelTemplate></ListBox.ItemsPanel>
                                </ListBox>
                            </StackPanel>
                            <DataGrid Grid.Row="3" x:Name="dgEpisodes" RowHeight="50">
                                <DataGrid.RowStyle>
                                    <Style TargetType="DataGridRow">
                                        <Style.Triggers>
                                            <DataTrigger Binding="{Binding IsNew}" Value="True"><Setter Property="Background" Value="#16352A"/><Setter Property="FontWeight" Value="SemiBold"/></DataTrigger>
                                            <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="{StaticResource AccentDim}"/></Trigger>
                                        </Style.Triggers>
                                    </Style>
                                </DataGrid.RowStyle>
                                <DataGrid.Columns>
                                    <DataGridTemplateColumn Header="" Width="44">
                                        <DataGridTemplateColumn.CellTemplate>
                                            <DataTemplate>
                                                <Border Background="{Binding MarkBg}" CornerRadius="3" Padding="5,1" HorizontalAlignment="Left">
                                                    <TextBlock Text="{Binding Mark}" Foreground="{Binding MarkFg}" FontSize="10.5" FontWeight="Bold"/>
                                                </Border>
                                            </DataTemplate>
                                        </DataGridTemplateColumn.CellTemplate>
                                    </DataGridTemplateColumn>
                                    <DataGridTemplateColumn Header="" Width="84" CanUserSort="False">
                                        <DataGridTemplateColumn.CellTemplate>
                                            <DataTemplate>
                                                <Grid Width="76" Height="43" Margin="0,2">
                                                    <Border Background="#232935" CornerRadius="3"/>
                                                    <Image Source="{Binding Thumb}" Stretch="UniformToFill"><Image.Clip><RectangleGeometry Rect="0,0,76,43" RadiusX="3" RadiusY="3"/></Image.Clip></Image>
                                                </Grid>
                                            </DataTemplate>
                                        </DataGridTemplateColumn.CellTemplate>
                                    </DataGridTemplateColumn>
                                    <DataGridTextColumn Header="Ep" Binding="{Binding Ep}" Width="54"/>
                                    <DataGridTextColumn Header="Title" Binding="{Binding Title}" Width="*"/>
                                    <DataGridTextColumn Header="Aired" Binding="{Binding Aired}" Width="92"/>
                                    <DataGridTextColumn Header="State" Binding="{Binding State}" Width="72"/>
                                    <DataGridTextColumn Header="Quality" Binding="{Binding Res}" Width="62"/>
                                    <DataGridTextColumn Header="Size" Binding="{Binding SizeText}" Width="74"/>
                                </DataGrid.Columns>
                            </DataGrid>
                            <TextBlock Grid.Row="4" x:Name="txtEpOverview" Style="{StaticResource Hint}" Margin="0,8,0,0" MaxHeight="60"/>
                            <WrapPanel Grid.Row="5" Margin="0,10,0,0">
                                <Button x:Name="btnEpPlay" Content="&#x25B6;  Play" Style="{StaticResource AccentButton}" Margin="0,0,6,6"/>
                                <Button x:Name="btnEpOpen" Content="Show file" Margin="0,0,6,6"/>
                            </WrapPanel>
                        </Grid>
                    </Border>
                </Grid>
            </TabItem>

            <!-- ================= NEW ================= -->
            <TabItem Header="New" Style="{StaticResource Nav}" x:Name="tNew">
                <Grid Margin="24,18">
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <StackPanel>
                        <TextBlock Text="New episodes" Style="{StaticResource H1}"/>
                        <TextBlock x:Name="txtNewHint" Style="{StaticResource Hint}" Margin="0,4,0,14"/>
                    </StackPanel>
                    <WrapPanel Grid.Row="1" Margin="0,0,0,12">
                        <TextBlock Text="Show" Foreground="{StaticResource Sub}" VerticalAlignment="Center" Margin="0,0,8,6"/>
                        <ComboBox x:Name="cmbNewRange" Width="200" Margin="0,0,16,6"/>
                        <TextBlock x:Name="txtNewSummary" Foreground="{StaticResource Sub}" VerticalAlignment="Center" Margin="0,0,0,6"/>
                    </WrapPanel>
                    <DataGrid Grid.Row="2" x:Name="dgNew" RowHeight="58">
                        <DataGrid.Columns>
                            <DataGridTemplateColumn Header="" Width="98" CanUserSort="False">
                                <DataGridTemplateColumn.CellTemplate>
                                    <DataTemplate>
                                        <Grid Width="88" Height="50" Margin="0,2">
                                            <Border Background="#232935" CornerRadius="3"/>
                                            <Image Source="{Binding Thumb}" Stretch="UniformToFill"><Image.Clip><RectangleGeometry Rect="0,0,88,50" RadiusX="3" RadiusY="3"/></Image.Clip></Image>
                                        </Grid>
                                    </DataTemplate>
                                </DataGridTemplateColumn.CellTemplate>
                            </DataGridTemplateColumn>

                            <DataGridTextColumn Header="Added" Binding="{Binding AddedText}" Width="110"/>
                            <DataGridTextColumn Header="Show" Binding="{Binding Show}" Width="2*"/>
                            <DataGridTextColumn Header="Ep" Binding="{Binding Ep}" Width="70"/>
                            <DataGridTextColumn Header="Title" Binding="{Binding Title}" Width="2*"/>
                            <DataGridTextColumn Header="Res" Binding="{Binding Res}" Width="64"/>
                            <DataGridTextColumn Header="Size" Binding="{Binding SizeText}" Width="84"/>
                        </DataGrid.Columns>
                    </DataGrid>
                    <WrapPanel Grid.Row="3" Margin="0,12,0,0">
                        <Button x:Name="btnNewPlay" Content="&#x25B6;  Play" Style="{StaticResource AccentButton}"/>
                        <Button x:Name="btnNewDismiss" Content="Not new" ToolTip="Take the selected episodes off this list"/>
                        <Button x:Name="btnNewGo" Content="Go to show"/>
                        <Button x:Name="btnNewOpen" Content="Show file"/>
                    </WrapPanel>
                </Grid>
            </TabItem>

            <!-- ================= CALENDAR ================= -->
            <TabItem Header="Calendar" Style="{StaticResource Nav}" x:Name="tCalendar">
                <Grid Margin="20,16,20,14">
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <DockPanel>
                        <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
                            <Button x:Name="btnCalPrev" Content="&#x25C0;  Previous week"/>
                            <Button x:Name="btnCalToday" Content="This week"/>
                            <Button x:Name="btnCalNext" Content="Next week  &#x25B6;"/>
                            <Button x:Name="btnCalIcs" Content="Save to my calendar (.ics)" Margin="8,0,0,0" ToolTip="Save the next 3 months of your shows' episodes as a calendar file for Outlook, Google Calendar or your phone"/>
                            <Button x:Name="btnCalRefresh" Content="Refresh airing info" Style="{StaticResource AccentButton}" Margin="8,0,0,0"/>
                        </StackPanel>
                        <StackPanel>
                            <TextBlock Text="Calendar" Style="{StaticResource H1}"/>
                            <TextBlock x:Name="txtCalRange" Foreground="{StaticResource Accent2}" FontSize="14" Margin="0,4,0,0"/>
                        </StackPanel>
                    </DockPanel>
                    <WrapPanel Grid.Row="1" Margin="0,12,0,4">
                        <CheckBox x:Name="chkCalHideHave" Content="Hide episodes already on disk" Margin="0,0,16,6"/>
                        <TextBlock x:Name="txtCalSummary" Foreground="{StaticResource Sub}" VerticalAlignment="Center" Margin="0,0,0,6"/>
                    </WrapPanel>
                    <Border Grid.Row="2" x:Name="bdCalMissed" Background="#2A1C22" BorderBrush="#5A2A35" BorderThickness="1" CornerRadius="6" Padding="12,8" Margin="0,4,0,10" Visibility="Collapsed">
                        <DockPanel>
                            <TextBlock DockPanel.Dock="Left" x:Name="txtCalMissed" Foreground="#F3A3B0" FontWeight="SemiBold" VerticalAlignment="Center" Margin="0,0,12,0"/>
                            <ScrollViewer HorizontalScrollBarVisibility="Auto" VerticalScrollBarVisibility="Disabled">
                                <ItemsControl x:Name="icCalMissed">
                                    <ItemsControl.ItemsPanel><ItemsPanelTemplate><StackPanel Orientation="Horizontal"/></ItemsPanelTemplate></ItemsControl.ItemsPanel>
                                    <ItemsControl.ItemTemplate>
                                        <DataTemplate>
                                            <Button Tag="{Binding Folder}" Content="{Binding Label}" ToolTip="{Binding Tip}" Padding="10,4" Margin="0,0,6,0" FontSize="12"/>
                                        </DataTemplate>
                                    </ItemsControl.ItemTemplate>
                                </ItemsControl>
                            </ScrollViewer>
                        </DockPanel>
                    </Border>
                    <ItemsControl Grid.Row="3" x:Name="icCalendar">
                        <ItemsControl.ItemsPanel><ItemsPanelTemplate><UniformGrid Rows="1"/></ItemsPanelTemplate></ItemsControl.ItemsPanel>
                        <ItemsControl.ItemTemplate>
                            <DataTemplate>
                                <Border Margin="0,0,8,0" Background="{StaticResource Panel}" BorderBrush="{Binding BorderBrush}" BorderThickness="{Binding BorderWidth}" CornerRadius="6">
                                    <DockPanel>
                                        <Border DockPanel.Dock="Top" Background="{Binding HeadBg}" CornerRadius="5,5,0,0" Padding="10,8">
                                            <DockPanel>
                                                <Border DockPanel.Dock="Right" Background="{Binding CountBg}" CornerRadius="9" Padding="7,1" VerticalAlignment="Center" Visibility="{Binding CountVis}">
                                                    <TextBlock Text="{Binding Count}" FontSize="11" FontWeight="Bold" Foreground="{Binding HeadBg}"/>
                                                </Border>
                                                <StackPanel>
                                                    <TextBlock Text="{Binding DayName}" FontFamily="Bahnschrift SemiBold, Segoe UI" FontSize="15" Foreground="{Binding HeadFg}"/>
                                                    <TextBlock Text="{Binding DateText}" FontSize="12" Foreground="{Binding HeadSub}"/>
                                                </StackPanel>
                                            </DockPanel>
                                        </Border>
                                        <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                                            <StackPanel Margin="6,8,6,6">
                                                <ItemsControl ItemsSource="{Binding Episodes}">
                                                    <ItemsControl.ItemTemplate>
                                                        <DataTemplate>
                                                            <Button Tag="{Binding Folder}" Style="{StaticResource Tile}" Margin="0,0,0,4" ToolTip="{Binding Tip}">
                                                                <Grid>
                                                                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                                                    <Grid Width="46" Height="68" VerticalAlignment="Top">
                                                                        <Border Background="#232935" CornerRadius="3"/>
                                                                        <Image Source="{Binding Poster}" Stretch="UniformToFill"/>
                                                                    </Grid>
                                                                    <StackPanel Grid.Column="1" Margin="8,0,0,0">
                                                                        <TextBlock Text="{Binding Show}" FontWeight="SemiBold" FontSize="12.5" TextTrimming="CharacterEllipsis"/>
                                                                        <TextBlock Text="{Binding EpLine}" FontSize="11.5" Foreground="#C9CFDA" TextTrimming="CharacterEllipsis" Margin="0,1,0,0"/>
                                                                        <TextBlock Text="{Binding TimeLine}" FontSize="11" Foreground="{StaticResource Sub}" TextTrimming="CharacterEllipsis" Margin="0,1,0,0"/>
                                                                        <Border Background="{Binding StatusBg}" CornerRadius="3" Padding="5,1" HorizontalAlignment="Left" Margin="0,4,0,0">
                                                                            <TextBlock Text="{Binding Status}" FontSize="10" FontWeight="Bold" Foreground="#101318"/>
                                                                        </Border>
                                                                    </StackPanel>
                                                                </Grid>
                                                            </Button>
                                                        </DataTemplate>
                                                    </ItemsControl.ItemTemplate>
                                                </ItemsControl>
                                                <TextBlock Text="{Binding EmptyText}" Foreground="{StaticResource Sub}" FontSize="12" Margin="4,6,4,0" TextWrapping="Wrap"/>
                                            </StackPanel>
                                        </ScrollViewer>
                                    </DockPanel>
                                </Border>
                            </DataTemplate>
                        </ItemsControl.ItemTemplate>
                    </ItemsControl>
                </Grid>
            </TabItem>

            <!-- ================= CAST ================= -->
            <TabItem Header="Cast" Style="{StaticResource Nav}" x:Name="tCast">
                <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <Grid Margin="20,16,10,0">
                        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                        <WrapPanel Margin="4,0,0,10">
                            <Grid Width="240" Margin="0,0,16,6">
                                <TextBox x:Name="txtCastSearch"/>
                                <TextBlock x:Name="txtCastSearchHint" Text="Search cast or character..." IsHitTestVisible="False" Foreground="{StaticResource Sub}" Margin="11,0,0,0" VerticalAlignment="Center"/>
                            </Grid>
                            <TextBlock Text="Show" Foreground="{StaticResource Sub}" VerticalAlignment="Center" Margin="0,0,8,6"/>
                            <ComboBox x:Name="cmbCastFilter" Width="220" Margin="0,0,16,6"/>
                            <TextBlock Text="Sort" Foreground="{StaticResource Sub}" VerticalAlignment="Center" Margin="0,0,8,6"/>
                            <ComboBox x:Name="cmbCastSort" Width="190" Margin="0,0,16,6"/>
                            <TextBlock x:Name="txtCastCount" Foreground="{StaticResource Sub}" VerticalAlignment="Center" Margin="0,0,0,6"/>
                        </WrapPanel>
                        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                            <Grid>
                                <ItemsControl x:Name="icPeople">
                                    <ItemsControl.ItemsPanel><ItemsPanelTemplate><WrapPanel/></ItemsPanelTemplate></ItemsControl.ItemsPanel>
                                    <ItemsControl.ItemTemplate>
                                        <DataTemplate>
                                            <Button Tag="{Binding Key}" Style="{StaticResource Tile}" Margin="2,2,2,8" Width="122" ToolTip="{Binding Tip}">
                                                <StackPanel>
                                                    <Grid Width="92" Height="92">
                                                        <Grid.Clip><EllipseGeometry Center="46,46" RadiusX="46" RadiusY="46"/></Grid.Clip>
                                                        <Ellipse Fill="#262C37"/>
                                                        <TextBlock Text="{Binding Initials}" Foreground="{StaticResource Sub}" HorizontalAlignment="Center" VerticalAlignment="Center" FontSize="22"/>
                                                        <Image Source="{Binding Photo}" Stretch="Uniform" Width="92" VerticalAlignment="Top" Margin="0,-3,0,0"/>
                                                        <Ellipse Stroke="{StaticResource Line}" StrokeThickness="1.5"/>
                                                    </Grid>
                                                    <TextBlock Text="{Binding Name}" FontWeight="SemiBold" TextAlignment="Center" TextTrimming="CharacterEllipsis" Margin="2,7,2,0"/>
                                                    <TextBlock Text="{Binding Sub}" Foreground="{StaticResource Sub}" FontSize="11.5" TextAlignment="Center" TextTrimming="CharacterEllipsis" Margin="2,2,2,0"/>
                                                </StackPanel>
                                            </Button>
                                        </DataTemplate>
                                    </ItemsControl.ItemTemplate>
                                </ItemsControl>
                                <TextBlock x:Name="txtCastEmpty" Style="{StaticResource Hint}" HorizontalAlignment="Center" Margin="0,120,0,0" TextAlignment="Center" MaxWidth="440" Visibility="Collapsed"/>
                            </Grid>
                        </ScrollViewer>
                    </Grid>

                    <Border Grid.Column="1" x:Name="bdPerson" Width="640" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}" BorderThickness="1,0,0,0" Visibility="Collapsed">
                        <Grid Margin="22,18,22,14">
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                            </Grid.RowDefinitions>
                            <Grid>
                                <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                                <Grid Width="150" Height="150" VerticalAlignment="Top">
                                    <Grid.Clip><EllipseGeometry Center="75,75" RadiusX="75" RadiusY="75"/></Grid.Clip>
                                    <Ellipse Fill="#262C37"/>
                                    <TextBlock x:Name="txtPersonInitials" Foreground="{StaticResource Sub}" HorizontalAlignment="Center" VerticalAlignment="Center" FontSize="36"/>
                                    <Image x:Name="imgPerson" Stretch="Uniform" Width="150" VerticalAlignment="Top" Margin="0,-4,0,0"/>
                                    <Ellipse Stroke="{StaticResource Accent2}" StrokeThickness="2"/>
                                </Grid>
                                <StackPanel Grid.Column="1" Margin="20,8,8,0" VerticalAlignment="Center">
                                    <TextBlock x:Name="txtPersonName" Style="{StaticResource H1}" FontSize="28" TextWrapping="Wrap"/>
                                    <TextBlock x:Name="txtPersonMeta" Foreground="{StaticResource Sub}" Margin="0,6,0,0" TextWrapping="Wrap" FontSize="13.5"/>
                                    <TextBlock x:Name="txtPersonMeta2" Foreground="{StaticResource Sub}" Margin="0,3,0,0" TextWrapping="Wrap"/>
                                    <TextBlock x:Name="txtPersonSummary" Foreground="{StaticResource Accent2}" Margin="0,8,0,0" TextWrapping="Wrap"/>
                                </StackPanel>
                                <Button Grid.Column="2" x:Name="btnClosePerson" Content="&#x2715;" Padding="9,4" Margin="0" VerticalAlignment="Top" ToolTip="Close"/>
                            </Grid>
                            <StackPanel Grid.Row="1" Margin="0,14,0,0">
                                <WrapPanel>
                                    <Button x:Name="btnPersonBack" Content="Back to show" Style="{StaticResource AccentButton}" Margin="0,0,6,6" Visibility="Collapsed"/>
                                    <Button x:Name="btnPersonTvmaze" Content="Open on TVmaze" Margin="0,0,6,6"/>
                                    <Button x:Name="btnPersonRefresh" Content="Refresh" Margin="0,0,6,6"/>
                                </WrapPanel>
                                <Border x:Name="bdPersonBio" Background="{StaticResource Panel2}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="6" Padding="14,10" Margin="0,6,0,0" Visibility="Collapsed">
                                    <StackPanel>
                                        <DockPanel Margin="0,0,0,6">
                                            <Button x:Name="btnPersonBioMore" DockPanel.Dock="Right" Content="Show more" Padding="10,3" Margin="0" FontSize="12"/>
                                            <TextBlock Text="Biography" Style="{StaticResource H2}" Margin="0" VerticalAlignment="Center"/>
                                        </DockPanel>
                                        <ScrollViewer x:Name="svPersonBio" MaxHeight="96" VerticalScrollBarVisibility="Disabled">
                                            <TextBlock x:Name="txtPersonBio" TextWrapping="Wrap" Foreground="#C9CFDA" LineHeight="20" FontSize="13"/>
                                        </ScrollViewer>
                                        <TextBlock Text="Biography from TVmaze" Foreground="{StaticResource Sub}" FontSize="10.5" Margin="0,6,0,0"/>
                                    </StackPanel>
                                </Border>
                            </StackPanel>
                            <TextBlock Grid.Row="2" x:Name="txtPersonLibHead" Text="In your library" Style="{StaticResource H2}" Margin="0,10,0,8"/>
                            <ScrollViewer Grid.Row="3" HorizontalScrollBarVisibility="Auto" VerticalScrollBarVisibility="Disabled">
                                <ItemsControl x:Name="icPersonShows">
                                    <ItemsControl.ItemsPanel><ItemsPanelTemplate><StackPanel Orientation="Horizontal"/></ItemsPanelTemplate></ItemsControl.ItemsPanel>
                                    <ItemsControl.ItemTemplate>
                                        <DataTemplate>
                                            <Button Tag="{Binding Folder}" Style="{StaticResource Tile}" Margin="0,0,4,6" Width="112" ToolTip="{Binding Tip}">
                                                <StackPanel>
                                                    <Grid Width="100" Height="148">
                                                        <Border Background="#232935" CornerRadius="4">
                                                            <TextBlock Text="{Binding Title}" TextWrapping="Wrap" Foreground="{StaticResource Sub}" Margin="8" VerticalAlignment="Center" TextAlignment="Center"/>
                                                        </Border>
                                                        <Image Source="{Binding Poster}" Stretch="UniformToFill"/>
                                                    </Grid>
                                                    <TextBlock Text="{Binding Title}" FontWeight="SemiBold" FontSize="12" Margin="2,6,2,0" TextTrimming="CharacterEllipsis"/>
                                                    <TextBlock Text="{Binding Role}" Foreground="{StaticResource Sub}" FontSize="11" Margin="2,1,2,0" TextTrimming="CharacterEllipsis"/>
                                                </StackPanel>
                                            </Button>
                                        </DataTemplate>
                                    </ItemsControl.ItemTemplate>
                                </ItemsControl>
                            </ScrollViewer>
                            <TextBlock Grid.Row="4" x:Name="txtOtherHead" Text="Other TV" Style="{StaticResource H2}" Margin="0,16,0,8"/>
                            <DataGrid Grid.Row="5" x:Name="dgCredits" SelectionMode="Single" ToolTip="Double-click to open the show on TVmaze">
                                <DataGrid.Columns>
                                    <DataGridTextColumn Header="Show" Binding="{Binding Show}" Width="2*"/>
                                    <DataGridTextColumn Header="As" Binding="{Binding Character}" Width="2*"/>
                                    <DataGridTextColumn Header="Years" Binding="{Binding Years}" Width="84"/>
                                    <DataGridTextColumn Header="Network" Binding="{Binding Network}" Width="*"/>
                                </DataGrid.Columns>
                            </DataGrid>
                        </Grid>
                    </Border>
                </Grid>
            </TabItem>

            <!-- ================= MISSING ================= -->
            <TabItem Header="Missing episodes" Style="{StaticResource Nav}" x:Name="tMissing">
                <Grid Margin="24,18">
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <StackPanel>
                        <TextBlock Text="Missing episodes" Style="{StaticResource H1}"/>
                        <TextBlock Style="{StaticResource Hint}" Margin="0,4,0,14" Text="Episodes that have aired (according to TVmaze) but aren't on disk. The check runs when you first open this page; press Check now to run it again."/>
                    </StackPanel>
                    <WrapPanel Grid.Row="1" Margin="0,0,0,12">
                        <Button x:Name="btnMissRun" Content="Check now" Style="{StaticResource AccentButton}" Margin="0,0,16,6"/>
                        <CheckBox x:Name="chkMissOwned" Content="Only seasons I have some of" Margin="0,0,16,6"/>
                        <CheckBox x:Name="chkMissSpecials" Content="Include specials" Margin="0,0,16,6"/>
                        <CheckBox x:Name="chkMissContinuing" Content="Continuing shows only" Margin="0,0,16,6"/>
                        <Grid Width="220" Margin="0,0,10,6">
                            <TextBox x:Name="txtMissFilter"/>
                            <TextBlock x:Name="txtMissFilterHint" Text="Filter by show..." IsHitTestVisible="False" Foreground="{StaticResource Sub}" Margin="11,0,0,0" VerticalAlignment="Center"/>
                        </Grid>
                        <TextBlock x:Name="txtMissSummary" Foreground="{StaticResource Sub}" VerticalAlignment="Center" Margin="0,0,0,6"/>
                    </WrapPanel>
                    <DataGrid Grid.Row="2" x:Name="dgMissing">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="Show" Binding="{Binding Show}" Width="2*"/>
                            <DataGridTextColumn Header="Ep" Binding="{Binding Ep}" Width="70"/>
                            <DataGridTextColumn Header="Title" Binding="{Binding Title}" Width="2*"/>
                            <DataGridTextColumn Header="Aired" Binding="{Binding Aired}" Width="100"/>
                        </DataGrid.Columns>
                    </DataGrid>
                    <WrapPanel Grid.Row="3" Margin="0,12,0,0">
                        <Button x:Name="btnMissGo" Content="Go to show"/>
                        <Button x:Name="btnMissIgnore" Content="Ignore this show" ToolTip="Leave this show out of future missing-episode checks"/>
                        <Button x:Name="btnMissExport" Content="Export list..."/>
                    </WrapPanel>
                </Grid>
            </TabItem>

            <!-- ================= FILENAMES ================= -->
            <TabItem Header="Filename checker" Style="{StaticResource Nav}">
                <Grid Margin="24,18">
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <StackPanel>
                        <TextBlock Text="Filename checker" Style="{StaticResource H1}"/>
                        <TextBlock Style="{StaticResource Hint}" Margin="0,4,0,14" Text="Finds files that don't follow 'Show - 1x01 - Title', have the wrong title, or sit in the wrong season folder. Nothing is renamed until you select rows and press Rename. Subtitles and other files with the same name are renamed with the video."/>
                    </StackPanel>
                    <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,12">
                        <Button x:Name="btnNamesRun" Content="Check names" Style="{StaticResource AccentButton}" Margin="0,0,16,0"/>
                        <CheckBox x:Name="chkNamesTitles" Content="Compare titles with TVmaze" IsChecked="True"/>
                        <CheckBox x:Name="chkNamesHideFormat" Content="Hide formatting-only differences"/>
                        <TextBlock x:Name="txtNamesSummary" Foreground="{StaticResource Sub}" VerticalAlignment="Center"/>
                    </StackPanel>
                    <DataGrid Grid.Row="2" x:Name="dgNames">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="Show" Binding="{Binding Show}" Width="170"/>
                            <DataGridTextColumn Header="Problem" Binding="{Binding Issue}" Width="210"/>
                            <DataGridTextColumn Header="Current name" Binding="{Binding Current}" Width="*"/>
                            <DataGridTextColumn Header="Rename to" Binding="{Binding Proposed}" Width="*"/>
                        </DataGrid.Columns>
                    </DataGrid>
                    <WrapPanel Grid.Row="3" Margin="0,12,0,0">
                        <Button x:Name="btnNamesApply" Content="Rename selected" Style="{StaticResource AccentButton}"/>
                        <Button x:Name="btnNamesUndo" Content="Undo last rename batch"/>
                        <Button x:Name="btnNamesOpen" Content="Show file"/>
                    </WrapPanel>
                </Grid>
            </TabItem>

            <!-- ================= DUPLICATES ================= -->
            <TabItem Header="Duplicates &amp; quality" Style="{StaticResource Nav}" x:Name="tDupes">
                <Grid Margin="24,18">
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <StackPanel>
                        <TextBlock Text="Duplicates" Style="{StaticResource H1}"/>
                        <TextBlock x:Name="txtDupes" Style="{StaticResource Hint}" Margin="0,4,0,12" Text="Episodes that have more than one file. Biggest copy first. Resolution is read from the video files."/>
                    </StackPanel>
                    <DataGrid Grid.Row="1" x:Name="dgDupes">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="Show" Binding="{Binding Show}" Width="180"/>
                            <DataGridTextColumn Header="Ep" Binding="{Binding Ep}" Width="70"/>
                            <DataGridTextColumn Header="File" Binding="{Binding File}" Width="*"/>
                            <DataGridTextColumn Header="Size" Binding="{Binding SizeText}" Width="90"/>
                            <DataGridTextColumn Header="Res" Binding="{Binding Res}" Width="70"/>
                            <DataGridTextColumn Header="Folder" Binding="{Binding Folder}" Width="80"/>
                        </DataGrid.Columns>
                    </DataGrid>
                    <WrapPanel Grid.Row="2" Margin="0,10,0,0">
                        <Button x:Name="btnDupesPlay" Content="&#x25B6;  Play"/>
                        <Button x:Name="btnDupesOpen" Content="Show file"/>
                        <Button x:Name="btnDupesMove" Content="Move to holding folder..." ToolTip="Moves the selected files (and their subtitles) out of the library into the holding folder set in Settings"/>
                    </WrapPanel>
                    <TextBlock Grid.Row="3" Text="Quality by show" Style="{StaticResource H2}" Margin="0,20,0,8"/>
                    <DataGrid Grid.Row="4" x:Name="dgQuality">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="Show" Binding="{Binding Show}" Width="*"/>
                            <DataGridTextColumn Header="Episodes" Binding="{Binding Episodes}" Width="80"/>
                            <DataGridTextColumn Header="Files" Binding="{Binding Files}" Width="70"/>
                            <DataGridTextColumn Header="Size" Binding="{Binding SizeText}" Width="90"/>
                            <DataGridTextColumn Header="2160p" Binding="{Binding UHD}" Width="70"/>
                            <DataGridTextColumn Header="1080p" Binding="{Binding FHD}" Width="70"/>
                            <DataGridTextColumn Header="720p" Binding="{Binding HD}" Width="70"/>
                            <DataGridTextColumn Header="SD" Binding="{Binding SD}" Width="60"/>
                            <DataGridTextColumn Header="Unknown" Binding="{Binding Unknown}" Width="80"/>
                        </DataGrid.Columns>
                    </DataGrid>
                </Grid>
            </TabItem>

            <!-- ================= PROBLEM FILES ================= -->
            <TabItem Header="Problem files" Style="{StaticResource Nav}" x:Name="tProblems">
                <Grid Margin="24,18">
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                    <StackPanel>
                        <TextBlock Text="Problem files" Style="{StaticResource H1}"/>
                        <TextBlock Style="{StaticResource Hint}" Margin="0,4,0,14" Text="Things in your show folders that look wrong: tiny or unreadable episodes, unfinished downloads, episodes not in a season folder, junk files, subtitles or .nfo files with no episode, and empty folders. Nothing changes until you choose an action, and files are moved to the holding folder rather than deleted."/>
                    </StackPanel>
                    <WrapPanel Grid.Row="1" Margin="0,0,0,12">
                        <Button x:Name="btnProbRun" Content="Check now" Style="{StaticResource AccentButton}" Margin="0,0,16,6"/>
                        <TextBlock Text="Show" Foreground="{StaticResource Sub}" VerticalAlignment="Center" Margin="0,0,8,6"/>
                        <ComboBox x:Name="cmbProbType" Width="300" Margin="0,0,16,6"/>
                        <TextBlock x:Name="txtProbSummary" Foreground="{StaticResource Sub}" VerticalAlignment="Center" Margin="0,0,0,6"/>
                    </WrapPanel>
                    <DataGrid Grid.Row="2" x:Name="dgProblems">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="Problem" Binding="{Binding Type}" Width="260"/>
                            <DataGridTextColumn Header="Show" Binding="{Binding Show}" Width="200"/>
                            <DataGridTextColumn Header="File or folder" Binding="{Binding File}" Width="*"/>
                            <DataGridTextColumn Header="Details" Binding="{Binding Detail}" Width="140"/>
                        </DataGrid.Columns>
                    </DataGrid>
                    <WrapPanel Grid.Row="3" Margin="0,12,0,0">
                        <Button x:Name="btnProbHold" Content="Move to holding folder" Style="{StaticResource AccentButton}" ToolTip="Move the selected files (and their subtitles) out of the library"/>
                        <Button x:Name="btnProbSeason" Content="Move into season folder" ToolTip="Move selected 'Not in a season folder' episodes into the right S01, S02... folder"/>
                        <Button x:Name="btnProbEmpty" Content="Remove empty folders" ToolTip="Remove the selected folders if they are still empty"/>
                        <Button x:Name="btnProbOpen" Content="Show file"/>
                        <Button x:Name="btnProbPlay" Content="&#x25B6;  Play"/>
                    </WrapPanel>
                </Grid>
            </TabItem>

            <!-- ================= STATS ================= -->
            <TabItem Header="Stats" Style="{StaticResource Nav}" x:Name="tStats">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel Margin="24,18,10,140">
                        <DockPanel Margin="0,0,14,14">
                            <Button DockPanel.Dock="Right" x:Name="btnStatsRefresh" Content="Refresh" VerticalAlignment="Center" Margin="0"/>
                            <StackPanel>
                                <TextBlock Text="Stats" Style="{StaticResource H1}"/>
                                <TextBlock x:Name="txtStatsWhen" Style="{StaticResource Hint}" Margin="0,4,0,0"/>
                            </StackPanel>
                        </DockPanel>
                        <ItemsControl x:Name="icStatTiles" Margin="0,0,0,4">
                            <ItemsControl.ItemsPanel><ItemsPanelTemplate><WrapPanel/></ItemsPanelTemplate></ItemsControl.ItemsPanel>
                            <ItemsControl.ItemTemplate>
                                <DataTemplate>
                                    <Border Style="{StaticResource Card}" Width="232" Margin="0,0,14,14" Padding="18,14" ToolTip="{Binding Tip}">
                                        <StackPanel>
                                            <TextBlock Text="{Binding Label}" Foreground="{StaticResource Sub}" FontSize="12.5"/>
                                            <TextBlock Text="{Binding Value}" FontFamily="Bahnschrift SemiBold, Segoe UI" FontSize="30" Foreground="{Binding ValueBrush}" Margin="0,2,0,0"/>
                                            <TextBlock Text="{Binding Sub}" Foreground="{StaticResource Sub}" FontSize="11.5" TextWrapping="Wrap"/>
                                            <Grid Height="6" Margin="0,8,0,0" Visibility="{Binding BarVis}">
                                                <Grid.ColumnDefinitions><ColumnDefinition Width="{Binding BarUsed}"/><ColumnDefinition Width="{Binding BarFree}"/></Grid.ColumnDefinitions>
                                                <Border Grid.ColumnSpan="2" Background="{StaticResource Panel3}" CornerRadius="3"/>
                                                <Border Background="{Binding BarBrush}" CornerRadius="3"/>
                                            </Grid>
                                        </StackPanel>
                                    </Border>
                                </DataTemplate>
                            </ItemsControl.ItemTemplate>
                        </ItemsControl>
                        <Grid>
                            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                            <Border Style="{StaticResource Card}" Margin="0,0,14,14" Grid.Row="0" Grid.Column="0">
                                <StackPanel>
                                    <TextBlock Text="Episodes added" Style="{StaticResource H2}"/>
                                    <TextBlock x:Name="icStatAddedSub" Style="{StaticResource Hint}" Margin="0,-4,0,12"/>
                                    <ItemsControl x:Name="icStatAdded" Height="176">
                                        <ItemsControl.ItemsPanel><ItemsPanelTemplate><UniformGrid Rows="1"/></ItemsPanelTemplate></ItemsControl.ItemsPanel>
                                        <ItemsControl.ItemTemplate>
                                            <DataTemplate>
                                                <Grid Margin="3,0" ToolTip="{Binding Tip}" Background="Transparent">
                                                    <Grid.RowDefinitions><RowDefinition Height="18"/><RowDefinition Height="*"/><RowDefinition Height="22"/></Grid.RowDefinitions>
                                                    <TextBlock Text="{Binding Top}" Foreground="{StaticResource Text}" FontSize="11" TextAlignment="Center" VerticalAlignment="Bottom"/>
                                                    <Border Grid.Row="1" BorderBrush="{StaticResource Line}" BorderThickness="0,0,0,1">
                                                        <Border Background="{Binding BarBrush}" CornerRadius="4,4,0,0" VerticalAlignment="Bottom" MaxWidth="34">
                                                            <Border.Height><Binding Path="BarHeight"/></Border.Height>
                                                        </Border>
                                                    </Border>
                                                    <TextBlock Grid.Row="2" Text="{Binding Label}" Foreground="{StaticResource Sub}" FontSize="11" TextAlignment="Center" VerticalAlignment="Bottom"/>
                                                </Grid>
                                            </DataTemplate>
                                        </ItemsControl.ItemTemplate>
                                    </ItemsControl>
                                </StackPanel>
                            </Border>
                            <Border Style="{StaticResource Card}" Margin="0,0,14,14" Grid.Row="1" Grid.Column="0">
                                <StackPanel>
                                    <TextBlock Text="Channels" Style="{StaticResource H2}"/>
                                    <TextBlock Text="Number of your shows on each channel" Style="{StaticResource Hint}" Margin="0,-4,0,12"/>
                                    <ItemsControl x:Name="icStatNetworks">
                                        <ItemsControl.ItemTemplate>
                                            <DataTemplate>
                                                <Grid Margin="0,0,0,7" ToolTip="{Binding Tip}" Background="Transparent">
                                                    <Grid.ColumnDefinitions><ColumnDefinition Width="5*" MinWidth="170"/><ColumnDefinition Width="4*"/><ColumnDefinition Width="80"/></Grid.ColumnDefinitions>
                                                    <TextBlock Text="{Binding Label}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center" Margin="0,0,10,0"/>
                                                    <Border Grid.Column="1" Background="{StaticResource Panel3}" CornerRadius="0,4,4,0" Height="12" VerticalAlignment="Center"/>
                                                    <Grid Grid.Column="1">
                                                        <Grid.ColumnDefinitions><ColumnDefinition Width="{Binding BarStar}"/><ColumnDefinition Width="{Binding RestStar}"/></Grid.ColumnDefinitions>
                                                        <Border Background="{StaticResource Accent}" CornerRadius="0,4,4,0" Height="12" VerticalAlignment="Center"/>
                                                    </Grid>
                                                    <TextBlock Grid.Column="2" Text="{Binding ValueText}" Foreground="{StaticResource Sub}" TextAlignment="Right" VerticalAlignment="Center"/>
                                                </Grid>
                                            </DataTemplate>
                                        </ItemsControl.ItemTemplate>
                                    </ItemsControl>
                                </StackPanel>
                            </Border>
                            <Border Style="{StaticResource Card}" Margin="0,0,14,14" Grid.Row="1" Grid.Column="1">
                                <StackPanel>
                                    <TextBlock Text="Genres" Style="{StaticResource H2}"/>
                                    <TextBlock Text="Number of your shows in each genre (a show can have several)" Style="{StaticResource Hint}" Margin="0,-4,0,12"/>
                                    <ItemsControl x:Name="icStatGenres">
                                        <ItemsControl.ItemTemplate>
                                            <DataTemplate>
                                                <Grid Margin="0,0,0,7" ToolTip="{Binding Tip}" Background="Transparent">
                                                    <Grid.ColumnDefinitions><ColumnDefinition Width="5*" MinWidth="170"/><ColumnDefinition Width="4*"/><ColumnDefinition Width="80"/></Grid.ColumnDefinitions>
                                                    <TextBlock Text="{Binding Label}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center" Margin="0,0,10,0"/>
                                                    <Border Grid.Column="1" Background="{StaticResource Panel3}" CornerRadius="0,4,4,0" Height="12" VerticalAlignment="Center"/>
                                                    <Grid Grid.Column="1">
                                                        <Grid.ColumnDefinitions><ColumnDefinition Width="{Binding BarStar}"/><ColumnDefinition Width="{Binding RestStar}"/></Grid.ColumnDefinitions>
                                                        <Border Background="{StaticResource Accent}" CornerRadius="0,4,4,0" Height="12" VerticalAlignment="Center"/>
                                                    </Grid>
                                                    <TextBlock Grid.Column="2" Text="{Binding ValueText}" Foreground="{StaticResource Sub}" TextAlignment="Right" VerticalAlignment="Center"/>
                                                </Grid>
                                            </DataTemplate>
                                        </ItemsControl.ItemTemplate>
                                    </ItemsControl>
                                </StackPanel>
                            </Border>
                            <Border Style="{StaticResource Card}" Margin="0,0,14,14" Grid.Row="2" Grid.Column="0">
                                <StackPanel>
                                    <TextBlock Text="Biggest shows" Style="{StaticResource H2}"/>
                                    <TextBlock Text="Space used on your TV drive" Style="{StaticResource Hint}" Margin="0,-4,0,12"/>
                                    <ItemsControl x:Name="icStatBiggest">
                                        <ItemsControl.ItemTemplate>
                                            <DataTemplate>
                                                <Grid Margin="0,0,0,7" ToolTip="{Binding Tip}" Background="Transparent">
                                                    <Grid.ColumnDefinitions><ColumnDefinition Width="5*" MinWidth="170"/><ColumnDefinition Width="4*"/><ColumnDefinition Width="80"/></Grid.ColumnDefinitions>
                                                    <TextBlock Text="{Binding Label}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center" Margin="0,0,10,0"/>
                                                    <Border Grid.Column="1" Background="{StaticResource Panel3}" CornerRadius="0,4,4,0" Height="12" VerticalAlignment="Center"/>
                                                    <Grid Grid.Column="1">
                                                        <Grid.ColumnDefinitions><ColumnDefinition Width="{Binding BarStar}"/><ColumnDefinition Width="{Binding RestStar}"/></Grid.ColumnDefinitions>
                                                        <Border Background="{StaticResource Accent}" CornerRadius="0,4,4,0" Height="12" VerticalAlignment="Center"/>
                                                    </Grid>
                                                    <TextBlock Grid.Column="2" Text="{Binding ValueText}" Foreground="{StaticResource Sub}" TextAlignment="Right" VerticalAlignment="Center"/>
                                                </Grid>
                                            </DataTemplate>
                                        </ItemsControl.ItemTemplate>
                                    </ItemsControl>
                                </StackPanel>
                            </Border>
                            <Border Style="{StaticResource Card}" Margin="0,0,14,14" Grid.Row="2" Grid.Column="1">
                                <StackPanel>
                                    <TextBlock Text="Most episodes" Style="{StaticResource H2}"/>
                                    <TextBlock Text="Episodes on disk" Style="{StaticResource Hint}" Margin="0,-4,0,12"/>
                                    <ItemsControl x:Name="icStatMostEps">
                                        <ItemsControl.ItemTemplate>
                                            <DataTemplate>
                                                <Grid Margin="0,0,0,7" ToolTip="{Binding Tip}" Background="Transparent">
                                                    <Grid.ColumnDefinitions><ColumnDefinition Width="5*" MinWidth="170"/><ColumnDefinition Width="4*"/><ColumnDefinition Width="80"/></Grid.ColumnDefinitions>
                                                    <TextBlock Text="{Binding Label}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center" Margin="0,0,10,0"/>
                                                    <Border Grid.Column="1" Background="{StaticResource Panel3}" CornerRadius="0,4,4,0" Height="12" VerticalAlignment="Center"/>
                                                    <Grid Grid.Column="1">
                                                        <Grid.ColumnDefinitions><ColumnDefinition Width="{Binding BarStar}"/><ColumnDefinition Width="{Binding RestStar}"/></Grid.ColumnDefinitions>
                                                        <Border Background="{StaticResource Accent}" CornerRadius="0,4,4,0" Height="12" VerticalAlignment="Center"/>
                                                    </Grid>
                                                    <TextBlock Grid.Column="2" Text="{Binding ValueText}" Foreground="{StaticResource Sub}" TextAlignment="Right" VerticalAlignment="Center"/>
                                                </Grid>
                                            </DataTemplate>
                                        </ItemsControl.ItemTemplate>
                                    </ItemsControl>
                                </StackPanel>
                            </Border>
                            <Border Style="{StaticResource Card}" Margin="0,0,14,14" Grid.Row="0" Grid.Column="1">
                                <StackPanel>
                                    <TextBlock Text="Picture quality" Style="{StaticResource H2}"/>
                                    <TextBlock x:Name="txtStatResSub" Text="Episode files by resolution" Style="{StaticResource Hint}" Margin="0,-4,0,12"/>
                                    <ItemsControl x:Name="icStatRes">
                                        <ItemsControl.ItemTemplate>
                                            <DataTemplate>
                                                <Grid Margin="0,0,0,7" ToolTip="{Binding Tip}" Background="Transparent">
                                                    <Grid.ColumnDefinitions><ColumnDefinition Width="5*" MinWidth="170"/><ColumnDefinition Width="4*"/><ColumnDefinition Width="80"/></Grid.ColumnDefinitions>
                                                    <TextBlock Text="{Binding Label}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center" Margin="0,0,10,0"/>
                                                    <Border Grid.Column="1" Background="{StaticResource Panel3}" CornerRadius="0,4,4,0" Height="12" VerticalAlignment="Center"/>
                                                    <Grid Grid.Column="1">
                                                        <Grid.ColumnDefinitions><ColumnDefinition Width="{Binding BarStar}"/><ColumnDefinition Width="{Binding RestStar}"/></Grid.ColumnDefinitions>
                                                        <Border Background="{StaticResource Accent}" CornerRadius="0,4,4,0" Height="12" VerticalAlignment="Center"/>
                                                    </Grid>
                                                    <TextBlock Grid.Column="2" Text="{Binding ValueText}" Foreground="{StaticResource Sub}" TextAlignment="Right" VerticalAlignment="Center"/>
                                                </Grid>
                                            </DataTemplate>
                                        </ItemsControl.ItemTemplate>
                                    </ItemsControl>
                                </StackPanel>
                            </Border>
                        </Grid>
                    </StackPanel>
                </ScrollViewer>
            </TabItem>

            <!-- ================= UTILITIES ================= -->
            <TabItem Header="Utilities" Style="{StaticResource Nav}" x:Name="tUtils">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel Margin="24,18" MaxWidth="900" HorizontalAlignment="Left">
                        <TextBlock Text="Utilities" Style="{StaticResource H1}" Margin="0,0,0,16"/>
                        <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                            <StackPanel>
                                <TextBlock Text="Backups" Style="{StaticResource H2}"/>
                                <TextBlock Style="{StaticResource Hint}" Margin="0,0,0,12" Text="A backup holds your settings and show matches (not the image cache). The last 15 are kept in Data\Backups. A backup is also made automatically before any restore."/>
                                <WrapPanel>
                                    <Button x:Name="btnBackup" Content="Back up now" Style="{StaticResource AccentButton}"/>
                                    <Button x:Name="btnRestore" Content="Restore from backup..."/>
                                    <TextBlock x:Name="txtBackupInfo" Foreground="{StaticResource Sub}" VerticalAlignment="Center"/>
                                </WrapPanel>
                            </StackPanel>
                        </Border>
                        <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                            <StackPanel>
                                <TextBlock Text="Move settings between PCs" Style="{StaticResource H2}"/>
                                <TextBlock Style="{StaticResource Hint}" Margin="0,0,0,12" Text="Export a single file with your settings, API keys and show matches, then import it on the other PC. Your library is rescanned there."/>
                                <WrapPanel>
                                    <Button x:Name="btnExportSettings" Content="Export settings..."/>
                                    <Button x:Name="btnImportSettings" Content="Import settings..."/>
                                </WrapPanel>
                            </StackPanel>
                        </Border>
                        <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                            <StackPanel>
                                <TextBlock Text="Printable show list" Style="{StaticResource H2}"/>
                                <TextBlock Style="{StaticResource Hint}" Margin="0,0,0,12" Text="Makes a clean page listing every show with its seasons, episode count, status and size, and opens it in your browser ready to print."/>
                                <WrapPanel>
                                    <Button x:Name="btnPrintList" Content="Make printable list" Style="{StaticResource AccentButton}"/>
                                    <CheckBox x:Name="chkPrintEps" Content="Include episode numbers"/>
                                </WrapPanel>
                            </StackPanel>
                        </Border>
                        <Border Style="{StaticResource Card}">
                            <StackPanel>
                                <TextBlock Text="Housekeeping" Style="{StaticResource H2}"/>
                                <WrapPanel>
                                    <Button x:Name="btnOpenData" Content="Open Data folder"/>
                                    <Button x:Name="btnRematchAll" Content="Re-match unmatched shows"/>
                                    <Button x:Name="btnRefreshAll" Content="Refresh all show info"/>
                                    <Button x:Name="btnReadMedia" Content="Re-read video details" ToolTip="Read resolution and length from every episode file again"/>
                                    <Button x:Name="btnClearImages" Content="Clear image cache"/>
                                </WrapPanel>
                            </StackPanel>
                        </Border>
                    </StackPanel>
                </ScrollViewer>
            </TabItem>

            <!-- ================= SETTINGS ================= -->
            <TabItem Header="Settings" Style="{StaticResource Nav}" x:Name="tSettings">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel Margin="24,18" MaxWidth="900" HorizontalAlignment="Left">
                        <TextBlock Text="Settings" Style="{StaticResource H1}" Margin="0,0,0,16"/>
                        <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                            <StackPanel>
                                <TextBlock Text="TV folders" Style="{StaticResource H2}"/>
                                <TextBlock Style="{StaticResource Hint}" Margin="0,0,0,8" Text="One per line. Each folder inside is treated as a show (Show\S01\Show - 1x01 - Title.mkv)."/>
                                <TextBox x:Name="txtRoots" AcceptsReturn="True" Height="70" VerticalScrollBarVisibility="Auto"/>
                                <TextBlock Style="{StaticResource Hint}" Margin="0,12,0,6" Text="Holding folder for duplicates you move out of the library (it's skipped when scanning):"/>
                                <TextBox x:Name="txtHold"/>
                            </StackPanel>
                        </Border>
                        <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                            <StackPanel>
                                <TextBlock Text="Show information" Style="{StaticResource H2}"/>
                                <TextBlock Style="{StaticResource Hint}" Margin="0,0,0,10" Text="Posters, cast, episode lists and air dates come from TVmaze. It's free and needs no API key."/>
                                <StackPanel Orientation="Horizontal">
                                    <TextBlock Text="Refresh every (days)" VerticalAlignment="Center" Margin="0,0,10,0"/>
                                    <TextBox x:Name="txtRefreshDays" Width="60"/>
                                    <TextBlock Style="{StaticResource Hint}" VerticalAlignment="Center" Margin="10,0,0,0" Text="for continuing shows (ended shows: every 30 days)"/>
                                </StackPanel>
                                <WrapPanel Margin="0,10,0,0"><Button x:Name="btnTestTvdb" Content="Test TVmaze"/><TextBlock x:Name="txtTvdbTest" Foreground="{StaticResource Sub}" VerticalAlignment="Center"/></WrapPanel>
                            </StackPanel>
                        </Border>
                        <Border Style="{StaticResource Card}" Margin="0,0,0,14">
                            <StackPanel>
                                <TextBlock Text="New episodes" Style="{StaticResource H2}"/>
                                <StackPanel Orientation="Horizontal">
                                    <TextBlock Text="Count episodes as new for" VerticalAlignment="Center" Margin="0,0,10,0"/>
                                    <TextBox x:Name="txtNewDays" Width="60"/>
                                    <TextBlock Style="{StaticResource Hint}" VerticalAlignment="Center" Margin="10,0,0,0" Text="days after they arrive on the drive"/>
                                </StackPanel>
                            </StackPanel>
                        </Border>
                        <WrapPanel>
                            <Button x:Name="btnSaveSettings" Content="Save settings" Style="{StaticResource AccentButton}"/>
                            <TextBlock x:Name="txtSettingsSaved" Foreground="{StaticResource Good}" VerticalAlignment="Center"/>
                        </WrapPanel>
                    </StackPanel>
                </ScrollViewer>
            </TabItem>

            <!-- ================= ABOUT ================= -->
            <TabItem Header="About" Style="{StaticResource Nav}">
                <Grid Margin="24,18,24,14">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*" MaxWidth="820"/><ColumnDefinition Width="28"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <ScrollViewer VerticalScrollBarVisibility="Auto">
                        <StackPanel>
                        <StackPanel Orientation="Horizontal">
                            <Border Background="{StaticResource Accent2}" CornerRadius="6" Padding="10,2" Margin="0,0,12,0">
                                <TextBlock Text="TV" FontFamily="Bahnschrift SemiBold, Segoe UI" FontSize="30" Foreground="#101318"/>
                            </Border>
                            <StackPanel VerticalAlignment="Center">
                                <TextBlock Text="TV Toolkit" Style="{StaticResource H1}"/>
                                <TextBlock x:Name="txtAboutVersion" Foreground="{StaticResource Sub}"/>
                            </StackPanel>
                        </StackPanel>
                        <TextBlock Style="{StaticResource Hint}" FontSize="13.5" Margin="0,18,0,0" Text="A desktop companion for the TV programmes on your NAS. Browse your shows as a poster wall or a list, with info, cast, backdrops and episode pictures from TVmaze. See what has arrived and what is airing, save the schedule to your calendar, find missing episodes and problem files, tidy up file names and duplicates, and keep an eye on drive space."/>
                        <Border Style="{StaticResource Card}" Margin="0,22,0,0">
                            <StackPanel>
                                <TextBlock Text="Credits" Style="{StaticResource H2}"/>
                                <Grid Margin="0,4,0,0">
                                    <Grid.ColumnDefinitions><ColumnDefinition Width="190"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                    <Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
                                    <TextBlock Grid.Row="0" Text="Made by" Foreground="{StaticResource Sub}" Margin="0,0,0,10"/>
                                    <TextBlock Grid.Row="0" Grid.Column="1" TextWrapping="Wrap" Margin="0,0,0,10">Jason Rhodes, built with Claude (Anthropic)</TextBlock>
                                    <TextBlock Grid.Row="1" Text="Show information" Foreground="{StaticResource Sub}" Margin="0,0,0,10"/>
                                    <TextBlock Grid.Row="1" Grid.Column="1" TextWrapping="Wrap" Margin="0,0,0,10"><Hyperlink NavigateUri="https://www.tvmaze.com" Foreground="{StaticResource Accent}">TVmaze</Hyperlink> - show details, episode lists, air times, posters, cast, photos and biographies. TVmaze data is licensed under <Hyperlink NavigateUri="https://creativecommons.org/licenses/by-sa/4.0/" Foreground="{StaticResource Accent}">CC BY-SA 4.0</Hyperlink>.</TextBlock>
                                    <TextBlock Grid.Row="2" Text="Built with" Foreground="{StaticResource Sub}" Margin="0,0,0,10"/>
                                    <TextBlock Grid.Row="2" Grid.Column="1" TextWrapping="Wrap" Margin="0,0,0,10">Windows PowerShell and WPF (.NET). Fonts: Bahnschrift and Segoe UI from Microsoft Windows.</TextBlock>
                                    <TextBlock Grid.Row="3" Text="Images" Foreground="{StaticResource Sub}" Margin="0,0,0,10"/>
                                    <TextBlock Grid.Row="3" Grid.Column="1" TextWrapping="Wrap" Margin="0,0,0,10">Posters and photos remain the property of their respective owners and are shown for personal use.</TextBlock>
                                    <TextBlock Grid.Row="4" Text="Look" Foreground="{StaticResource Sub}"/>
                                    <TextBlock Grid.Row="4" Grid.Column="1" TextWrapping="Wrap">"Test Card" theme - colour bars, slate and cyan.</TextBlock>
                                </Grid>
                            </StackPanel>
                        </Border>
                        <TextBlock Text="Data" Style="{StaticResource H2}" Margin="0,22,0,8"/>
                        <TextBlock x:Name="txtAboutData" Style="{StaticResource Hint}" FontSize="13"/>
                        </StackPanel>
                    </ScrollViewer>
                    <Border Grid.Column="2" Style="{StaticResource Card}" Padding="0">
                        <DockPanel>
                            <TextBlock DockPanel.Dock="Top" Text="What's new" Style="{StaticResource H2}" Margin="18,16,18,8"/>
                            <ScrollViewer VerticalScrollBarVisibility="Auto">
                                <TextBlock x:Name="txtAboutNew" Style="{StaticResource Hint}" FontSize="13" LineHeight="21" Margin="18,0,18,16"/>
                            </ScrollViewer>
                        </DockPanel>
                    </Border>
                </Grid>
            </TabItem>
        </TabControl>

        <!-- 'since you last opened it' card -->
        <Border Grid.Row="2" x:Name="bdSince" Visibility="Collapsed" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,28,24" Width="400"
                Background="{StaticResource Panel2}" BorderBrush="{StaticResource Accent}" BorderThickness="1" CornerRadius="8" Padding="18,14">
            <Border.Effect><DropShadowEffect BlurRadius="24" ShadowDepth="4" Opacity="0.55"/></Border.Effect>
            <StackPanel>
                <DockPanel>
                    <Button x:Name="btnSinceClose" DockPanel.Dock="Right" Content="&#x2715;" Padding="8,2" Margin="8,0,0,0" ToolTip="Close"/>
                    <StackPanel>
                        <TextBlock Text="Since you last opened TV Toolkit" FontWeight="SemiBold" FontSize="15"/>
                        <TextBlock x:Name="txtSinceWhen" Foreground="{StaticResource Sub}" FontSize="11.5" Margin="0,2,0,0"/>
                    </StackPanel>
                </DockPanel>
                <ItemsControl x:Name="icSince" Margin="0,10,0,0">
                    <ItemsControl.ItemTemplate>
                        <DataTemplate>
                            <Grid Margin="0,5">
                                <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                <Border Width="9" Height="9" CornerRadius="5" Background="{Binding Dot}" VerticalAlignment="Top" Margin="0,5,10,0"/>
                                <StackPanel Grid.Column="1">
                                    <TextBlock Text="{Binding Head}" FontWeight="SemiBold" TextWrapping="Wrap"/>
                                    <TextBlock Text="{Binding Detail}" Foreground="{StaticResource Sub}" FontSize="12" TextWrapping="Wrap" Margin="0,1,0,0"/>
                                </StackPanel>
                            </Grid>
                        </DataTemplate>
                    </ItemsControl.ItemTemplate>
                </ItemsControl>
                <WrapPanel Margin="0,10,0,0">
                    <Button x:Name="btnSinceNew" Content="New episodes" Style="{StaticResource AccentButton}"/>
                    <Button x:Name="btnSinceMissing" Content="Missing episodes"/>
                    <Button x:Name="btnSinceCal" Content="Calendar"/>
                </WrapPanel>
            </StackPanel>
        </Border>

        <!-- status bar -->
        <Border Grid.Row="3" Background="#13171D" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0" Padding="16,6">
            <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="220"/></Grid.ColumnDefinitions>
                <TextBlock x:Name="txtStatus" Foreground="{StaticResource Sub}" TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
                <ProgressBar Grid.Column="1" x:Name="pbStatus" Height="5" Maximum="100" Visibility="Hidden"/>
            </Grid>
        </Border>
    </Grid>
</Window>
'@
function New-Window([string]$xamlText) {
    $x = [xml]($xamlText.Replace('<!--THEME-->', $ThemeXaml))
    $w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
    $names = @{}
    foreach ($n in $x.SelectNodes("//*[@*[local-name()='Name']]")) {
        $nm = $n.Attributes | Where-Object { $_.LocalName -eq 'Name' } | Select-Object -First 1
        if ($nm) { $names[$nm.Value] = $w.FindName($nm.Value) }
    }
    return @{ Window = $w; UI = $names }
}
$main = New-Window $MainXaml
Write-StartLog 'Main window built'
$Win = $main.Window
$ui = $main.UI

# ---------- helpers ----------
function Show-Msg([string]$Text, [string]$Title = 'TV Toolkit', [string]$Icon = 'Information') {
    [void][Windows.MessageBox]::Show($Win, $Text, $Title, 'OK', $Icon)
}
function Confirm-Action([string]$Text, [string]$Title = 'TV Toolkit') {
    return ([Windows.MessageBox]::Show($Win, $Text, $Title, 'YesNo', 'Question') -eq 'Yes')
}
function Set-Status([string]$t) { $ui.txtStatus.Text = $t }
function Get-Bitmap([string]$Path, [int]$Width = 0) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    $fs = $null
    try {
        $fs = [IO.File]::OpenRead($Path)
        $b = New-Object Windows.Media.Imaging.BitmapImage
        $b.BeginInit()
        $b.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $b.CreateOptions = [Windows.Media.Imaging.BitmapCreateOptions]::IgnoreColorProfile
        if ($Width -gt 0) { $b.DecodePixelWidth = $Width }
        $b.StreamSource = $fs
        $b.EndInit()
        $b.Freeze()
        return $b
    } catch { return $null } finally { if ($fs) { $fs.Dispose() } }
}
function Get-HashName([string]$s) {
    $md5 = [Security.Cryptography.MD5]::Create()
    return (($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($s)) | ForEach-Object { $_.ToString('x2') }) -join '')
}
function Get-ShowPosterPath($show) {
    $m = $script:MatchMap[$show.Folder]
    if ($m -and $m.Id -gt 0) { $p = Get-PosterCachePath $m.Id; if (Test-Path -LiteralPath $p) { return $p } }
    $lp = Join-Path $DataDir ("Cache\posters\local-" + (Get-HashName $show.Folder) + '.jpg')
    if (Test-Path -LiteralPath $lp) { return $lp }
    return $null
}
function Format-SizeWhole([double]$bytes) {
    if ($bytes -ge 1TB) { return ('{0:N0} GB' -f [math]::Round($bytes / 1GB)) }
    if ($bytes -ge 1GB) { return ('{0:N0} GB' -f [math]::Round($bytes / 1GB)) }
    if ($bytes -ge 1MB) { return ('{0:N0} MB' -f [math]::Round($bytes / 1MB)) }
    return (Format-Size $bytes)
}
function Get-ShowQuality($show) {
    $c = @{}; foreach ($f in $show.Files) { if ($f.Res -ne '?') { $c[$f.Res] = [int]$c[$f.Res] + 1 } }
    if ($c.Count -eq 0) { return '' }
    $top = $c.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1
    if ($c.Count -gt 1) { return "$($top.Key)+" }
    return $top.Key
}
function Set-LibView([string]$v) {
    $TVT.Settings.LibView = $v
    if ($v -eq 'list') {
        $ui.svShows.Visibility = 'Collapsed'; $ui.dgLibList.Visibility = 'Visible'; $ui.dgLibList.ItemsSource = $ui.icShows.ItemsSource
        $ui.btnViewList.Background = $Win.FindResource('AccentDim'); $ui.btnViewPosters.ClearValue([Windows.Controls.Control]::BackgroundProperty)
    } else {
        $ui.dgLibList.Visibility = 'Collapsed'; $ui.svShows.Visibility = 'Visible'
        $ui.btnViewPosters.Background = $Win.FindResource('AccentDim'); $ui.btnViewList.ClearValue([Windows.Controls.Control]::BackgroundProperty)
    }
}
function Update-HeadStats {
    $eps = 0; $size = [int64]0; foreach ($s in $script:Lib.Values) { $eps += $s.EpisodeCount; $size += $s.Size }
    # The little numbers in the top bar - each one is a shortcut to the page that explains it
    $sub = [Windows.Media.Brush]$Win.FindResource('Text')
    $items = New-Object System.Collections.Generic.List[object]
    $nNew = 0; $cutoff = Get-NewCutoff; foreach ($sh in $script:Lib.Values) { $nNew += (Get-ShowCounts $sh $cutoff).New }
    if ($nNew -gt 0) { $items.Add([pscustomobject]@{ Value = "$nNew"; Label = 'new'; Go = 'tNew'; Tip = "$nNew episode(s) arrived recently - click to see them"; Brush = [Windows.Media.Brush]$Win.FindResource('Good') }) }
    $items.Add([pscustomobject]@{ Value = "$($script:Lib.Count)"; Label = 'shows'; Go = 'tLibrary'; Tip = 'Show the library'; Brush = $sub })
    $items.Add([pscustomobject]@{ Value = "$eps"; Label = 'episodes'; Go = 'tStats'; Tip = 'Library stats'; Brush = $sub })
    $items.Add([pscustomobject]@{ Value = (Format-SizeWhole $size); Label = 'used'; Go = 'tStats'; Tip = 'Space your TV takes up - click for stats'; Brush = $sub })
    $free = [double]0; $total = [double]0; $letters = @{}
    foreach ($r in @($TVT.Settings.Roots)) { if ("$r" -match '^([A-Za-z]):') { $letters[$Matches[1].ToUpper()] = $true } }
    foreach ($l in $letters.Keys) { try { $di = [IO.DriveInfo]::new($l); if ($di.IsReady) { $free += $di.AvailableFreeSpace; $total += $di.TotalSize } } catch {} }
    if ($total -gt 0) {
        $pct = ($total - $free) / $total * 100
        $fb = $(if ($pct -ge 90) { 'Bad' } elseif ($pct -ge 75) { 'Warn' } else { 'Text' })
        $ft = $(if ($free -ge 1TB) { '{0:N1} TB' -f ($free / 1TB) } else { '{0:N0} GB' -f ($free / 1GB) })
        $items.Add([pscustomobject]@{ Value = $ft; Label = 'free'; Go = 'tStats'; Tip = ("Free space on {0} ({1:N0}% used) - click for the drive details on Stats" -f (($letters.Keys | Sort-Object | ForEach-Object { "$($_):" }) -join ' '), $pct); Brush = [Windows.Media.Brush]$Win.FindResource($fb) })
    }
    $ui.icHeadStats.ItemsSource = $items.ToArray()
    $lib = Join-Path $DataDir 'library.tsv'
    if (Test-Path -LiteralPath $lib) {
        $t = (Get-Item -LiteralPath $lib).LastWriteTime
        $ui.txtLastScan.Text = $(if ($t.Date -eq (Get-Date).Date) { "today $($t.ToString('HH:mm'))" } elseif ($t.Date -eq (Get-Date).Date.AddDays(-1)) { "yesterday $($t.ToString('HH:mm'))" } else { $t.ToString('d MMM HH:mm') })
        $ui.btnScan.ToolTip = "Read the TV folders again (F5)`nLast scanned $($t.ToString('dddd d MMM, HH:mm'))"
    } else { $ui.txtLastScan.Text = 'never scanned' }
}
function Get-Today { return (Get-Date).ToString('yyyy-MM-dd') }
function Get-Initials([string]$name) {
    $ini = (($name -split '\s+' | Where-Object { $_ -match '^\w' } | ForEach-Object { $_.Substring(0, 1).ToUpper() }) -join '')
    if ($ini.Length -gt 2) { $ini = $ini.Substring(0, 1) + $ini.Substring($ini.Length - 1) }
    return $ini
}
function Get-PersonKey($c) { $perId = 0; try { $perId = [int]$c.PersonId } catch {}; if ($perId -gt 0) { return "p$perId" }; return "n:" + "$($c.Name)".ToLowerInvariant() }
function Get-PersonPhotoPath([string]$url) { if (-not $url) { return '' }; return (Join-Path $DataDir ("Cache\people\" + (Get-HashName $url) + '.jpg')) }
function Get-CachedBitmap([string]$path, [int]$width) {
    if (-not $path) { return $null }
    $k = "$width|$path"
    if (-not $script:BitmapCache.ContainsKey($k)) {
        if (-not (Test-Path -LiteralPath $path)) { return $null }
        $script:BitmapCache[$k] = [Windows.Media.ImageSource](Get-Bitmap $path $width)
    }
    return $script:BitmapCache[$k]
}
function Format-Date([string]$d) { try { return ([datetime]::ParseExact($d.Substring(0, 10), 'yyyy-MM-dd', $null)).ToString('d MMM yyyy') } catch { return $d } }
function Open-InExplorer([string]$path) {
    if (-not $path) { return }
    if (Test-Path -LiteralPath $path -PathType Leaf) { Start-Process explorer.exe "/select,`"$path`"" }
    elseif (Test-Path -LiteralPath $path) { Start-Process explorer.exe "`"$path`"" }
    else { Show-Msg "Can't find:`n$path" 'TV Toolkit' 'Warning' }
}

# ---------- background work ----------
$script:Jobs = New-Object System.Collections.ArrayList
$script:BusyGroups = @{}
function Start-Work([string]$Label, [scriptblock]$Work, [object[]]$ArgList = @(), [scriptblock]$OnDone = $null, [string]$Group = '', $Context = $null, [switch]$Sta) {
    if ($Group -and $script:BusyGroups[$Group]) {
        Show-Msg "Still busy with: $($script:BusyGroups[$Group])`n`nTry again when it has finished." 'TV Toolkit' 'Information'
        return $false
    }
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = $(if ($Sta) { 'STA' } else { 'MTA' })
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($core, $dataDir, $settings, $sync, $work, $argv)
        $ErrorActionPreference = 'Stop'
        $TVT = @{ DataDir = $dataDir; Settings = $settings; Sync = $sync }
        . ([scriptblock]::Create($core))
        Initialize-Net
        & ([scriptblock]::Create($work)) @argv
    })
    [void]$ps.AddArgument($CoreText).AddArgument($DataDir).AddArgument($TVT.Settings.Clone()).AddArgument($Sync).AddArgument($Work.ToString()).AddArgument($ArgList)
    $Sync.Status = "$Label..."; $Sync.Pct = -1
    $h = $ps.BeginInvoke()
    [void]$script:Jobs.Add(@{ PS = $ps; RS = $rs; H = $h; OnDone = $OnDone; Label = $Label; Group = $Group; Context = $Context })
    if ($Group) { $script:BusyGroups[$Group] = $Label }
    $ui.pbStatus.Visibility = 'Visible'
    return $true
}
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(250)
$timer.Add_Tick({
    if ($script:ShowEvent -and $script:ShowEvent.WaitOne(0)) {
        try {
            if ($Win.WindowState -eq 'Minimized') { $Win.WindowState = 'Maximized' }
            $Win.Show(); $Win.Activate() | Out-Null
            $Win.Topmost = $true; $Win.Topmost = $false
            [void]$Win.Focus()
        } catch {}
        try { [void]$script:AckEvent.Set() } catch {}
    }
    if ($script:Jobs.Count -gt 0) {
        $ui.txtStatus.Text = $Sync.Status
        if ($Sync.Pct -ge 0) { $ui.pbStatus.IsIndeterminate = $false; $ui.pbStatus.Value = $Sync.Pct } else { $ui.pbStatus.IsIndeterminate = $true }
    }
    foreach ($j in @($script:Jobs)) {
        if (-not $j.H.IsCompleted) { continue }
        [void]$script:Jobs.Remove($j)
        if ($j.Group) { $script:BusyGroups.Remove($j.Group) }
        $res = $null; $err = $null
        try { $res = $j.PS.EndInvoke($j.H) } catch { $err = $_.Exception.InnerException; if (-not $err) { $err = $_.Exception } }
        $errText = $null
        if ($err) { $errText = $err.Message }
        elseif ((-not $res -or $res.Count -eq 0) -and $j.PS.Streams.Error.Count -gt 0) { $errText = ($j.PS.Streams.Error | Select-Object -First 2 | ForEach-Object { $_.ToString() }) -join "`n" }
        try { $j.PS.Dispose(); $j.RS.Close(); $j.RS.Dispose() } catch {}
        if ($script:Jobs.Count -eq 0) { $ui.pbStatus.Visibility = 'Hidden'; $ui.txtStatus.Text = $Sync.Status }
        if ($j.OnDone) {
            try { & $j.OnDone $res $errText $j.Context } catch { Show-Msg "Something went wrong after '$($j.Label)':`n$($_.Exception.Message)" 'TV Toolkit' 'Warning' }
        } elseif ($errText) { Set-Status "$($j.Label): $errText" }
    }
})
$timer.Start()

# ---------- state ----------
$script:Lib = [ordered]@{}
$script:MatchMap = Import-Matches
$script:Index = Import-SeriesIndex; $script:PeopleDirty = $true
$script:CurrentShow = $null
$script:CurrentInfo = $null
$script:MissingRows = @()
$script:MissingChecked = $false
$script:LastRenameLog = $null
$script:People = @{}
$script:PeopleDirty = $true
$script:CastStale = @()
$script:CastPhotosAsked = @{}
$script:CalOffset = 0
$script:CalRows = @()
$script:CalLoaded = $false
$script:CalRefreshedThisRun = $false
$script:CalDirty = $false
$script:SkipCastRefresh = $false
$script:CurrentPersonInfo = $null
$script:CurrentPersonKey = $null
$script:PersonReturn = $null
$script:Dismissed = @{}
$script:BackdropAsked = @{}
$script:ThumbAsked = @{}
$script:ThumbUpgraded = @{}
foreach ($kv in (Read-TsvMap (Join-Path $DataDir 'new-dismissed.tsv')).GetEnumerator()) { $script:Dismissed[$kv.Key] = $true }
$script:BitmapCache = @{}
$script:AfterLoad = $null

function Get-ShowIndex($show) {
    $m = $script:MatchMap[$show.Folder]
    if ($m -and $m.Id -gt 0) { return $script:Index[[int]$m.Id] }
    return $null
}
function Get-ShowInfoId($show) { $m = $script:MatchMap[$show.Folder]; if ($m) { return [int]$m.Id }; return 0 }
function Get-NewCutoff { $d = [int]$TVT.Settings.NewDays; if ($d -lt 1) { $d = 14 }; return (Get-Date).ToUniversalTime().AddDays(-$d).Ticks }
function Test-NewKey($show, [string]$k, [int64]$cutoff) {
    $f = $show.EpKeys[$k]; if (-not $f) { return $false }
    if ($f.Added -lt $cutoff) { return $false }
    return -not $script:Dismissed.ContainsKey("$($show.Folder)|$k")
}
function Get-ShowCounts($show, [int64]$cutoff) {
    $new = 0
    foreach ($k in $show.EpKeys.Keys) { if (Test-NewKey $show $k $cutoff) { $new++ } }
    return @{ New = $new }
}
function Save-Dismissed { Write-TsvLines (Join-Path $DataDir 'new-dismissed.tsv') @($script:Dismissed.Keys | ForEach-Object { "$_`t1" }) }

# ---------- library view ----------
$ui.cmbLibFilter.ItemsSource = @('All shows', 'Continuing', 'Ended', 'Has new episodes', 'Airing in the next 7 days', 'Needs a match check', 'Waiting for episodes')
$ui.cmbLibSort.ItemsSource = @('Name', 'Recently added', 'Most episodes', 'Biggest', 'Next airing', 'Most new episodes')
$ui.cmbLibFilter.SelectedIndex = $(if ([int]$TVT.Settings.LibFilter -le 6) { [int]$TVT.Settings.LibFilter } else { 0 })
$ui.cmbLibSort.SelectedIndex = [int]$TVT.Settings.LibSort

$BadgeYellow = $Win.FindResource('Accent2')
$BadgeCyan = $Win.FindResource('Accent')
$BadgeRed = $Win.FindResource('Bad')
$BadgeGreen = $Win.FindResource('Good')
$script:Transparent = [Windows.Media.Brushes]::Transparent
$script:MarkDarkFg = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(16, 19, 24))
$script:MarkDarkFg.Freeze()

$script:SeasonCache = @{}
function Get-LatestSeasonState($show) {
    # Is every aired episode of the newest aired season on disk? Cached until the show info or the files change.
    $id = Get-ShowInfoId $show
    if ($id -le 0) { return $null }
    $p = Get-SeriesCachePath $id
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    $today = Get-Today
    $key = "$((Get-Item -LiteralPath $p).LastWriteTimeUtc.Ticks)|$($show.EpisodeCount)|$($show.NewestTicks)|$today"
    $c = $script:SeasonCache[$show.Folder]
    if ($c -and $c.Key -eq $key) { return $c }
    $info = Get-SeriesInfo $id -CacheOnly
    $aired = @{}; $have = @{}
    if ($info -and $info.Episodes) {
        foreach ($e in $info.Episodes) {
            if (-not $e -or [int]$e.S -le 0 -or -not $e.Aired -or "$($e.Aired)" -gt $today) { continue }
            $sn = [int]$e.S
            $aired[$sn] = [int]$aired[$sn] + 1
            if ($show.EpKeys.ContainsKey("$($e.S)|$($e.E)")) { $have[$sn] = [int]$have[$sn] + 1 }
        }
    }
    $latest = 0; foreach ($k in $aired.Keys) { if ($k -gt $latest) { $latest = $k } }
    $c = @{ Key = $key; Latest = $latest; Aired = [int]$aired[$latest]; Have = [int]$have[$latest]; Done = ($latest -gt 0 -and [int]$have[$latest] -eq [int]$aired[$latest]); Seasons = $aired; HaveBy = $have }
    $script:SeasonCache[$show.Folder] = $c
    return $c
}
function Refresh-Library {
    $search = $ui.txtSearch.Text.Trim().ToLowerInvariant()
    $filter = $ui.cmbLibFilter.SelectedIndex
    $today = Get-Today
    $week = (Get-Date).AddDays(7).ToString('yyyy-MM-dd')
    $cutoff = Get-NewCutoff
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($show in $script:Lib.Values) {
        $idx = Get-ShowIndex $show
        if ($search) {
            $hay = $show.Folder
            if ($idx) { $hay += " $($idx.Name) $($idx.Network) $($idx.Genres) $($idx.Status) $($idx.Year)" }
            if ($hay.ToLowerInvariant() -notlike "*$search*") { continue }
        }
        $m = $script:MatchMap[$show.Folder]
        $counts = Get-ShowCounts $show $cutoff
        $status = ''; if ($idx) { $status = $idx.Status }
        $nextDate = ''; if ($idx -and $idx.Next) { $nextDate = $idx.Next.Split('|')[0] }
        $keep = $true
        if ($filter -eq 1) { $keep = $status -match 'Continuing|Upcoming' }
        elseif ($filter -eq 2) { $keep = $status -match 'Ended' }
        elseif ($filter -eq 3) { $keep = ($counts.New -gt 0) }
        elseif ($filter -eq 4) { $keep = [bool]($nextDate -and $nextDate -le $week) }
        elseif ($filter -eq 5) { $keep = (-not $m -or $m.Id -le 0 -or $m.How -eq 'guess') }
        elseif ($filter -eq 6) { $keep = ($show.EpisodeCount -eq 0) }
        if (-not $keep) { continue }
        $ss = $null; if ($show.EpisodeCount -gt 0) { $ss = Get-LatestSeasonState $show }
        $seasonCount = @($show.Seasons | Where-Object { $_ -gt 0 }).Count
        $sub = "$seasonCount season$(if ($seasonCount -ne 1) {'s'}) $DOT $($show.EpisodeCount) eps"
        if ($show.EpisodeCount -eq 0) {
            $sub = 'Waiting for episodes'
            if ($status -match 'Ended') { $sub = 'Ended - nothing on disk' }
            elseif ($nextDate) {
                $verb = $(if ($status -match 'Upcoming|Development') { 'Starts' } else { 'Back' })
                $sub = $(if ($nextDate -eq $today) { "$verb today" } else { "$verb $(Format-Date $nextDate)" })
            }
        } elseif ($seasonCount -eq 0) { $sub = "Specials $DOT $($show.EpisodeCount) eps" }
        $badge = ''; $badgeBrush = $BadgeYellow
        if ($counts.New -gt 0) { $badge = "$($counts.New) NEW"; $badgeBrush = $BadgeGreen }
        elseif (-not $m -or $m.Id -le 0) { $badge = 'NO MATCH'; $badgeBrush = $BadgeRed }
        elseif ($m.How -eq 'guess') { $badge = 'CHECK MATCH'; $badgeBrush = $BadgeRed }
        elseif ($nextDate -and $nextDate -le $week) { if ($nextDate -eq $today) { $badge = 'NEW TODAY' } else { $badge = 'NEW ' + ([datetime]::ParseExact($nextDate, 'yyyy-MM-dd', $null)).ToString('ddd').ToUpper() } }
        elseif ($status -match 'Ended') { $badge = 'ENDED'; $badgeBrush = $BadgeCyan }
        $tip = $show.Folder
        if ($idx) { $tip += "`n$($idx.Network) $DOT $($idx.Status)" }
        if ($counts.New -gt 0) { $tip += "`n$($counts.New) new episode(s)" }
        $tip += "`n" + (Format-Size $show.Size)
        $items.Add([pscustomobject]@{
            Folder = $show.Folder; Title = $show.Folder; Sub = $sub; Tip = $tip
            Poster = $null; PosterPath = (Get-ShowPosterPath $show)
            Badge = $badge; BadgeBrush = [Windows.Media.Brush]$badgeBrush; BadgeVis = $(if ($badge) { 'Visible' } else { 'Collapsed' })
            SortName = $show.Name; Newest = $show.NewestTicks; NewCount = $counts.New; Eps = $show.EpisodeCount; Size = $show.Size; Next = $(if ($nextDate) { $nextDate } else { '9999' })
            Channel = $(if ($idx) { $idx.Network } else { '' }); Status = $status; SeasonsN = $seasonCount; SizeText = (Format-Size $show.Size)
            Quality = (Get-ShowQuality $show); NewText = $(if ($counts.New) { "$($counts.New)" } else { '' })
            NewestText = $(if ($show.NewestTicks -gt 0) { ([datetime]::new($show.NewestTicks, [DateTimeKind]::Utc)).ToLocalTime().ToString('d MMM yyyy') } else { '' })
            NextText = $(if ($nextDate) { Format-Date $nextDate } else { '' })
            DoneVis = $(if ($ss -and $ss.Done) { 'Visible' } else { 'Collapsed' })
            DoneTip = $(if ($ss -and $ss.Done) { "Season $($ss.Latest) complete - all $($ss.Aired) aired episodes on disk" } else { '' })
            DoneText = $(if ($ss -and $ss.Latest -gt 0) { if ($ss.Done) { "S$($ss.Latest) complete" } else { "S$($ss.Latest) $($ss.Have)/$($ss.Aired)" } } else { '' })
        })
    }
    switch ($ui.cmbLibSort.SelectedIndex) {
        1 { $sorted = $items | Sort-Object Newest -Descending }
        2 { $sorted = $items | Sort-Object Eps -Descending }
        3 { $sorted = $items | Sort-Object Size -Descending }
        4 { $sorted = $items | Sort-Object Next, SortName }
        5 { $sorted = $items | Sort-Object @{ Expression = 'NewCount'; Descending = $true }, @{ Expression = 'Newest'; Descending = $true } }
        default { $sorted = $items | Sort-Object { ($_.SortName -replace '^(?i)the\s+', '') } }
    }
    $sorted = @($sorted)
    foreach ($it in $sorted) {
        if (-not $it.PosterPath) { continue }
        if (-not $script:BitmapCache.ContainsKey($it.PosterPath)) { $script:BitmapCache[$it.PosterPath] = [Windows.Media.ImageSource](Get-Bitmap $it.PosterPath 220) }
        $it.Poster = $script:BitmapCache[$it.PosterPath]
    }
    $ui.icShows.ItemsSource = $sorted
    if ($ui.dgLibList.Visibility -eq 'Visible') { $ui.dgLibList.ItemsSource = $sorted; if ($script:LibSortKey) { Sort-LibList $script:LibSortKey $script:LibSortDesc } }
    $ui.txtLibCount.Text = "$($sorted.Count) of $($script:Lib.Count) shows"
    Update-HeadStats
    if ($script:Lib.Count -eq 0) { $ui.spEmpty.Visibility = 'Visible' } else { $ui.spEmpty.Visibility = 'Collapsed' }
}

# ---------- loading, scanning, matching ----------
function Start-LoadLibrary([switch]$ThenMatch) {
    $ok = Start-Work 'Loading library' { $lib = Import-Library; [pscustomobject]@{ Lib = $lib } } @() {
        param($res, $err)
        if ($err) { Set-Status "Couldn't load the library: $err"; return }
        $script:Lib = $null
        if ($res -and $res.Count -gt 0) { $script:Lib = $res[0].Lib }
        if ($null -eq $script:Lib) { $script:Lib = [ordered]@{} }
        Refresh-Library
        Update-NewTabHeader
        $script:CalDirty = $true
        Start-MediaProbe
        if ($ui.tabMain.SelectedItem -eq $ui.tNew) { Refresh-NewPage }
        if ($script:CurrentShow -and $script:Lib.Contains($script:CurrentShow.Folder)) { Open-Show $script:CurrentShow.Folder -Keep } elseif ($script:CurrentShow) { Close-Show }
        Set-Status "Library loaded: $($script:Lib.Count) shows."
        try { Update-SinceCard } catch { Set-Status "Library loaded: $($script:Lib.Count) shows. (Couldn't build the 'since last time' card: $($_.Exception.Message))" }
        if ($script:AfterLoad) { $a = $script:AfterLoad; $script:AfterLoad = $null; & $a }
    }
    if ($ok -and $ThenMatch) { $script:AfterLoad = { Start-MatchJob } }
}
function Start-Scan {
    $roots = @($TVT.Settings.Roots)
    if (-not $roots) { Show-Msg 'Add your TV folder in Settings first.'; return }
    Start-Work 'Scanning TV folders' { param($r) Invoke-LibraryScan $r } @(, $roots) {
        param($res, $err)
        if ($err) { Show-Msg "Scan problem:`n$err" 'TV Toolkit' 'Warning' }
        Start-LoadLibrary -ThenMatch
    } 'scan' | Out-Null
}

function Start-MatchJob([switch]$RefreshAll) {
    $shows = @($script:Lib.Values | ForEach-Object { [pscustomobject]@{ Folder = $_.Folder; Name = $_.Name; Year = $_.Year; NfoTvdb = $_.NfoTvdb; Path = $_.Path; LocalPoster = $_.LocalPoster } })
    $existing = @{}; foreach ($kv in $script:MatchMap.GetEnumerator()) { $existing[$kv.Key] = $kv.Value }
    Start-Work 'Matching shows with TVmaze' {
        param($shows, $existing, $refreshAll)
        $new = @{}; $failed = @()
        $i = 0
        foreach ($s in $shows) {
            $i++
            Set-Progress ("TVmaze: {0} ({1}/{2})" -f $s.Name, $i, $shows.Count) ($i / [math]::Max(1, $shows.Count) * 100)
            $m = $existing[$s.Folder]
            if (-not $m -or $m.Id -le 0) {
                $threw = $false
                try { $m = Find-ShowMatch $s } catch { $threw = $true; $failed += "$($s.Folder): $($_.Exception.Message)"; $m = $null }
                if ($m) { $new[$s.Folder] = $m } elseif (-not $threw) { $failed += "$($s.Folder): TVmaze found nothing for '$($s.Name)'" }
            }
            if ($m -and $m.Id -gt 0) {
                try { Get-SeriesInfo $m.Id -Force:$refreshAll | Out-Null } catch {}
            }
            # Copy a local poster (e.g. from Kodi) into the cache if TVmaze had none
            $cacheP = $(if ($m -and $m.Id -gt 0) { Get-PosterCachePath $m.Id } else { '' })
            if ((-not $cacheP -or -not (Test-Path -LiteralPath $cacheP)) -and $s.LocalPoster) {
                $md5 = [Security.Cryptography.MD5]::Create()
                $hn = (($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($s.Folder)) | ForEach-Object { $_.ToString('x2') }) -join '')
                $lp = Join-Path $TVT.DataDir ("Cache\posters\local-$hn.jpg")
                if (-not (Test-Path -LiteralPath $lp)) { try { Copy-Item -LiteralPath (Join-Path $s.Path $s.LocalPoster) -Destination $lp -Force } catch {} }
            }
        }
        Set-Progress ("TVmaze: matched {0} new show(s)" -f $new.Count) 100
        [pscustomobject]@{ New = $new; Failed = $failed }
    } @($shows, $existing, [bool]$RefreshAll) {
        param($res, $err)
        if ($err) { Set-Status "TVmaze: $err"; Show-Msg "Couldn't get show info from TVmaze:`n`n$err" 'TV Toolkit' 'Warning' }
        if ($res -and $res[0]) {
            foreach ($kv in $res[0].New.GetEnumerator()) { $script:MatchMap[$kv.Key] = $kv.Value }
            Save-Matches $script:MatchMap
            $guesses = @($res[0].New.Values | Where-Object { $_.How -eq 'guess' }).Count
            $failed = @($res[0].Failed)
            if ($guesses -gt 0) { Set-Status "TVmaze done. $guesses show(s) were a best guess - use the 'Needs a match check' filter to check them." }
            if ($failed.Count -gt 0) {
                Set-Status "TVmaze: matched $($res[0].New.Count), couldn't match $($failed.Count). Details in Data\Logs\tvinfo.log"
                if ($res[0].New.Count -eq 0) {
                    Show-Msg ("TVmaze didn't match any shows. First problems:`n`n" + (($failed | Select-Object -First 4) -join "`n`n") + "`n`nFull details are in Data\Logs\tvinfo.log") 'TV Toolkit' 'Warning'
                }
            }
        }
        $script:Index = Import-SeriesIndex; $script:PeopleDirty = $true
        $script:BitmapCache = @{}
        Refresh-Library
        if ($script:CurrentShow) { Open-Show $script:CurrentShow.Folder -Keep }
    } 'info' | Out-Null
}

# ---------- show detail ----------
function Close-Show { $script:CurrentShow = $null; $script:CurrentInfo = $null; $ui.bdDetail.Visibility = 'Collapsed' }

function Open-Show([string]$Folder, [switch]$Keep) {
    if (-not $script:Lib.Contains($Folder)) { return }
    $show = $script:Lib[$Folder]
    $prevSeason = $null
    if ($Keep -and $ui.lbSeasons.SelectedItem) { $prevSeason = $ui.lbSeasons.SelectedItem.S }
    $script:CurrentShow = $show
    $ui.bdDetail.Visibility = 'Visible'
    $id = Get-ShowInfoId $show
    $info = $null
    if ($id -gt 0) { $info = Get-SeriesInfo $id -CacheOnly }
    $script:CurrentInfo = $info
    $ui.txtDetailTitle.Text = $show.Folder
    $ui.imgDetail.Source = Get-Bitmap (Get-ShowPosterPath $show) 240
    $ui.imgBackdrop.Source = $null
    if ($id -gt 0) {
        $bd = Join-Path $DataDir "Cache\backdrops\$id.jpg"
        if (Test-Path -LiteralPath $bd) { $ui.imgBackdrop.Source = Get-CachedBitmap $bd 900 }
        elseif (-not $script:BackdropAsked.ContainsKey($id) -and -not (Test-Path -LiteralPath (Join-Path $DataDir "Cache\backdrops\$id.none"))) {
            $script:BackdropAsked[$id] = $true
            Start-Work 'Fetching backdrop' { param($id) Get-ShowBackdrop $id } @($id) {
                param($res, $err, $ctx)
                if ($script:CurrentShow -and $script:CurrentShow.Folder -eq $ctx.Folder -and $res -and "$($res[0])") { $ui.imgBackdrop.Source = Get-CachedBitmap "$($res[0])" 900 }
            } '' @{ Folder = $show.Folder } | Out-Null
        }
    }
    $meta = @()
    if ($info) {
        if ($info.Year) { $meta += $info.Year }
        if ($info.Network) { $meta += $info.Network }
        if ($info.Status) { $meta += $info.Status }
        if ($info.Genres) { $meta += (@($info.Genres) -join ', ') }
    }
    $meta += (Format-Size $show.Size)
    $ui.txtDetailMeta.Text = ($meta -join "  $DOT  ")
    $ui.txtDetailOverview.Text = $(if ($info) { $info.Overview } elseif ($id -le 0) { 'Not matched yet. Use Fix match... to choose the right show.' } else { 'Fetching show info...' })
    $nextText = ''
    if ($info) {
        $today = Get-Today
        $n = @($info.Episodes | Where-Object { $_.Aired -and "$($_.Aired)" -ge $today } | Select-Object -First 1)
        if ($n) { $nextText = "Next: $(Format-Ep $n[0].S $n[0].E) '$($n[0].Title)' on $(Format-Date $n[0].Aired)" }
    }
    $ui.txtDetailNext.Text = $nextText
    $mm = $script:MatchMap[$show.Folder]
    $ui.btnShowConfirm.Visibility = $(if ($mm -and $mm.How -eq 'guess') { 'Visible' } else { 'Collapsed' })

    # Cast
    $cast = @()
    if ($info -and $info.Cast) {
        foreach ($c in @($info.Cast | Select-Object -First 20)) {
            $pp = Get-PersonPhotoPath $c.Image
            $tip = "$($c.Name)"; if ($c.Role) { $tip += " as $($c.Role)" }; $tip += "`nClick for more about them"
            $cast += [pscustomobject]@{ Key = (Get-PersonKey $c); Name = $c.Name; Role = $c.Role; Tip = $tip; Initials = (Get-Initials $c.Name); Photo = [Windows.Media.ImageSource](Get-Bitmap $pp 128); Url = $c.Image; PhotoPath = $pp }
        }
    }
    $ui.icCast.ItemsSource = $cast
    if ($cast.Count -gt 0) { $ui.txtCastHead.Visibility = 'Visible'; $ui.svCast.Visibility = 'Visible' } else { $ui.txtCastHead.Visibility = 'Collapsed'; $ui.svCast.Visibility = 'Collapsed' }
    $needPhotos = @($cast | Where-Object { $_.Url -and -not (Test-Path -LiteralPath $_.PhotoPath) } | ForEach-Object { , @($_.Url, $_.PhotoPath) })
    if ($needPhotos.Count -gt 0 -and -not $Keep) {
        Start-Work 'Fetching cast photos' { param($list) foreach ($p in $list) { Save-WebFile $p[0] $p[1] | Out-Null } } @(, $needPhotos) {
            param($res, $err, $ctx)
            if ($script:CurrentShow -and $script:CurrentShow.Folder -eq $ctx) { Open-Show $ctx -Keep }
        } '' $Folder | Out-Null
    }

    # Seasons
    $cutoff = Get-NewCutoff
    $seasons = @{}
    foreach ($s in $show.Seasons) { $seasons[[int]$s] = $true }
    if ($info) { foreach ($e in @($info.Episodes)) { $seasons[[int]$e.S] = $true } }
    $chips = foreach ($s in ($seasons.Keys | Sort-Object { if ($_ -eq 0) { 9999 } else { $_ } })) {
        $have = @($show.EpKeys.Keys | Where-Object { $_.StartsWith("$s|") }).Count
        $total = 0; if ($info) { $total = @($info.Episodes | Where-Object { $_.S -eq $s -and $_.Aired -and "$($_.Aired)" -le (Get-Today) }).Count }
        $label = $(if ($s -eq 0) { 'Specials' } else { "Season $s" })
        if ($total -gt 0) {
            $haveAired = 0; foreach ($e in $info.Episodes) { if ($e.S -eq $s -and $e.Aired -and "$($e.Aired)" -le (Get-Today) -and $show.EpKeys.ContainsKey("$($e.S)|$($e.E)")) { $haveAired++ } }
            if ($haveAired -eq $total) { $label = "$([char]0x2713) $label" }
            $label += "  $have/$total"
        } elseif ($have -gt 0) { $label += "  $have" }
        $nNew = @($show.EpKeys.Keys | Where-Object { $_.StartsWith("$s|") -and (Test-NewKey $show $_ $cutoff) }).Count
        if ($nNew -gt 0) { $label += "  $DOT  $nNew new" }
        [pscustomobject]@{ S = [int]$s; Label = $label }
    }
    $chips = @($chips)
    $ui.lbSeasons.ItemsSource = $chips
    $pick = $null
    if ($null -ne $prevSeason) { $pick = $chips | Where-Object { $_.S -eq $prevSeason } | Select-Object -First 1 }
    if (-not $pick) { $pick = $chips | Where-Object { $show.Seasons -contains $_.S -and $_.S -gt 0 } | Select-Object -Last 1 }
    if (-not $pick -and $chips.Count) { $pick = $chips[0] }
    $ui.lbSeasons.SelectedItem = $pick
    Fill-Episodes

    if ($id -gt 0 -and -not $info -and -not $Keep -and -not $script:BusyGroups['info']) {
        Start-Work 'Fetching show info' { param($id) Get-SeriesInfo $id | Out-Null } @($id) {
            param($res, $err, $ctx)
            $script:Index = Import-SeriesIndex; $script:PeopleDirty = $true
            $script:BitmapCache = @{}
            if ($script:CurrentShow -and $script:CurrentShow.Folder -eq $ctx) { Open-Show $ctx -Keep }
            Refresh-Library
            if ($err) { Set-Status "Show info: $err" }
        } 'info' $Folder | Out-Null
    }
}

function Get-ThumbPath([string]$url) { if (-not $url) { return '' }; return (Join-Path $DataDir ("Cache\epthumbs\" + (Get-HashName $url) + '.jpg')) }
function Test-InfoHasImg($info) {
    # Show info saved before 1.8.0 has no episode pictures
    if (-not $info -or -not $info.Episodes) { return $true }
    foreach ($e in $info.Episodes) { if ($e) { return ($e.PSObject.Properties.Name -contains 'Img') } }
    return $true
}
function Request-EpisodeThumbs($rows, $info, [scriptblock]$Then) {
    # Old show info has no episode pictures - fetch it again once, then download any missing stills in the background
    if ($info -and -not (Test-InfoHasImg $info)) {
        $iid = [int]$info.Id
        if (-not $script:ThumbUpgraded.ContainsKey($iid) -and -not $script:BusyGroups['info']) {
            $script:ThumbUpgraded[$iid] = $true
            $al = New-Object object[] 1; $al[0] = $iid
            Start-Work 'Getting episode pictures' { param($id) Get-SeriesInfo $id -Force | Out-Null } $al {
                param($res, $err, $ctx)
                if ($script:CurrentShow -and (Get-ShowInfoId $script:CurrentShow) -eq $ctx) { Open-Show $script:CurrentShow.Folder -Keep }
            } 'info' $iid | Out-Null
        }
        return
    }
    $need = New-Object System.Collections.Generic.List[string]
    foreach ($r in $rows) {
        if (-not $r.ThumbUrl) { continue }
        $p = Get-ThumbPath $r.ThumbUrl
        if ($script:ThumbAsked.ContainsKey($p) -or (Test-Path -LiteralPath $p)) { continue }
        $script:ThumbAsked[$p] = $true
        $need.Add($r.ThumbUrl); $need.Add($p)
    }
    if ($need.Count -eq 0) { return }
    $al = New-Object object[] 1; $al[0] = $need.ToArray()
    Start-Work "Fetching $($need.Count / 2) episode picture(s)" { param($list) for ($i = 0; $i -lt $list.Count; $i += 2) { Save-WebFile $list[$i] $list[$i + 1] | Out-Null } } $al {
        param($res, $err, $then)
        if ($then) { & $then }
    } '' $Then | Out-Null
}
function Fill-Episodes {
    $show = $script:CurrentShow; if (-not $show) { return }
    $info = $script:CurrentInfo
    $sel = $ui.lbSeasons.SelectedItem
    if (-not $sel) { $ui.dgEpisodes.ItemsSource = @(); return }
    $season = [int]$sel.S
    $today = Get-Today
    $cutoff = Get-NewCutoff
    $mk = {
        param($k)
        if (Test-NewKey $show $k $cutoff) { return @{ Mark = 'NEW'; MarkFg = $script:MarkDarkFg; MarkBg = $BadgeGreen; IsNew = $true } }
        return @{ Mark = ''; MarkFg = $script:Transparent; MarkBg = $script:Transparent; IsNew = $false }
    }
    $rows = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    if ($info) {
        foreach ($e in @($info.Episodes | Where-Object { $_.S -eq $season })) {
            $k = "$($e.S)|$($e.E)"; $seen[$k] = $true
            $f = $show.EpKeys[$k]
            $state = $(if ($f) { 'On disk' } elseif (-not $e.Aired -or "$($e.Aired)" -gt $today) { 'Upcoming' } else { 'Missing' })
            $mm = & $mk $k
            $tu = "$($e.Img)"; $tp = Get-ThumbPath $tu
            $rows.Add([pscustomobject]@{ ThumbUrl = $tu; Thumb = [Windows.Media.ImageSource](Get-CachedBitmap $tp 176); S = [int]$e.S; E = [int]$e.E; Ep = (Format-Ep $e.S $e.E); Title = $e.Title; Aired = $(if ($e.Aired) { Format-Date "$($e.Aired)" } else { '' })
                State = $(if ($mm.IsNew) { 'New' } else { $state }); Res = $(if ($f -and $f.Res -ne '?') { $f.Res } else { '' }); SizeText = $(if ($f) { Format-Size $f.Size } else { '' }); Path = $(if ($f) { $f.Path } else { '' }); Overview = $e.Overview
                Mark = $mm.Mark; MarkFg = [Windows.Media.Brush]$mm.MarkFg; MarkBg = [Windows.Media.Brush]$mm.MarkBg; IsNew = [bool]$mm.IsNew })
        }
    }
    foreach ($k in $show.EpKeys.Keys) {
        if ($seen[$k]) { continue }
        $p = $k.Split('|'); if ([int]$p[0] -ne $season) { continue }
        $f = $show.EpKeys[$k]
        $mm = & $mk $k
        $rows.Add([pscustomobject]@{ ThumbUrl = ''; Thumb = $null; S = [int]$p[0]; E = [int]$p[1]; Ep = (Format-Ep ([int]$p[0]) ([int]$p[1])); Title = $f.TitlePart; Aired = ''
            State = $(if ($mm.IsNew) { 'New' } elseif ($info) { 'Extra' } else { 'On disk' }); Res = $(if ($f.Res -ne '?') { $f.Res } else { '' }); SizeText = (Format-Size $f.Size); Path = $f.Path; Overview = $(if ($info) { 'This file is not in the TVmaze episode list for this season.' } else { '' })
            Mark = $mm.Mark; MarkFg = [Windows.Media.Brush]$mm.MarkFg; MarkBg = [Windows.Media.Brush]$mm.MarkBg; IsNew = [bool]$mm.IsNew })
    }
    $ui.dgEpisodes.ItemsSource = @($rows | Sort-Object E)
    $ui.txtEpOverview.Text = ''
    Request-EpisodeThumbs $rows $info { if ($script:CurrentShow) { Fill-Episodes } }
}

function Play-File($show, [int]$s, [int]$e, [string]$path) {
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { Show-Msg "Can't find the file:`n$path" 'TV Toolkit' 'Warning'; return }
    try { Start-Process -FilePath $path } catch { Show-Msg "Couldn't start a player:`n$($_.Exception.Message)" 'TV Toolkit' 'Warning'; return }
}
function Refresh-ShowViews {
    if ($script:CurrentShow) { Open-Show $script:CurrentShow.Folder -Keep }
    Refresh-Library
    if ($ui.tabMain.SelectedItem -eq $ui.tNew) { Refresh-NewPage } else { Update-NewTabHeader }
}

# ---------- new episodes page ----------
$ui.cmbNewRange.ItemsSource = @('Arrived in the last 2 days', 'Arrived in the last 7 days', 'Arrived in the last 14 days', 'Arrived in the last 30 days', 'Using my setting')
$ui.cmbNewRange.SelectedIndex = 4
function Get-NewRangeCutoff {
    switch ($ui.cmbNewRange.SelectedIndex) {
        0 { return (Get-Date).ToUniversalTime().AddDays(-2).Ticks }
        1 { return (Get-Date).ToUniversalTime().AddDays(-7).Ticks }
        2 { return (Get-Date).ToUniversalTime().AddDays(-14).Ticks }
        3 { return (Get-Date).ToUniversalTime().AddDays(-30).Ticks }
        default { return (Get-NewCutoff) }
    }
}
function Update-NewTabHeader {
    $cutoff = Get-NewCutoff; $n = 0
    foreach ($show in $script:Lib.Values) { $n += (Get-ShowCounts $show $cutoff).New }
    $ui.tNew.Header = $(if ($n -gt 0) { "New  ($n)" } else { 'New' })
    Update-HeadStats
}
function Refresh-NewPage {
    $all = $false
    $cutoff = Get-NewRangeCutoff
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($show in $script:Lib.Values) {
        $info = $null; $iid = Get-ShowInfoId $show; if ($iid -gt 0) { $info = Get-SeriesInfo $iid -CacheOnly }
        $titles = @{}; $imgs = @{}; if ($info) { foreach ($e in @($info.Episodes)) { $titles["$($e.S)|$($e.E)"] = $e.Title; $imgs["$($e.S)|$($e.E)"] = "$($e.Img)" } }
        foreach ($k in $show.EpKeys.Keys) {
            if (-not $all -and -not (Test-NewKey $show $k $cutoff)) { continue }
            $f = $show.EpKeys[$k]; $p = $k.Split('|')
            $t = $titles[$k]; if (-not $t) { $t = $f.TitlePart }
            $added = [datetime]::new($f.Added, [DateTimeKind]::Utc).ToLocalTime()
            $tu = "$($imgs[$k])"
            $rows.Add([pscustomobject]@{ ThumbUrl = $tu; Thumb = [Windows.Media.ImageSource](Get-CachedBitmap (Get-ThumbPath $tu) 176); Show = $show.Folder; Folder = $show.Folder; S = [int]$p[0]; E = [int]$p[1]; Ep = (Format-Ep ([int]$p[0]) ([int]$p[1])); Title = $t
                Added = $f.Added; AddedText = $added.ToString('ddd d MMM'); Res = $f.Res; SizeText = (Format-Size $f.Size); Path = $f.Path })
        }
    }
    $sorted = @($rows | Sort-Object @{ Expression = 'Added'; Descending = $true }, Show, S, E)
    if ($all) { $sorted = @($rows | Sort-Object Show, S, E) }
    $ui.dgNew.ItemsSource = $sorted
    $shows = @($sorted | Select-Object -ExpandProperty Folder -Unique).Count
    $ui.txtNewSummary.Text = "$($sorted.Count) episode(s) in $shows show(s)"
    $ui.txtNewHint.Text = "Episodes that arrived on your TV drive recently, newest first. 'Not new' takes them off the list."
    Update-NewTabHeader
    if ($sorted.Count) {
        # shows whose saved info predates episode pictures: refresh them once, together
        $old = New-Object System.Collections.Generic.List[int]
        $seenF = @{}
        foreach ($r in $sorted) {
            if ($seenF.ContainsKey($r.Folder)) { continue }; $seenF[$r.Folder] = $true
            $iid = Get-ShowInfoId $script:Lib[$r.Folder]; if ($iid -le 0 -or $script:ThumbUpgraded.ContainsKey($iid)) { continue }
            if (-not (Test-InfoHasImg (Get-SeriesInfo $iid -CacheOnly))) { $old.Add($iid); $script:ThumbUpgraded[$iid] = $true }
        }
        if ($old.Count -and -not $script:BusyGroups['info']) {
            $al = New-Object object[] 1; $al[0] = $old.ToArray()
            Start-Work "Getting episode pictures for $($old.Count) show(s)" { param($ids) foreach ($i in $ids) { try { Get-SeriesInfo $i -Force | Out-Null } catch {} } } $al {
                param($res, $err)
                if ($ui.tabMain.SelectedItem -eq $ui.tNew) { Refresh-NewPage }
            } 'info' | Out-Null
        } else { Request-EpisodeThumbs $sorted $null { if ($ui.tabMain.SelectedItem -eq $ui.tNew) { Refresh-NewPage } } }
    }
}

# ---------- video details (resolution / length from the files) ----------
$script:MediaResult = $null
function Start-MediaProbe([switch]$All) {
    if ($script:BusyGroups['media']) { return }
    $items = foreach ($show in $script:Lib.Values) { foreach ($f in $show.Files) { , @($f.Path, $f.Size, $f.Ticks) } }
    $items = @($items)
    if (-not $All) {
        $need = @($script:Lib.Values | ForEach-Object { $_.Files } | Where-Object { $_.ResSource -ne 'file' -and $_.Seconds -le 0 })
        if ($need.Count -eq 0) { return }
    }
    Start-Work 'Reading video details' { param($items, $all) Invoke-MediaProbe $items -All:$all } @($items, [bool]$All) {
        param($res, $err)
        if ($err) { Set-Status "Video details: $err"; return }
        $r = $res[0]; $script:MediaResult = $r
        Apply-MediaInfo
        if ($r.Checked -gt 0) {
            $msg = "Video details: read $($r.Ok) of $($r.Checked) file(s)."
            if ($r.Failed -gt 0 -and -not $r.FFprobe) { $msg += " $($r.Failed) couldn't be read - installing ffprobe (winget install Gyan.FFmpeg) would let TV Toolkit read them." }
            Set-Status $msg
        }
        if ($ui.tabMain.SelectedItem -eq $ui.tStats) { Refresh-Stats }
        elseif ($ui.tabMain.SelectedItem -eq $ui.tDupes) { Refresh-Dupes }
        if ($script:CurrentShow) { Fill-Episodes }
    } 'media' $null -Sta:$true | Out-Null
}
function Apply-MediaInfo {
    $media = Import-MediaInfo
    foreach ($show in $script:Lib.Values) {
        foreach ($f in $show.Files) {
            $mi = $media[$f.Path]
            if ($mi -and [int64]$mi[1] -eq $f.Size) {
                $f.Width = [int]$mi[3]; $f.Height = [int]$mi[4]; $f.Seconds = [int]$mi[5]
                if ($f.Width -gt 0) { $f.Res = Get-VideoClass $f.Width $f.Height; $f.ResSource = 'file' }
            }
        }
    }
}

# ---------- problem files page ----------
$script:ProblemRows = @()
$script:ProblemsChecked = $false
$ui.cmbProbType.ItemsSource = @('Everything')
$ui.cmbProbType.SelectedIndex = 0
function Refresh-ProblemGrid {
    $sel = "$($ui.cmbProbType.SelectedItem)"
    $rows = @($script:ProblemRows | Where-Object { -not $sel -or $sel -eq 'Everything' -or $sel -like "$($_.Type) (*" })
    $ui.dgProblems.ItemsSource = @($rows | Sort-Object Type, Show, File)
    $ui.txtProbSummary.Text = $(if ($script:ProblemsChecked) { "$($rows.Count) item(s)$(if ($rows.Count -ne $script:ProblemRows.Count) { " of $($script:ProblemRows.Count)" })" } else { "Press Check now to look through your show folders" })
}
function Start-ProblemCheck {
    Start-Work 'Looking for problem files' { param($lib) [pscustomobject]@{ Rows = @(Get-ProblemFiles $lib) } } @(, $script:Lib) {
        param($res, $err)
        if ($err) { Set-Status "Problem files: $err"; return }
        $script:ProblemRows = @($res[0].Rows | Where-Object { $_ })
        $script:ProblemsChecked = $true
        $types = @($script:ProblemRows | Group-Object Type | Sort-Object Name | ForEach-Object { "$($_.Name) ($($_.Count))" })
        $keep = "$($ui.cmbProbType.SelectedItem)"
        $ui.cmbProbType.ItemsSource = @('Everything') + $types
        $hit = @($ui.cmbProbType.ItemsSource | Where-Object { $_ -and $keep -and $_.Split('(')[0] -eq $keep.Split('(')[0] } | Select-Object -First 1)
        $ui.cmbProbType.SelectedItem = $(if ($hit) { $hit[0] } else { 'Everything' })
        Refresh-ProblemGrid
        Set-Status "Problem check done: $($script:ProblemRows.Count) item(s)."
    } 'problems' | Out-Null
}
function Move-WithSidecars([string]$path, [string]$destDir) {
    # Moves a file plus anything sharing its name (subtitles, .nfo, -thumb.jpg) into destDir
    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    $dir = Split-Path -Parent $path; $base = [IO.Path]::GetFileNameWithoutExtension($path)
    foreach ($f in [IO.Directory]::GetFiles($dir)) {
        $n = [IO.Path]::GetFileName($f)
        if ($f -eq $path -or $n.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
            $rest = $n.Substring([math]::Min($n.Length, $base.Length))
            if ($f -ne $path -and $rest -and -not ($rest.StartsWith('.') -or $rest.StartsWith('-'))) { continue }
            $target = Join-Path $destDir $n
            if (Test-Path -LiteralPath $target) { throw "'$n' already exists in $destDir" }
            Move-Item -LiteralPath $f -Destination $target
        }
    }
}

# ---------- stats page ----------
function New-BarRows($pairs, [int]$Max = 8, [string]$Unit = '', [scriptblock]$Fmt = $null) {
    # pairs: objects with Label, Value (number), optional Tip. Returns rows with Pct as pixel width (max 300)
    $top = @($pairs | Sort-Object @{ Expression = 'Value'; Descending = $true }, Label | Select-Object -First $Max)
    $peak = 0; foreach ($p in $top) { if ($p.Value -gt $peak) { $peak = $p.Value } }
    foreach ($p in $top) {
        $vt = $(if ($Fmt) { & $Fmt $p.Value } else { "$($p.Value)$Unit" })
        $frac = [double]$(if ($peak -gt 0) { [math]::Max(0.015, [double]$p.Value / $peak) } else { 0 })
        [pscustomobject]@{ Label = $p.Label; ValueText = $vt; BarStar = [Windows.GridLength]::new([double]($frac * 1000), [Windows.GridUnitType]::Star); RestStar = [Windows.GridLength]::new([double]((1 - $frac) * 1000 + 0.001), [Windows.GridUnitType]::Star); Tip = $(if ($p.Tip) { $p.Tip } else { "$($p.Label): $vt" }) }
    }
}
function New-MonthBars([hashtable]$byMonth, [string]$noun) {
    $months = @(); $now = Get-Date
    for ($i = 11; $i -ge 0; $i--) { $months += $now.AddMonths(-$i).ToString('yyyy-MM') }
    $peak = 0; foreach ($k in $months) { if ([int]$byMonth[$k] -gt $peak) { $peak = [int]$byMonth[$k] } }
    $last = $months[-1]
    foreach ($k in $months) {
        $v = [int]$byMonth[$k]
        $d = [datetime]::ParseExact($k + '-01', 'yyyy-MM-dd', $null)
        [pscustomobject]@{ Label = $d.ToString('MMM'); Top = $(if ($v -gt 0 -and ($v -eq $peak -or $k -eq $last)) { "$v" } else { '' })
            BarHeight = [double]$(if ($peak -gt 0 -and $v -gt 0) { [math]::Max(3, $v / $peak * 130) } else { 0 }); BarBrush = [Windows.Media.Brush]$(if ($k -eq $last) { $StatBr.Current } else { $StatBr.Bar })
            Tip = "$($d.ToString('MMMM yyyy')): $v $noun" }
    }
}
$StatBr = @{ Bar = $Win.FindResource('Accent'); Current = $Win.FindResource('Accent2'); Text = $Win.FindResource('Text'); Good = $Win.FindResource('Good'); Warn = $Win.FindResource('Warn'); Bad = $Win.FindResource('Bad') }
function Get-DriveTiles($shows) {
    # One tile per TV drive: free space, a used/free bar and a rough 'full in' estimate from how fast episodes arrive
    $tiles = @()
    $since = (Get-Date).ToUniversalTime().AddDays(-182).Ticks
    $drives = @{}
    foreach ($r in @($TVT.Settings.Roots)) { if ("$r" -match '^([A-Za-z]):') { $drives[$Matches[1].ToUpper()] = $true } }
    foreach ($letter in ($drives.Keys | Sort-Object)) {
        try { $di = [IO.DriveInfo]::new($letter); if (-not $di.IsReady) { continue } } catch { continue }
        $total = [double]$di.TotalSize; $free = [double]$di.AvailableFreeSpace; $used = $total - $free
        if ($total -le 0) { continue }
        $recent = 0.0
        foreach ($sh in $shows) { if ($sh.Path -like "$($letter):*") { foreach ($f in $sh.Files) { if ($f.Added -ge $since) { $recent += $f.Size } } } }
        $perMonth = $recent / 6
        $pct = [math]::Round($used / $total * 100)
        $fullIn = ''
        if ($perMonth -gt 1GB) {
            $months = $free / $perMonth
            $fullIn = $(if ($months -ge 24) { "full in about $([math]::Round($months / 12)) years" } elseif ($months -ge 1) { "full in about $([math]::Round($months)) months" } else { 'full within a month' })
        }
        $fmt = { param($b) if ($b -ge 1TB) { '{0:N1} TB' -f ($b / 1TB) } else { '{0:N0} GB' -f ($b / 1GB) } }
        $tip = "$($letter): drive`nUsed: $(& $fmt $used) of $(& $fmt $total) ($pct%)`nFree: $(& $fmt $free)`nTV added in the last 6 months: $(& $fmt $recent) (about $(& $fmt $perMonth) a month)"
        $tiles += [pscustomobject]@{ Label = "$($letter): drive free"; Value = (& $fmt $free); Sub = "$pct% used of $(& $fmt $total)$(if ($fullIn) { " $DOT $fullIn" })"; Tip = $tip
            BarVis = 'Visible'; BarUsed = [Windows.GridLength]::new([double][math]::Max(1, $pct), [Windows.GridUnitType]::Star); BarFree = [Windows.GridLength]::new([double][math]::Max(1, 100 - $pct), [Windows.GridUnitType]::Star)
            BarBrush = [Windows.Media.Brush]$(if ($pct -ge 90) { $StatBr.Bad } elseif ($pct -ge 75) { $StatBr.Warn } else { $StatBr.Bar }) }
    }
    return $tiles
}
function Format-Duration([double]$minutes) {
    if ($minutes -le 0) { return '0 h' }
    $h = $minutes / 60
    if ($h -ge 48) { return ('{0:N1} days' -f ($h / 24)) }
    return ('{0:N0} h' -f $h)
}
function Refresh-Stats {
    $ui.txtStatsWhen.Text = "Your library as of $(Get-Date -Format 'dddd d MMMM, HH:mm')"
    $shows = @($script:Lib.Values)
    $eps = 0; $files = 0; $size = [int64]0; $seasons = 0
    $cont = 0; $ended = 0; $other = 0; $waiting = 0
    $nets = @{}; $genres = @{}; $res = @{ '2160p' = 0; '1080p' = 0; '720p' = 0; 'SD' = 0; '?' = 0 }
    $addedBy = @{}
    $minsOnDisk = 0.0; $knownEps = 0
    $realLen = 0; $resRead = 0
    $wk = (Get-Date).ToUniversalTime().AddDays(-7).Ticks; $mo = (Get-Date).ToUniversalTime().AddDays(-30).Ticks; $newWeek = 0; $newMonth = 0
    $big = @(); $most = @()
    foreach ($show in $shows) {
        $eps += $show.EpisodeCount; $files += $show.Files.Count; $size += $show.Size
        $seasons += @($show.Seasons | Where-Object { $_ -gt 0 }).Count
        if ($show.EpisodeCount -eq 0) { $waiting++ }
        $idx = Get-ShowIndex $show
        if ($idx -and $idx.Status -match 'Ended') { $ended++ } elseif ($idx -and $idx.Status -match 'Continuing|Running') { $cont++ } else { $other++ }
        if ($idx -and $idx.Network) { $nets[$idx.Network] = [int]$nets[$idx.Network] + 1 }
        if ($idx -and $idx.Genres) { foreach ($g in ($idx.Genres -split ',\s*')) { if ($g) { $genres[$g] = [int]$genres[$g] + 1 } } }
        $info = $null; $iid = Get-ShowInfoId $show; if ($iid -gt 0) { $info = Get-SeriesInfo $iid -CacheOnly }
        $rt = @{}; if ($info) { foreach ($e in @($info.Episodes)) { if ($e -and $e.Runtime) { $r = 0; if ([int]::TryParse("$($e.Runtime)", [ref]$r) -and $r -gt 0) { $rt["$($e.S)|$($e.E)"] = $r } } } }
        foreach ($f in $show.Files) {
            $res[$f.Res]++; if ($f.ResSource -eq 'file') { $resRead++ }
            $mk = ([datetime]::new($f.Added, [DateTimeKind]::Utc)).ToLocalTime().ToString('yyyy-MM'); $addedBy[$mk] = [int]$addedBy[$mk] + 1
            if ($f.Added -ge $wk) { $newWeek++ }; if ($f.Added -ge $mo) { $newMonth++ }
        }
        foreach ($k in $show.EpKeys.Keys) {
            $fk = $show.EpKeys[$k]
            if ($fk -and $fk.Seconds -gt 0) { $minsOnDisk += $fk.Seconds / 60.0 / [math]::Max(1, @($fk.Eps).Count); $knownEps++; $realLen++ }
            elseif ($rt.ContainsKey($k)) { $minsOnDisk += $rt[$k]; $knownEps++ }
        }
        if ($show.Size -gt 0) { $big += [pscustomobject]@{ Label = $show.Folder; Value = [double]$show.Size } }
        if ($show.EpisodeCount -gt 0) { $most += [pscustomobject]@{ Label = $show.Folder; Value = $show.EpisodeCount } }
    }
    if ($script:PeopleDirty) { try { Build-CastIndex } catch {} }
    $tiles = @(
        [pscustomobject]@{ Label = 'Shows'; Value = "$($shows.Count)"; Sub = "$cont continuing $DOT $ended ended$(if ($waiting) { " $DOT $waiting waiting" })"; Tip = "$($shows.Count) show folders on your TV drive" }
        [pscustomobject]@{ Label = 'Episodes on disk'; Value = ('{0:N0}' -f $eps); Sub = "$seasons seasons $DOT $files files"; Tip = "$eps episodes in $files video files" }
        [pscustomobject]@{ Label = 'Space used'; Value = (Format-SizeWhole $size); Sub = $(if ($files) { "about $(Format-Size ($size / $files)) per file" } else { '' }); Tip = 'Total size of all episode files' }
        [pscustomobject]@{ Label = 'Viewing time on disk'; Value = (Format-Duration $minsOnDisk); Sub = "from $knownEps of $eps episodes with a known length"; Tip = "Uses each file's real length where it could be read ($realLen episodes), otherwise TVmaze's running time" }
        [pscustomobject]@{ Label = 'New this week'; Value = "$newWeek"; Sub = "$newMonth in the last 30 days"; Tip = 'Episode files that arrived on the drive' }
        [pscustomobject]@{ Label = 'Cast'; Value = ('{0:N0}' -f $script:People.Count); Sub = "$(@($script:People.Values | Where-Object { $_.Shows.Count -gt 1 }).Count) in more than one show"; Tip = 'People in the cast of your shows' }
        [pscustomobject]@{ Label = 'Channels'; Value = "$($nets.Count)"; Sub = "$($genres.Count) genres"; Tip = 'Different channels and streaming services' }
    )
    $tiles = @(Get-DriveTiles $shows) + $tiles
    $one = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
    $tiles = @(foreach ($t in $tiles) {
        $hasBar = $t.PSObject.Properties.Name -contains 'BarVis'
        [pscustomobject]@{ Label = $t.Label; Value = $t.Value; Sub = $t.Sub; Tip = $t.Tip; ValueBrush = [Windows.Media.Brush]$StatBr.Text
            BarVis = $(if ($hasBar) { $t.BarVis } else { 'Collapsed' })
            BarUsed = [Windows.GridLength]$(if ($hasBar) { $t.BarUsed } else { $one }); BarFree = [Windows.GridLength]$(if ($hasBar) { $t.BarFree } else { $one })
            BarBrush = [Windows.Media.Brush]$(if ($hasBar) { $t.BarBrush } else { $StatBr.Bar }) }
    })
    $ui.icStatTiles.ItemsSource = $tiles
    $ui.icStatAdded.ItemsSource = @(New-MonthBars $addedBy 'episodes added')
    $ui.icStatAddedSub.Text = 'Episode files arriving each month, last 12 months (this month in yellow)'
    $ui.icStatNetworks.ItemsSource = @(New-BarRows @($nets.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Label = $_.Key; Value = $_.Value } }) 10 '' { param($v) "$v show$(if ($v -ne 1) { 's' })" })
    $ui.icStatGenres.ItemsSource = @(New-BarRows @($genres.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Label = $_.Key; Value = $_.Value } }) 10 '' { param($v) "$v show$(if ($v -ne 1) { 's' })" })
    $ui.icStatBiggest.ItemsSource = @(New-BarRows $big 10 '' { param($v) Format-SizeWhole $v })
    $ui.icStatMostEps.ItemsSource = @(New-BarRows $most 10 '' { param($v) "$v eps" })
    $resRows = foreach ($k in '2160p', '1080p', '720p', 'SD', '?') { if ($res[$k] -gt 0) { [pscustomobject]@{ Label = $(if ($k -eq '?') { 'Not stated' } else { $k }); Value = $res[$k]; Tip = "$($res[$k]) file(s) at $k" } } }
    $ui.icStatRes.ItemsSource = @(New-BarRows @($resRows) 5 '' { param($v) "$v files" })
    $tf = 0; foreach ($sh in $shows) { $tf += $sh.Files.Count }
    $ui.txtStatResSub.Text = $(if ($script:BusyGroups['media']) { "Reading video details from your files... ($resRead of $tf done so far)" }
        elseif ($resRead -ge $tf) { 'Episode files by resolution, read from the video files themselves' }
        else { "Read from the video files ($resRead of $tf); the rest from file names$(if ($script:MediaResult -and -not $script:MediaResult.FFprobe -and $script:MediaResult.Failed -gt 0) { ' - install ffprobe to read the others' })" })
}

# ---------- calendar page ----------
function New-Brush([string]$hex) { $b = (New-Object Windows.Media.BrushConverter).ConvertFromString($hex); $b.Freeze(); return $b }
$CalBr = @{
    Have = (New-Brush '#5CC98A'); Missing = (New-Brush '#E5566B'); Today = (New-Brush '#F4C542'); Upcoming = (New-Brush '#98A2B3')
    HeadToday = (New-Brush '#F4C542'); HeadNormal = (New-Brush '#1F242D'); HeadPast = (New-Brush '#1A1E25')
    FgDark = (New-Brush '#101318'); FgLight = (New-Brush '#E9ECF2'); SubDark = (New-Brush '#3A3320'); SubLight = (New-Brush '#98A2B3')
    BorderToday = (New-Brush '#F4C542'); BorderNormal = (New-Brush '#2C333F'); CountNormal = (New-Brush '#35C2D6')
}
function ConvertTo-IcsText([string]$t) { return $t.Replace('\', '\\').Replace(';', '\;').Replace(',', '\,').Replace("`r", '').Replace("`n", '\n') }
function Export-CalendarIcs {
    $rows = @($script:CalRows)
    if ($rows.Count -eq 0) { $rows = @(Get-CalendarEpisodes $script:Lib $script:MatchMap) }
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $up = @($rows | Where-Object { $_.Date -ge $today } | Sort-Object Date, Time, Show, S, E)
    if ($up.Count -eq 0) { Show-Msg "There's nothing coming up in the next 3 months. Press Refresh airing info first if you haven't for a while."; return }
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = 'Calendar file (*.ics)|*.ics'; $dlg.FileName = 'TV Toolkit - coming up.ics'
    $dlg.InitialDirectory = [Environment]::GetFolderPath('MyDocuments')
    if (-not $dlg.ShowDialog($Win)) { return }
    $stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd'T'HHmmss'Z'")
    $sb = New-Object Text.StringBuilder
    $add = { param($line)
        # calendar files want lines of 75 characters or less; longer ones carry on after a space
        while ($line.Length -gt 74) { [void]$sb.Append($line.Substring(0, 74) + "`r`n"); $line = ' ' + $line.Substring(74) }
        [void]$sb.Append($line + "`r`n") }
    & $add 'BEGIN:VCALENDAR'; & $add 'VERSION:2.0'; & $add "PRODID:-//TV Toolkit//$AppVersion//EN"; & $add 'CALSCALE:GREGORIAN'; & $add 'X-WR-CALNAME:TV Toolkit'
    foreach ($r in $up) {
        $uid = ("{0}-{1}-{2}" -f ($r.Folder -replace '[^A-Za-z0-9]', ''), $r.S, $r.E) + '@tvtoolkit'
        & $add 'BEGIN:VEVENT'
        & $add "UID:$uid"; & $add "DTSTAMP:$stamp"
        if ($r.Time) {
            $st = [datetime]::ParseExact("$($r.Date) $($r.Time)", 'yyyy-MM-dd HH:mm', $null)
            $mins = 60; if ("$($r.Runtime)" -match '^\d+$' -and [int]$r.Runtime -gt 0) { $mins = [int]$r.Runtime }
            & $add ("DTSTART:" + $st.ToUniversalTime().ToString("yyyyMMdd'T'HHmmss'Z'"))
            & $add ("DTEND:" + $st.AddMinutes($mins).ToUniversalTime().ToString("yyyyMMdd'T'HHmmss'Z'"))
        } else {
            $d = [datetime]::ParseExact($r.Date, 'yyyy-MM-dd', $null)
            & $add ("DTSTART;VALUE=DATE:" + $d.ToString('yyyyMMdd')); & $add ("DTEND;VALUE=DATE:" + $d.AddDays(1).ToString('yyyyMMdd'))
        }
        & $add ("SUMMARY:" + (ConvertTo-IcsText "$($r.Show) - $($r.Ep)$(if ($r.Title) { " $($r.Title)" })"))
        $desc = @("$($r.Show), $($r.Ep)$(if ($r.Title) { ": $($r.Title)" })"); if ($r.Network) { $desc += "On $($r.Network)" }; if ($r.Have) { $desc += 'Already on your TV drive' }
        & $add ("DESCRIPTION:" + (ConvertTo-IcsText ($desc -join "`n")))
        if ($r.Network) { & $add ("LOCATION:" + (ConvertTo-IcsText $r.Network)) }
        & $add 'TRANSP:TRANSPARENT'
        & $add 'END:VEVENT'
    }
    & $add 'END:VCALENDAR'
    try { [IO.File]::WriteAllText($dlg.FileName, $sb.ToString(), (New-Object Text.UTF8Encoding($false))) } catch { Show-Msg "Couldn't save the file:`n$($_.Exception.Message)" 'TV Toolkit' 'Warning'; return }
    Set-Status "Saved $($up.Count) episode(s) to $($dlg.FileName)"
    if (Confirm-Action "Saved $($up.Count) upcoming episode(s) to:`n$($dlg.FileName)`n`nOpen it now? Outlook (or your calendar app) will offer to add them. Saving again later and re-importing updates the same entries rather than doubling them.") { try { Start-Process -FilePath $dlg.FileName } catch {} }
}
function Refresh-CalendarView {
    $today = (Get-Date).Date
    $start = $today.AddDays(7 * $script:CalOffset)
    $end = $start.AddDays(6)
    $ui.txtCalRange.Text = "$($start.ToString('ddd d MMM')) - $($end.ToString('ddd d MMM yyyy'))" + $(if ($script:CalOffset -eq 0) { '   (this week)' } else { '' })
    $hideHave = [bool]$ui.chkCalHideHave.IsChecked
    $rows = @($script:CalRows)
    $days = New-Object System.Collections.Generic.List[object]
    $total = 0
    for ($i = 0; $i -lt 7; $i++) {
        $d = $start.AddDays($i); $ds = $d.ToString('yyyy-MM-dd')
        $isToday = ($d -eq $today); $isPast = ($d -lt $today)
        $eps = foreach ($r in @($rows | Where-Object { $_.Date -eq $ds } | Sort-Object @{ Expression = { if ($_.Time) { $_.Time } else { '99:99' } } }, Show, S, E)) {
            if ($hideHave -and $r.Have) { continue }
            $show = $script:Lib[$r.Folder]
            if ($r.Have) { $st = 'ON DISK'; $bg = $CalBr.Have }
            elseif ($isPast) { $st = 'MISSING'; $bg = $CalBr.Missing }
            elseif ($isToday) { $st = 'TODAY'; $bg = $CalBr.Today }
            else { $st = 'UPCOMING'; $bg = $CalBr.Upcoming }
            $tl = @(); if ($r.Time) { $tl += $r.Time }; if ($r.Network) { $tl += $r.Network }; if ($r.Runtime) { $tl += "$($r.Runtime) min" }
            $pp = $null; if ($show) { $pp = Get-ShowPosterPath $show }
            [pscustomobject]@{ Folder = $r.Folder; Show = $r.Show; EpLine = "$($r.Ep)  $DOT  $($r.Title)"; TimeLine = ($tl -join "  $DOT  "); Status = $st; StatusBg = [Windows.Media.Brush]$bg
                Poster = [Windows.Media.ImageSource](Get-CachedBitmap $pp 100); Tip = "$($r.Show)`n$($r.Ep) - $($r.Title)`n$($d.ToString('dddd d MMMM'))$(if ($r.Time) { " at $($r.Time)" })$(if ($r.Network) { " on $($r.Network)" })`nClick to open the show" }
        }
        $eps = @($eps); $total += $eps.Count
        $days.Add([pscustomobject]@{
            DayName = $(if ($isToday) { 'Today' } elseif ($d -eq $today.AddDays(1)) { 'Tomorrow' } elseif ($d -eq $today.AddDays(-1)) { 'Yesterday' } else { $d.ToString('dddd') })
            DateText = $d.ToString('ddd d MMM'); Episodes = $eps; Count = $eps.Count; CountVis = $(if ($eps.Count) { 'Visible' } else { 'Collapsed' })
            EmptyText = $(if ($eps.Count) { '' } else { 'Nothing airing' })
            HeadBg = [Windows.Media.Brush]$(if ($isToday) { $CalBr.HeadToday } elseif ($isPast) { $CalBr.HeadPast } else { $CalBr.HeadNormal })
            HeadFg = [Windows.Media.Brush]$(if ($isToday) { $CalBr.FgDark } else { $CalBr.FgLight }); HeadSub = [Windows.Media.Brush]$(if ($isToday) { $CalBr.SubDark } else { $CalBr.SubLight })
            CountBg = [Windows.Media.Brush]$(if ($isToday) { $CalBr.FgDark } else { $CalBr.CountNormal })
            BorderBrush = [Windows.Media.Brush]$(if ($isToday) { $CalBr.BorderToday } else { $CalBr.BorderNormal }); BorderWidth = [Windows.Thickness]$(if ($isToday) { 2 } else { 1 })
        })
    }
    $ui.icCalendar.ItemsSource = $days
    $ui.txtCalSummary.Text = $(if (-not $script:CalLoaded) { 'Loading...' } else { "$total episode(s) this week from $(@($script:CalRows | Select-Object -ExpandProperty Folder -Unique).Count) airing show(s) in your library" })
    # Missed: aired in the 7 days before today, not on disk (only on the current week)
    $missed = @()
    if ($script:CalOffset -eq 0) {
        $f = $today.AddDays(-7).ToString('yyyy-MM-dd'); $t = $today.AddDays(-1).ToString('yyyy-MM-dd')
        $missed = @($rows | Where-Object { $_.Date -ge $f -and $_.Date -le $t -and -not $_.Have } | Sort-Object Date, Show | ForEach-Object {
            [pscustomobject]@{ Folder = $_.Folder; Label = "$($_.Show)  $($_.Ep)"; Tip = "$($_.Ep) - $($_.Title)`nAired $(Format-Date $_.Date)`nClick to open the show" } })
    }
    $ui.icCalMissed.ItemsSource = $missed
    $ui.txtCalMissed.Text = "Missed in the last 7 days ($($missed.Count)):"
    $ui.bdCalMissed.Visibility = $(if ($missed.Count) { 'Visible' } else { 'Collapsed' })
}
function Start-CalendarLoad([switch]$Refresh) {
    Start-Work $(if ($Refresh) { 'Refreshing airing info' } else { 'Loading calendar' }) {
        param($lib, $mm, $refresh)
        [pscustomobject]@{ Rows = @(Get-CalendarEpisodes $lib $mm -Refresh:$refresh) }
    } @($script:Lib, $script:MatchMap, [bool]$Refresh) {
        param($res, $err, $wasRefresh)
        if ($err) { Set-Status "Calendar: $err" }
        if ($res -and $res.Count) { $script:CalRows = @($res[0].Rows | Where-Object { $_ }) }
        $script:CalLoaded = $true
        if ($wasRefresh) { $script:Index = Import-SeriesIndex; $script:CalRefreshedThisRun = $true }
        if ($ui.tabMain.SelectedItem -eq $ui.tCalendar) { Refresh-CalendarView }
        # first visit: show what's cached straight away, then quietly bring airing info up to date
        if (-not $wasRefresh -and -not $script:CalRefreshedThisRun -and -not $script:BusyGroups['info']) { Start-CalendarLoad -Refresh }
    } $(if ($Refresh) { 'info' } else { '' }) ([bool]$Refresh) | Out-Null
}

# ---------- cast page ----------
$ui.cmbCastFilter.ItemsSource = @('Everyone', 'In 2 or more of my shows', 'Main cast only (top 6 per show)')
$ui.cmbCastFilter.SelectedIndex = 0
$ui.cmbCastSort.ItemsSource = @('Most shows first', 'First name A-Z', 'Surname A-Z')
$ui.cmbCastSort.SelectedIndex = 0

function Build-CastIndex {
    $people = @{}
    $stale = New-Object System.Collections.Generic.List[int]
    foreach ($show in $script:Lib.Values) {
        $iid = Get-ShowInfoId $show; if ($iid -le 0) { continue }
        $info = Get-SeriesInfo $iid -CacheOnly; if (-not $info) { continue }
        $list = @($info.Cast | Where-Object { $_ })
        if ($list.Count -gt 0 -and -not ($list[0].PSObject.Properties.Name -contains 'PersonId')) { $stale.Add($iid) }
        $order = 0
        foreach ($c in $list) {
            $order++
            if (-not $c.Name) { continue }
            $key = Get-PersonKey $c
            $e = $people[$key]
            if (-not $e) {
                $perId = 0; try { $perId = [int]$c.PersonId } catch {}
                $e = [pscustomobject]@{ Key = $key; PersonId = $perId; Name = "$($c.Name)"; Image = "$($c.Image)"; Shows = (New-Object System.Collections.Generic.List[object]); BestOrder = 999 }
                $people[$key] = $e
            }
            if (-not $e.Image -and $c.Image) { $e.Image = "$($c.Image)" }
            if ($order -lt $e.BestOrder) { $e.BestOrder = $order }
            if (-not ($e.Shows | Where-Object { $_.Folder -eq $show.Folder })) { $e.Shows.Add([pscustomobject]@{ Folder = $show.Folder; Role = "$($c.Role)" }) }
        }
    }
    $script:People = $people
    $script:CastStale = @($stale | Sort-Object -Unique)
    $script:PeopleDirty = $false
}

function Refresh-CastWall {
    if ($script:PeopleDirty) { Build-CastIndex }
    $q = $ui.txtCastSearch.Text.Trim().ToLowerInvariant()
    $f = $ui.cmbCastFilter.SelectedIndex
    $items = New-Object System.Collections.Generic.List[object]
    $needPhotos = New-Object System.Collections.Generic.List[object]
    foreach ($e in $script:People.Values) {
        if ($f -eq 1 -and $e.Shows.Count -lt 2) { continue }
        if ($f -eq 2 -and $e.BestOrder -gt 6) { continue }
        if ($q) {
            $hay = ($e.Name + ' ' + (($e.Shows | ForEach-Object { "$($_.Role) $($_.Folder)" }) -join ' ')).ToLowerInvariant()
            if ($hay -notlike "*$q*") { continue }
        }
        $pp = Get-PersonPhotoPath $e.Image
        if ($e.Image -and -not (Test-Path -LiteralPath $pp) -and -not $script:CastPhotosAsked.ContainsKey($pp)) { $needPhotos.Add(@($e.Image, $pp)); $script:CastPhotosAsked[$pp] = $true }
        if ($e.Shows.Count -eq 1) { $sub = $e.Shows[0].Folder; if ($e.Shows[0].Role) { $sub = "$($e.Shows[0].Role) $DOT $sub" } } else { $sub = "$($e.Shows.Count) of your shows" }
        $tip = $e.Name + "`n" + (($e.Shows | ForEach-Object { if ($_.Role) { "$($_.Folder) - as $($_.Role)" } else { $_.Folder } }) -join "`n")
        $parts = $e.Name -split '\s+'
        $items.Add([pscustomobject]@{ Key = $e.Key; Name = $e.Name; Sub = $sub; Tip = $tip; Initials = (Get-Initials $e.Name); Photo = [Windows.Media.ImageSource](Get-CachedBitmap $pp 140)
            Count = $e.Shows.Count; Surname = $parts[-1] + ' ' + $e.Name; Order = $e.BestOrder })
    }
    switch ($ui.cmbCastSort.SelectedIndex) {
        1 { $sorted = @($items | Sort-Object Name) }
        2 { $sorted = @($items | Sort-Object Surname) }
        default { $sorted = @($items | Sort-Object @{ Expression = 'Count'; Descending = $true }, Order, Name) }
    }
    $ui.icPeople.ItemsSource = $sorted
    $ui.txtCastCount.Text = "$($sorted.Count) of $($script:People.Count) people"
    if ($script:People.Count -eq 0) {
        $ui.txtCastEmpty.Text = 'No cast yet. Cast comes from TVmaze once your shows are matched - open a few shows or use Utilities > Refresh all show info.'
        $ui.txtCastEmpty.Visibility = 'Visible'
    } elseif ($sorted.Count -eq 0) { $ui.txtCastEmpty.Text = 'Nobody matches that search.'; $ui.txtCastEmpty.Visibility = 'Visible' }
    else { $ui.txtCastEmpty.Visibility = 'Collapsed' }
    if ($needPhotos.Count -gt 0) {
        Start-Work "Fetching $($needPhotos.Count) cast photo(s)" { param($list) $i = 0; foreach ($p in $list) { $i++; Set-Progress ("Cast photos {0}/{1}" -f $i, $list.Count) ($i / $list.Count * 100); Save-WebFile $p[0] $p[1] | Out-Null } } @(, $needPhotos.ToArray()) {
            param($res, $err)
            if ($ui.tabMain.SelectedItem -eq $ui.tCast) { Refresh-CastWall }
        } 'castphotos' | Out-Null
    }
}

function Start-CastUpgrade {
    # Older show info didn't keep TVmaze person ids - fetch it again once so every face can be opened
    if ($script:CastStale.Count -eq 0 -or $script:BusyGroups['info']) { return }
    $ids = @($script:CastStale)
    Start-Work "Updating cast details for $($ids.Count) show(s)" {
        param($ids) $i = 0
        foreach ($id in $ids) { $i++; Set-Progress ("Cast details {0}/{1}" -f $i, $ids.Count) ($i / $ids.Count * 100); try { Get-SeriesInfo $id -Force | Out-Null } catch {} }
        Set-Progress 'Cast details up to date' 100
    } @(, $ids) {
        param($res, $err)
        $script:PeopleDirty = $true
        $script:Index = Import-SeriesIndex
        if ($ui.tabMain.SelectedItem -eq $ui.tCast) {
            Refresh-CastWall
            # carry the open person over to their new key
            if ($script:CurrentPersonKey -and $script:CurrentPersonKey.StartsWith('n:')) {
                $hit = @($script:People.Values | Where-Object { $_.Name.ToLowerInvariant() -eq $script:CurrentPersonKey.Substring(2) } | Select-Object -First 1)
                if ($hit) { $script:CurrentPersonKey = $hit[0].Key }
            }
        }
    } 'info' | Out-Null
}

function Refresh-CastPage { Refresh-CastWall; Start-CastUpgrade }

function Format-Age([string]$from, [string]$to) {
    try {
        $a = [datetime]::ParseExact($from.Substring(0, 10), 'yyyy-MM-dd', $null)
        $b = $(if ($to) { [datetime]::ParseExact($to.Substring(0, 10), 'yyyy-MM-dd', $null) } else { (Get-Date).Date })
        $n = $b.Year - $a.Year; if ($b.DayOfYear -lt $a.DayOfYear) { $n-- }
        return $n
    } catch { return $null }
}

function Open-Person([string]$Key, [string]$ReturnFolder = $null, [string]$FallbackName = '', [string]$FallbackImage = '') {
    if ($script:PeopleDirty) { Build-CastIndex }
    $e = $script:People[$Key]
    if (-not $e) {
        $perId = 0; if ($Key -like 'p*') { [void][int]::TryParse($Key.Substring(1), [ref]$perId) }
        $e = [pscustomobject]@{ Key = $Key; PersonId = $perId; Name = $FallbackName; Image = $FallbackImage; Shows = (New-Object System.Collections.Generic.List[object]); BestOrder = 999 }
    }
    $script:CurrentPersonKey = $Key
    $script:PersonReturn = $ReturnFolder
    if ($ui.tabMain.SelectedItem -ne $ui.tCast) { $script:SkipCastRefresh = $true; $ui.tabMain.SelectedItem = $ui.tCast; $script:SkipCastRefresh = $false; Refresh-CastWall }
    $ui.bdPerson.Visibility = 'Visible'
    $ui.txtPersonName.Text = $e.Name
    $ui.txtPersonInitials.Text = Get-Initials $e.Name
    $ui.txtPersonMeta.Text = 'Getting details from TVmaze...'
    $ui.txtPersonMeta2.Text = ''
    $ui.txtPersonSummary.Text = $(if ($e.Shows.Count -gt 1) { "In $($e.Shows.Count) of your shows" } else { '' })
    $big = $(if ($e.PersonId -gt 0) { Join-Path $DataDir "Cache\people-large\$($e.PersonId).jpg" } else { '' })
    $img = $null
    if ($big -and (Test-Path -LiteralPath $big)) { $img = [Windows.Media.ImageSource](Get-Bitmap $big 320) }
    if (-not $img) { $img = [Windows.Media.ImageSource](Get-Bitmap (Get-PersonPhotoPath $e.Image) 320) }
    $ui.imgPerson.Source = $img
    if ($ReturnFolder) { $ui.btnPersonBack.Content = "$([char]0x2190)  Back to $ReturnFolder"; $ui.btnPersonBack.Visibility = 'Visible' } else { $ui.btnPersonBack.Visibility = 'Collapsed' }
    $ui.btnPersonTvmaze.Tag = $null
    $shows = foreach ($s in $e.Shows) {
        $show = $script:Lib[$s.Folder]
        $pp = $null; if ($show) { $pp = Get-ShowPosterPath $show }
        [pscustomobject]@{ Folder = $s.Folder; Title = $s.Folder; Role = $s.Role; Tip = "$($s.Folder)$(if ($s.Role) { "`nas $($s.Role)" })`nClick to open"; Poster = [Windows.Media.ImageSource](Get-CachedBitmap $pp 220) }
    }
    $ui.icPersonShows.ItemsSource = @($shows)
    $ui.txtPersonLibHead.Visibility = $(if (@($shows).Count) { 'Visible' } else { 'Collapsed' })
    $ui.dgCredits.ItemsSource = @()
    $ui.txtOtherHead.Text = 'Other TV'
    $ui.bdPersonBio.Visibility = 'Collapsed'; $ui.txtPersonBio.Text = ''
    Start-Work "Getting details for $($e.Name)" { param($id, $name) [pscustomobject]@{ P = (Get-PersonFull $id $name) } } @([int]$e.PersonId, "$($e.Name)") {
        param($res, $err, $key)
        if ($script:CurrentPersonKey -ne $key) { return }
        if ($err -or -not $res -or -not $res[0].P) { $ui.txtPersonMeta.Text = "Couldn't get details from TVmaze. $err"; return }
        Show-PersonDetails $res[0].P
    } '' $Key | Out-Null
}

function Show-PersonDetails($p) {
    $script:CurrentPersonInfo = $p
    $e = $script:People[$script:CurrentPersonKey]; if ($e -and $e.PersonId -le 0) { $e.PersonId = [int]$p.Id }
    if ($p.Name) { $ui.txtPersonName.Text = $p.Name }
    $big = Join-Path $DataDir "Cache\people-large\$($p.Id).jpg"
    if (Test-Path -LiteralPath $big) { $bi = [Windows.Media.ImageSource](Get-Bitmap $big 320); if ($bi) { $ui.imgPerson.Source = $bi } }
    $meta = @()
    if ($p.Birthday) {
        $b = "Born $(Format-Date $p.Birthday)"
        if (-not $p.Deathday) { $age = Format-Age $p.Birthday ''; if ($null -ne $age) { $b += " (age $age)" } }
        $meta += $b
    }
    if ($p.Deathday) { $d = "Died $(Format-Date $p.Deathday)"; $age = Format-Age $p.Birthday $p.Deathday; if ($p.Birthday -and $null -ne $age) { $d += " (aged $age)" }; $meta += $d }
    $ui.txtPersonMeta.Text = $(if ($meta) { $meta -join "  $DOT  " } else { 'No birth date on TVmaze' })
    $m2 = @(); if ($p.Country) { $m2 += $p.Country }; if ($p.Gender) { $m2 += $p.Gender }
    $aka = @($p.AlsoKnownAs | Where-Object { $_ })
    $sl = @()
    if ($e -and $e.Shows.Count -gt 1) { $sl += "In $($e.Shows.Count) of your shows" }
    if ($aka.Count) { $sl += "Also known as $($aka -join ', ')" }
    $ui.txtPersonSummary.Text = $sl -join "`n"
    if ("$($p.Bio)".Trim()) {
        $ui.txtPersonBio.Text = "$($p.Bio)".Trim()
        $ui.bdPersonBio.Visibility = 'Visible'
        $ui.svPersonBio.MaxHeight = 96; $ui.svPersonBio.VerticalScrollBarVisibility = 'Disabled'; $ui.btnPersonBioMore.Content = 'Show more'
        $ui.btnPersonBioMore.Visibility = $(if ($ui.txtPersonBio.Text.Length -gt 330) { 'Visible' } else { 'Collapsed' })
    } else { $ui.bdPersonBio.Visibility = 'Collapsed' }
    $credits = @($p.Credits | Where-Object { $_ })
    $m2 += "$($credits.Count) TV credit$(if ($credits.Count -ne 1) { 's' }) on TVmaze"
    $ui.txtPersonMeta2.Text = $m2 -join "  $DOT  "
    $ui.btnPersonTvmaze.Tag = "$($p.Url)"
    $libIds = @{}; foreach ($mm in $script:MatchMap.Values) { if ($mm.Id -gt 0) { $libIds[[int]$mm.Id] = $true } }
    $other = @($credits | Where-Object { -not $libIds.ContainsKey([int]$_.ShowId) } | ForEach-Object {
        [pscustomobject]@{ Show = $_.Show; Character = $_.Character; Years = $(if ($_.Years) { $_.Years } else { $_.Year }); Network = $_.Network; Url = $_.Url } })
    $ui.dgCredits.ItemsSource = $other
    $ui.txtOtherHead.Text = $(if ($other.Count) { "Other TV  ($($other.Count))" } else { 'Other TV  (nothing else listed)' })
}

# ---------- missing ----------
function Refresh-MissingGrid {
    $flt = $ui.txtMissFilter.Text.Trim().ToLowerInvariant()
    $rows = @($script:MissingRows | Where-Object { -not $flt -or $_.Show.ToLowerInvariant() -like "*$flt*" })
    $ui.dgMissing.ItemsSource = $rows
    $showsN = @($rows | Select-Object -ExpandProperty Folder -Unique).Count
    $ui.txtMissSummary.Text = "$($rows.Count) missing episode(s) across $showsN show(s)"
}
function Start-MissingCheck {
    $TVT.Settings.MissOwned = [bool]$ui.chkMissOwned.IsChecked
    $TVT.Settings.MissSpecials = [bool]$ui.chkMissSpecials.IsChecked
    $TVT.Settings.MissContinuing = [bool]$ui.chkMissContinuing.IsChecked
    Save-Settings
    $unmatched = @($script:Lib.Values | Where-Object { (Get-ShowInfoId $_) -le 0 }).Count
    Start-Work 'Checking for missing episodes' {
        param($lib, $mm, $owned, $specials, $cont, $ignore)
        Get-MissingEpisodes $lib $mm -Specials:$specials -OwnedSeasonsOnly:$owned -ContinuingOnly:$cont -IgnoreShows $ignore
    } @($script:Lib, $script:MatchMap, $TVT.Settings.MissOwned, $TVT.Settings.MissSpecials, $TVT.Settings.MissContinuing, @($TVT.Settings.IgnoreMissing)) {
        param($res, $err, $unmatched)
        if ($err) { Set-Status "Missing check: $err" }
        $script:MissingRows = @($res | Where-Object { $_ } | Sort-Object Show, S, E)
        $script:MissingChecked = $true
        Refresh-MissingGrid
        $script:Index = Import-SeriesIndex; $script:PeopleDirty = $true
        if ($unmatched -gt 0) { Set-Status "Missing check done. $unmatched show(s) aren't matched yet and were skipped." } else { Set-Status 'Missing check done.' }
    } 'info' $unmatched | Out-Null
}

# ---------- filenames ----------
$script:NameRows = @()
function Refresh-NamesGrid {
    $rows = @($script:NameRows | Where-Object { -not ($ui.chkNamesHideFormat.IsChecked -and $_.Issue -eq 'Formatting differs') })
    $ui.dgNames.ItemsSource = $rows
    $canFix = @($rows | Where-Object { $_.Proposed }).Count
    $ui.txtNamesSummary.Text = "$($rows.Count) file(s) flagged, $canFix can be renamed automatically"
}
function Start-NamesCheck {
    Start-Work 'Checking file names' {
        param($lib, $mm, $titles)
        Get-FilenameIssues $lib $mm -CheckTitles:$titles
    } @($script:Lib, $script:MatchMap, [bool]$ui.chkNamesTitles.IsChecked) {
        param($res, $err)
        if ($err) { Set-Status "Name check: $err" }
        $script:NameRows = @($res | Where-Object { $_ })
        Refresh-NamesGrid
        Set-Status 'Name check done.'
    } 'info' | Out-Null
}

# ---------- duplicates ----------
function Refresh-Dupes {
    $d = @(Get-Duplicates $script:Lib)
    $ui.dgDupes.ItemsSource = $d
    $eps = @($d | ForEach-Object { "$($_.Show)|$($_.Ep)" } | Sort-Object -Unique).Count
    $ui.txtDupes.Text = "$eps episode(s) have more than one file. Biggest copy first. Resolution is read from the video files."
    $ui.dgQuality.ItemsSource = @(Get-QualitySummary $script:Lib)
}


# ---------- dialogs ----------
$MatchXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Choose the show" Width="760" Height="560" WindowStartupLocation="CenterOwner" Background="#101318" Foreground="#E9ECF2" FontFamily="Segoe UI" FontSize="13" ResizeMode="CanResizeWithGrip">
    <Window.Resources>
<!--THEME-->
    </Window.Resources>
    <Grid Margin="20">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <TextBlock x:Name="txtHead" Style="{StaticResource H2}" TextWrapping="Wrap"/>
        <DockPanel Grid.Row="1" Margin="0,0,0,10">
            <Button x:Name="btnGo" DockPanel.Dock="Right" Content="Search" Style="{StaticResource AccentButton}" Margin="8,0,0,0" IsDefault="True"/>
            <TextBox x:Name="txtQuery"/>
        </DockPanel>
        <DataGrid Grid.Row="2" x:Name="dgRes" SelectionMode="Single">
            <DataGrid.Columns>
                <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="2*"/>
                <DataGridTextColumn Header="Year" Binding="{Binding Year}" Width="60"/>
                <DataGridTextColumn Header="Network" Binding="{Binding Network}" Width="*"/>
                <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="90"/>
            </DataGrid.Columns>
        </DataGrid>
        <Grid Grid.Row="3" Margin="0,12,0,0">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <TextBlock x:Name="txtOverview" Style="{StaticResource Hint}" MaxHeight="64" Margin="0,0,12,0"/>
            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Bottom">
                <Button x:Name="btnOk" Content="Use this show" Style="{StaticResource AccentButton}" IsEnabled="False"/>
                <Button x:Name="btnCancel" Content="Cancel" Margin="0" IsCancel="True"/>
            </StackPanel>
        </Grid>
    </Grid>
</Window>
'@
function Show-ShowPicker([string]$Heading, [string]$Query, [string]$OkText = 'Use this show') {
    $d = New-Window $MatchXaml
    $w = $d.Window; $u = $d.UI
    $w.Owner = $Win
    $u.txtHead.Text = $Heading
    $u.txtQuery.Text = $Query
    $u.btnOk.Content = $OkText
    $script:PickerResult = $null
    $doSearch = {
        $u.txtOverview.Text = 'Searching TVmaze...'
        $w.Cursor = [Windows.Input.Cursors]::Wait
        try { $u.dgRes.ItemsSource = @(Search-Shows $u.txtQuery.Text.Trim()); $u.txtOverview.Text = "$(@($u.dgRes.ItemsSource).Count) result(s)" }
        catch { $u.txtOverview.Text = "Search failed: $($_.Exception.Message)" }
        $w.Cursor = $null
    }
    $u.btnGo.Add_Click($doSearch)
    $u.dgRes.Add_SelectionChanged({ $r = $u.dgRes.SelectedItem; $u.btnOk.IsEnabled = [bool]$r; if ($r) { $u.txtOverview.Text = $r.Overview } })
    $u.dgRes.Add_MouseDoubleClick({ if ($u.dgRes.SelectedItem) { $script:PickerResult = $u.dgRes.SelectedItem; $w.DialogResult = $true } })
    $u.btnOk.Add_Click({ $script:PickerResult = $u.dgRes.SelectedItem; $w.DialogResult = $true })
    $w.Add_ContentRendered({ & $doSearch })
    [void]$w.ShowDialog()
    return $script:PickerResult
}

function Fix-Match($show) {
    $r = Show-ShowPicker "Which show is the folder '$($show.Folder)'?" $show.Name
    if (-not $r) { return }
    $script:MatchMap[$show.Folder] = [pscustomobject]@{ Id = [int]$r.Id; How = 'manual'; Tvdb = [int]$r.Tvdb }
    Save-Matches $script:MatchMap
    Start-Work 'Fetching show info' { param($id) Get-SeriesInfo $id -Force | Out-Null } @([int]$r.Id) {
        param($res, $err, $folder)
        $script:Index = Import-SeriesIndex; $script:PeopleDirty = $true
        $script:BitmapCache = @{}
        Refresh-Library
        if ($script:CurrentShow -and $script:CurrentShow.Folder -eq $folder) { Open-Show $folder }
        if ($err) { Set-Status "Show info: $err" }
    } 'info' $show.Folder | Out-Null
}

# ---------- events: header / library ----------
$SearchAccent = $Win.FindResource('Accent'); $SearchLine = $Win.FindResource('Line'); $SearchSub = $Win.FindResource('Sub')
function Update-SearchBox {
    $has = [bool]$ui.txtSearch.Text
    $focused = $ui.txtSearch.IsKeyboardFocused
    $ui.txtSearchHint.Visibility = $(if ($has) { 'Collapsed' } else { 'Visible' })
    $ui.btnSearchClear.Visibility = $(if ($has) { 'Visible' } else { 'Collapsed' })
    $ui.bdSearchKey.Visibility = $(if ($has -or $focused) { 'Collapsed' } else { 'Visible' })
    $ui.bdSearch.BorderBrush = $(if ($focused) { $SearchAccent } else { $SearchLine })
    $ib = $(if ($focused -or $has) { $SearchAccent } else { $SearchSub })
    $ui.elSearchIcon.Stroke = $ib; $ui.lnSearchIcon.Stroke = $ib
    if ($has) {
        $n = @($ui.icShows.ItemsSource).Count
        $ui.txtSearchCount.Text = "$n match$(if ($n -ne 1) { 'es' })"; $ui.txtSearchCount.Visibility = 'Visible'
    } else { $ui.txtSearchCount.Visibility = 'Collapsed' }
}
$ui.txtSearch.Add_TextChanged({
    if ($ui.tabMain.SelectedItem -ne $ui.tLibrary -and $ui.txtSearch.Text) { $ui.tabMain.SelectedItem = $ui.tLibrary }
    Refresh-Library
    Update-SearchBox
})
$ui.txtSearch.Add_GotKeyboardFocus({ Update-SearchBox })
$ui.txtSearch.Add_LostKeyboardFocus({ Update-SearchBox })
$ui.txtSearch.Add_PreviewKeyDown({
    param($sender, $e)
    if ($e.Key -eq 'Escape') { if ($ui.txtSearch.Text) { $ui.txtSearch.Clear() } else { [void]$ui.svShows.Focus() }; $e.Handled = $true }
    elseif ($e.Key -eq 'Return') {
        $first = @($ui.icShows.ItemsSource | Select-Object -First 1)
        if ($first -and @($ui.icShows.ItemsSource).Count -eq 1) { Open-Show $first[0].Folder }
        $e.Handled = $true
    }
})
$ui.bdSearch.Add_MouseLeftButtonDown({ [void]$ui.txtSearch.Focus() })
$ui.btnSearchClear.Add_Click({ $ui.txtSearch.Clear(); [void]$ui.txtSearch.Focus() })
$ui.btnScan.Add_Click({ Start-Scan })
$ui.btnCalIcs.Add_Click({ Export-CalendarIcs })
$ui.icHeadStats.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler]{
    param($sender, $e)
    $b = $e.OriginalSource; if ($b -isnot [Windows.Controls.Button] -or -not $b.Tag) { return }
    $tab = $ui[[string]$b.Tag]; if ($tab) { $ui.tabMain.SelectedItem = $tab }
})
$ui.btnViewPosters.Add_Click({ Set-LibView 'posters' })
$ui.btnViewList.Add_Click({ Set-LibView 'list' })
$script:LibSortKey = ''; $script:LibSortDesc = $false
function Sort-LibList([string]$key, [bool]$desc) {
    $items = $ui.dgLibList.ItemsSource
    if (-not $key -or -not $items) { return }
    $sorted = @($items | Sort-Object -Property @{ Expression = { $_.$key }; Descending = $desc }, @{ Expression = { $_.SortName }; Descending = $false })
    $ui.dgLibList.ItemsSource = $sorted
    foreach ($c in $ui.dgLibList.Columns) {
        if ($c.SortMemberPath -eq $key) { $c.SortDirection = $(if ($desc) { [ComponentModel.ListSortDirection]::Descending } else { [ComponentModel.ListSortDirection]::Ascending }) } else { $c.SortDirection = $null }
    }
}
$ui.dgLibList.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler]{
    param($sender, $e)
    $h = $e.OriginalSource
    if ($h -isnot [Windows.Controls.Primitives.DataGridColumnHeader] -or -not $h.Column) { return }
    $key = $h.Column.SortMemberPath; if (-not $key) { return }
    # first click: biggest/newest first for numbers and dates, A-Z for text
    if ($script:LibSortKey -eq $key) { $script:LibSortDesc = -not $script:LibSortDesc } else { $script:LibSortKey = $key; $script:LibSortDesc = ($key -in @('Size', 'Eps', 'SeasonsN', 'Newest', 'NewCount')) }
    Sort-LibList $script:LibSortKey $script:LibSortDesc
    $e.Handled = $true
})
$ui.dgLibList.Add_Sorting({ param($sender, $e) $e.Handled = $true })
$ui.dgLibList.Add_SelectionChanged({ $r = $ui.dgLibList.SelectedItem; if ($r) { Open-Show $r.Folder } })
Set-LibView $(if ("$($TVT.Settings.LibView)" -eq 'list') { 'list' } else { 'posters' })
$ui.cmbLibFilter.Add_SelectionChanged({ $TVT.Settings.LibFilter = $ui.cmbLibFilter.SelectedIndex; Refresh-Library })
$ui.cmbLibSort.Add_SelectionChanged({ $TVT.Settings.LibSort = $ui.cmbLibSort.SelectedIndex; Refresh-Library })
$ui.icShows.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler]{
    param($sender, $e)
    $b = $e.OriginalSource
    if ($b -and $b.Tag) { Open-Show ([string]$b.Tag) }
})
$ui.btnCloseDetail.Add_Click({ Close-Show })
$ui.lbSeasons.Add_SelectionChanged({ Fill-Episodes })
$ui.dgEpisodes.Add_SelectionChanged({ $r = $ui.dgEpisodes.SelectedItem; if ($r) { $ui.txtEpOverview.Text = $r.Overview } })
$ui.dgEpisodes.Add_MouseDoubleClick({ $r = $ui.dgEpisodes.SelectedItem; if ($r -and $r.Path) { Play-File $script:CurrentShow $r.S $r.E $r.Path; Refresh-ShowViews } })
$ui.btnShowFolder.Add_Click({ if ($script:CurrentShow) { Open-InExplorer $script:CurrentShow.Path } })
$ui.btnShowMatch.Add_Click({ if ($script:CurrentShow) { Fix-Match $script:CurrentShow } })
$ui.btnShowConfirm.Add_Click({
    $show = $script:CurrentShow; if (-not $show) { return }
    $m = $script:MatchMap[$show.Folder]; if (-not $m) { return }
    $script:MatchMap[$show.Folder] = [pscustomobject]@{ Id = [int]$m.Id; How = 'confirmed'; Tvdb = [int]$m.Tvdb }
    Save-Matches $script:MatchMap
    Set-Status "Match confirmed for $($show.Folder)."
    Open-Show $show.Folder -Keep
    Refresh-Library
})
$ui.btnShowRefresh.Add_Click({
    $show = $script:CurrentShow; if (-not $show) { return }
    $id = Get-ShowInfoId $show; if ($id -le 0) { Fix-Match $show; return }
    Start-Work 'Refreshing show info' { param($id) Get-SeriesInfo $id -Force | Out-Null } @($id) {
        param($res, $err, $folder)
        $script:BitmapCache = @{}
        $script:Index = Import-SeriesIndex; $script:PeopleDirty = $true
        if ($err) { Set-Status "Show info: $err" } else { Set-Status 'Show info refreshed.' }
        if ($script:CurrentShow -and $script:CurrentShow.Folder -eq $folder) { Open-Show $folder }
        Refresh-Library
    } 'info' $show.Folder | Out-Null
})
$ui.btnEpPlay.Add_Click({ $r = $ui.dgEpisodes.SelectedItem; if ($r -and $r.Path) { Play-File $script:CurrentShow $r.S $r.E $r.Path; Refresh-ShowViews } elseif ($r) { Show-Msg "That episode isn't on disk." } })
$ui.btnEpOpen.Add_Click({ $r = $ui.dgEpisodes.SelectedItem; if ($r -and $r.Path) { Open-InExplorer $r.Path } elseif ($script:CurrentShow) { Open-InExplorer $script:CurrentShow.Path } })

# ---------- events: new page ----------
$ui.cmbNewRange.Add_SelectionChanged({ Refresh-NewPage })
$ui.btnNewPlay.Add_Click({ $r = $ui.dgNew.SelectedItem; if ($r) { Play-File $script:Lib[$r.Folder] $r.S $r.E $r.Path; Refresh-ShowViews } })
$ui.dgNew.Add_MouseDoubleClick({ $r = $ui.dgNew.SelectedItem; if ($r) { Play-File $script:Lib[$r.Folder] $r.S $r.E $r.Path; Refresh-ShowViews } })
$ui.btnNewDismiss.Add_Click({
    $rows = @($ui.dgNew.SelectedItems); if (-not $rows) { Show-Msg 'Select one or more episodes first.'; return }
    foreach ($r in $rows) { $script:Dismissed["$($r.Folder)|$($r.S)|$($r.E)"] = $true }
    Save-Dismissed
    Refresh-ShowViews
})
$ui.btnNewGo.Add_Click({ $r = $ui.dgNew.SelectedItem; if ($r) { $ui.tabMain.SelectedItem = $ui.tLibrary; Open-Show $r.Folder } })
$ui.btnNewOpen.Add_Click({ $r = $ui.dgNew.SelectedItem; if ($r) { Open-InExplorer $r.Path } })

# ---------- events: stats / about ----------
$ui.btnStatsRefresh.Add_Click({ Refresh-Stats })
$Win.AddHandler([Windows.Documents.Hyperlink]::RequestNavigateEvent, [Windows.Navigation.RequestNavigateEventHandler]{
    param($sender, $e)
    $u = "$($e.Uri)"
    if ($u -match '^https://') { try { Start-Process $u } catch {} }
    $e.Handled = $true
})

# ---------- events: calendar ----------
$ui.btnCalPrev.Add_Click({ $script:CalOffset--; Refresh-CalendarView })
$ui.btnCalNext.Add_Click({ $script:CalOffset++; Refresh-CalendarView })
$ui.btnCalToday.Add_Click({ $script:CalOffset = 0; Refresh-CalendarView })
$ui.btnCalRefresh.Add_Click({ Start-CalendarLoad -Refresh })
$ui.chkCalHideHave.Add_Click({ Refresh-CalendarView })
foreach ($ic in @($ui.icCalendar, $ui.icCalMissed)) {
    $ic.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler]{
        param($sender, $e)
        $b = $e.OriginalSource
        if ($b -and $b.Tag -and $script:Lib.Contains([string]$b.Tag)) { $ui.tabMain.SelectedItem = $ui.tLibrary; Open-Show ([string]$b.Tag) }
    })
}

# ---------- events: cast ----------
$ui.icCast.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler]{
    param($sender, $e)
    $b = $e.OriginalSource
    if ($b -and $b.Tag) {
        $it = $b.DataContext
        $from = $null; if ($script:CurrentShow) { $from = $script:CurrentShow.Folder }
        Open-Person ([string]$b.Tag) $from "$($it.Name)" "$($it.Url)"
    }
})
$ui.icPeople.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler]{
    param($sender, $e)
    $b = $e.OriginalSource
    if ($b -and $b.Tag) { Open-Person ([string]$b.Tag) $null "$($b.DataContext.Name)" }
})
$ui.icPersonShows.AddHandler([Windows.Controls.Primitives.ButtonBase]::ClickEvent, [Windows.RoutedEventHandler]{
    param($sender, $e)
    $b = $e.OriginalSource
    if ($b -and $b.Tag) { $ui.tabMain.SelectedItem = $ui.tLibrary; Open-Show ([string]$b.Tag) }
})
$ui.btnPersonBack.Add_Click({ if ($script:PersonReturn) { $ui.tabMain.SelectedItem = $ui.tLibrary; Open-Show $script:PersonReturn } })
$ui.btnClosePerson.Add_Click({ $ui.bdPerson.Visibility = 'Collapsed'; $script:CurrentPersonKey = $null })
$ui.btnPersonTvmaze.Add_Click({ $u = "$($ui.btnPersonTvmaze.Tag)"; if ($u -match '^https://www\.tvmaze\.com/') { Start-Process $u } else { Show-Msg 'Still getting details - try again in a moment.' } })
$ui.btnPersonRefresh.Add_Click({
    $k = $script:CurrentPersonKey; if (-not $k) { return }
    $p = $script:CurrentPersonInfo
    if ($p -and $p.Id) { Remove-Item -LiteralPath (Join-Path $DataDir "Cache\people-info\$($p.Id).json") -Force -ErrorAction SilentlyContinue; Remove-Item -LiteralPath (Join-Path $DataDir "Cache\people-large\$($p.Id).jpg") -Force -ErrorAction SilentlyContinue }
    Open-Person $k $script:PersonReturn $ui.txtPersonName.Text
})
$ui.btnPersonBioMore.Add_Click({
    if ($ui.svPersonBio.MaxHeight -lt 1000) { $ui.svPersonBio.MaxHeight = 320; $ui.svPersonBio.VerticalScrollBarVisibility = 'Auto'; $ui.btnPersonBioMore.Content = 'Show less' }
    else { $ui.svPersonBio.MaxHeight = 96; $ui.svPersonBio.VerticalScrollBarVisibility = 'Disabled'; $ui.svPersonBio.ScrollToTop(); $ui.btnPersonBioMore.Content = 'Show more' }
})
$ui.dgCredits.Add_MouseDoubleClick({ $r = $ui.dgCredits.SelectedItem; if ($r -and "$($r.Url)" -match '^https://www\.tvmaze\.com/') { Start-Process $r.Url } })
$ui.txtCastSearch.Add_TextChanged({ $ui.txtCastSearchHint.Visibility = $(if ($ui.txtCastSearch.Text) { 'Collapsed' } else { 'Visible' }); Refresh-CastWall })
$ui.cmbCastFilter.Add_SelectionChanged({ Refresh-CastWall })
$ui.cmbCastSort.Add_SelectionChanged({ Refresh-CastWall })

# ---------- events: coming / missing / names / dupes ----------

$ui.chkMissOwned.IsChecked = [bool]$TVT.Settings.MissOwned
$ui.chkMissSpecials.IsChecked = [bool]$TVT.Settings.MissSpecials
$ui.chkMissContinuing.IsChecked = [bool]$TVT.Settings.MissContinuing
$ui.btnMissRun.Add_Click({ Start-MissingCheck })
$ui.txtMissFilter.Add_TextChanged({ $ui.txtMissFilterHint.Visibility = $(if ($ui.txtMissFilter.Text) { 'Collapsed' } else { 'Visible' }); Refresh-MissingGrid })
$ui.btnMissGo.Add_Click({ $r = $ui.dgMissing.SelectedItem; if ($r) { $ui.tabMain.SelectedItem = $ui.tLibrary; Open-Show $r.Folder } })
$ui.dgMissing.Add_MouseDoubleClick({ $r = $ui.dgMissing.SelectedItem; if ($r) { $ui.tabMain.SelectedItem = $ui.tLibrary; Open-Show $r.Folder } })
$ui.btnMissIgnore.Add_Click({
    $r = $ui.dgMissing.SelectedItem; if (-not $r) { return }
    if (-not (Confirm-Action "Leave '$($r.Show)' out of missing-episode checks from now on?`n`n(You can undo this by removing it from IgnoreMissing in Data\settings.json.)")) { return }
    $TVT.Settings.IgnoreMissing = @($TVT.Settings.IgnoreMissing) + $r.Folder
    Save-Settings
    $script:MissingRows = @($script:MissingRows | Where-Object { $_.Folder -ne $r.Folder })
    Refresh-MissingGrid
})
$ui.btnMissExport.Add_Click({
    if (-not $script:MissingRows) { Show-Msg 'Run a check first.'; return }
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = 'CSV file (*.csv)|*.csv'; $dlg.FileName = "Missing episodes $(Get-Date -Format 'yyyy-MM-dd').csv"
    if ($dlg.ShowDialog($Win)) {
        @($ui.dgMissing.ItemsSource) | Select-Object Show, Ep, Title, Aired | Export-Csv -LiteralPath $dlg.FileName -NoTypeInformation -Encoding UTF8
        Set-Status "Saved $($dlg.FileName)"
    }
})

$ui.btnNamesRun.Add_Click({ Start-NamesCheck })
$ui.chkNamesHideFormat.Add_Click({ Refresh-NamesGrid })
$ui.btnNamesOpen.Add_Click({ $r = $ui.dgNames.SelectedItem; if ($r) { Open-InExplorer $r.Path } })
$ui.btnNamesApply.Add_Click({
    $rows = @($ui.dgNames.SelectedItems | Where-Object { $_.Proposed })
    if (-not $rows) { Show-Msg 'Select rows that have a Rename to name first. (Rows without one need fixing by hand.)'; return }
    $preview = ($rows | Select-Object -First 8 | ForEach-Object { "$([IO.Path]::GetFileName($_.Current))`n   -> $($_.Proposed)" }) -join "`n"
    if ($rows.Count -gt 8) { $preview += "`n...and $($rows.Count - 8) more" }
    if (-not (Confirm-Action "Rename $($rows.Count) file(s)? Subtitles and other files with the same name go with them.`n`n$preview")) { return }
    $log = New-Object System.Collections.Generic.List[string]
    $fails = @()
    foreach ($r in $rows) {
        try { foreach ($l in (Invoke-RenameEpisode $r.Path $r.Proposed)) { $log.Add($l) } } catch { $fails += "$([IO.Path]::GetFileName($r.Path)): $($_.Exception.Message)" }
    }
    if ($log.Count) {
        $script:LastRenameLog = Join-Path $DataDir ("Logs\renames-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.tsv')
        Write-TsvLines $script:LastRenameLog $log.ToArray()
    }
    $done = $rows.Count - $fails.Count
    $msg = "Renamed $done file(s)."
    if ($fails) { $msg += "`n`nCouldn't rename:`n" + ($fails -join "`n") }
    Show-Msg $msg
    $paths = @{}; foreach ($r in $rows) { $paths[$r.Path] = $true }
    $script:NameRows = @($script:NameRows | Where-Object { -not $paths[$_.Path] })
    Refresh-NamesGrid
    Start-Scan
})
$ui.btnNamesUndo.Add_Click({
    $logFile = $script:LastRenameLog
    if (-not $logFile) { $logFile = Get-ChildItem -LiteralPath (Join-Path $DataDir 'Logs') -Filter 'renames-*.tsv' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName }
    if (-not $logFile -or -not (Test-Path -LiteralPath $logFile)) { Show-Msg 'There is no rename batch to undo.'; return }
    $lines = @([IO.File]::ReadAllLines($logFile))
    if (-not (Confirm-Action "Undo the rename batch from $([IO.Path]::GetFileNameWithoutExtension($logFile).Replace('renames-',''))? ($($lines.Count) file(s))")) { return }
    $fails = 0
    [array]::Reverse($lines)
    foreach ($l in $lines) { $p = $l.Split("`t"); try { if (Test-Path -LiteralPath $p[1]) { [IO.File]::Move($p[1], $p[0]) } } catch { $fails++ } }
    Rename-Item -LiteralPath $logFile -NewName ([IO.Path]::GetFileName($logFile) + '.undone') -ErrorAction SilentlyContinue
    $script:LastRenameLog = $null
    Show-Msg $(if ($fails) { "Undone, but $fails file(s) couldn't be put back." } else { 'Rename batch undone.' })
    Start-Scan
})

$ui.btnDupesPlay.Add_Click({ $r = $ui.dgDupes.SelectedItem; if ($r) { Start-Process -FilePath $r.Path } })
$ui.btnDupesOpen.Add_Click({ $r = $ui.dgDupes.SelectedItem; if ($r) { Open-InExplorer $r.Path } })
$ui.btnDupesMove.Add_Click({
    $rows = @($ui.dgDupes.SelectedItems); if (-not $rows) { Show-Msg 'Select the copies you want to move out first.'; return }
    $hold = "$($TVT.Settings.HoldFolder)".Trim()
    if (-not $hold) { Show-Msg 'Set a holding folder in Settings first.'; return }
    if (-not (Confirm-Action "Move $($rows.Count) file(s) into:`n$hold`n`nThey're moved, not deleted - you can delete them from there when you're sure.")) { return }
    $fails = @()
    foreach ($r in $rows) { try { Move-WithSidecars $r.Path (Join-Path $hold $r.Show) } catch { $fails += "$($r.File): $($_.Exception.Message)" } }
    if ($fails) { Show-Msg ("Some files couldn't be moved:`n" + ($fails -join "`n")) 'TV Toolkit' 'Warning' }
    Start-Scan
})

# ---------- events: problem files ----------
$ui.btnProbRun.Add_Click({ Start-ProblemCheck })
$ui.cmbProbType.Add_SelectionChanged({ Refresh-ProblemGrid })
$ui.btnProbOpen.Add_Click({ $r = $ui.dgProblems.SelectedItem; if ($r) { Open-InExplorer $r.Path } })
$ui.btnProbPlay.Add_Click({ $r = $ui.dgProblems.SelectedItem; if ($r -and $r.Kind -eq 'file' -and $script:VideoExt -contains [IO.Path]::GetExtension($r.Path).ToLowerInvariant()) { try { Start-Process -FilePath $r.Path } catch {} } })
$ui.dgProblems.Add_MouseDoubleClick({ $r = $ui.dgProblems.SelectedItem; if ($r) { Open-InExplorer $r.Path } })
$ui.btnProbHold.Add_Click({
    $rows = @($ui.dgProblems.SelectedItems | Where-Object { $_.Kind -eq 'file' })
    if (-not $rows) { Show-Msg 'Select one or more files first (folders are handled by Remove empty folders).'; return }
    $hold = "$($TVT.Settings.HoldFolder)".Trim()
    if (-not $hold) { Show-Msg 'Set a holding folder in Settings first.'; return }
    if (-not (Confirm-Action "Move $($rows.Count) file(s) into:`n$hold`n`nThey're moved, not deleted.")) { return }
    $fails = @(); $done = 0
    foreach ($r in $rows) {
        if (-not (Test-Path -LiteralPath $r.Path)) { continue }
        try { Move-WithSidecars $r.Path (Join-Path $hold $r.Show); $done++ } catch { $fails += "$([IO.Path]::GetFileName($r.Path)): $($_.Exception.Message)" }
    }
    if ($fails) { Show-Msg ("Some files couldn't be moved:`n" + ($fails -join "`n")) 'TV Toolkit' 'Warning' } else { Set-Status "Moved $done file(s) to the holding folder." }
    Start-Scan; Start-ProblemCheck
})
$ui.btnProbSeason.Add_Click({
    $rows = @($ui.dgProblems.SelectedItems | Where-Object { $_.Type -eq 'Not in a season folder' -and $_.Target })
    if (-not $rows) { Show-Msg "Select one or more 'Not in a season folder' rows that say which season they belong in."; return }
    $preview = ($rows | Select-Object -First 8 | ForEach-Object { "$([IO.Path]::GetFileName($_.Path))`n   -> $($_.Target)\" }) -join "`n"
    if (-not (Confirm-Action "Move $($rows.Count) episode(s) into their season folders? Subtitles and other files with the same name go with them.`n`n$preview")) { return }
    $fails = @()
    foreach ($r in $rows) {
        $show = $script:Lib[$r.Folder]; if (-not $show) { continue }
        try { Move-WithSidecars $r.Path (Join-Path $show.Path $r.Target) } catch { $fails += "$([IO.Path]::GetFileName($r.Path)): $($_.Exception.Message)" }
    }
    if ($fails) { Show-Msg ("Some files couldn't be moved:`n" + ($fails -join "`n")) 'TV Toolkit' 'Warning' }
    Start-Scan; Start-ProblemCheck
})
$ui.btnProbEmpty.Add_Click({
    $rows = @($ui.dgProblems.SelectedItems | Where-Object { $_.Kind -eq 'dir' })
    if (-not $rows) { $rows = @($script:ProblemRows | Where-Object { $_.Kind -eq 'dir' }) }
    if (-not $rows) { Show-Msg 'There are no empty folders in the list.'; return }
    if (-not (Confirm-Action "Remove $($rows.Count) empty folder(s)? Only folders that are still completely empty are removed.")) { return }
    $n = 0
    foreach ($r in ($rows | Sort-Object { $_.Path.Length } -Descending)) {
        try { if ((Test-Path -LiteralPath $r.Path) -and @([IO.Directory]::GetFileSystemEntries($r.Path)).Count -eq 0) { [IO.Directory]::Delete($r.Path); $n++ } } catch {}
    }
    Set-Status "Removed $n empty folder(s)."
    Start-ProblemCheck
})

# ---------- events: utilities ----------
function New-Backup([string]$Reason = '') {
    $stage = Join-Path $env:TEMP ("tvt-backup-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    foreach ($f in 'settings.json', 'matches.tsv', 'series-index.tsv', 'new-dismissed.tsv') {
        $p = Join-Path $DataDir $f; if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination $stage }
    }
    $zip = Join-Path $DataDir ("Backups\TVToolkit-backup-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + $Reason + '.zip')
    [IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip)
    Remove-Item -LiteralPath $stage -Recurse -Force
    Get-ChildItem -LiteralPath (Join-Path $DataDir 'Backups') -Filter '*.zip' | Sort-Object Name -Descending | Select-Object -Skip 15 | Remove-Item -Force -ErrorAction SilentlyContinue
    return $zip
}
function Import-DataZip([string]$zipPath) {
    $tmp = Join-Path $env:TEMP ("tvt-restore-" + [guid]::NewGuid().ToString('N'))
    [IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $tmp)
    $n = 0
    foreach ($f in 'settings.json', 'matches.tsv', 'series-index.tsv', 'new-dismissed.tsv') {
        $p = Join-Path $tmp $f; if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination (Join-Path $DataDir $f) -Force; $n++ }
    }
    Remove-Item -LiteralPath $tmp -Recurse -Force
    return $n
}
function Reload-All {
    Load-Settings
    Fill-SettingsForm
    $script:MatchMap = Import-Matches
        $script:Dismissed = @{}
    foreach ($kv in (Read-TsvMap (Join-Path $DataDir 'new-dismissed.tsv')).GetEnumerator()) { $script:Dismissed[$kv.Key] = $true }
    $script:Index = Import-SeriesIndex; $script:PeopleDirty = $true
    $script:TvdbAuth = $null
    Refresh-Library
}
function Update-BackupInfo {
    $last = Get-ChildItem -LiteralPath (Join-Path $DataDir 'Backups') -Filter '*.zip' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
    $ui.txtBackupInfo.Text = $(if ($last) { "Last backup: $($last.LastWriteTime.ToString('d MMM yyyy HH:mm'))" } else { 'No backups yet' })
}
$ui.btnBackup.Add_Click({ try { $z = New-Backup; Update-BackupInfo; Set-Status "Backup saved: $z" } catch { Show-Msg "Backup failed:`n$($_.Exception.Message)" 'TV Toolkit' 'Warning' } })
$ui.btnRestore.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'TV Toolkit backup (*.zip)|*.zip'; $dlg.InitialDirectory = (Join-Path $DataDir 'Backups')
    if (-not $dlg.ShowDialog($Win)) { return }
    if (-not (Confirm-Action "Restore from $([IO.Path]::GetFileName($dlg.FileName))?`n`nYour current settings and matches will be replaced. A backup of them is made first.")) { return }
    try { New-Backup '-before-restore' | Out-Null; $n = Import-DataZip $dlg.FileName; Reload-All; Update-BackupInfo; Show-Msg "Restored $n file(s)." } catch { Show-Msg "Restore failed:`n$($_.Exception.Message)" 'TV Toolkit' 'Warning' }
})
$ui.btnExportSettings.Add_Click({
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = 'TV Toolkit settings (*.zip)|*.zip'; $dlg.FileName = "TV Toolkit settings $(Get-Date -Format 'yyyy-MM-dd').zip"
    if (-not $dlg.ShowDialog($Win)) { return }
    try {
        $z = New-Backup '-export'
        Copy-Item -LiteralPath $z -Destination $dlg.FileName -Force
        Remove-Item -LiteralPath $z -Force
        Show-Msg "Saved. Copy it to the other PC and use Import settings there.`n`n"
    } catch { Show-Msg "Export failed:`n$($_.Exception.Message)" 'TV Toolkit' 'Warning' }
})
$ui.btnImportSettings.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'TV Toolkit settings (*.zip)|*.zip'
    if (-not $dlg.ShowDialog($Win)) { return }
    if (-not (Confirm-Action "Import settings and matches from this file? What's here now is backed up first.")) { return }
    try { New-Backup '-before-import' | Out-Null; Import-DataZip $dlg.FileName | Out-Null; Reload-All; Show-Msg 'Imported. Rescanning the library now.'; Start-Scan } catch { Show-Msg "Import failed:`n$($_.Exception.Message)" 'TV Toolkit' 'Warning' }
})
$ui.btnPrintList.Add_Click({
    if ($script:Lib.Count -eq 0) { Show-Msg 'Scan your library first.'; return }
    $html = New-ShowListHtml $script:Lib $script:MatchMap $script:Index -Episodes:([bool]$ui.chkPrintEps.IsChecked)
    $p = Join-Path $DataDir 'Exports\TV Shows.html'
    [IO.File]::WriteAllText($p, $html, (New-Object Text.UTF8Encoding($false)))
    Start-Process $p
})
$ui.btnOpenData.Add_Click({ Open-InExplorer $DataDir })
$ui.btnRematchAll.Add_Click({ Start-MatchJob })
$ui.btnReadMedia.Add_Click({ Start-MediaProbe -All; Set-Status 'Reading video details from every episode file...' })
$ui.btnRefreshAll.Add_Click({ if (Confirm-Action 'Fetch fresh info for every matched show from TVmaze? This takes a minute or two.') { Start-MatchJob -RefreshAll } })
$ui.btnClearImages.Add_Click({
    if (-not (Confirm-Action 'Delete the cached posters and cast photos? They download again as needed.')) { return }
    Get-ChildItem -LiteralPath (Join-Path $DataDir 'Cache\posters') -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath (Join-Path $DataDir 'Cache\people') -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath (Join-Path $DataDir 'Cache\people-large') -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    foreach ($sub in 'backdrops', 'epthumbs') { Get-ChildItem -LiteralPath (Join-Path $DataDir "Cache\$sub") -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue }
    $script:BackdropAsked = @{}; $script:ThumbAsked = @{}
    $script:CastPhotosAsked = @{}
    $script:BitmapCache = @{}
    Refresh-Library
    Start-MatchJob
})

# ---------- events: settings ----------
function Fill-SettingsForm {
    $s = $TVT.Settings
    $ui.txtRoots.Text = (@($s.Roots) -join "`r`n")
    $ui.txtHold.Text = "$($s.HoldFolder)"
    $ui.txtRefreshDays.Text = "$($s.RefreshDays)"
    $ui.txtNewDays.Text = "$($s.NewDays)"
}
function Read-SettingsForm {
    $s = $TVT.Settings
    $oldRoots = (@($s.Roots) -join '|')
    $s.Roots = @($ui.txtRoots.Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $s.HoldFolder = $ui.txtHold.Text.Trim()
    $d = 3; [void][int]::TryParse($ui.txtRefreshDays.Text, [ref]$d); if ($d -lt 1) { $d = 1 }; $s.RefreshDays = $d
    $nd = 14; [void][int]::TryParse($ui.txtNewDays.Text, [ref]$nd); if ($nd -lt 1) { $nd = 1 }; $s.NewDays = $nd
    return ($oldRoots -ne (@($s.Roots) -join '|'))
}
$ui.btnSaveSettings.Add_Click({
    $rootsChanged = Read-SettingsForm
    Save-Settings
    $ui.txtSettingsSaved.Text = "Saved at $(Get-Date -Format 'HH:mm')"
    Refresh-Library
    Update-NewTabHeader
    if ($rootsChanged -and (Confirm-Action 'Your TV folders changed. Rescan now?')) { Start-Scan }
})
$ui.btnTestTvdb.Add_Click({
    Read-SettingsForm | Out-Null
    $ui.txtTvdbTest.Text = 'Testing...'
    Start-Work 'Testing TVmaze' {
        $r = @(Search-Shows 'Doctor Who')
        $first = ''; if ($r.Count) { $first = " (first: $($r[0].Name) $($r[0].Year))" }
        Write-InfoLog "Test: search 'Doctor Who' -> $($r.Count) result(s)$first"
        "Connected to TVmaze. Test search for Doctor Who found $($r.Count) show(s)$first"
    } @() {
        param($res, $err)
        if ($err) { $ui.txtTvdbTest.Text = "Failed: $err" } else { $ui.txtTvdbTest.Text = "$($res[0])" }
    } | Out-Null
})

# ---------- tab switching ----------
$ui.tabMain.Add_SelectionChanged({
    param($sender, $e)
    if ($e.OriginalSource -ne $ui.tabMain) { return }
    $t = $ui.tabMain.SelectedItem
    if ($t -eq $ui.tNew) { Refresh-NewPage }
    elseif ($t -eq $ui.tCast) { if (-not $script:SkipCastRefresh) { Refresh-CastPage } }
    elseif ($t -eq $ui.tStats) { Refresh-Stats }
    elseif ($t -eq $ui.tProblems) { if (-not $script:ProblemsChecked) { Refresh-ProblemGrid; Start-ProblemCheck } }
    elseif ($t -eq $ui.tCalendar) { Refresh-CalendarView; if (-not $script:CalLoaded -or $script:CalDirty) { $script:CalDirty = $false; Start-CalendarLoad } }
    elseif ($t -eq $ui.tDupes) { Refresh-Dupes }
    elseif ($t -eq $ui.tMissing) { if (-not $script:MissingChecked -and -not $script:BusyGroups['info'] -and $script:Lib.Count) { $script:MissingChecked = $true; Start-MissingCheck } }
    elseif ($t -eq $ui.tUtils) { Update-BackupInfo }
})

# ---------- keyboard ----------
$Win.Add_PreviewKeyDown({
    param($sender, $e)
    if ($e.Key -eq 'F5') { Start-Scan; $e.Handled = $true }
    elseif ($e.Key -eq 'F' -and [Windows.Input.Keyboard]::Modifiers -eq 'Control') { $ui.txtSearch.Focus() | Out-Null; $ui.txtSearch.SelectAll(); $e.Handled = $true }
    elseif ($e.Key -eq 'Escape' -and -not $ui.txtSearch.IsKeyboardFocused -and $ui.tabMain.SelectedItem -eq $ui.tLibrary -and $script:CurrentShow) { Close-Show; $e.Handled = $true }
})

# ---------- about ----------
$ui.txtAboutVersion.Text = "Version $AppVersion  $DOT  PowerShell $($PSVersionTable.PSVersion)"
$ui.txtHeaderVersion.Text = "v$AppVersion"
$Win.Title = "TV Toolkit v$AppVersion"
$ui.txtAboutNew.Text = @"
1.9.0
$DOT  'Since you last opened it' card: when you open TV Toolkit it lists episodes that arrived, shows that came back on TV and episodes that aired that you don't have, with buttons to the New, Missing and Calendar pages.
$DOT  Season complete: a green tick on a poster when you have every aired episode of the show's latest season, a tick on complete season chips, and a Latest season column in the list view.
$DOT  Calendar: Save to my calendar (.ics) exports the next 3 months of your shows' episodes (UK times, channel, length) for Outlook, Google Calendar or your phone.
$DOT  Library: type a letter to jump to the first show starting with it; type it again for the next one, Enter to open.
$DOT  Missing episodes now checks itself the first time you open the page. About page description brought up to date.

1.8.2
$DOT  Top bar: shows, episodes, space used and free space as tidy figures (free space turns amber or red as the drive fills), a green count of new episodes, and when the library was last scanned on a quieter Rescan button. Click any figure to jump to its page.

1.8.1
$DOT  Shows with no episodes yet now say when they start or come back (e.g. 'Back 25 Nov 2026') instead of 'Waiting for episodes', when TVmaze knows the date. Ended shows no longer say they're waiting.
$DOT  Library list: click a column heading to sort, click again to reverse.

1.8.0
$DOT  Stats: a tile for each TV drive showing free space, a used/free bar (amber over 75%, red over 90%) and roughly when it'll be full at the rate episodes have been arriving.
$DOT  New Problem files page: tiny or unreadable episodes, unfinished downloads, sample files, episodes not in a season folder, junk files, subtitles or .nfo files with no episode, and empty folders. Move files to the holding folder, move loose episodes into the right season folder, or remove empty folders.
$DOT  Show panel: the show's backdrop picture fades in behind the top of the panel.
$DOT  Episode pictures: each episode has a still in the episode list and on the New page.
$DOT  Library list view: switch between Posters and a sortable List (channel, status, seasons, episodes, size, quality, newest episode, new, next airing). Your choice is remembered.

1.7.1
$DOT  Tidy-up: removed leftover code from the watched and Medusa features and unused settings. Old settings (Medusa address/key, TheTVDB keys) are cleared from settings.json the next time settings are saved.

1.7.0
$DOT  Medusa removed: no Medusa page, settings, Add to Medusa, search or pick-a-copy buttons. TV Toolkit now just looks after your library.

1.6.2
$DOT  About page: What's new moved into its own panel on the right.

1.6.1
$DOT  Space used is shown as a whole number of GB (header, Stats tile and Biggest shows).

1.6.0
$DOT  Watched tracking removed: no Next up page, no watched buttons, ticks, progress bars or watched stats. 'New' now simply means episodes that arrived recently.
$DOT  Stats bar charts give names more room.

1.5.1
$DOT  Picture quality is now read from inside the video files (resolution and length), so it works without 1080p etc. in the file names. Uses Windows' own video details, with ffprobe as a backup if it's installed. New and changed files are read automatically in the background.
$DOT  Episode lists have a Quality column, Duplicates & quality uses the real resolution, and Stats' viewing time uses real file lengths.
$DOT  Utilities: 'Re-read video details'.

1.5.0
$DOT  New Stats page: shows, episodes, space used, viewing time, how much you've watched, new this week and more - plus charts of episodes added and watched per month, channels, genres, biggest shows, most episodes, picture quality and most watched. Hover any bar for the exact figure.
$DOT  About page now has a Credits section (TVmaze, TheTVDB, Medusa and more) with links.

1.4.3
$DOT  Redesigned search box: rounded, with a search icon, centred text, a highlighted border while typing, a match count, a clear button and a Ctrl+F hint.
$DOT  Search now also matches channels, genres, status and year (try 'BBC', 'Comedy' or 'Ended'). Esc clears it; Enter opens the show when there's only one match.

1.4.2
$DOT  Cast members now show their biography (from their TVmaze page) with Show more / Show less, and any other names they're known by.

1.4.1
$DOT  Coming up page removed - the Calendar covers it. The 'NEW TUE' style badges on the poster wall still show when a new episode airs this week.

1.4.0
$DOT  New Calendar page, like Medusa's schedule: the next 7 days as columns, starting today, with every episode airing from your shows - poster, episode and title, UK air time, channel and running time.
$DOT  Each episode is tagged ON DISK, WATCHED, TODAY, UPCOMING or MISSING. Today's column is highlighted.
$DOT  'Missed in the last 7 days' strip lists aired episodes that aren't on disk - click one to open the show, or send them all to Medusa in one go.
$DOT  Previous / This / Next week buttons, 'Only shows I'm watching' and 'Hide episodes already on disk'. Click any episode to jump to its show.
$DOT  Air times are now saved with each episode and shown in your local time.

1.3.0
$DOT  New Cast page: everyone who appears in your shows, as a wall of faces. Search by name or character, show only people in 2+ of your shows or the main cast, and sort by most shows or name.
$DOT  Click anyone - on the Cast page or the cast row of a show - to see their photo, birthday and age, country, which of your shows they're in (click to jump there) and the rest of their TV work.
$DOT  'Back to show' takes you straight back to the show you came from.

1.2.4
$DOT  Cast photos are framed on the face (cropped from the top) instead of the middle, so heads aren't cut off.

1.2.3
$DOT  Cast photos now actually show (they were downloading fine but weren't being displayed).
$DOT  Start TV Toolkit.cmd logs each launch to Data\Logs\launch.log, and shows an error box if TV Toolkit can't start.

1.2.2
$DOT  A small TV Toolkit splash appears straight away while it starts, so you know it's on its way.
$DOT  Only one copy runs at a time - opening it again just brings the existing window to the front.
$DOT  The window now comes to the front when it opens, instead of sometimes hiding behind other windows.
$DOT  Each start is recorded in Data\Logs\startup.log to help track down any slow or failed starts.

1.2.1
$DOT  Cast now shows each person's photo (it was downloading but only the initials were showing).

1.2.0
$DOT  New page: every episode that arrived recently and you haven't watched, newest first - play, mark watched, or 'Not new' to hide it. The tab shows how many are waiting.
$DOT  Poster wall: green 'N NEW' badge on shows with new unwatched episodes, and '5 unwatched of 13' under shows you've started.
$DOT  Episode list: new episodes are highlighted with a green NEW tag, watched ones ticked, unwatched ones on disk get a dot. Season chips show how many are new.
$DOT  Library filters 'Has new episodes' and 'Has unwatched episodes', and a 'Most new episodes' sort.
$DOT  Settings: choose how many days an episode counts as new (default 14). 'New' uses the date the file arrived on the drive.

1.1.2
$DOT  Version number shown in the header and the window title.

1.1.1
$DOT  Confirm match button: tick off a best-guess match without re-searching.
$DOT  New 'Waiting for episodes' library filter for show folders with nothing in them yet.
$DOT  Extras folders (backdrops, extras, trailers, featurettes...) and theme music are ignored when scanning.
$DOT  'Special 13'-style files in S00/Specials are read as specials (0x13).

1.1.0
$DOT  Show info, posters, cast and episode lists now come from TVmaze - free, no API key needed. (TheTVDB no longer accepts legacy keys.)
$DOT  Each show's TheTVDB id is still picked up from TVmaze, so Medusa works as before.
$DOT  Logging moved to Data\Logs\tvinfo.log.

1.0.1
$DOT  TheTVDB problems are now logged to Data\Logs\tvdb.log, and you're told when matching fails instead of it failing silently.
$DOT  Test TheTVDB now runs a real search as well as logging in.

1.0.0  (first release)
$DOT  Poster wall for every show on your TV drive, with filters (continuing, ended, watching, airing this week) and sorting.
$DOT  Show page with TheTVDB info, cast photos, season chips and an episode list showing what's on disk, missing or upcoming.
$DOT  Watched tracking per episode, 'watched up to here', season watched, and a Next up list of where you left off.
$DOT  Missing episodes check, with options for specials, owned seasons only and continuing shows only.
$DOT  Filename checker for 'Show - 1x01 - Title', with preview, sidecar files renamed too, and undo.
$DOT  Duplicates and quality by show, with a holding folder instead of deleting.
$DOT  Medusa: add shows (you choose the root folder, with a preview), search for missing episodes, or pick the exact copy yourself - English-labelled only, largest first.
$DOT  Backups, restore, moving settings between PCs, and a printable show list.
"@
$ui.txtAboutData.Text = "Everything TV Toolkit keeps is in:`n$DataDir`n`nThe whole TV Toolkit folder is portable - move it anywhere and it keeps working."

# ---------- start ----------
Fill-SettingsForm
$Win.Add_ContentRendered({
    Write-StartLog 'Main window on screen'
    if ($Splash) { try { $Splash.Close() } catch {}; $Splash = $null }
    try { $Win.Activate() | Out-Null; $Win.Topmost = $true; $Win.Topmost = $false } catch {}
    if (Test-Path -LiteralPath (Join-Path $DataDir 'shows.tsv')) {
        Start-LoadLibrary
        $script:AfterLoad = {
            # Fill in anything new since last time (unmatched shows, missing info/posters)
            $need = @($script:Lib.Values | Where-Object { $m = $script:MatchMap[$_.Folder]; -not $m -or ($m.Id -gt 0 -and -not (Test-Path -LiteralPath (Get-SeriesCachePath $m.Id))) }).Count
            if ($need -gt 0) { Start-MatchJob }
        }
    } elseif (@($TVT.Settings.Roots | Where-Object { Test-Path -LiteralPath $_ }).Count -gt 0) {
        Set-Status 'First run: scanning your TV folders...'
        Start-Scan
    } else {
        $ui.spEmpty.Visibility = 'Visible'
        $ui.txtEmpty.Text = "Couldn't reach $(@($TVT.Settings.Roots) -join ', '). Set your TV folder in Settings, then press Rescan library."
        $ui.tabMain.SelectedItem = $ui.tSettings
    }
})
# ---------- jump by letter (Library) ----------
$script:JumpLast = ''; $script:JumpIdx = -1
$Win.Add_PreviewTextInput({
    param($sender, $e)
    if ($ui.tabMain.SelectedItem -ne $ui.tLibrary) { return }
    $f = [Windows.Input.Keyboard]::FocusedElement
    if ($f -is [Windows.Controls.Primitives.TextBoxBase] -or $f -is [Windows.Controls.ComboBox] -or $f -is [Windows.Controls.ComboBoxItem]) { return }
    $ch = "$($e.Text)"; if ($ch.Length -ne 1 -or $ch -notmatch '[A-Za-z0-9]') { return }
    $items = $(if ($ui.dgLibList.Visibility -eq 'Visible') { $ui.dgLibList.ItemsSource } else { $ui.icShows.ItemsSource })
    if (-not $items) { return }
    $list = New-Object System.Collections.Generic.List[object]; foreach ($it in $items) { $list.Add($it) }
    $hits = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $list.Count; $i++) { if ("$($list[$i].Title)".StartsWith($ch, [StringComparison]::OrdinalIgnoreCase)) { $hits.Add($i) } }
    if ($hits.Count -eq 0) { Set-Status "No show starting with '$($ch.ToUpper())'"; $e.Handled = $true; return }
    # pressing the same letter again moves on to the next show with that letter
    if ($script:JumpLast -eq $ch.ToUpper()) { $pos = $hits.IndexOf($script:JumpIdx) + 1; if ($pos -ge $hits.Count) { $pos = 0 } } else { $pos = 0 }
    $idx = $hits[$pos]; $script:JumpLast = $ch.ToUpper(); $script:JumpIdx = $idx
    $item = $list[$idx]
    if ($ui.dgLibList.Visibility -eq 'Visible') {
        $ui.dgLibList.ScrollIntoView($item)
    } else {
        $cp = $ui.icShows.ItemContainerGenerator.ContainerFromIndex($idx)
        if ($cp) {
            $pt = [Windows.Point]::new(0, 0); try { $pt = $cp.TransformToAncestor($ui.svShows).Transform([Windows.Point]::new(0, 0)) } catch {}
            $ui.svShows.ScrollToVerticalOffset([math]::Max(0, $ui.svShows.VerticalOffset + $pt.Y - 8))
            if ([Windows.Media.VisualTreeHelper]::GetChildrenCount($cp) -gt 0) { $btn = [Windows.Media.VisualTreeHelper]::GetChild($cp, 0); try { [void]$btn.Focus() } catch {} }
        }
    }
    Set-Status "$($item.Title)  ($($pos + 1) of $($hits.Count) starting with '$($ch.ToUpper())' - press it again for the next, Enter to open)"
    $e.Handled = $true
})

# ---------- since you last opened it ----------
$script:SessionPath = Join-Path $DataDir 'last-session.json'
$script:PrevSession = $null
try { if (Test-Path -LiteralPath $script:SessionPath) { $script:PrevSession = Get-Content -LiteralPath $script:SessionPath -Raw | ConvertFrom-Json } } catch {}
$script:SinceClosed = $false
function Get-MissingKeySet {
    # Same rules as the Missing episodes page, from saved show info only (no downloads)
    $set = @{}
    $today = Get-Today
    $ignore = @($TVT.Settings.IgnoreMissing)
    foreach ($show in $script:Lib.Values) {
        if ($ignore -contains $show.Folder) { continue }
        $id = Get-ShowInfoId $show; if ($id -le 0) { continue }
        $info = Get-SeriesInfo $id -CacheOnly; if (-not $info -or -not $info.Episodes) { continue }
        if ($TVT.Settings.MissContinuing -and "$($info.Status)" -match 'Ended') { continue }
        foreach ($e in $info.Episodes) {
            if (-not $e) { continue }
            if ([int]$e.S -eq 0 -and -not $TVT.Settings.MissSpecials) { continue }
            if (-not $e.Aired -or "$($e.Aired)" -gt $today) { continue }
            if ($TVT.Settings.MissOwned -and ($show.Seasons -notcontains [int]$e.S)) { continue }
            if (-not $show.EpKeys.ContainsKey("$($e.S)|$($e.E)")) { $set["$($show.Folder)|$($e.S)|$($e.E)"] = $true }
        }
    }
    return $set
}
function Update-SinceCard {
    if ($script:SinceClosed -or -not $script:PrevSession -or -not $script:PrevSession.Time) { return }
    $prev = [datetime]::new([int64]$script:PrevSession.Time, [DateTimeKind]::Utc)
    $prevTicks = $prev.Ticks
    $now = (Get-Date).ToUniversalTime()
    $lines = New-Object System.Collections.Generic.List[object]
    $dot = @{ Good = [Windows.Media.Brush]$Win.FindResource('Good'); Accent = [Windows.Media.Brush]$Win.FindResource('Accent'); Bad = [Windows.Media.Brush]$Win.FindResource('Bad') }
    # 1. episodes that arrived on disk
    $arr = @{}; $nArr = 0
    foreach ($show in $script:Lib.Values) { foreach ($f in $show.Files) { if ($f.Added -gt $prevTicks) { $arr[$show.Folder] = [int]$arr[$show.Folder] + 1; $nArr++ } } }
    if ($nArr -gt 0) {
        $names = @($arr.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { if ($_.Value -gt 1) { "$($_.Key) ($($_.Value))" } else { $_.Key } })
        $more = $(if ($names.Count -gt 4) { ", +$($names.Count - 4) more" } else { '' })
        $lines.Add([pscustomobject]@{ Head = "$nArr new episode$(if ($nArr -ne 1) { 's' }) arrived"; Detail = (($names | Select-Object -First 4) -join ', ') + $more; Dot = $dot.Good })
    }
    # 2. shows that came back (a season premiere aired since last time)
    $back = New-Object System.Collections.Generic.List[string]
    foreach ($show in $script:Lib.Values) {
        $id = Get-ShowInfoId $show; if ($id -le 0) { continue }
        $info = Get-SeriesInfo $id -CacheOnly; if (-not $info -or -not $info.Episodes) { continue }
        foreach ($e in $info.Episodes) {
            if (-not $e -or [int]$e.E -ne 1 -or [int]$e.S -le 0) { continue }
            $lt = Get-LocalAirTime $e
            $when = $null
            if ($lt) { $when = $lt.ToUniversalTime() } elseif ($e.Aired) { try { $when = [datetime]::ParseExact("$($e.Aired)", 'yyyy-MM-dd', $null).ToUniversalTime() } catch {} }
            if ($when -and $when -gt $prev -and $when -le $now) {
                $back.Add($(if ([int]$e.S -eq 1) { "$($show.Folder) started" } else { "$($show.Folder) - season $($e.S) started" }) + " $($when.ToLocalTime().ToString('ddd d MMM'))")
            }
        }
    }
    if ($back.Count) { $lines.Add([pscustomobject]@{ Head = "Back on TV"; Detail = ($back -join "`n"); Dot = $dot.Accent }) }
    # 3. newly missing (aired but not on disk, and not missing last time)
    if ($script:PrevSession.Missing) {
        $old = @{}; foreach ($k in $script:PrevSession.Missing) { $old["$k"] = $true }
        $nowSet = Get-MissingKeySet
        $newMiss = New-Object System.Collections.Generic.List[string]
        foreach ($k in $nowSet.Keys) { if (-not $old.ContainsKey($k)) { $newMiss.Add($k) } }
        if ($newMiss.Count) {
            $txt = @($newMiss | Sort-Object | Select-Object -First 5 | ForEach-Object { $p = $_.Split('|'); "$($p[0]) $(Format-Ep ([int]$p[1]) ([int]$p[2]))" })
            $more = $(if ($newMiss.Count -gt 5) { ", +$($newMiss.Count - 5) more" } else { '' })
            $lines.Add([pscustomobject]@{ Head = "$($newMiss.Count) episode$(if ($newMiss.Count -ne 1) { 's' }) aired that you don't have"; Detail = ($txt -join ', ') + $more; Dot = $dot.Bad })
        }
    }
    if ($lines.Count -eq 0) { $ui.bdSince.Visibility = 'Collapsed'; return }
    $ui.txtSinceWhen.Text = "Last opened $($prev.ToLocalTime().ToString('dddd d MMM, HH:mm'))"
    $ui.icSince.ItemsSource = $lines.ToArray()
    $ui.btnSinceNew.Visibility = $(if ($nArr -gt 0) { 'Visible' } else { 'Collapsed' })
    $ui.bdSince.Visibility = 'Visible'
}
function Save-Session {
    try {
        $miss = @(); if ($script:Lib.Count) { $miss = @((Get-MissingKeySet).Keys) }
        $o = [ordered]@{ Time = (Get-Date).ToUniversalTime().Ticks; Missing = $miss }
        [IO.File]::WriteAllText($script:SessionPath, ($o | ConvertTo-Json -Depth 3 -Compress), [Text.Encoding]::UTF8)
    } catch {}
}
$ui.btnSinceClose.Add_Click({ $script:SinceClosed = $true; $ui.bdSince.Visibility = 'Collapsed' })
$ui.btnSinceNew.Add_Click({ $script:SinceClosed = $true; $ui.bdSince.Visibility = 'Collapsed'; $ui.tabMain.SelectedItem = $ui.tNew })
$ui.btnSinceMissing.Add_Click({ $script:SinceClosed = $true; $ui.bdSince.Visibility = 'Collapsed'; $ui.tabMain.SelectedItem = $ui.tMissing })
$ui.btnSinceCal.Add_Click({ $script:SinceClosed = $true; $ui.bdSince.Visibility = 'Collapsed'; $ui.tabMain.SelectedItem = $ui.tCalendar })

$Win.Add_Closing({ try { Save-Settings } catch {}; if ($script:Lib.Count) { Save-Session } })
Write-StartLog 'Showing main window'
# A display problem in one page shouldn't close the whole app: log it and carry on
$Win.Dispatcher.Add_UnhandledException({
    param($sender, $e)
    try { Add-Content -LiteralPath (Join-Path $DataDir 'Logs\crash.log') -Value ("[{0}] (handled) {1}`n{2}`n" -f (Get-Date), $e.Exception.ToString(), $(if ($e.Exception.ErrorRecord) { $e.Exception.ErrorRecord.ScriptStackTrace })) } catch {}
    try { Set-Status "Something went wrong (details in Data\Logs\crash.log): $($e.Exception.Message)" } catch {}
    $e.Handled = $true
})
[void]$Win.ShowDialog()
$timer.Stop()
Write-StartLog 'Closed'
try { if ($script:Mutex) { $script:Mutex.ReleaseMutex(); $script:Mutex.Dispose() } } catch {}
