pragma Singleton
import Quickshell
import Quickshell.Io
import QtQuick

// Manga library and reader state. The window is MangaReader.qml; files,
// covers, unpacking and reading progress are scripts/manga.py.
// Opened with /manga in the launcher or `qs ipc call manga open`.
Singleton {
    id: root

    // manga.py sits next to this file.
    readonly property string script: Qt.resolvedUrl("manga.py").toString().replace(/^file:\/\//, "")
    // Terminal for "Log" (F4): it runs `<terminal> -e tail -f <log>`.
    property string terminal: "kitty"

    property bool open: false
    property string view: "library"        // library · series · reader

    // Which library: "manga" (~/Manga) or "doujin" (its own folder and
    // reading state, /doujin in the launcher). In a "flat" one every file is a
    // work of its own: a cover opens straight into the reader.
    property string collection: "manga"
    readonly property bool flat: collection === "doujin"
    function cmd(args) { return ["python3", script, "--collection", collection].concat(args) }

    // Library filter (title / artist), typed in the window.
    property string filter: ""

    // Doujin library: facet filters from each work's metadata, as
    // { "tags:x": 1 (must have) | -1 (must not have),
    //   "languages:english": 1, "unc:uncensored": 1 / "unc:censored": 1 }.
    // Replaced, never edited in place, so bindings see the change.
    property var facets: ({})
    readonly property int facetCount: Object.keys(facets).length
    function facetState(key) { return facets[key] || 0 }
    // Click cycles: off -> must have -> must not have -> off. Censorship is
    // either/or, so those chips only go on and off.
    function toggleFacet(key) {
        let f = Object.assign({}, facets)
        let st = f[key] || 0
        if (key.startsWith("unc:")) {
            delete f["unc:uncensored"]; delete f["unc:censored"]
            if (st === 0) f[key] = 1
        } else if (st === 0) f[key] = 1
        else if (st === 1) f[key] = -1
        else delete f[key]
        facets = f
    }
    function clearFacets() { facets = ({}) }
    function hasFacet(m, key) {
        let i = key.indexOf(":")
        let group = key.slice(0, i), v = key.slice(i + 1)
        if (group === "unc") return v === "uncensored" ? m.uncensored : !m.uncensored
        return (m[group] || []).indexOf(v) >= 0
    }
    function matchesFacets(s) {
        if (!facetCount) return true
        if (!s.meta) return false
        for (let k in facets) if (hasFacet(s.meta, k) !== (facets[k] === 1)) return false
        return true
    }
    // How many of the works shown now have each value of `group` (tags,
    // parodies, characters, languages), most common first; the ones picked
    // are kept even at 0.
    function facetCounts(group) {
        let n = {}
        for (let s of sorted) {
            if (!s.meta) continue
            for (let v of (s.meta[group] || [])) n[v] = (n[v] || 0) + 1
        }
        for (let k in facets)
            if (k.startsWith(group + ":")) { let v = k.slice(group.length + 1); if (!(v in n)) n[v] = 0 }
        return Object.keys(n).map(v => ({ v: v, n: n[v] }))
            .sort((a, b) => (b.n - a.n) || a.v.localeCompare(b.v))
    }

    property var series: []                // manga.py library → series
    property string rootDir: ""
    property bool loading: false
    property string error: ""

    property bool rtl: false               // right-to-left page turns
    property string fit: "page"            // page · width
    property string sort: "recent"         // recent · updated · name · manual
    property var order: []                 // series names, for "manual"
    property real checked: 0               // last update check (unix s)
    // A check in progress, from manga.py (also one started elsewhere):
    // { i, n, name, found } or null.
    readonly property var checkState: queue ? queue.check : null
    readonly property bool checking: checkProc.running || checkState !== null

    // The library in the chosen order.
    readonly property var sorted: {
        let q = filter.trim().toLowerCase()
        let s = q ? series.filter(x => (x.name + " " + x.by).toLowerCase().includes(q)) : series.slice()
        if (facetCount) s = s.filter(x => matchesFacets(x))
        let byName = (a, b) => a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: "base" })
        let date = x => x.meta && x.meta.date ? x.meta.date : ""
        if (sort === "name") s.sort(byName)
        else if (sort === "newest" || sort === "oldest") {
            // Undated ones go last either way.
            let dir = sort === "newest" ? -1 : 1
            s.sort((a, b) => (!date(a) - !date(b)) || dir * date(a).localeCompare(date(b)) || byName(a, b))
        }
        else if (sort === "updated")
            s.sort((a, b) => ((b.fresh || 0) + b.updates - (a.fresh || 0) - a.updates) || (b.added - a.added) || byName(a, b))
        else if (sort === "manual") {
            let pos = n => { let i = order.indexOf(n); return i < 0 ? 1e6 : i }
            s.sort((a, b) => (pos(a.name) - pos(b.name)) || byName(a, b))
        } else
            s.sort((a, b) => (b.read - a.read) || (b.added - a.added) || byName(a, b))
        return s
    }
    readonly property int updateCount: series.reduce((n, s) => n + (s.updates > 0 ? 1 : 0), 0)

    property var current: null             // the series being looked at
    property int chapter: -1               // index into current.chapters
    property var pages: []                 // page image paths
    property int page: 0

    // A local path as an image URL. Plain "file://" + path breaks on names with
    // "#" or "?" (a URL fragment / query: "#Gyaru to Gyaru no Yuri"), so every
    // path segment is encoded.
    function url(path) {
        return path ? "file://" + path.split("/").map(encodeURIComponent).join("/") : ""
    }

    function show(coll) {
        if (coll && coll !== collection) {
            saveProgress()
            collection = coll
            series = []
            current = null
            chapter = -1
            pages = []
            order = []
            filter = ""
            facets = ({})
            view = "library"
        }
        open = true
        autoCheck = !flat
        refresh()
    }
    function hide() {
        saveProgress()
        open = false
    }

    // Re-read the library -- after any progress saves still on their way, or
    // it would show the marks from before them.
    property bool refreshWanted: false
    function refresh() {
        if (saveProc.running || saveQueue.length) { refreshWanted = true; return }
        if (libProc.running) { refreshWanted = true; return }
        refreshWanted = false
        loading = true
        libProc.running = true
    }

    // For the launcher, which rebuilds its list on every keystroke and on every
    // library change: rescan at most every 15 s.
    property real libAsked: 0
    function refreshSoon() {
        if (Date.now() - libAsked < 15000) return
        libAsked = Date.now()
        refresh()
    }

    function openSeries(s) {
        current = s
        if (flat) { openChapter(Math.max(0, resumeIndex(s))); return }
        view = "series"
    }
    // Open a series by (part of) its name, e.g. from the launcher.
    function openByName(name) {
        show("manga")
        let s = series.find(x => x.name === name)
        open = true
        if (s) openSeries(s)
        refresh()
    }

    // Where "Continue" goes: the last chapter read, or the one after it once
    // that is finished.
    function resumeIndex(s) {
        if (!s || s.resume < 0) return 0
        let c = s.chapters[s.resume]
        return c.done && s.resume + 1 < s.chapters.length ? s.resume + 1 : s.resume
    }

    // atEnd: open on the last page (paging back from the next chapter).
    property bool openAtEnd: false
    function openChapter(i, atEnd) {
        if (!current || i < 0 || i >= current.chapters.length) return
        saveProgress()
        openAtEnd = !!atEnd
        chapter = i
        pages = []
        page = 0
        error = ""
        view = "reader"
        loading = true
        openProc.command = root.cmd(["open", current.chapters[i].file])
        openProc.running = true
    }

    function next() {
        if (page + 1 < pages.length) { page++; saveSoon.restart() }
        else if (current && chapter + 1 < current.chapters.length) { markRead(); openChapter(chapter + 1) }
    }
    function prev() {
        if (page > 0) { page--; saveSoon.restart() }
        else if (chapter > 0) openChapter(chapter - 1, true)
    }
    function goTo(p) {
        page = Math.max(0, Math.min(pages.length - 1, p))
        saveSoon.restart()
    }
    function back() {
        if (view === "reader") { saveProgress(); view = flat ? "library" : "series"; refresh() }
        else if (view === "series") view = "library"
        else hide()
    }

    function setRtl(on) {
        rtl = on
        Quickshell.execDetached(root.cmd(["setting", "rtl", on ? "1" : "0"]))
    }
    function setSort(s) {
        sort = s
        Quickshell.execDetached(root.cmd(["setting", "sort", s]))
    }
    // Custom order, after a drag in the library.
    function setOrder(names) {
        order = names
        Quickshell.execDetached(root.cmd(["order"]).concat(names))
    }

    // ── Read marks ───────────────────────────────────────────────────────────
    function markSeries(name, read) { run(["mark", name, read ? "read" : "unread"]) }
    function markChapter(file, read, before) {
        run(["markch", file, read ? "read" : "unread"].concat(before ? ["--before"] : []))
    }
    function setSource(name, url) { run(["setsource", name, url.trim()]) }
    // One of the series' own cover images as its cover; "" = the default.
    function setCover(name, path) { run(["setcover", name, path]) }
    // Every cover a MangaDex page has, into a series (whatever site its
    // chapters come from). Takes a while: covers are full size.
    property bool fetchingCovers: false
    property string coversNote: ""
    function addCovers(name, url) {
        if (coverProc.running) return
        fetchingCovers = true
        coversNote = ""
        coverProc.command = cmd(["covers", name, url])
        coverProc.running = true
    }
    Process {
        id: coverProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                let d = null
                try { d = JSON.parse(text) } catch (e) {}
                root.fetchingCovers = false
                root.coversNote = !d ? "could not add covers"
                    : d.ok ? (d.added ? d.added + " covers added" : "no new covers (" + d.found + " already here)")
                    : d.error
                root.refresh()
            }
        }
    }

    // ── Deleting (to the Trash) ──────────────────────────────────────────────
    function deleteSeries(name) {
        if (view === "series" && current && current.name === name) { current = null; view = "library" }
        run(["delete", "series", name])
    }
    function deleteChapter(file) { run(["delete", "chapter", file]) }

    // Small changes: run, then re-read the library.
    function run(args) {
        actProc.command = root.cmd([]).concat(args)
        actProc.running = true
    }
    Process { id: actProc; onExited: root.refresh() }

    // ── Updates ──────────────────────────────────────────────────────────────
    // Check = list each series' chapters on its site (no downloading); the
    // library then shows "+N". Opening the window checks by itself when the
    // last check is over 12 h old.
    property bool autoCheck: false
    function checkUpdates(name) {
        if (checking) return
        checkProc.command = root.cmd(["check"]).concat(name ? [name] : [])
        checkProc.running = true
    }
    Process {
        id: checkProc
        onExited: { queuePollSoon.restart(); root.refresh() }
    }

    // Downloads go into a queue that one background worker (manga.py worker)
    // works through, a series at a time; it keeps going with this window
    // closed and sends a notification as each series finishes.
    // name "" = every series with new chapters.
    function downloadUpdates(name) { queueRun(["queue", "updates"].concat(name ? [name] : [])) }
    // coll: "manga" (a series, into ~/Manga) or "doujin" (a gallery, as one
    // .cbz into the doujin library).
    function download(url, coll) { queueRun(["queue", "add", url], coll) }
    function cancelDownloads() { queueRun(["queue", "cancel"]) }
    function queueRun(args) {
        // Into the library asked for -- not whichever one is open.
        Quickshell.execDetached(["python3", script, "--collection", arguments[1] || "manga"].concat(args))
        queuePollSoon.restart()
    }
    // The worker's output, live, in a terminal.
    function showLog() {
        Quickshell.execDetached([terminal, "-e", "tail", "-n", "200", "-f",
            Quickshell.env("HOME") + "/.local/state/quickshell/manga-download.log"])
    }

    // What the worker is doing, for the library header. Polled while the
    // window is open.
    property var queue: null               // { current, items, finished, running }
    readonly property bool downloading: queue !== null && (queue.current !== null || queue.items.length > 0)
    property int finishedSeen: -1
    property var lastCheck: null
    Timer {
        interval: root.downloading || root.checking ? 1500 : 6000
        running: root.open
        repeat: true
        triggeredOnStart: true
        onTriggered: if (!queueProc.running) queueProc.running = true
    }
    Timer { id: queuePollSoon; interval: 700; onTriggered: if (!queueProc.running) queueProc.running = true }
    Process {
        id: queueProc
        command: ["python3", root.script, "queue", "status"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                let d = null
                try { d = JSON.parse(text) } catch (e) {}
                if (!d || !d.ok) return
                root.queue = d
                // A series finished: show its new chapters. A check ended: its badges.
                if (root.finishedSeen >= 0 && d.finished !== root.finishedSeen) root.refresh()
                if (root.lastCheck !== null && d.check === null) root.refresh()
                root.lastCheck = d.check
                root.finishedSeen = d.finished
            }
        }
    }

    function setFit(f) {
        fit = f
        Quickshell.execDetached(root.cmd(["setting", "fit", f]))
    }

    // ── Progress ─────────────────────────────────────────────────────────────
    // Saved a moment after the page settles, and when leaving a chapter.
    Timer { id: saveSoon; interval: 1500; onTriggered: root.saveProgress() }

    function saveProgress() {
        saveSoon.stop()
        if (view !== "reader" || !current || chapter < 0 || pages.length === 0) return
        save(["progress", current.chapters[chapter].file, String(page), String(pages.length)])
    }
    function markRead() {
        if (!current || chapter < 0 || pages.length === 0) return
        save(["progress", current.chapters[chapter].file, String(pages.length - 1), String(pages.length)])
    }

    // Saves run one after another, in order, and the library waits for them.
    property var saveQueue: []
    function save(args) {
        saveQueue.push(args)
        pumpSaves()
    }
    function pumpSaves() {
        if (saveProc.running || saveQueue.length === 0) return
        saveProc.command = root.cmd([]).concat(saveQueue.shift())
        saveProc.running = true
    }
    Process {
        id: saveProc
        onExited: {
            if (root.saveQueue.length) root.pumpSaves()
            else if (root.refreshWanted) root.refresh()
        }
    }

    // ── manga.py ─────────────────────────────────────────────────────────────
    Process {
        id: libProc
        command: root.cmd(["library"])
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                root.loading = false
                let d = null
                try { d = JSON.parse(text) } catch (e) {}
                if (root.refreshWanted) Qt.callLater(root.refresh)      // asked again meanwhile
                if (!d || !d.ok) { root.error = d && d.error ? d.error : "Could not read the library"; return }
                root.series = d.series
                root.rootDir = d.root
                root.rtl = !!d.settings.rtl
                root.fit = d.settings.fit || "page"
                root.sort = d.settings.sort || "recent"
                root.order = d.order
                root.checked = d.checked
                if (root.autoCheck) {
                    root.autoCheck = false
                    if (Date.now() / 1000 - d.checked > 12 * 3600 && d.series.some(s => s.source))
                        root.checkUpdates("")
                }
                // Keep the open series pointing at fresh data (progress marks).
                if (root.current) {
                    let s = d.series.find(x => x.name === root.current.name)
                    if (s) root.current = s
                }
            }
        }
    }

    Process {
        id: openProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                root.loading = false
                let d = null
                try { d = JSON.parse(text) } catch (e) {}
                if (!d || !d.ok) { root.error = d && d.error ? d.error : "Could not open the chapter"; return }
                root.pages = d.pages
                root.page = root.openAtEnd ? d.pages.length - 1 : Math.min(d.page, d.pages.length - 1)
                root.openAtEnd = false
            }
        }
    }
}
