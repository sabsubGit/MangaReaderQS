# MangaReaderQS

Manga + doujin library and CBZ/CBR reader for Quickshell, with gallery-dl downloads, update checks and a download queue.

## Requirements

- quickshell
- python3, python-pillow
- gallery-dl (AUR)
- libnotify (`notify-send`)
- libarchive (`bsdtar`, for `.cbr`) and glib2 (`gio`, deleting goes to the Trash)
- kitty, or set `Manga.terminal` to your terminal (used by the Log view)
- JetBrains Mono + JetBrainsMono Nerd Font

## Install

1. Copy `manga/` to `~/.config/quickshell/manga/`.
2. In your `shell.qml`:
   ```qml
   import qs.manga
   ShellRoot {
       MangaModule {}
   }
   ```
3. Merge `gallery-dl-config.json` into `~/.config/gallery-dl/config.json`.
4. Bind keys or your launcher to:
   ```
   qs ipc call manga open                  # manga library
   qs ipc call manga doujin                # doujin library
   qs ipc call manga download <url>        # queue a series
   qs ipc call manga downloadDoujin <url>  # queue a gallery
   ```

Libraries: `~/Manga/<Series>/*.cbz` and `~/Doujin/*.cbz` (override with `MANGA_DIR` / `DOUJIN_DIR`). Colours and fonts are at the top of `manga/Tui.qml`.

## Keys

Library: arrows/Enter, `/` filter, F2 check updates, F3 get new, F4 log, Del delete (twice), T tag filters (doujin). Series: C continue, V covers, F5/F6 all read/unread, right-click a chapter to toggle read. Reader: ←/→ or click halves, W fit width, D right-to-left, Esc back.
