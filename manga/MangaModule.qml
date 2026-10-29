import Quickshell
import Quickshell.Io
import QtQuick

// Drop this into your shell.qml (ShellRoot): the reader window plus IPC.
//   qs ipc call manga open            manga library
//   qs ipc call manga doujin          doujin library
//   qs ipc call manga toggle | close
//   qs ipc call manga download <url>        queue a series (gallery-dl)
//   qs ipc call manga downloadDoujin <url>  queue a gallery into the doujin library
Scope {
    MangaReader {}

    IpcHandler {
        target: "manga"
        function open(): void { Manga.show("manga") }
        function doujin(): void { Manga.show("doujin") }
        function close(): void { Manga.hide() }
        function toggle(): void { if (Manga.open) Manga.hide(); else Manga.show("manga") }
        function download(url: string): void { Manga.download(url, "manga") }
        function downloadDoujin(url: string): void { Manga.download(url, "doujin") }
    }
}
