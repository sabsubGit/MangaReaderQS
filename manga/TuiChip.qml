import QtQuick

// A filter chip with a count, three states: off (outline), on (accent block),
// excluded (red block, "−" in front).
//     TuiChip { label: "glasses"; count: 12; mode: 1; onClicked: ... }
Rectangle {
    id: root

    property string label: ""
    property int count: -1                   // -1 = no count shown
    property int mode: 0                     // 0 off · 1 on · -1 excluded
    signal clicked()

    readonly property bool filled: mode !== 0
    width: row.implicitWidth + 16
    height: row.implicitHeight + 8
    color: mode === 1 ? Tui.accent : mode === -1 ? Tui.danger
         : hover.hovered ? Tui.alpha(Tui.accent, 0.14) : "transparent"
    border.width: filled ? 0 : Tui.border
    border.color: hover.hovered ? Tui.line : Tui.lineDim
    opacity: !filled && count === 0 ? 0.45 : 1
    Behavior on color { ColorAnimation { duration: Tui.dFast } }

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 6
        Text {
            text: (root.mode === -1 ? "− " : "") + root.label
            color: root.filled ? Tui.accentInk : Tui.fg
            font.family: Tui.font
            font.pixelSize: Tui.fsSm + 1
            font.weight: root.filled ? Font.Bold : Font.Normal
        }
        Text {
            visible: root.count >= 0
            text: root.count
            color: root.filled ? Tui.accentInk : Tui.dim
            opacity: root.filled ? 0.75 : 1
            font.family: Tui.font
            font.pixelSize: Tui.fsSm
        }
    }
    HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: root.clicked() }
}
