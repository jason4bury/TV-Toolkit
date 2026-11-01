TV TOOLKIT  v1.9.1
==================
A desktop companion for the TV programmes on your NAS (PowerShell + WPF, Windows 10/11).


GETTING STARTED
---------------
1. Unzip anywhere, e.g. E:\TV Toolkit. The folder is portable - everything it
   keeps lives in the Data folder beside App, so you can move the whole folder.
2. Double-click "Start TV Toolkit.cmd".
   (If Windows blocks it, right-click the zip > Properties > Unblock before unzipping.)
3. Go to Settings: T:\ is filled in already as your TV folder. Add more lines
   if you have other drives. Press Save settings, then Rescan library (or F5).

The first scan reads every show folder, then matches each show with TVmaze
(free, no API key) and downloads posters, info and cast in the background. A big library takes a
few minutes the first time; after that everything is cached.


EXPECTED LAYOUT
---------------
  T:\Show Name\S30\Show Name - 30x01 - Episode Title.mkv
Season folders can be S01, Season 1 or Specials. SxxEyy names are understood
too. If a tvshow.nfo with a TheTVDB id is in the show folder it is used for the
match; otherwise the folder name is searched on TVmaze. Shows marked CHECK MATCH were a
best guess - open them and press Confirm match if it's right, or Fix match... if not.
Extras folders (backdrops, extras, trailers...) are ignored. 'Special 13' files in
S00 are read as specials.


WHAT'S WHERE
------------
Library          Poster wall, or a sortable List (Posters / List buttons at the
                 top - your choice is remembered). Click a show for info, cast,
                 seasons and episodes, with the show's backdrop behind and a
                 picture for each episode. Double-click an episode to play it.
                 Esc closes the panel. Shows with nothing on disk yet say when
                 they start or come back, if TVmaze knows the date. A green
                 tick on a poster means you have every aired episode of its
                 latest season. Type a letter to jump to shows starting with
                 it (again for the next one, Enter to open).
New              Episodes that arrived recently (default 14 days, see Settings),
                 newest first. Shows with new episodes get a green 'N NEW'
                 badge on the poster wall. 'Not new' takes one off the list.
Calendar         The week ahead: a column per day with every episode airing,
                 its UK time, channel and whether it's on disk, plus episodes
                 missed in the last 7 days. "Save to my calendar (.ics)"
                 exports the next 3 months for Outlook, Google or your phone.
Cast             Everyone in your shows. Click a face (here or on a show's
                 panel) for their biography and details, which of your shows
                 they're in, and their other TV work.
Missing episodes Aired (per TVmaze) but not on disk. Export the list if you need it.
Filename checker Wrong pattern, wrong title, wrong season folder. Preview,
                 rename selected (subtitles/.nfo go with the video), undo.
Duplicates       More than one file for the same episode + quality by show.
                 Resolution and length are read from inside the video files
                 (Windows' video details, or ffprobe if installed).
                 "Move to holding folder" moves files out - nothing is deleted.
Problem files    Tiny or unreadable episodes, unfinished downloads, sample
                 files, episodes not in a season folder, junk files, subtitles
                 or .nfo files with no episode, and empty folders. Move files to
                 the holding folder, move loose episodes into the right season
                 folder, or remove empty folders.
Stats            Free space on each TV drive (with a rough 'full in' estimate),
                 library totals (shows, episodes, space, viewing time) and
                 charts: episodes added per month, channels, genres,
                 biggest shows, most episodes and picture quality.
Utilities        Backup / restore, move settings between PCs, printable list.
About            Version, credits and what's new.

GOOD TO KNOW
------------
- When you open it, a card lists what's changed since last time: episodes
  that arrived, shows back on TV, and aired episodes you don't have.
- The figures in the top bar (new, shows, episodes, used, free) are shortcuts:
  click one to jump to its page. The Rescan button shows when you last scanned.
- Show info comes from TVmaze (tvmaze.com), licensed CC BY-SA 4.0.
- Show matches are in Data\matches.tsv.
- If it ever closes unexpectedly, details are in Data\Logs\crash.log.
  Every start is logged in Data\Logs\startup.log. Opening it again while it's
  running just brings the existing window to the front.
- Shortcuts: F5 rescan, Ctrl+F search (show names, channels, genres), Esc clears
  the search or closes the show panel, Enter opens the show if only one matches.
