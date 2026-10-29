import Quickshell
import QtQuick

// Manga library and CBZ reader, as an ordinary window (tile it, fullscreen
// it, close it with SUPER+Q). State lives in Manga.qml; files in ~/Manga.
// Drawn in the TUI look of the lock screen (Tui*.qml).
//
//   Library   arrows/Enter pick · F2 check updates · F3 get new · F4 log
//             F8 stop downloads · Del series to the Trash (press twice)
//             R rescan · Esc close
//   Series    ↑ ↓ Enter read · C continue · F2 check · F3 get new
//             F5 all read · F6 all unread · right-click a chapter: read/unread
//             (Shift: everything up to it) · Del chapter / F9 series to the
//             Trash (press twice) · V or a click on the cover: cover viewer
//             (← → browse, Enter use as cover, F7 default) · Esc back
//   Reader    → Space next · ← Backspace previous (swapped in right-to-left)
//             click the right / left half to turn · Home End · W fit width
//             D right-to-left · Esc back to the chapter list
LazyLoader {
    active: Manga.open

    FloatingWindow {
        id: win
        title: Manga.view === "reader" && Manga.current
            ? Manga.current.name + " · " + Manga.current.chapters[Manga.chapter].name
            : Manga.flat ? "Doujin" : "Manga"
        implicitWidth: 1100
        implicitHeight: 1000
        minimumSize: Qt.size(560, 420)
        color: Tui.bg

        onClosed: Manga.hide()       // closed by the compositor (SUPER+Q)

        function esc(t) { return String(t).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;") }
        function seriesNamed(n) { return Manga.series.find(x => x.name === n) || null }

        // "Chapter 12.5 · Title" → { num: "12.5", title: "Title" }
        function splitName(name) {
            let m = /^Chapter (\S+)(?: · (.*))?$/.exec(name || "")
            return m ? { num: m[1], title: m[2] || "" } : { num: "", title: name || "" }
        }
        function chapterCount() { return Manga.series.reduce((n, s) => n + s.chapters.length, 0) }
        function host(url) { let m = /^https?:\/\/([^/]+)/.exec(url || ""); return m ? m[1].replace(/^www\./, "") : "" }

        // Hand the keyboard back to the window. Not just keys.forceActiveFocus():
        // `keys` is a FocusScope, and that gives the focus to whatever inside it
        // had it last -- a text box (the "/" filter, the url field, the tag
        // search), hidden or not, which then swallows Esc. So the text boxes
        // let go first, and the list of the current view takes the keys.
        function takeKeys() {
            for (let t of [filterInput, urlInput, facetSearch, coversUrl]) t.focus = false
            if (Manga.view === "library" && !filters) grid.forceActiveFocus()
            else if (Manga.view === "series" && !gallery) chapters.forceActiveFocus()
            else keys.forceActiveFocus()
        }

        // Every view change hands the keyboard back to the window's handler.
        Connections {
            target: Manga
            function onViewChanged() { win.takeKeys() }
        }

        // Library drag: the grid's model is the order; save it when one lands.
        property bool dragging: false
        function saveOrder() {
            let m = grid.model, names = []
            for (let i = 0; i < m.count; i++) names.push(m.get(i).name)
            Manga.setOrder(names)
        }

        // Cover viewer: every cover a series has, full size; one can be picked
        // as the series' cover. Opened from the series page.
        // Filter panel (doujin library): tags, parodies, characters, language,
        // censorship, from each work's metadata. T opens it.
        property bool filters: false
        property string facetTab: "tags"          // tags · parodies · characters
        onFiltersChanged: if (filters) facetSearch.forceActiveFocus(); else takeKeys()

        property bool gallery: false
        onGalleryChanged: takeKeys()
        property int galleryIndex: 0
        readonly property var galleryCovers: Manga.current ? Manga.current.covers : []
        function openGallery() {
            let c = galleryCovers
            if (!c.length) return
            let i = c.findIndex(x => x.path === Manga.current.art)
            galleryIndex = Math.max(0, i)
            gallery = true
        }
        function galleryStep(d) {
            let n = galleryCovers.length
            if (n) galleryIndex = (galleryIndex + d + n) % n
        }
        Connections {
            target: Manga
            function onViewChanged() { if (Manga.view !== "series") win.gallery = false }
        }

        // Deleting needs a second press within 3 s, like the login screen's
        // reboot key. `armed` names what the first press picked:
        // "series:<name>" or "chapter:<file>".
        property string armed: ""
        Timer { id: disarm; interval: 3000; onTriggered: win.armed = "" }
        function confirm(what, run) {
            if (armed === what) { armed = ""; disarm.stop(); run(); return }
            armed = what
            disarm.restart()
        }
        function deleteSeries(name) { confirm("series:" + name, () => Manga.deleteSeries(name)) }
        function deleteChapter(file) { confirm("chapter:" + file, () => Manga.deleteChapter(file)) }

        // |/-\ while something runs.
        property int spinStep: 0
        Timer {
            interval: 110; repeat: true
            running: Manga.checking || Manga.downloading || Manga.fetchingCovers
            onTriggered: win.spinStep = (win.spinStep + 1) % 4
        }
        readonly property string spin: Tui.spinner[spinStep]

        // Scanlines over the background (not over the pages being read).
        Canvas {
            anchors.fill: parent
            visible: Manga.view !== "reader"
            opacity: 0.06
            onPaint: {
                let ctx = getContext("2d")
                ctx.fillStyle = "#000"
                for (let y = 0; y < height; y += 3) ctx.fillRect(0, y, width, 1)
            }
            onHeightChanged: requestPaint()
        }

        FocusScope {
            id: keys
            anchors.fill: parent
            focus: true
            Component.onCompleted: forceActiveFocus()

            Keys.onPressed: event => {
                let k = event.key
                event.accepted = true
                if (win.filters) {
                    if (k === Qt.Key_Escape || k === Qt.Key_T) { win.filters = false; return }
                    if (k === Qt.Key_F7) { Manga.clearFacets(); return }
                    if (k === Qt.Key_Tab) {
                        let tabs = ["tags", "parodies", "characters"]
                        win.facetTab = tabs[(tabs.indexOf(win.facetTab) + 1) % tabs.length]
                        return
                    }
                    return
                }
                if (win.gallery) {
                    let c = win.galleryCovers[win.galleryIndex]
                    if (k === Qt.Key_Escape || k === Qt.Key_V) { win.gallery = false; return }
                    if (k === Qt.Key_Left || k === Qt.Key_Up) { win.galleryStep(-1); return }
                    if (k === Qt.Key_Right || k === Qt.Key_Down || k === Qt.Key_Space) { win.galleryStep(1); return }
                    if (k === Qt.Key_Home) { win.galleryIndex = 0; return }
                    if (k === Qt.Key_End) { win.galleryIndex = win.galleryCovers.length - 1; return }
                    if ((k === Qt.Key_Return || k === Qt.Key_Enter) && c) { Manga.setCover(Manga.current.name, c.path); return }
                    if (k === Qt.Key_F7) { Manga.setCover(Manga.current.name, ""); return }
                    return
                }
                if (k === Qt.Key_Escape) { Manga.back(); return }
                if (Manga.view === "reader") {
                    let fwd = Manga.rtl ? Qt.Key_Left : Qt.Key_Right
                    let bwd = Manga.rtl ? Qt.Key_Right : Qt.Key_Left
                    if (k === fwd || k === Qt.Key_Space || k === Qt.Key_PageDown) {
                        // Fit-width pages scroll first, then turn.
                        if (k !== fwd && !reader.atEnd()) { reader.scrollBy(0.85); return }
                        Manga.next(); return
                    }
                    if (k === bwd || k === Qt.Key_Backspace || k === Qt.Key_PageUp) {
                        if (k !== bwd && !reader.atStart()) { reader.scrollBy(-0.85); return }
                        Manga.prev(); return
                    }
                    if (k === Qt.Key_Down) { reader.scrollBy(0.25); return }
                    if (k === Qt.Key_Up) { reader.scrollBy(-0.25); return }
                    if (k === Qt.Key_Home) { Manga.goTo(0); return }
                    if (k === Qt.Key_End) { Manga.goTo(Manga.pages.length - 1); return }
                    if (k === Qt.Key_W) { Manga.setFit(Manga.fit === "width" ? "page" : "width"); return }
                    if (k === Qt.Key_D) { Manga.setRtl(!Manga.rtl); return }
                    event.accepted = false
                    return
                }
                // Library and series share the F-keys.
                if (k === Qt.Key_F2) { Manga.checkUpdates(Manga.view === "series" ? Manga.current.name : ""); return }
                if (k === Qt.Key_F3) { Manga.downloadUpdates(Manga.view === "series" ? Manga.current.name : ""); return }
                if (k === Qt.Key_F4) { Manga.showLog(); return }
                if (k === Qt.Key_F8 && Manga.downloading) { Manga.cancelDownloads(); return }
                if (Manga.view === "series") {
                    if (k === Qt.Key_C) { Manga.openChapter(Manga.resumeIndex(Manga.current)); return }
                    if (k === Qt.Key_V) { win.openGallery(); return }
                    if (k === Qt.Key_Delete) {
                        let c = Manga.current.chapters[chapters.currentIndex]
                        if (c) win.deleteChapter(c.file)
                        return
                    }
                    if (k === Qt.Key_F9) { win.deleteSeries(Manga.current.name); return }
                    if (k === Qt.Key_F5) { Manga.markSeries(Manga.current.name, true); return }
                    if (k === Qt.Key_F6) { Manga.markSeries(Manga.current.name, false); return }
                    event.accepted = false     // the list handles arrows / Enter
                    return
                }
                if (k === Qt.Key_R) { Manga.refresh(); return }
                if (k === Qt.Key_Slash) { filterInput.forceActiveFocus(); return }
                if (k === Qt.Key_T && Manga.flat) { win.filters = true; return }
                if (k === Qt.Key_F7 && Manga.flat) { Manga.clearFacets(); return }
                if (k === Qt.Key_Delete && grid.currentIndex >= 0 && grid.currentIndex < libModel.count) {
                    win.deleteSeries(libModel.get(grid.currentIndex).name)
                    return
                }
                event.accepted = false
            }

            // ── Header (library and series) ─────────────────────────────────
            // Left: where you are. Right: what is running (check / downloads).
            Item {
                id: header
                visible: Manga.view !== "reader"
                x: 26; y: 20
                width: parent.width - 52
                height: 40

                Row {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 12
                    Text {
                        id: hdrTitle
                        text: Manga.collection + (Manga.view === "series" ? " /" : "")
                        color: Tui.accent
                        font.family: Tui.font
                        font.pixelSize: Tui.fsXl
                        font.weight: Font.Bold
                        HoverHandler { cursorShape: Manga.view === "series" ? Qt.PointingHandCursor : Qt.ArrowCursor }
                        TapHandler { onTapped: if (Manga.view === "series") Manga.back() }
                    }
                    Text {
                        anchors.baseline: hdrTitle.baseline
                        text: Manga.view === "series"
                            ? (Manga.current ? Manga.current.chapters.length + " chapters · " + Manga.current.done + " read" : "")
                            : Manga.flat ? Manga.series.length + " works"
                                           + (Manga.filter ? " · " + Manga.sorted.length + " shown" : "")
                            : Manga.series.length + " series · " + win.chapterCount() + " chapters"
                              + (Manga.checked ? " · checked " + Qt.formatDateTime(new Date(Manga.checked * 1000), "yyyy-MM-dd HH:mm") : "")
                        color: Tui.dim
                        font.family: Tui.font
                        font.pixelSize: Tui.fsSm
                    }
                }

                // Activity: update check with its cells, downloads with spinner.
                Column {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6
                    Row {
                        anchors.right: parent.right
                        spacing: 10
                        visible: Manga.checking
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: {
                                let c = Manga.checkState
                                return c ? win.spin + " checking " + (c.i + 1) + "/" + c.n : win.spin + " checking"
                            }
                            color: Tui.fg
                            font.family: Tui.font
                            font.pixelSize: Tui.fsSm
                        }
                        TuiCells {
                            anchors.verticalCenter: parent.verticalCenter
                            cells: 16
                            cell: 7
                            value: Manga.checkState ? Manga.checkState.i / Math.max(1, Manga.checkState.n) : 0
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.min(implicitWidth, 220)
                            elide: Text.ElideRight
                            text: Manga.checkState ? Manga.checkState.name : ""
                            color: Tui.dim
                            font.family: Tui.font
                            font.pixelSize: Tui.fsSm
                        }
                    }
                    Row {
                        anchors.right: parent.right
                        spacing: 10
                        visible: Manga.downloading
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.min(implicitWidth, header.width * 0.5)
                            elide: Text.ElideRight
                            text: {
                                let q = Manga.queue
                                if (!q) return ""
                                let c = q.current
                                let t = win.spin + " " + (c ? "get " + c.name + (c.chapter ? " / " + c.chapter : "") : "starting")
                                return t + (q.items.length ? "  +" + q.items.length + " queued" : "")
                            }
                            color: Tui.fg
                            font.family: Tui.font
                            font.pixelSize: Tui.fsSm
                        }
                    }
                }
            }

            // ── F-key bar (library and series) ──────────────────────────────
            Row {
                id: fbar
                visible: Manga.view !== "reader" && !win.gallery && !win.filters
                anchors { left: parent.left; bottom: parent.bottom; leftMargin: 22; bottomMargin: 16 }
                spacing: 14
                TuiKey {
                    visible: Manga.view === "series"
                    key: "↵"; label: "read"
                    onClicked: Manga.openChapter(chapters.currentIndex)
                }
                TuiKey {
                    visible: Manga.view === "series"
                    key: "C"; label: "continue"; quiet: true
                    onClicked: Manga.openChapter(Manga.resumeIndex(Manga.current))
                }
                TuiKey {
                    visible: !Manga.flat
                    key: "F2"; label: Manga.checking ? "checking…" : "check"
                    busy: Manga.checking
                    onClicked: Manga.checkUpdates(Manga.view === "series" ? Manga.current.name : "")
                }
                TuiKey {
                    visible: Manga.view === "series" ? (Manga.current && Manga.current.updates > 0) : Manga.updateCount > 0
                    key: "F3"
                    label: Manga.view === "series" ? "get " + (Manga.current ? Manga.current.updates : 0) + " new"
                                                   : "get new (" + Manga.updateCount + ")"
                    onClicked: Manga.downloadUpdates(Manga.view === "series" ? Manga.current.name : "")
                }
                TuiKey { visible: !Manga.flat; key: "F4"; label: "log"; quiet: true; onClicked: Manga.showLog() }
                TuiKey {
                    visible: Manga.flat && Manga.view === "library"
                    key: "T"; label: Manga.facetCount ? "filters (" + Manga.facetCount + ")" : "tags & filters"
                    quiet: !Manga.facetCount
                    onClicked: win.filters = true
                }
                TuiKey {
                    visible: Manga.view === "series"
                    key: "F5"; label: "all read"; quiet: true
                    onClicked: Manga.markSeries(Manga.current.name, true)
                }
                TuiKey {
                    visible: Manga.view === "series"
                    key: "F6"; label: "all unread"; quiet: true
                    onClicked: Manga.markSeries(Manga.current.name, false)
                }
                TuiKey {
                    visible: Manga.downloading
                    key: "F8"; label: "stop downloads"; quiet: true
                    onClicked: Manga.cancelDownloads()
                }
                TuiKey {
                    visible: Manga.view === "series"
                    readonly property bool on: Manga.current !== null && win.armed === "series:" + Manga.current.name
                    key: "F9"; quiet: true; danger: on
                    label: on ? "delete series? F9 again" : "delete series"
                    onClicked: win.deleteSeries(Manga.current.name)
                }
                // Library only: on a series page this hint is on the chapter panel.
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: Manga.view === "library" && libModel.count > 0
                    readonly property bool on: win.armed.startsWith("series:")
                    readonly property string what: Manga.flat ? "work" : "series"
                    text: on ? "del again: " + what + " to the trash"
                        : "del: delete " + what + (Manga.flat ? " · right-click: read / unread" : "")
                    color: on ? Tui.danger : Tui.dim
                    font.family: Tui.font
                    font.pixelSize: Tui.fsSm
                }
                TuiKey { key: "esc"; label: Manga.view === "series" ? "back" : "close"; quiet: true; onClicked: Manga.back() }
            }

            // ── Library ─────────────────────────────────────────────────────
            Item {
                id: library
                anchors.fill: parent
                visible: Manga.view === "library"
                enabled: !win.filters

                // Sort tabs.
                Row {
                    id: sortRow
                    x: 26; y: 76
                    spacing: 8
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "sort"
                        color: Tui.dim
                        font.family: Tui.font
                        font.pixelSize: Tui.fsSm
                        rightPadding: 4
                    }
                    Repeater {
                        model: Manga.flat ? [["recent", "last read"], ["newest", "newest"], ["oldest", "oldest"],
                                             ["name", "a-z"], ["manual", "custom"]]
                                          : [["recent", "last read"], ["updated", "updates"], ["name", "a-z"], ["manual", "custom"]]
                        TuiTab {
                            required property var modelData
                            label: modelData[1]
                            selected: Manga.sort === modelData[0]
                            onClicked: Manga.setSort(modelData[0])
                        }
                    }
                    // Filter by title / artist; "/" jumps here.
                    Item { width: 18; height: 1 }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "filter"
                        color: Tui.dim
                        font.family: Tui.font
                        font.pixelSize: Tui.fsSm
                        rightPadding: 4
                    }
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 220
                        height: 28
                        color: "transparent"
                        border.width: Tui.border
                        border.color: filterInput.activeFocus || filterInput.text ? Tui.line : Tui.lineDim
                        TextInput {
                            id: filterInput
                            anchors { fill: parent; leftMargin: 8; rightMargin: 8 }
                            verticalAlignment: TextInput.AlignVCenter
                            clip: true
                            text: Manga.filter
                            onTextChanged: if (Manga.filter !== text) Manga.filter = text
                            color: Tui.fg
                            font.family: Tui.font
                            font.pixelSize: Tui.fsSm
                            selectByMouse: true
                            selectionColor: Tui.accent
                            selectedTextColor: Tui.accentInk
                            cursorDelegate: Rectangle { width: 7; color: Tui.accent; visible: filterInput.activeFocus }
                            // Enter: to the results; Esc: clear, then leave.
                            onAccepted: { grid.currentIndex = 0; win.takeKeys() }
                            Keys.onEscapePressed: {
                                if (text) text = ""
                                else win.takeKeys()
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                visible: !filterInput.text && !filterInput.activeFocus
                                text: "/ title or artist"
                                color: Tui.dim
                                font: filterInput.font
                            }
                        }
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        leftPadding: 8
                        visible: Manga.sort === "manual"
                        text: "drag covers to reorder"
                        color: Tui.dim
                        font.family: Tui.font
                        font.pixelSize: Tui.fsXs
                    }
                }

                Text {
                    anchors.centerIn: parent
                    width: parent.width - 80
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    visible: !Manga.loading && Manga.series.length === 0
                    text: Manga.error || "nothing here yet.\n\nput .cbz files in ~/Manga/<series>/, or download with\n/manga <url> in the launcher."
                    color: Tui.dim
                    font.family: Tui.font
                    font.pixelSize: Tui.fsLg
                }

                // The filters in force, as chips (a click drops one); T edits them.
                Flow {
                    id: activeRow
                    visible: Manga.flat && Manga.facetCount > 0
                    x: 26; y: 116
                    width: parent.width - 52
                    spacing: 8
                    Text {
                        height: 26
                        verticalAlignment: Text.AlignVCenter
                        text: Manga.sorted.length + " match"
                        color: Tui.dim
                        font.family: Tui.font
                        font.pixelSize: Tui.fsSm
                        rightPadding: 4
                    }
                    Repeater {
                        model: Object.keys(Manga.facets)
                        TuiChip {
                            required property string modelData
                            label: modelData.replace(/^unc:/, "").replace(/^[a-z]+:/, "")
                            mode: Manga.facets[modelData] || 0
                            onClicked: {
                                let f = Object.assign({}, Manga.facets)
                                delete f[modelData]
                                Manga.facets = f
                            }
                        }
                    }
                    TuiKey { key: "F7"; label: "clear"; quiet: true; onClicked: Manga.clearFacets() }
                }

                // The grid's own model, so a drag can move covers live; rebuilt
                // from Manga.sorted whenever that changes (not mid-drag).
                ListModel { id: libModel }
                function sync() {
                    if (win.dragging) return
                    let names = Manga.sorted.map(x => x.name)
                    let same = names.length === libModel.count
                    for (let i = 0; same && i < names.length; i++) same = libModel.get(i).name === names[i]
                    if (same) return
                    libModel.clear()
                    for (let n of names) libModel.append({ name: n })
                }
                Connections {
                    target: Manga
                    function onSortedChanged() { library.sync() }
                }
                Component.onCompleted: sync()

                GridView {
                    id: grid
                    anchors { fill: parent; topMargin: activeRow.visible ? 162 : 122; leftMargin: 18; rightMargin: 10; bottomMargin: 58 }
                    clip: true
                    focus: Manga.view === "library"
                    model: libModel
                    readonly property int cols: Math.max(2, Math.floor(width / 200))
                    cellWidth: Math.floor(width / cols)
                    cellHeight: (cellWidth - 26) * 1.45 + 74
                    keyNavigationEnabled: true
                    highlightFollowsCurrentItem: false
                    function openCurrent() {
                        if (currentIndex >= 0 && currentIndex < libModel.count)
                            Manga.openSeries(win.seriesNamed(libModel.get(currentIndex).name))
                    }
                    Keys.onReturnPressed: openCurrent()
                    Keys.onEnterPressed: openCurrent()
                    // Covers slide into place while one is dragged.
                    moveDisplaced: Transition { NumberAnimation { properties: "x,y"; duration: 160; easing.type: Easing.OutCubic } }
                    // A wheel notch moves most of a row of covers.
                    MangaScroller { target: grid; wheelStep: Math.round(grid.cellHeight * 0.6) }

                    delegate: DropArea {
                        id: card
                        required property string name
                        required property int index
                        readonly property var s: win.seriesNamed(name)
                        readonly property int visualIndex: index
                        width: grid.cellWidth
                        height: grid.cellHeight
                        readonly property bool current: GridView.isCurrentItem
                        readonly property bool armed: win.armed === "series:" + name
                        // Chapters read; for a single-file work, how far into it.
                        readonly property real readFrac: {
                            if (!s) return 0
                            if (s.chapters.length !== 1) return s.done / Math.max(1, s.chapters.length)
                            let c = s.chapters[0]
                            return c.done ? 1 : c.read && c.pages ? (c.page + 1) / c.pages : 0
                        }
                        readonly property bool active: current || hover.hovered

                        onEntered: drag => {
                            let from = drag.source.visualIndex
                            if (from !== card.visualIndex) libModel.move(from, card.visualIndex, 1)
                        }

                        Item {
                            id: tile
                            width: card.width
                            height: card.height
                            anchors.horizontalCenter: card.horizontalCenter
                            anchors.verticalCenter: card.verticalCenter
                            visible: card.s !== null

                            Drag.active: dragH.active
                            Drag.source: card
                            Drag.hotSpot.x: width / 2
                            Drag.hotSpot.y: height / 2

                            states: State {
                                when: dragH.active
                                ParentChange { target: tile; parent: grid }
                                AnchorChanges {
                                    target: tile
                                    anchors.horizontalCenter: undefined
                                    anchors.verticalCenter: undefined
                                }
                                PropertyChanges { target: tile; z: 10; opacity: 0.85 }
                            }

                            DragHandler {
                                id: dragH
                                enabled: Manga.sort === "manual"
                                onActiveChanged: {
                                    win.dragging = active
                                    if (!active) win.saveOrder()
                                }
                            }

                            // Cover: square, bordered, hard shadow; lifts a
                            // little when picked.
                            Item {
                                id: coverBox
                                x: 8 + (card.active ? -2 : 0)
                                y: 14 + (card.active ? -2 : 0)
                                Behavior on x { NumberAnimation { duration: Tui.dFast } }
                                Behavior on y { NumberAnimation { duration: Tui.dFast } }
                                width: card.width - 26
                                height: width * 1.45

                                Rectangle {
                                    x: card.active ? Tui.shadow + 2 : Tui.shadow
                                    y: x
                                    width: parent.width; height: parent.height
                                    color: Tui.shadowColor
                                }
                                Rectangle {
                                    anchors.fill: parent
                                    color: Tui.bg1
                                    border.width: Tui.border
                                    border.color: card.armed ? Tui.danger
                                                : card.current ? Tui.accent : card.active ? Tui.line : Tui.lineDim
                                    Image {
                                        anchors.fill: parent
                                        anchors.margins: Tui.border
                                        source: card.s && card.s.cover ? Manga.url(card.s.cover) : ""
                                        fillMode: Image.PreserveAspectCrop
                                        asynchronous: true
                                        opacity: card.active ? 1 : 0.86
                                    }
                                }
                                // Armed for deleting: a red tab where "+N new" goes.
                                Rectangle {
                                    visible: card.armed
                                    z: 1
                                    x: 10
                                    y: -height / 2 + 1
                                    width: armedText.implicitWidth + 14
                                    height: armedText.implicitHeight + 4
                                    color: Tui.danger
                                    Text {
                                        id: armedText
                                        anchors.centerIn: parent
                                        text: "del again: to trash"
                                        color: Tui.accentInk
                                        font.family: Tui.font
                                        font.pixelSize: Tui.fsSm
                                        font.weight: Font.Bold
                                    }
                                }
                                // New chapters: a title tab on the cover's top border.
                                // "3 new" = downloaded and not read yet; "+2" = found
                                // on the site by a check, not downloaded yet.
                                Rectangle {
                                    visible: card.s && (card.s.fresh > 0 || card.s.updates > 0) && !card.armed
                                    x: 10
                                    y: -height / 2 + 1
                                    width: badge.implicitWidth + 14
                                    height: badge.implicitHeight + 4
                                    color: Tui.accent
                                    Text {
                                        id: badge
                                        anchors.centerIn: parent
                                        text: !card.s ? ""
                                            : (card.s.fresh ? card.s.fresh + " new" : "")
                                              + (card.s.fresh && card.s.updates ? " · " : "")
                                              + (card.s.updates ? "+" + card.s.updates + (card.s.fresh ? "" : " to get") : "")
                                        color: Tui.accentInk
                                        font.family: Tui.font
                                        font.pixelSize: Tui.fsSm
                                        font.weight: Font.Bold
                                    }
                                }
                            }
                            Text {
                                anchors { top: coverBox.bottom; topMargin: 12; left: coverBox.left; right: coverBox.right }
                                // Archive names read as a title, with who made it below.
                                text: card.s ? (card.s.title || card.s.name) : ""
                                elide: Text.ElideRight
                                color: card.active ? Tui.fg : Tui.mix(Tui.fg, Tui.bg, 0.2)
                                font.family: Tui.font
                                font.pixelSize: Tui.fsMd
                                font.weight: Font.DemiBold
                            }
                            // Chapters read, as pixel cells, and the count.
                            Row {
                                anchors { top: coverBox.bottom; topMargin: 34; left: coverBox.left }
                                spacing: 8
                                TuiCells {
                                    anchors.verticalCenter: parent.verticalCenter
                                    cells: 10
                                    cell: 6
                                    value: card.readFrac
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: !card.s ? "" : card.s.by ? card.s.by
                                        : Manga.flat ? Math.round(card.readFrac * 100) + "%"
                                        : card.s.done + "/" + card.s.chapters.length
                                    color: Tui.dim
                                    font.family: Tui.font
                                    font.pixelSize: Tui.fsXs
                                }
                            }
                            // Hovering selects, like the arrow keys (so Del and Enter
                            // act on what the pointer is on).
                            HoverHandler {
                                id: hover
                                cursorShape: Manga.sort === "manual" ? Qt.OpenHandCursor : Qt.PointingHandCursor
                                onHoveredChanged: if (hovered && !win.dragging && !win.filters) grid.currentIndex = card.index
                            }
                            TapHandler { onTapped: { grid.currentIndex = card.index; Manga.openSeries(card.s) } }
                            // Doujin library: right-click marks a work unread (read or
                            // started) or read (not started). In the manga library a
                            // cover is a whole series, so nothing happens there.
                            MouseArea {
                                anchors.fill: parent
                                enabled: Manga.flat
                                acceptedButtons: Qt.RightButton
                                onClicked: if (card.s) Manga.markSeries(card.s.name, card.readFrac === 0)
                            }
                        }
                    }
                }
            }

            // ── Series: chapter list ────────────────────────────────────────
            Item {
                anchors.fill: parent
                visible: Manga.view === "series"
                // Under the cover viewer: no hover or clicks reach the chapters.
                enabled: !win.gallery

                // Cover + title + continue + where updates come from.
                Item {
                    id: head
                    x: 26; y: 80
                    width: parent.width - 52
                    height: 196

                    Item {
                        id: headCover
                        width: 132; height: 190
                        readonly property int count: Manga.current ? Manga.current.covers.length : 0
                        Rectangle { x: Tui.shadow; y: Tui.shadow; width: parent.width; height: parent.height; color: Tui.shadowColor }
                        HoverHandler { id: coverHover; cursorShape: headCover.count ? Qt.PointingHandCursor : Qt.ArrowCursor }
                        TapHandler { onTapped: win.openGallery() }
                        Rectangle {
                            anchors.fill: parent
                            color: Tui.bg1
                            border.width: Tui.border
                            border.color: coverHover.hovered && headCover.count ? Tui.accent : Tui.line
                            Image {
                                anchors.fill: parent
                                anchors.margins: Tui.border
                                source: Manga.current && Manga.current.cover ? Manga.url(Manga.current.cover) : ""
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                            }
                        }
                    }

                    Column {
                        anchors { left: headCover.right; leftMargin: 28; right: parent.right; top: parent.top }
                        spacing: 10
                        Text {
                            width: parent.width
                            text: Manga.current ? Manga.current.name : ""
                            wrapMode: Text.Wrap
                            maximumLineCount: 2
                            elide: Text.ElideRight
                            color: Tui.fg
                            font.family: Tui.font
                            font.pixelSize: Tui.fsXl - 4
                            font.weight: Font.Bold
                        }
                        Row {
                            spacing: 10
                            TuiCells {
                                anchors.verticalCenter: parent.verticalCenter
                                cells: 20
                                cell: 8
                                value: Manga.current ? Manga.current.done / Math.max(1, Manga.current.chapters.length) : 0
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: Manga.current
                                    ? Math.round(100 * Manga.current.done / Math.max(1, Manga.current.chapters.length)) + "% read"
                                    : ""
                                color: Tui.dim
                                font.family: Tui.font
                                font.pixelSize: Tui.fsSm
                            }
                        }
                        // How many covers there are; clicking (or V) opens the viewer.
                        Text {
                            visible: headCover.count > 1
                            text: headCover.count + " covers · v to view"
                            color: coversHover.hovered ? Tui.accent : Tui.dim
                            font.family: Tui.font
                            font.pixelSize: Tui.fsSm
                            HoverHandler { id: coversHover; cursorShape: Qt.PointingHandCursor }
                            TapHandler { onTapped: win.openGallery() }
                        }
                        Item { width: 1; height: 4 }
                        TuiKey {
                            label: {
                                let s = Manga.current
                                if (!s) return ""
                                let i = Manga.resumeIndex(s)
                                let n = win.splitName(s.chapters[i].name)
                                return "▶ " + (s.resume < 0 ? "start" : "continue") + "  ch " + (n.num || n.title)
                                    + (s.chapters[i].read && !s.chapters[i].done
                                       ? "  p " + (s.chapters[i].page + 1) + "/" + s.chapters[i].pages : "")
                            }
                            onClicked: Manga.openChapter(Manga.resumeIndex(Manga.current))
                        }
                        Item { width: 1; height: 2 }
                        // Where updates come from, or a field to say so.
                        Text {
                            width: parent.width
                            visible: Manga.current && Manga.current.source !== ""
                            text: Manga.current ? (Manga.current.updateError
                                ? "update check failed: " + Manga.current.updateError
                                : "updates from " + win.host(Manga.current.source)) : ""
                            elide: Text.ElideRight
                            color: Manga.current && Manga.current.updateError ? Tui.warn : Tui.dim
                            font.family: Tui.font
                            font.pixelSize: Tui.fsSm
                        }
                        Row {
                            visible: Manga.current && Manga.current.source === ""
                            spacing: 0
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "url: "
                                color: Tui.dim
                                font.family: Tui.font
                                font.pixelSize: Tui.fsSm
                            }
                            Rectangle {
                                width: Math.min(head.width - headCover.width - 80, 520)
                                height: 26
                                color: "transparent"
                                border.width: Tui.border
                                border.color: urlInput.activeFocus ? Tui.line : Tui.lineDim
                                TextInput {
                                    id: urlInput
                                    anchors { fill: parent; leftMargin: 8; rightMargin: 8 }
                                    verticalAlignment: TextInput.AlignVCenter
                                    clip: true
                                    color: Tui.fg
                                    font.family: Tui.font
                                    font.pixelSize: Tui.fsSm
                                    selectByMouse: true
                                    selectionColor: Tui.accent
                                    selectedTextColor: Tui.accentInk
                                    cursorDelegate: Rectangle { width: 7; color: Tui.accent; visible: urlInput.activeFocus }
                                    onAccepted: {
                                        if (/^https?:\/\//.test(text)) { Manga.setSource(Manga.current.name, text); text = "" }
                                        win.takeKeys()
                                    }
                                    // Esc in the field: leave it, and go back as usual.
                                    Keys.onEscapePressed: { text = ""; win.takeKeys(); Manga.back() }
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: !urlInput.text && !urlInput.activeFocus
                                        text: "paste the series url for updates, enter saves"
                                        color: Tui.dim
                                        font: urlInput.font
                                    }
                                }
                            }
                        }
                    }
                }

                TuiPanel {
                    id: chapterPanel
                    anchors { left: parent.left; right: parent.right; top: head.bottom; bottom: parent.bottom
                              leftMargin: 26; rightMargin: 34; topMargin: 26; bottomMargin: 62 }
                    title: "chapters"
                    note: win.armed.startsWith("chapter:") ? "del again: chapter to the trash"
                        : "right-click: read / unread · shift: up to here · del: delete"
                    noteColor: win.armed.startsWith("chapter:") ? Tui.danger : Tui.dim
                    padding: 6

                    ListView {
                        id: chapters
                        anchors.fill: parent
                        anchors.topMargin: 6
                        clip: true
                        // Not while the cover viewer is open: Enter and the arrows are its.
                        focus: Manga.view === "series" && !win.gallery
                        model: Manga.current ? Manga.current.chapters : []
                        keyNavigationEnabled: true
                        highlightMoveDuration: 0
                        // Start on the chapter "continue" goes to whenever a series
                        // is opened from the library -- not on library refreshes or
                        // coming back from the reader (that would undo what the
                        // arrows or the pointer picked).
                        property string lastView: ""      // set once, then by hand (not a binding)
                        Component.onCompleted: lastView = Manga.view
                        Connections {
                            target: Manga
                            function onViewChanged() {
                                if (Manga.view === "series" && chapters.lastView === "library" && Manga.current) {
                                    chapters.currentIndex = Manga.resumeIndex(Manga.current)
                                    chapters.positionViewAtIndex(chapters.currentIndex, ListView.Center)
                                }
                                chapters.lastView = Manga.view
                            }
                        }
                        Keys.onReturnPressed: Manga.openChapter(currentIndex)
                        Keys.onEnterPressed: Manga.openChapter(currentIndex)
                        // A wheel notch moves four chapters.
                        MangaScroller { target: chapters; wheelStep: 34 * 4 }

                        delegate: Rectangle {
                            id: row
                            required property var modelData
                            required property int index
                            readonly property var parts: win.splitName(modelData.name)
                            readonly property bool started: modelData.read > 0 && !modelData.done
                            readonly property bool armed: win.armed === "chapter:" + modelData.file
                            readonly property real progress: modelData.done ? 1
                                : started && modelData.pages ? (modelData.page + 1) / modelData.pages : 0
                            width: chapters.width
                            height: 34
                            // Selection is the accent block; every other row a shade lighter.
                            color: row.armed ? Tui.alpha(Tui.danger, 0.28)
                                 : ListView.isCurrentItem ? Tui.alpha(Tui.accent, 0.22)
                                 : rowHover.hovered ? Tui.alpha(Tui.accent, 0.10)
                                 : row.index % 2 ? Tui.stripe : "transparent"

                            Rectangle {      // selection bar on the left edge
                                visible: row.ListView.isCurrentItem
                                width: 3; height: parent.height
                                color: Tui.accent
                            }

                            // Read mark, first thing on the row: a pixel cell that
                            // fills with the reading progress.
                            Rectangle {
                                id: mark
                                x: 14
                                anchors.verticalCenter: parent.verticalCenter
                                width: 12; height: 12
                                radius: 1.5
                                color: "transparent"
                                border.width: 2
                                border.color: row.modelData.done || row.started ? Tui.accent : Tui.lineDim
                                Rectangle {
                                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                                    height: parent.height * row.progress
                                    radius: 1
                                    color: Tui.accent
                                }
                            }
                            Text {
                                id: num
                                x: 38
                                width: 64
                                anchors.verticalCenter: parent.verticalCenter
                                horizontalAlignment: Text.AlignRight
                                text: row.parts.num ? "ch " + row.parts.num : ""
                                color: row.modelData.done ? Tui.dim : Tui.accent
                                font.family: Tui.font
                                font.pixelSize: Tui.fsMd
                                font.weight: Font.Bold
                            }
                            Text {
                                anchors { left: num.right; leftMargin: 16; right: tail.left; rightMargin: 12; verticalCenter: parent.verticalCenter }
                                // The translation group, dimmed, when two groups did the chapter.
                                textFormat: Text.StyledText
                                text: win.esc(row.parts.title || (row.parts.num ? "" : row.modelData.name)) + (row.modelData.group
                                    ? '  <font color="' + Tui.dim + '">[' + win.esc(row.modelData.group) + ']</font>' : "")
                                elide: Text.ElideRight
                                color: row.modelData.done ? Tui.dim : Tui.fg
                                font.family: Tui.font
                                font.pixelSize: Tui.fsMd
                            }
                            Text {
                                id: tail
                                anchors { right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
                                text: row.armed ? "del again: to trash"
                                    : row.modelData.new && !row.started ? "new"
                                    : row.modelData.done ? "read"
                                    : row.started ? "p " + (row.modelData.page + 1) + "/" + row.modelData.pages
                                    : ""
                                color: row.armed ? Tui.danger : row.started || row.modelData.new ? Tui.accent : Tui.dim
                                font.weight: row.modelData.new && !row.started && !row.armed ? Font.Bold : Font.Normal
                                font.family: Tui.font
                                font.pixelSize: Tui.fsSm
                            }
                            HoverHandler {
                                id: rowHover
                                cursorShape: Qt.PointingHandCursor
                                // Not through the cover viewer above it.
                                onHoveredChanged: if (hovered && !win.gallery) chapters.currentIndex = row.index
                            }
                            TapHandler { onTapped: Manga.openChapter(row.index) }
                            MouseArea {
                                anchors.fill: parent
                                acceptedButtons: Qt.RightButton
                                onClicked: mouse => {
                                    let before = (mouse.modifiers & Qt.ShiftModifier) !== 0
                                    Manga.markChapter(row.modelData.file, before || !row.modelData.done, before)
                                }
                            }
                        }
                    }
                }
            }

            // ── Filter panel (doujin library) ───────────────────────────────
            Rectangle {
                id: filterPanel
                anchors.fill: parent
                visible: win.filters && Manga.view === "library"
                color: Tui.alpha(Tui.bg, 0.97)
                z: 20
                MouseArea { anchors.fill: parent; onClicked: win.filters = false }   // outside the panel closes

                TuiPanel {
                    anchors { fill: parent; margins: 26; topMargin: 34; bottomMargin: 66 }
                    title: "filters"
                    note: Manga.sorted.length + " of " + Manga.series.length + " works match"
                    padding: 18
                    MouseArea { anchors.fill: parent }       // clicks inside stay inside

                    Column {
                        id: facetHead
                        width: parent.width
                        spacing: 12
                        MangaFacetRow {
                            title: "language"
                            items: Manga.facetCounts("languages").map(x => ({ key: "languages:" + x.v, label: x.v, n: x.n }))
                        }
                        MangaFacetRow {
                            title: "censorship"
                            items: {
                                let unc = Manga.sorted.filter(x => x.meta && x.meta.uncensored).length
                                let all = Manga.sorted.filter(x => x.meta).length
                                return [{ key: "unc:uncensored", label: "uncensored", n: unc },
                                        { key: "unc:censored", label: "censored", n: all - unc }]
                            }
                        }
                        Item { width: 1; height: 4 }
                        Row {
                            spacing: 8
                            Repeater {
                                model: [["tags", "tags"], ["parodies", "parodies"], ["characters", "characters"]]
                                TuiTab {
                                    required property var modelData
                                    label: modelData[1]
                                    selected: win.facetTab === modelData[0]
                                    onClicked: win.facetTab = modelData[0]
                                }
                            }
                            Item { width: 18; height: 1 }
                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 260
                                height: 28
                                color: "transparent"
                                border.width: Tui.border
                                border.color: facetSearch.activeFocus ? Tui.line : Tui.lineDim
                                TextInput {
                                    id: facetSearch
                                    anchors { fill: parent; leftMargin: 8; rightMargin: 8 }
                                    verticalAlignment: TextInput.AlignVCenter
                                    clip: true
                                    color: Tui.fg
                                    font.family: Tui.font
                                    font.pixelSize: Tui.fsSm
                                    selectionColor: Tui.accent
                                    selectedTextColor: Tui.accentInk
                                    cursorDelegate: Rectangle { width: 7; color: Tui.accent; visible: facetSearch.activeFocus }
                                    // Esc: clear the search, then close the panel.
                                    Keys.onEscapePressed: { if (text) text = ""; else win.filters = false }
                                    Keys.onTabPressed: {
                                        let tabs = ["tags", "parodies", "characters"]
                                        win.facetTab = tabs[(tabs.indexOf(win.facetTab) + 1) % tabs.length]
                                    }
                                    // Enter picks the first match.
                                    onAccepted: if (facetFlow.shown.length) Manga.toggleFacet(win.facetTab + ":" + facetFlow.shown[0].v)
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: !facetSearch.text
                                        text: "search " + win.facetTab + " · enter picks"
                                        color: Tui.dim
                                        font: facetSearch.font
                                    }
                                }
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                leftPadding: 8
                                text: "click: must have · again: must not · again: off"
                                color: Tui.dim
                                font.family: Tui.font
                                font.pixelSize: Tui.fsXs
                            }
                        }
                    }

                    // The chosen tab's values, most common in what is shown now first.
                    Flickable {
                        id: facetScroll
                        anchors { left: parent.left; right: parent.right; top: facetHead.bottom; bottom: parent.bottom; topMargin: 16 }
                        clip: true
                        contentHeight: facetFlow.height
                        boundsBehavior: Flickable.StopAtBounds
                        Flow {
                            id: facetFlow
                            width: facetScroll.width - 14
                            spacing: 8
                            readonly property var shown: {
                                let q = facetSearch.text.trim().toLowerCase()
                                let all = Manga.facetCounts(win.facetTab)
                                return q ? all.filter(x => x.v.includes(q)) : all
                            }
                            Repeater {
                                model: facetFlow.shown
                                TuiChip {
                                    required property var modelData
                                    label: modelData.v
                                    count: modelData.n
                                    mode: Manga.facetState(win.facetTab + ":" + modelData.v)
                                    onClicked: Manga.toggleFacet(win.facetTab + ":" + modelData.v)
                                }
                            }
                        }
                        MangaScroller { target: facetScroll; wheelStep: 120 }
                    }
                }

                Row {
                    anchors { left: parent.left; bottom: parent.bottom; leftMargin: 22; bottomMargin: 16 }
                    spacing: 14
                    TuiKey { key: "tab"; label: "next list"; quiet: true
                             onClicked: { let t = ["tags", "parodies", "characters"]; win.facetTab = t[(t.indexOf(win.facetTab) + 1) % 3] } }
                    TuiKey { key: "F7"; label: "clear all"; quiet: true; onClicked: Manga.clearFacets() }
                    TuiKey { key: "esc"; label: "done"; onClicked: win.filters = false }
                }
            }

            // ── Cover viewer (over the series page) ─────────────────────────
            Rectangle {
                id: viewer
                anchors.fill: parent
                visible: win.gallery && Manga.view === "series"
                color: Tui.alpha(Tui.bg, 0.97)
                z: 20
                readonly property var c: win.galleryCovers[win.galleryIndex] || null
                readonly property bool inUse: c !== null && Manga.current !== null && c.path === Manga.current.art

                MouseArea { anchors.fill: parent }       // nothing underneath takes clicks

                // The cover, as large as fits, in a bordered frame with a shadow.
                Item {
                    id: stage
                    anchors { left: parent.left; right: parent.right; top: parent.top; bottom: strip.top
                              topMargin: 46; bottomMargin: 30; leftMargin: 40; rightMargin: 40 }
                    Item {
                        id: frame
                        anchors.centerIn: parent
                        width: big.paintedWidth + 2 * Tui.border
                        height: big.paintedHeight + 2 * Tui.border
                        visible: big.status === Image.Ready
                        Rectangle { x: Tui.shadow + 4; y: Tui.shadow + 4; width: parent.width; height: parent.height; color: Tui.shadowColor }
                        Rectangle {
                            anchors.fill: parent
                            color: "transparent"
                            border.width: Tui.border
                            border.color: viewer.inUse ? Tui.accent : Tui.line
                        }
                    }
                    Image {
                        id: big
                        anchors.fill: parent
                        anchors.margins: Tui.border
                        source: viewer.c ? Manga.url(viewer.c.path) : ""
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                        smooth: true
                        mipmap: true
                    }
                    // Label tab on the frame's top border -- after the image, so
                    // the cover does not paint over its lower half.
                    Rectangle {
                        visible: frame.visible
                        x: frame.x + 16
                        y: frame.y - height / 2 + 1
                        width: capText.implicitWidth + 18
                        height: capText.implicitHeight + 6
                        color: Tui.accent
                        Text {
                            id: capText
                            anchors.centerIn: parent
                            text: viewer.c ? viewer.c.label + "  " + (win.galleryIndex + 1) + "/" + win.galleryCovers.length
                                           + (viewer.inUse ? "  · in use" : "") : ""
                            color: Tui.accentInk
                            font.family: Tui.font
                            font.pixelSize: Tui.fsSm + 1
                            font.weight: Font.Bold
                        }
                    }
                    // Click the left / right half to step.
                    MouseArea {
                        anchors.fill: parent
                        onClicked: mouse => win.galleryStep(mouse.x > width / 2 ? 1 : -1)
                        onWheel: wheel => win.galleryStep(wheel.angleDelta.y < 0 ? 1 : -1)
                    }
                }

                // Every cover, small; the one shown is outlined, the one in use tagged.
                ListView {
                    id: strip
                    anchors { left: parent.left; right: parent.right; bottom: viewerKeys.top
                              leftMargin: 40; rightMargin: 40; bottomMargin: 22 }
                    height: 132
                    orientation: ListView.Horizontal
                    spacing: 14
                    clip: true
                    model: win.galleryCovers
                    currentIndex: win.galleryIndex
                    highlightMoveDuration: 160
                    preferredHighlightBegin: width / 2 - 45
                    preferredHighlightEnd: width / 2 + 45
                    highlightRangeMode: ListView.ApplyRange
                    delegate: Item {
                        id: thumb
                        required property var modelData
                        required property int index
                        readonly property bool shown: index === win.galleryIndex
                        readonly property bool used: Manga.current !== null && modelData.path === Manga.current.art
                        width: 90
                        height: strip.height
                        Rectangle {
                            id: thumbBox
                            y: 8
                            width: 82; height: 116
                            color: Tui.bg1
                            border.width: Tui.border
                            border.color: thumb.shown ? Tui.accent : thumbHover.hovered ? Tui.line : Tui.lineDim
                            opacity: thumb.shown || thumbHover.hovered ? 1 : 0.7
                            Image {
                                anchors.fill: parent
                                anchors.margins: Tui.border
                                source: Manga.url(thumb.modelData.path)
                                sourceSize.height: 240
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                            }
                        }
                        Rectangle {
                            visible: thumb.used
                            x: 6; y: 2
                            width: useText.implicitWidth + 8
                            height: useText.implicitHeight + 2
                            color: Tui.accent
                            Text {
                                id: useText
                                anchors.centerIn: parent
                                text: "in use"
                                color: Tui.accentInk
                                font.family: Tui.font
                                font.pixelSize: Tui.fsXs
                                font.weight: Font.Bold
                            }
                        }
                        HoverHandler { id: thumbHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: win.galleryIndex = thumb.index }
                    }
                }

                Row {
                    id: viewerKeys
                    anchors { left: parent.left; bottom: parent.bottom; leftMargin: 22; bottomMargin: 16 }
                    spacing: 14
                    TuiKey { key: "← →"; label: "browse"; quiet: true; onClicked: win.galleryStep(1) }
                    TuiKey {
                        key: "↵"
                        label: viewer.inUse ? "in use" : "use as cover"
                        busy: viewer.inUse
                        onClicked: if (viewer.c) Manga.setCover(Manga.current.name, viewer.c.path)
                    }
                    TuiKey { key: "F7"; label: "default cover"; quiet: true; onClicked: Manga.setCover(Manga.current.name, "") }
                    TuiKey { key: "esc"; label: "close"; quiet: true; onClicked: win.gallery = false }
                    // More covers from a MangaDex page, e.g. for a series whose
                    // chapters come from another site.
                    Item { width: 12; height: 1 }
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 340
                        height: 28
                        color: "transparent"
                        border.width: Tui.border
                        border.color: coversUrl.activeFocus ? Tui.line : Tui.lineDim
                        TextInput {
                            id: coversUrl
                            anchors { fill: parent; leftMargin: 8; rightMargin: 8 }
                            verticalAlignment: TextInput.AlignVCenter
                            clip: true
                            enabled: !Manga.fetchingCovers
                            color: Tui.fg
                            font.family: Tui.font
                            font.pixelSize: Tui.fsSm
                            selectByMouse: true
                            selectionColor: Tui.accent
                            selectedTextColor: Tui.accentInk
                            cursorDelegate: Rectangle { width: 7; color: Tui.accent; visible: coversUrl.activeFocus }
                            onAccepted: {
                                if (/mangadex\.org\/(title|manga)\//.test(text)) { Manga.addCovers(Manga.current.name, text); text = "" }
                                win.takeKeys()
                            }
                            Keys.onEscapePressed: { text = ""; win.takeKeys() }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                visible: !coversUrl.text && !coversUrl.activeFocus
                                text: Manga.fetchingCovers ? win.spin + " fetching covers…"
                                    : "+ covers from a mangadex url (enter)"
                                color: Tui.dim
                                font: coversUrl.font
                            }
                        }
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: Manga.coversNote !== "" && !Manga.fetchingCovers
                        text: Manga.coversNote
                        color: Tui.dim
                        font.family: Tui.font
                        font.pixelSize: Tui.fsSm
                    }
                }
            }

            // ── Reader ──────────────────────────────────────────────────────
            Rectangle {
                id: reader
                anchors.fill: parent
                visible: Manga.view === "reader"
                color: "#0b0b0b"

                function atEnd() { return Manga.fit !== "width" || flick.atYEnd }
                function atStart() { return Manga.fit !== "width" || flick.atYBeginning }
                function scrollBy(f) {
                    if (Manga.fit !== "width") return
                    flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height,
                                                         flick.contentY + f * flick.height))
                }

                Flickable {
                    id: flick
                    anchors.fill: parent
                    clip: true
                    contentWidth: width
                    contentHeight: Math.max(height, pageImg.height)
                    boundsBehavior: Flickable.StopAtBounds
                    interactive: Manga.fit === "width"

                    Image {
                        id: pageImg
                        source: Manga.pages.length ? Manga.url(Manga.pages[Manga.page]) : ""
                        asynchronous: true
                        smooth: true
                        mipmap: true
                        fillMode: Image.PreserveAspectFit
                        // Fit page: whole page in the window. Fit width: as wide as
                        // the window (capped for very wide windows), scroll down.
                        width: Manga.fit === "width" ? Math.min(flick.width, 1400) : flick.width
                        height: Manga.fit === "width" && implicitWidth > 0
                            ? width * implicitHeight / implicitWidth : flick.height
                        x: (flick.width - width) / 2
                        onSourceChanged: flick.contentY = 0
                    }
                }

                // The next page, decoded ahead so turning is instant.
                Image {
                    visible: false
                    asynchronous: true
                    source: Manga.page + 1 < Manga.pages.length ? Manga.url(Manga.pages[Manga.page + 1]) : ""
                }

                // Click halves to turn; the wheel scrolls (fit width) or turns.
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton
                    onClicked: mouse => {
                        let right = mouse.x > width / 2
                        if (right !== Manga.rtl) Manga.next(); else Manga.prev()
                    }
                    onWheel: wheel => {
                        if (Manga.fit === "width") {
                            if (wheel.angleDelta.y < 0 && flick.atYEnd) Manga.next()
                            else if (wheel.angleDelta.y > 0 && flick.atYBeginning) Manga.prev()
                            else reader.scrollBy(-wheel.angleDelta.y / 120 * 0.2)
                        } else if (wheel.angleDelta.y < 0) Manga.next()
                        else if (wheel.angleDelta.y > 0) Manga.prev()
                    }
                }

                Text {
                    anchors.centerIn: parent
                    visible: Manga.loading || Manga.error.length > 0
                    text: Manga.error || "opening…"
                    color: Manga.error ? Tui.warn : "#bbbbbb"
                    font.family: Tui.font
                    font.pixelSize: Tui.fsLg
                }

                // Chapter and page tag, bottom corner, always shown.
                Item {
                    anchors { right: parent.right; bottom: parent.bottom; margins: 16 }
                    width: tag.width
                    height: tag.height
                    Rectangle { x: 5; y: 5; width: tag.width; height: tag.height; color: Qt.rgba(0, 0, 0, 0.5) }
                    Rectangle {
                        id: tag
                        width: tagRow.implicitWidth + 20
                        height: tagRow.implicitHeight + 10
                        color: Qt.rgba(0.04, 0.04, 0.04, 0.92)
                        border.width: Tui.border
                        border.color: Tui.line
                        Row {
                            id: tagRow
                            anchors.centerIn: parent
                            spacing: 10
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                visible: text !== ""
                                text: {
                                    if (!Manga.current || Manga.chapter < 0) return ""
                                    let n = win.splitName(Manga.current.chapters[Manga.chapter].name)
                                    return n.num ? "ch " + n.num : ""
                                }
                                color: Tui.fg
                                font.family: Tui.font
                                font.pixelSize: Tui.fsSm + 1
                                font.weight: Font.Bold
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: String(Manga.page + 1).padStart(String(Manga.pages.length).length, "0")
                                    + "/" + Manga.pages.length
                                color: Tui.accent
                                font.family: Tui.font
                                font.pixelSize: Tui.fsSm + 1
                                font.weight: Font.Bold
                            }
                            TuiCells {
                                anchors.verticalCenter: parent.verticalCenter
                                cells: 12
                                cell: 6
                                value: Manga.pages.length ? (Manga.page + 1) / Manga.pages.length : 0
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                visible: text !== ""
                                text: (Manga.rtl ? "rtl" : "") + (Manga.rtl && Manga.fit === "width" ? " · " : "")
                                    + (Manga.fit === "width" ? "fit width" : "")
                                color: Tui.dim
                                font.family: Tui.font
                                font.pixelSize: Tui.fsSm
                            }
                        }
                    }
                }
            }
        }
    }
}
