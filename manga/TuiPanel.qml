import QtQuick

// A TUI dialog panel: square, 2 px border, hard shadow, and an optional title
// tab sitting on the top border, as in the login box:
//   ┌[ chapters ]──────────────┐
//   │ children go here          │
//   └───────────────────────────┘
//     TuiPanel { title: "chapters"; ListView { anchors.fill: parent ... } }
// Children fill the inside, inset by `padding`.
Item {
    id: root

    property string title: ""
    property string note: ""                 // dim text on the right of the top border
    property color noteColor: Tui.dim
    property bool active: true               // accent border, else a quiet one
    property color fill: Tui.alpha(Tui.bg, 0.94)
    property color tabColor: Tui.accent
    property bool shadow: true
    property int padding: 14

    default property alias content: inner.data

    Rectangle {
        visible: root.shadow
        x: Tui.shadow; y: Tui.shadow
        width: root.width; height: root.height
        color: Tui.shadowColor
    }
    Rectangle {
        anchors.fill: parent
        color: root.fill
        border.width: Tui.border
        border.color: root.active ? Tui.line : Tui.lineDim
        Behavior on border.color { ColorAnimation { duration: Tui.dFast } }
    }

    Item {
        id: inner
        anchors.fill: parent
        anchors.margins: root.padding
        anchors.topMargin: root.padding + (root.title ? 6 : 0)
    }

    // Title tab on the border.
    Rectangle {
        visible: root.title !== ""
        x: 18
        y: -height / 2 + 1
        width: tabText.implicitWidth + 18
        height: tabText.implicitHeight + 6
        color: root.tabColor
        Text {
            id: tabText
            anchors.centerIn: parent
            text: root.title
            color: Tui.accentInk
            font.family: Tui.font
            font.pixelSize: Tui.fsSm + 1
            font.weight: Font.Bold
            font.letterSpacing: 1
        }
    }
    // Note on the border, right side, on a patch of the panel colour.
    Rectangle {
        visible: root.note !== ""
        anchors.right: parent.right
        anchors.rightMargin: 18
        y: -height / 2 + 1
        width: noteText.implicitWidth + 12
        height: noteText.implicitHeight + 2
        color: root.fill
        Text {
            id: noteText
            anchors.centerIn: parent
            text: root.note
            color: root.noteColor
            font.family: Tui.font
            font.pixelSize: Tui.fsSm
        }
    }
}
