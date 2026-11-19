<p align="center">
  <img src="assets/TV-Toolkit.png" alt="TV Toolkit logo" width="160">
</p>

# TV Toolkit

A Windows app for keeping an eye on the TV programmes on your NAS or media drive: what's new, what's airing, what's missing and what looks wrong on disk.

![Version](https://img.shields.io/badge/version-v1.03-blue) ![Platform](https://img.shields.io/badge/platform-Windows-0078D6) ![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391FE) ![Licence](https://img.shields.io/badge/licence-MIT-green) ![Last commit](https://img.shields.io/github/last-commit/jason4bury/TV-Toolkit)

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
- **Dark or light**: the dark Test Card look, a light version, or follow Windows (Settings > Look). A **Help** page (F1) explains it all

## 📋 Requirements

- Windows 10 or 11 with Windows PowerShell 5.1 (built in, nothing to install)
- An internet connection for show info from TVmaze (free, no API key)
- Optional: ffprobe (`winget install Gyan.FFmpeg`). TV Toolkit reads resolution and length with Windows' own video details first, and uses ffprobe for files Windows can't read

## 📦 Installation

1. Download `TV-Toolkit-v1.03.zip` from the [latest release](../../releases/latest) and unzip it wherever you like to keep it.
2. Double-click **TV Toolkit.cmd** in the unzipped folder. It makes a **TV Toolkit** shortcut there and in the Start menu, and starts TV Toolkit. From then on, use the shortcut, the Start menu or a pinned taskbar button.

Nothing is installed and no Windows settings are changed. The shortcut runs the script with PowerShell's execution policy bypassed for that run only.

**From the repo:** clone it, or download it as a zip. If you download a zip, right-click it, choose **Properties** and tick **Unblock** *before* unzipping, so Windows doesn't block the scripts. Then double-click **Start TV Toolkit.cmd**.

**Updating from v1.00 (the exe):** unzip the new release, double-click **TV Toolkit.cmd**, and delete `TV Toolkit v1.00.exe` and any shortcut to it. Your settings, show matches and cache are in `%APPDATA%\TV Toolkit\`, so they carry straight over.

### Why no exe

Home tools used to ship as PS2EXE exes, and antivirus programs (ESET among them) kept flagging those exes as generic trojans by mistake. A plain script and a shortcut give the same one-click start without the false alarms, and you can read exactly what runs.

### Build a release

Double-click **Build.cmd** in the repo folder. It reads `build.json`, checks every script for syntax errors and that `$AppVersion` matches the newest `CHANGELOG.md` entry, runs PSScriptAnalyzer if it's installed, copies the release files into `..\Builds\TV Toolkit v<version>\`, zips that folder for the GitHub release, refreshes `..\Builds\TV Toolkit.lnk` (what the Home Launcher starts) and scans the result with ESET's command-line scanner if it's installed.

## 🚀 Usage

### First run

1. Start TV Toolkit (the shortcut, the Start menu, or **TV Toolkit.cmd**). The first time, it opens **Settings**.
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

- **Nothing happens when I start it**: run `"TV Toolkit.cmd" debug` from a command prompt in the release folder to see any errors, and check `Logs\startup.log` in the data folder (see Configuration; `Logs\launch.log` is written when you start it from the repo). Opening it again while it's already running just brings the existing window to the front.
- **Rescan says it can't reach a folder**: the NAS is off or the drive isn't mapped. Your last scan is kept; rescan when it's back.
- **Something went wrong on a page**: details are written to `Logs\crash.log`, and the app keeps running.
- **"Running scripts is disabled"**: start it with the TV Toolkit shortcut or **TV Toolkit.cmd** (or **Start TV Toolkit.cmd** in the repo), which bypass the execution policy for TV Toolkit only.
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
