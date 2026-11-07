<p align="center">
  <img src="assets/TV-Toolkit.png" alt="TV Toolkit logo" width="160">
</p>

# TV Toolkit

A Windows app for keeping an eye on the TV programmes on your NAS or media drive: what's new, what's airing, what's missing and what looks wrong on disk.

![Version](https://img.shields.io/badge/version-v1.00-blue) ![Platform](https://img.shields.io/badge/platform-Windows-0078D6) ![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391FE) ![Licence](https://img.shields.io/badge/licence-MIT-green) ![Last commit](https://img.shields.io/github/last-commit/jason4bury/TV-Toolkit)

## ✨ Features

TV Toolkit reads your TV folders, matches each show with [TVmaze](https://www.tvmaze.com) (free, no API key) and gives you a poster wall with show info, cast, episode pictures and air dates. It never renames, moves or deletes anything without asking first, and files are moved to a holding folder rather than deleted.

**Library**
- Poster wall or sortable list view (channel, status, seasons, episodes, size, quality, newest episode, next airing)
- Badges for new episodes, episodes airing this week, ended shows and shows whose match needs checking
- "Back 20 Jan 2027" or "Starts 25 Nov 2026" under shows with nothing on disk yet
- A green tick when you have every aired episode of a show's latest season
- Search by name, channel, genre, status or year (`Ctrl+F`), or type a letter to jump to shows starting with it
- Show panel with backdrop, overview, cast photos, season chips and an episode list with stills, air dates, quality and size

**Keeping up**
- **New**: episodes that arrived on the drive recently, newest first
- **Calendar**: the week ahead from all your shows with UK air times and channels, plus anything that aired in the last 7 days that you don't have. Save the next 3 months to Outlook, Google Calendar or your phone as an `.ics` file
- **Since you last opened it**: a card listing what arrived, which shows came back on TV, and episodes that aired that you don't have
- **Missing episodes**: aired episodes that aren't on disk, with options for specials, owned seasons only and continuing shows only

**Tidying up**
- **Filename checker**: files that don't follow `Show - 1x01 - Title`, have the wrong title or sit in the wrong season folder. Preview, rename (subtitles, `.nfo` files and artwork go with the video) and undo
- **Duplicates & quality**: more than one file for the same episode, and picture quality per show. Resolution is read from inside the video files, so it works without `1080p` in the file name
- **Problem files**: tiny or unreadable episodes, unfinished downloads, sample files, episodes outside a season folder, junk files, orphan subtitles or `.nfo` files, and empty folders

**Everything else**
- **Cast**: everyone in your shows, with photos, biographies, which of your shows they're in and their other TV work
- **Stats**: shows, episodes, space used, viewing time, free space per drive with a "full in about..." estimate, and charts by month, channel, genre, size and quality
- **Utilities**: backup and restore, moving settings to another PC, a printable show list
- A top bar with new, shows, episodes, used and free at a glance, and when the library was last scanned

## 📋 Requirements

- Windows 10 or 11 with Windows PowerShell 5.1 (built in, nothing to install)
- An internet connection for show info from TVmaze (free, no API key)
- Optional: ffprobe (`winget install Gyan.FFmpeg`). TV Toolkit reads resolution and length with Windows' own video details first, and uses ffprobe for files Windows can't read

## 📦 Installation

**Exe:** download `TV Toolkit v1.00.exe` from the [latest release](../../releases/latest) and run it. Nothing else to install.

**Script:** clone or download the repo, then double-click **`Start TV Toolkit.cmd`**. It starts TV Toolkit with an execution-policy bypass for that run only; no Windows settings are changed. If you downloaded a zip and Windows blocks the files, right-click the zip, choose **Properties**, tick **Unblock**, then unzip it again.

### Build the exe

Builds use the standard build script, which reads `build.json`, runs PSScriptAnalyzer, compiles the exe with [ps2exe](https://github.com/MScholtes/PS2EXE) and saves it to the project's `Builds\` folder (outside the repo) as `TV Toolkit v<version>.exe`:

```powershell
E:\Created\_shared\Build-Tool.ps1 -Project "E:\Created\Home\TV-Toolkit"
```

Until the shared build script is in place, double-click `Build-Exe.cmd` in the repo folder instead. It does the same build in Windows PowerShell 5.1 (no admin rights needed): it checks the script for syntax errors, installs ps2exe for your user the first time, and saves its output to `Build-Exe.log`. The version comes from `$AppVersion` at the top of `src\TV-Toolkit.ps1`, which matches the newest CHANGELOG entry.

Some antivirus programs are wary of new ps2exe-built programs. If yours blocks the exe, allow it or keep using `Start TV Toolkit.cmd`.

## 🚀 Usage

### First run

1. Start TV Toolkit. The first time, it opens **Settings**.
2. Enter your TV folder, one per line (for example `T:\` or `\\NAS\TV`), and a holding folder for files you move out of the library.
3. Press **Save settings**, then **Rescan** (or `F5`).

The first scan reads every show folder, then matches each show with TVmaze and downloads posters, info and cast in the background. A big library takes a few minutes the first time; after that everything is cached.

### Folder layout

```
T:\Show Name\S30\Show Name - 30x01 - Episode Title.mkv
```

- Season folders can be `S01`, `Season 1` or `Specials`, and `S01E01` style names are understood too
- If a `tvshow.nfo` with a TheTVDB id is in the show folder it's used for the match; otherwise the folder name is searched on TVmaze
- Shows marked **CHECK MATCH** were a best guess: open them and press **Confirm match**, or **Fix match...** to choose the right one
- Extras folders (backdrops, extras, trailers, featurettes...) are ignored

### Keyboard shortcuts

| Key | What it does |
| --- | --- |
| `F5` | Rescan the TV folders |
| `Ctrl+F` | Search shows |
| `Esc` | Clear the search, or close the show panel |
| `Enter` | Open the show when only one matches the search |
| `A`-`Z`, `0`-`9` | On the Library page, jump to the first show starting with that letter (press again for the next) |

### Troubleshooting

- **Nothing happens when I start it**: check `Logs\launch.log` and `Logs\startup.log` in the data folder (see Configuration). Opening it again while it's already running just brings the existing window to the front.
- **Rescan says it can't reach a folder**: the NAS is off or the drive isn't mapped. Your last scan is kept; rescan when it's back.
- **Something went wrong on a page**: details are written to `Logs\crash.log`, and the app keeps running.
- **"Running scripts is disabled"**: start it with `Start TV Toolkit.cmd`, which bypasses the execution policy for TV Toolkit only.
- **A show is matched to the wrong programme**: open it and press **Fix match...**.

## ⚙️ Configuration

Everything TV Toolkit saves lives in:

```
%APPDATA%\TV Toolkit\
```

| File or folder | What it holds |
| --- | --- |
| `settings.json` | your TV folders, holding folder and options |
| `matches.tsv` | which TVmaze show each folder is matched to |
| `library.tsv`, `shows.tsv` | the last scan |
| `mediainfo.tsv` | resolution and length read from each video file |
| `series-index.tsv`, `new-dismissed.tsv`, `last-session.json` | show summaries, episodes marked "Not new", and what the "since you last opened it" card compares against |
| `Cache\` | show info, posters, backdrops, episode pictures and cast photos |
| `Logs\` | `launch.log`, `startup.log`, `tvinfo.log`, `crash.log` and rename batches for undo |
| `Backups\`, `Exports\` | the last 15 backups, and the printable show list |

**Utilities > Open data folder** opens it. Versions before v1.00 kept all of this in a `Data` folder beside the app; v1.00 copies that folder across the first time it starts. None of it is part of this repository, so your library details and paths stay on your PC.

The options on the **Settings** page are: TV folders, holding folder, how often show info is refreshed (default every 3 days for continuing shows, 30 for ended ones) and how many days an episode counts as new (default 14).

## 📝 Changelog

See [CHANGELOG.md](CHANGELOG.md). History from before the v1.00 renumbering is in [docs/HISTORY-before-1.00.md](docs/HISTORY-before-1.00.md).

## 📄 Licence

MIT, see [LICENSE](LICENSE). Copyright (c) 2026 Jason Rhodes.

Show information, episode lists, air times, posters, cast, photos and biographies come from [TVmaze](https://www.tvmaze.com), licensed under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). TV Toolkit uses the free public TVmaze API and respects its rate limit. Posters and photos remain the property of their owners and are shown for personal use. TV Toolkit isn't affiliated with or endorsed by TVmaze. Fonts: Bahnschrift and Segoe UI from Microsoft Windows.
