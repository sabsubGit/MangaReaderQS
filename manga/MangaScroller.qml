import QtQuick

// Slim scrollbar for any Flickable (ListView, GridView, Flickable), drawn here.
//
//     ListView { id: list; ...; Scroller { target: list } }
//
// Deliberately NOT QtQuick.Controls' ScrollBar. This shell runs on
// qqc2-desktop-style (picked up through the qt6ct/Kvantum platform theme), and
// that style paints a native track and handle for every ScrollBar underneath
// whatever contentItem we give it -- so each list showed two bars at once.
// Nothing here goes through a Controls style, so it looks the same regardless.
//
// Drag the handle or click the track to scroll. A mouse wheel notch scrolls
// `wheelStep` pixels with a short glide; the Flickable's own wheel handling moved
// only a few rows per notch. Touchpads keep the Flickable's native pixel scrolling.
Item {
    id: bar
    required property Flickable target
    property real wheelStep: 90            // pixels per wheel notch

    // Declared as a child of the flickable, QML would put this inside its
    // contentItem and it would scroll away with the list. Re-parent onto the
    // flickable itself so it stays put along the edge.
    parent: target
    z: 10

    readonly property bool scrollable: target.contentHeight > target.height + 1
    readonly property bool engaged: target.moving || track.containsMouse || track.pressed

    visible: scrollable
    width: 8
    height: target.height - 4
    x: target.width - width - 2
    y: 2

    // Handle length follows how much of the content is showing; its position
    // follows scroll progress (0..1), so it always reaches both ends of the track
    // even when the minimum length kicks in.
    readonly property real ratio: Math.min(1, target.visibleArea.heightRatio)
    readonly property real progress: {
        let room = 1 - ratio
        return room > 0.0001 ? Math.max(0, Math.min(1, target.visibleArea.yPosition / room)) : 0
    }

    function scrollToTrackY(my) {
        let f = (my - handle.height / 2) / Math.max(1, bar.height - handle.height)
        f = Math.max(0, Math.min(1, f))
        target.cancelFlick()
        target.contentY = target.originY + f * Math.max(0, target.contentHeight - target.height)
    }

    // ── Mouse wheel ─────────────────────────────────────────────────────────
    // Consecutive notches add up (they extend the glide's destination instead of
    // restarting from where the list currently is), so a fast spin goes far.
    NumberAnimation {
        id: glide
        target: bar.target
        property: "contentY"
        duration: 160
        easing.type: Easing.OutCubic
    }
    function scrollBy(d) {
        let lo = target.originY
        let hi = target.originY + Math.max(0, target.contentHeight - target.height)
        let from = glide.running ? glide.to : target.contentY
        target.cancelFlick()
        glide.stop()
        glide.to = Math.max(lo, Math.min(hi, from + d))
        glide.start()
    }
    // Catches the wheel over the whole list. A WheelHandler did nothing here: a
    // pointer handler cannot be moved onto another item, and declared in this bar
    // it only covers the bar. A plain item can (see `parent: target` above). No
    // buttons and no hover, so clicks and hover still reach the rows underneath.
    MouseArea {
        parent: bar.target
        anchors.fill: parent
        z: 5
        acceptedButtons: Qt.NoButton
        onWheel: (ev) => {
            if (ev.pixelDelta.y !== 0 && ev.angleDelta.y % 120 !== 0) {
                // touchpad: follow the fingers 1:1, no glide
                glide.stop()
                bar.target.contentY = Math.max(bar.target.originY,
                    Math.min(bar.target.originY + Math.max(0, bar.target.contentHeight - bar.target.height),
                             bar.target.contentY - ev.pixelDelta.y))
            } else {
                bar.scrollBy(-ev.angleDelta.y / 120 * bar.wheelStep)
            }
            ev.accepted = true
        }
    }

    Rectangle {
        id: handle
        width: bar.engaged ? 6 : 4
        height: Math.max(28, bar.height * bar.ratio)
        x: bar.width - width - 1
        y: bar.progress * (bar.height - height)
        radius: width / 2
        color: Tui.alpha(Tui.fg, bar.engaged ? 0.55 : 0.28)
        Behavior on width { NumberAnimation { duration: Tui.dFast; easing.type: Easing.OutCubic } }
        Behavior on color { ColorAnimation  { duration: Tui.dFast } }
    }

    // Generous hit area: extends left of the visible handle so it is easy to grab.
    MouseArea {
        id: track
        anchors { fill: parent; leftMargin: -8 }
        hoverEnabled: true
        preventStealing: true
        onPressed:  (m) => bar.scrollToTrackY(m.y)
        onPositionChanged: (m) => { if (pressed) bar.scrollToTrackY(m.y) }
    }
}
