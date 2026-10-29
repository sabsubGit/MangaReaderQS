import QtQuick

// A progress bar of pixel cells, like the login clock's digits:
//   ■■■■■■□□□□   value 0.6, 10 cells
//     TuiCells { cells: 10; value: done / total }
Row {
    id: root

    property int cells: 10
    property real value: 0                   // 0..1
    property real cell: 8                    // cell size in px
    property color onColor: Tui.accent
    property color offColor: Tui.alpha(Tui.fg, 0.13)

    readonly property int lit: Math.round(Math.max(0, Math.min(1, value)) * cells)

    spacing: Math.max(1, Math.round(cell * 0.25))

    Repeater {
        model: root.cells
        Rectangle {
            required property int index
            width: root.cell
            height: root.cell
            radius: root.cell * 0.12
            color: index < root.lit ? root.onColor : root.offColor
            Behavior on color { ColorAnimation { duration: Tui.dFast } }
        }
    }
}
