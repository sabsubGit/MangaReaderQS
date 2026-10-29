pragma Singleton
import Quickshell
import QtQuick

// Look of the manga reader: square panels with a hard shadow, accent title
// tabs on the border, monospace text, pixel cells, an F-key bar.
// Change the colours and fonts below to match your setup (or point them at
// your own theme singleton, e.g. `readonly property color bg: Colors.bg`).
Singleton {
    id: root

    function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
    function mix(a, b, t) {
        return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1)
    }

    // ── Colours ──────────────────────────────────────────────────────────────
    readonly property color bg: "#1b1f1b"
    readonly property color bg1: "#262b26"
    readonly property color fg: "#e4e8df"
    readonly property color dim: "#8f968b"
    readonly property color accent: "#a9d282"
    readonly property color accentStrong: "#84ac5d"
    readonly property color accentInk: "#141414"
    readonly property color warn: "#fa934e"
    readonly property color danger: "#f1645d"

    readonly property color line: alpha(accent, 0.6)          // panel borders
    readonly property color lineDim: alpha(fg, 0.16)          // inactive borders
    readonly property color stripe: alpha(fg, 0.04)           // zebra rows
    readonly property color shadowColor: Qt.rgba(0, 0, 0, 0.42)

    // ── Shape and type ───────────────────────────────────────────────────────
    readonly property int border: 2
    readonly property int shadow: 8                           // hard drop shadow offset
    readonly property string font: "JetBrains Mono"
    readonly property string nf: "JetBrainsMono Nerd Font"
    readonly property int fsXs: 11
    readonly property int fsSm: 12
    readonly property int fsMd: 14
    readonly property int fsLg: 17
    readonly property int fsXl: 26

    readonly property int dFast: 120
    readonly property int dNormal: 220

    // |/-\ like the login box while it authenticates; see `spin`.
    readonly property var spinner: ["|", "/", "-", "\\"]
}
