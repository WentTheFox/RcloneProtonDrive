import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    // Parsed contents of $XDG_RUNTIME_DIR/rclone-protondrive/status.json
    property var status: ({ state: "unknown" })
    readonly property string statusDir: "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/rclone-protondrive"
    readonly property string waitScript: Qt.resolvedUrl("../scripts/wait-for-change").toString().replace("file://", "")
    readonly property string unit: "rclone-protondrive-sync.service"

    readonly property string iconName: {
        switch (status.state) {
        case "syncing": return "folder-sync"
        case "idle": return "folder-cloud"
        case "error": return "dialog-error"
        default: return "folder-cloud"
        }
    }
    readonly property string stateText: {
        switch (status.state) {
        case "syncing": return i18n("Syncing…")
        case "idle": return i18n("Up to date")
        case "error": return i18n("Sync failed")
        default: return i18n("No sync run yet")
        }
    }

    Plasmoid.icon: iconName
    toolTipMainText: i18n("Proton Drive")
    toolTipSubText: status.state === "error" && status.message ? status.message : stateText
    Plasmoid.status: status.state === "error" ? PlasmaCore.Types.NeedsAttentionStatus
        : status.state === "syncing" ? PlasmaCore.Types.ActiveStatus
        : PlasmaCore.Types.PassiveStatus

    function ago(ts) {
        if (!ts) return i18n("never")
        const s = Math.max(0, Math.floor(Date.now() / 1000 - ts))
        if (s < 60) return i18n("just now")
        if (s < 3600) return i18n("%1 min ago", Math.floor(s / 60))
        if (s < 86400) return i18n("%1 h ago", Math.floor(s / 3600))
        return i18n("%1 d ago", Math.floor(s / 86400))
    }

    // One executable source per command; each exits and is re-armed, so there is no timer.
    P5Support.DataSource {
        id: exec
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => {
            disconnectSource(source)
            if (source.indexOf("cat ") === 0) {
                try { root.status = JSON.parse(data.stdout) } catch (e) { root.status = { state: "unknown" } }
                // Re-arm: blocks (inotify) until the helper rewrites the file
                connectSource("python3 " + root.waitScript + " " + root.statusDir)
            } else if (source.indexOf("wait-for-change") >= 0 || source.indexOf(root.waitScript) >= 0) {
                connectSource("cat " + root.statusDir + "/status.json 2>/dev/null")
            }
        }
    }

    Component.onCompleted: exec.connectSource("cat " + statusDir + "/status.json 2>/dev/null")

    // Cheap safety net for the instant between a waiter exiting and being re-armed
    onExpandedChanged: if (expanded) exec.connectSource("cat " + statusDir + "/status.json 2>/dev/null")

    function syncNow() {
        exec.connectSource("systemctl --user start --no-block " + unit)
    }

    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: i18n("Sync now")
            icon.name: "view-refresh"
            enabled: root.status.state !== "syncing"
            onTriggered: root.syncNow()
        },
        PlasmaCore.Action {
            text: i18n("Open web UI")
            icon.name: "internet-web-browser"
            onTriggered: Qt.openUrlExternally("http://localhost:5573")
        }
    ]

    compactRepresentation: MouseArea {
        onClicked: root.expanded = !root.expanded
        Kirigami.Icon {
            anchors.fill: parent
            source: root.iconName
        }
    }

    fullRepresentation: ColumnLayout {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 18
        Layout.minimumHeight: Kirigami.Units.gridUnit * 8
        spacing: Kirigami.Units.smallSpacing

        RowLayout {
            Kirigami.Icon { source: root.iconName; implicitWidth: Kirigami.Units.iconSizes.medium; implicitHeight: implicitWidth }
            PlasmaComponents.Label { text: root.stateText; font.bold: true; Layout.fillWidth: true }
        }
        PlasmaComponents.Label {
            visible: root.status.state === "syncing"
            text: i18n("Started %1", root.ago(root.status.since))
            opacity: 0.7
        }
        PlasmaComponents.Label {
            text: i18n("Last successful sync: %1", root.ago(root.status.lastOk))
            opacity: 0.7
        }
        PlasmaComponents.Label {
            visible: root.status.state === "error"
            text: (root.status.errors && root.status.errors.length ? root.status.errors.join("\n") : root.status.message)
            color: Kirigami.Theme.negativeTextColor
            wrapMode: Text.Wrap
            Layout.fillWidth: true
        }
        Item { Layout.fillHeight: true }
        PlasmaComponents.Button {
            text: i18n("Sync now")
            icon.name: "view-refresh"
            enabled: root.status.state !== "syncing"
            onClicked: root.syncNow()
        }
    }
}
