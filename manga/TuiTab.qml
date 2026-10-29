import QtQuick

// A selectable tab: the chosen one is a solid accent block, the others an
// outline. Square, like everything in the TUI look.
//     TuiTab { label: "a-z"; selected: sort === "name"; onClicked: sort = "name" }
Rectangle {
    id: root

    property string label: ""
    property bool selected: false
    signal clicked()

    width: tabText.implicitWidth + 18
    height: tabText.implicitHeight + 8
    color: selected ? Tui.accent : hover.hovered ? Tui.alpha(Tui.accent, 0.14) : "transparent"
    border.width: selected ? 0 : Tui.border
    border.color: hover.hovered ? Tui.line : Tui.lineDim
    Behavior on color { ColorAnimation { duration: Tui.dFast } }

    Text {
        id: tabText
        anchors.centerIn: parent
        text: root.label
        color: root.selected ? Tui.accentInk : Tui.fg
        font.family: Tui.font
        font.pixelSize: Tui.fsSm + 1
        font.weight: root.selected ? Font.Bold : Font.Normal
    }
    HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
    TapHandler { onTapped: root.clicked() }
}
