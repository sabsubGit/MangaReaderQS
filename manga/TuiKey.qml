import QtQuick

// An F-key bar button, Midnight Commander style: the key, then its label on an
// accent block (the login screen's "F1 suspend").
//     TuiKey { key: "F2"; label: "check"; onClicked: ... }
// `key` may be empty (a plain block button). `quiet` uses an outline instead
// of the accent fill, for secondary actions.
Row {
    id: root

    property string key: ""
    property string label: ""
    property bool quiet: false
    property bool busy: false                // label dims, clicks still allowed
    property bool danger: false              // armed destructive action: red block
    signal clicked()

    spacing: 0

    Text {
        visible: root.key !== ""
        anchors.verticalCenter: parent.verticalCenter
        text: root.key
        color: Tui.fg
        font.family: Tui.font
        font.pixelSize: Tui.fsMd
        font.weight: Font.Bold
        rightPadding: 4
    }
    Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: labelText.implicitWidth + 16
        height: labelText.implicitHeight + 6
        color: root.danger ? Tui.danger
             : root.quiet ? (hover.hovered ? Tui.alpha(Tui.accent, 0.18) : "transparent")
             : hover.hovered ? Tui.accent : Tui.alpha(Tui.accent, 0.78)
        border.width: root.quiet && !root.danger ? Tui.border : 0
        border.color: hover.hovered ? Tui.line : Tui.lineDim
        Behavior on color { ColorAnimation { duration: Tui.dFast } }
        Text {
            id: labelText
            anchors.centerIn: parent
            text: root.label
            color: root.quiet && !root.danger ? Tui.fg : Tui.accentInk
            opacity: root.busy ? 0.6 : 1
            font.family: Tui.font
            font.pixelSize: Tui.fsMd
        }
        HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: root.clicked() }
    }
}
