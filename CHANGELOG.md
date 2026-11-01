# Changelog

All notable changes to TV Toolkit are listed here, newest first.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [1.9.1]

### Added
- `Build-Exe.ps1` and `Build TV Toolkit exe.cmd` build `TV Toolkit.exe` with PS2EXE. Before building they check:
  - Windows, Windows PowerShell 5.1 and .NET Framework 4.7.2 or later
  - that Group Policy or Intune isn't enforcing a blocking execution policy
  - the app script (syntax) and icon
  - the PS2EXE module, offering to install it
  - that the exe isn't running
- TV Toolkit icon (`App\TV-Toolkit.ico`) on the window, taskbar and exe.

### Changed
- TV Toolkit works out where its `Data` folder is whether it runs as the script or as the exe.

## [1.9.0]

### Added
- **"Since you last opened it" card**: when you open TV Toolkit it lists episodes that arrived, shows that came back on TV, and episodes that aired that you don't have. It has buttons to the New, Missing episodes and Calendar pages.
- **Season complete**: a green tick on a poster when you have every aired episode of the show's latest season, a tick on complete season chips, and a *Latest season* column in the list view.
- **Calendar export**: *Save to my calendar (.ics)* saves the next 3 months of your shows' episodes (UK times, channel, length) for Outlook, Google Calendar or your phone. Re-importing updates the same entries.
- **Jump by letter**: on the Library page, type a letter to jump to the first show starting with it. Type it again for the next one, and press Enter to open.

### Changed
- Missing episodes checks itself the first time you open the page.
- About page description brought up to date.
- Calendar, Cast and poster images are always passed to the screen as images, guarding against the PowerShell display error fixed in 1.8.0.

## [1.8.2]

### Changed
- Top bar shows new, shows, episodes, space used and free space as separate figures. Free space turns amber at 75% full and red at 90%. Click any figure to jump to its page.
- Rescan is a quieter outlined button that shows when the library was last scanned.

## [1.8.1]

### Changed
- Shows with nothing on disk say when they start or come back (for example *Back 25 Nov 2026*) instead of *Waiting for episodes*, when TVmaze knows the date. Ended shows say *Ended - nothing on disk*.

### Fixed
- Library list view: clicking a column heading now sorts, and clicking again reverses the order.

## [1.8.0]

### Added
- **Drive space** on Stats: free space for each TV drive, a used/free bar (amber over 75%, red over 90%), and roughly when it'll be full at the rate episodes have been arriving.
- **Problem files** page: tiny or unreadable episodes, unfinished downloads, sample files, episodes not in a season folder, junk files, subtitles or `.nfo` files with no episode, and empty folders. You can move files to the holding folder, move loose episodes into the right season folder (using an existing *Season 2* style folder if there is one), or remove empty folders.
- **Backdrops**: the show's wide background picture fades in behind the top of the show panel.
- **Episode pictures** in the episode list and on the New page.
- **Library list view**: switch between Posters and a sortable List. Your choice is remembered.

### Changed
- The show panel is wider, so episode titles still fit next to the pictures.

### Fixed
- A crash when opening a show, caused by a Windows PowerShell 5.1 engine quirk.
- If something goes wrong on a page, it's now written to `Data\Logs\crash.log` with full details and the app keeps running instead of closing.

## [1.7.1]

### Removed
- Leftover code from the watched and Medusa features, and unused settings. Old settings (Medusa address and key, TheTVDB keys) are cleared from `settings.json` the next time settings are saved.

## [1.7.0]

### Removed
- All Medusa features: the Medusa page and settings, *Add to Medusa*, search and pick-a-copy buttons. TV Toolkit now just looks after your library.

## [1.6.2]

### Changed
- About page: What's new moved into its own panel on the right.

## [1.6.1]

### Changed
- Space used is shown as a whole number of GB in the header, the Stats tile and Biggest shows.

## [1.6.0]

### Removed
- Watched tracking: the Next up page, watched buttons, ticks, progress bars and watched stats. *New* now simply means episodes that arrived recently.

### Changed
- Stats bar charts are shorter, giving names more room.

## [1.5.1]

### Added
- Picture quality and length are read from inside the video files, using Windows' own video details with ffprobe as a fallback. This works without `1080p` in the file names, and new or changed files are read in the background.
- Quality column in episode lists.
- *Re-read video details* in Utilities.

### Changed
- Duplicates & quality uses the real resolution, and Stats' viewing time uses real file lengths.

## [1.5.0]

### Added
- **Stats** page: totals and charts of episodes added per month, channels, genres, biggest shows, most episodes and picture quality. Hover over a bar for the exact figure.
- Credits section on the About page.

## [1.4.3]

### Changed
- Redesigned search box with an icon, match count, clear button and Ctrl+F hint.
- Search also matches channels, genres, status and year. Esc clears it, and Enter opens the show when there's only one match.

## [1.4.2]

### Added
- Cast members show their biography from TVmaze (Show more / Show less) and any other names they're known by.

## [1.4.1]

### Removed
- The Coming up page, because the Calendar covers it. The *NEW TUE* style badges on the poster wall still show when a new episode airs this week.

## [1.4.0]

### Added
- **Calendar** page: the next 7 days as columns with every episode airing from your shows, plus a *Missed in the last 7 days* strip. Each episode shows its UK air time, channel and running time, and is tagged ON DISK, TODAY, UPCOMING or MISSING.
- Previous / This / Next week buttons, and *Hide episodes already on disk*.
- Air times are saved with each episode and shown in your local time.

## [1.3.0]

### Added
- **Cast** page: everyone in your shows as a wall of faces, with search, filters and sorting.
- Person details: photo, birthday and age, country, which of your shows they're in, and the rest of their TV work.
- *Back to show* returns to the show you came from.

## [1.2.4]

### Fixed
- Cast photos are framed on the face (cropped from the top) instead of the middle.

## [1.2.3]

### Fixed
- Cast photos now show. They were downloading but not being displayed.

### Added
- `Start TV Toolkit.cmd` logs each launch to `Data\Logs\launch.log`, and shows an error box if TV Toolkit can't start.

## [1.2.2]

### Added
- Splash screen while starting.
- Only one copy runs at a time. Opening it again brings the existing window to the front.
- Each start is recorded in `Data\Logs\startup.log`.

### Fixed
- The window comes to the front when it opens instead of sometimes hiding behind other windows.

## [1.2.1]

### Fixed
- Cast photos were downloading but only initials were showing.

## [1.2.0]

### Added
- **New** page: every episode that arrived recently, newest first, with *Not new* to hide one. The tab shows how many are waiting.
- Green *N NEW* badge on the poster wall, NEW tags in episode lists and new counts on season chips.
- Setting for how many days an episode counts as new (default 14), based on when the file arrived on the drive.

## [1.1.2]

### Added
- Version number in the header and window title.

## [1.1.1]

### Added
- *Confirm match* button for best-guess matches.
- *Waiting for episodes* library filter.

### Changed
- Extras folders (backdrops, extras, trailers, featurettes…) and theme music are ignored when scanning.
- *Special 13* style files in S00/Specials are read as specials.

## [1.1.0]

### Changed
- Show info, posters, cast and episode lists come from **TVmaze** (free, no API key) instead of TheTVDB, which no longer accepts legacy keys.
- Logging moved to `Data\Logs\tvinfo.log`.

## [1.0.1]

### Fixed
- Show-info problems are logged, and you're told when matching fails instead of it failing silently.

## [1.0.0]

First release.

### Added
- Poster wall for every show on your TV drive, with filters and sorting.
- Show panel with info, cast photos, season chips and an episode list showing what's on disk, missing or upcoming.
- Missing episodes check.
- Filename checker for `Show - 1x01 - Title`, with preview, sidecar files renamed too, and undo.
- Duplicates and quality by show, with a holding folder instead of deleting.
- Backups, restore, moving settings between PCs, and a printable show list.
- Watched tracking with a Next up list (removed in 1.6.0).
- Medusa integration: add shows, search for missing episodes, pick a copy (removed in 1.7.0).

