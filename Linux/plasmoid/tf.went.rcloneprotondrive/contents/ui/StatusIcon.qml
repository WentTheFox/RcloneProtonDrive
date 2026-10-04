import QtQuick
import org.kde.kirigami as Kirigami

// Lucide cloud icon: the outline follows the theme text colour, the glyph
// (check / arrows / !) keeps the state colour. Files are staged by install.sh.
Item {
    id: icon
    property string name: "idle"   // synced | syncing | error | idle
    readonly property bool hasGlyph: name !== "idle"

    Kirigami.Icon {
        anchors.fill: parent
        source: Qt.resolvedUrl("../icons/" + icon.name + "-outline.svg")
        isMask: true
        color: Kirigami.Theme.textColor
    }
    Kirigami.Icon {
        anchors.fill: parent
        visible: icon.hasGlyph
        source: icon.hasGlyph ? Qt.resolvedUrl("../icons/" + icon.name + "-glyph.svg") : ""
    }
}
