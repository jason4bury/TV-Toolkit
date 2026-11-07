# Changelog

All notable changes to TV Toolkit are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), with versions numbered
`<major>.<minor>` and a two-digit minor (v1.00, v1.01 ... v1.10) to match the exe file names.

## [Unreleased]

## [1.00] - 2026-11-07
First release in the house style. Version numbers restart here; the history before this
(1.0.0 to 1.9.1) is kept in [docs/HISTORY-before-1.00.md](docs/HISTORY-before-1.00.md).

### Changed
- **Settings and data moved to `%APPDATA%\TV Toolkit\`.** They used to be in a portable
  `Data` folder beside `App`. The first time v1.00 starts, it copies an existing `Data`
  folder across (settings, show matches, the image cache, logs and backups), leaves a
  "MOVED - read me.txt" note in the old folder and says where it came from, so you can
  delete the old copy once you've checked it.
- **New repo layout.** The script is now `src/TV-Toolkit.ps1` with its launcher
  `src/Launch.ps1`, the icon is `assets/TV-Toolkit.ico` (plus `assets/TV-Toolkit.png` for
  the README), and older history is in `docs/`. Builds go to the project's `Builds\`
  folder, outside the repo.
- **Exe name.** Builds are now named `TV Toolkit v<version>.exe`, e.g. `TV Toolkit v1.00.exe`,
  using the standard build script and `build.json`. `Build-Exe.cmd` does the same build
  until the shared script is ready, and replaces `Build-Exe.ps1` and `Build TV Toolkit exe.cmd`.
- **No TV folder is assumed.** New installs start with an empty TV folder list (and no
  holding folder) and open Settings, instead of filling in `T:\`. Existing settings are kept.
- **About tab** shows the version as "v1.00", the copyright, MIT licence and a link to the
  GitHub repo. Its "What's new" list now matches this changelog instead of repeating the
  whole history, and the Data section says where everything is kept.
- The main window's minimum height is 640 instead of 700, so it fits a 1080p screen at
  150% scaling when it isn't maximised.
- Web requests identify themselves to TVmaze as TV Toolkit with a link to the repo, and
  use TLS 1.2 only (TLS 1.0 and 1.1 are no longer offered).

### Fixed
- **Moving a duplicate to the holding folder could move the copy you were keeping.** Files
  were matched by name only, so moving `Show - 1x01 - Title.avi` also moved
  `Show - 1x01 - Title.mkv`. Only the selected file moves now; its subtitles and artwork
  stay with the copy that's left. The same applies to Problem files and Rename.
- **Rename could pick up a different episode's files** whose names started the same way
  (for example a multi-episode `1x01-02` file when renaming `1x01`). Only subtitles, `.nfo`
  files and Kodi-style artwork (`-thumb`, `-poster`, `-fanart` and so on) go with an episode
  now, and every new name is checked before any file is touched.
- **Rescan with the NAS switched off emptied the library.** If a TV folder can't be reached,
  the last scan is kept and you're told which folder couldn't be reached.
- Half-downloaded posters and photos are no longer left behind as `.part` files when a
  download fails.
- The Utilities page no longer says exported settings include API keys (TVmaze needs none).

### Internal
- PSScriptAnalyzer clean-up: functions with unapproved verbs renamed (`Refresh-Library` is
  now `Update-LibraryView`, `Fill-Episodes` is `Update-EpisodeList`, `Fix-Match` is
  `Repair-ShowMatch`, `Load-Settings` is `Import-Settings` and so on), event handlers no
  longer use the automatic `$sender` variable, and empty `catch` blocks write the error to
  the verbose stream. Added `PSScriptAnalyzerSettings.psd1`.
- Leftover TheTVDB sign-in code removed. App name, version and copyright are set once at the
  top of the script, with comment-based help.
- Closing the window asks any background downloads or checks to stop.
