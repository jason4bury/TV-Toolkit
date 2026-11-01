# TV Toolkit

A Windows desktop app for keeping an eye on the TV programmes on your NAS or media drive.

TV Toolkit reads your TV folders, matches each show with [TVmaze](https://www.tvmaze.com), and gives you a poster wall with show info, cast, episode pictures and air dates. It tells you what's new, what's airing this week, what's missing and what looks wrong on disk, and it never renames, moves or deletes anything without asking first.

It's written in Windows PowerShell and WPF, so there's nothing to install: unzip it and run it.

> Current version: **1.9.1** - see [CHANGELOG.md](CHANGELOG.md)

---

## Features

**Library**
- Poster wall or sortable list view (channel, status, seasons, episodes, size, quality, newest episode, next airing)
- Badges for new episodes, episodes airing this week, ended shows and shows that need their match checked
- "Back 20 Jan 2027" / "Starts 25 Nov 2026" under shows that have nothing on disk yet
- Green tick when you have every aired episode of a show's latest season
- Search by name, channel, genre, status or year (`Ctrl+F`), or type a letter to jump to shows starting with it
- Show panel with backdrop, overview, cast photos, season chips and an episode list with stills, air dates, quality and size

**Keeping up**
- **New** - episodes that arrived on the drive recently, newest first
- **Calendar** - the week ahead from all your shows with UK air times and channels, plus anything that aired in the last 7 days that you don't have. Export the next 3 months to Outlook, Google Calendar or your phone as an `.ics` file
- **"Since you last opened it" card** - what arrived, which shows came back on TV, and episodes that aired that you don't have
- **Missing episodes** - aired episodes that aren't on disk, with options for specials, owned seasons only and continuing shows only

**Tidying up**
- **Filename checker** - finds files that don't follow `Show - 1x01 - Title`, have the wrong title or sit in the wrong season folder. Preview, rename (subtitles and `.nfo` files go with the video) and undo
- **Duplicates & quality** - more than one file for the same episode, and picture quality per show. Resolution is read from inside the video files, so it works without `1080p` in the file name
- **Problem files** - tiny or unreadable episodes, unfinished downloads, sample files, episodes outside a season folder, junk files, orphan subtitles or `.nfo` files, and empty folders
- Files are moved to a **holding folder** rather than deleted

**Everything else**
- **Cast** - everyone in your shows, with photos, biographies, which of your shows they're in and their other TV work
- **Stats** - shows, episodes, space used, viewing time, free space per drive with a "full in about…" estimate, and charts by month, channel, genre, size and quality
- **Utilities** - backup and restore, moving settings to another PC, a printable show list
- Top bar with new / shows / episodes / used / free at a glance, and when the library was last scanned

---

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (built into Windows, nothing to install)
- An internet connection for show info from TVmaze (free, no API key)
- Optional: [ffprobe](https://ffmpeg.org) on your `PATH`. TV Toolkit uses Windows' own video details first and falls back to ffprobe for files Windows can't read

## Getting started

1. Download the latest release zip (or clone this repository) and put the folder anywhere, for example `E:\TV Toolkit`.
2. If Windows blocked the download, right-click the zip > **Properties** > tick **Unblock** before unzipping.
3. Double-click **`Start TV Toolkit.cmd`**.
4. Open **Settings**, enter your TV folder (one per line, for example `T:\`), set a holding folder, then press **Save settings** and **Rescan** (or `F5`).

The first scan reads every show folder, then matches each show with TVmaze and downloads posters, info and cast in the background. A big library takes a few minutes the first time; after that everything is cached.

## Expected folder layout

```
T:\Show Name\S30\Show Name - 30x01 - Episode Title.mkv
```

- Season folders can be `S01`, `Season 1` or `Specials`
- `S01E01` style names are understood too
- If a `tvshow.nfo` with a TheTVDB id is in the show folder it's used for the match; otherwise the folder name is searched on TVmaze
- Shows marked **CHECK MATCH** were a best guess: open them and press **Confirm match**, or **Fix match…** to choose the right one
- Extras folders (backdrops, extras, trailers, featurettes…) are ignored

## Building an exe (optional)

You can turn TV Toolkit into a normal Windows program, `TV Toolkit.exe`, with the TV icon:

1. Double-click **`Build TV Toolkit exe.cmd`**. You can also run `.\Build-Exe.ps1` from Windows PowerShell.
2. It checks everything it needs first:
   - Windows and Windows PowerShell 5.1
   - .NET Framework 4.7.2 or later
   - the app script and icon
   - that Group Policy or Intune isn't enforcing an execution policy that blocks scripts
   - that the exe isn't already running
3. If the [PS2EXE](https://github.com/MScholtes/PS2EXE) module is missing, it offers to install it for your user account from the PowerShell Gallery. Use `-Install` to skip the question.
4. It writes `TV Toolkit.exe` next to `Start TV Toolkit.cmd`. Both use the same `Data` folder, so your settings and cache carry over.

You don't need to change your execution policy. The `.cmd` file runs the build with `-ExecutionPolicy Bypass` for that run only, and the script unblocks files downloaded from GitHub.

| Option | What it does |
| --- | --- |
| `-CheckOnly` | Check the requirements without building |
| `-Install` | Install PS2EXE without asking |
| `-Run` | Start the exe when the build finishes |

Some antivirus programs are wary of new PS2EXE-built programs. If yours blocks the exe, allow it or keep using `Start TV Toolkit.cmd`.

## Keyboard shortcuts

| Key | What it does |
| --- | --- |
| `F5` | Rescan the TV folders |
| `Ctrl+F` | Search shows |
| `Esc` | Clear the search, or close the show panel |
| `Enter` | Open the show when only one matches the search |
| `A`–`Z`, `0`–`9` | On the Library page, jump to the first show starting with that letter (press again for the next) |

## Where things are kept

Everything TV Toolkit stores lives in a `Data` folder next to `App`, so the whole folder is portable:

| File / folder | Contents |
| --- | --- |
| `settings.json` | Your settings |
| `matches.tsv` | Which TVmaze show each folder is matched to |
| `library.tsv`, `shows.tsv` | The last scan |
| `mediainfo.tsv` | Resolution and length read from each video file |
| `Cache\` | Show info, posters, backdrops, episode pictures and cast photos |
| `Logs\` | `startup.log`, `launch.log`, `tvinfo.log` and `crash.log` |

The `Data` folder is created on first run and is **not** part of this repository (see `.gitignore`), so your library details, paths and cache stay on your PC.

## Troubleshooting

- **Nothing happens when I start it** - check `Data\Logs\launch.log` and `Data\Logs\startup.log`. Opening it again while it's already running just brings the existing window to the front.
- **Something went wrong on a page** - details are written to `Data\Logs\crash.log`, and the app keeps running.
- **"Running scripts is disabled"** - always start it with `Start TV Toolkit.cmd`, which runs PowerShell with `-ExecutionPolicy Bypass` for this app only.
- **A show is matched to the wrong programme** - open it and press **Fix match…**.

## Repository layout

```
Start TV Toolkit.cmd    Double-click to start
App\TV-Toolkit.ps1      The application (single file: UI, logic and theme)
App\TV-Toolkit.ico      The TV Toolkit icon (window, taskbar and exe)
App\Launch.ps1          Small launcher that logs each start and shows an error if it can't start
Build-Exe.ps1           Builds TV Toolkit.exe (optional)
Build TV Toolkit exe.cmd  Double-click to run Build-Exe.ps1
README.md               This file
CHANGELOG.md            Version history
LICENSE                 MIT licence
```

## Credits

- Show information, episode lists, air times, posters, cast, photos and biographies from **[TVmaze](https://www.tvmaze.com)**, licensed under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). TV Toolkit uses the free public TVmaze API and respects its rate limit.
- Posters and photos remain the property of their respective owners and are shown for personal use.
- Built with Windows PowerShell and WPF (.NET). Fonts: Bahnschrift and Segoe UI from Microsoft Windows.
- Made by Jason Rhodes, built with Claude (Anthropic).

TV Toolkit isn't affiliated with or endorsed by TVmaze.

## License

TV Toolkit is released under the [MIT License](LICENSE). Show data from TVmaze is separately licensed under CC BY-SA 4.0 (see Credits above).
