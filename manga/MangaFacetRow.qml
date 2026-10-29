import QtQuick

// One row of the doujin filter panel: a label, then a chip per value with how
// many works shown now have it. Clicking a chip cycles must have / must not /
// off (Manga.toggleFacet).
//     MangaFacetRow { title: "language"; items: [{ key: "languages:english", label: "english", n: 420 }] }
Row {
    id: fr
    property string title
    property var items: []                  // [{ key, label, n }]
    spacing: 8

    Text {
        width: 110
        height: 28
        verticalAlignment: Text.AlignVCenter
        text: fr.title
        color: Tui.dim
        font.family: Tui.font
        font.pixelSize: Tui.fsSm
    }
    Repeater {
        model: fr.items
        TuiChip {
            required property var modelData
            label: modelData.label
            count: modelData.n
            mode: Manga.facetState(modelData.key)
            onClicked: Manga.toggleFacet(modelData.key)
        }
    }
}
