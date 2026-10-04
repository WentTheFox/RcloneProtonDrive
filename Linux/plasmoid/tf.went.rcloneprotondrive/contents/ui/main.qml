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
    readonly property string queryCmd: "sh -c 'cat " + statusDir + "/status.json 2>/dev/null; echo; echo @@; systemctl --user show -p ActiveState --value " + unit + "'"
    // True while systemd says the unit is running, even if the status file predates it
    property bool running: false
    readonly property string effectiveState: running ? "syncing" : status.state

    readonly property string iconName: {
        switch (effectiveState) {
        case "syncing": return "folder-sync"
        case "idle": return "folder-cloud"
        case "error": return "dialog-error"
        default: return "folder-cloud"
        }
    }
    readonly property string stateText: {
        switch (effectiveState) {
        case "syncing": return i18n("Syncing…")
        case "idle": return i18n("Up to date")
        case "error": return i18n("Sync failed")
        default: return i18n("No sync run yet")
        }
    }

    Plasmoid.icon: iconName
    toolTipMainText: i18n("Proton Drive")
    toolTipSubText: effectiveState === "error" && status.message ? status.message : stateText
    Plasmoid.status: effectiveState === "error" ? PlasmaCore.Types.NeedsAttentionStatus
        : effectiveState === "syncing" ? PlasmaCore.Types.ActiveStatus
        : PlasmaCore.Types.PassiveStatus

    function ago(ts) {
        if (!ts) return i18n("never")
        const s = Math.max(0, Math.floor(Date.now() / 1000 - ts))
        if (s < 60) return i18n("just now")
        if (s < 3600) return i18n("%1 min ago", Math.floor(s / 60))
        if (s < 86400) return i18n("%1 h ago", Math.floor(s / 3600))
        return i18n("%1 d ago", Math.floor(s / 86400))
    }

    // Each command exits and is re-armed, so there is no timer.
    P5Support.DataSource {
        id: exec
        engine: "executable"
        connectedSources: []
        onNewData: (source, data) => {
            disconnectSource(source)
            if (source === root.queryCmd) {
                const parts = (data.stdout || "").split("@@")
                try { root.status = JSON.parse(parts[0]) } catch (e) { root.status = { state: "unknown" } }
                const active = (parts[1] || "").trim()
                root.running = active === "active" || active === "activating" || active === "deactivating"
                // Re-arm: blocks until the status file or the unit's D-Bus state changes
                connectSource("python3 " + root.waitScript + " " + root.statusDir + " " + root.unit)
            } else {
                connectSource(root.queryCmd)
            }
        }
    }

    Component.onCompleted: exec.connectSource(queryCmd)

    // Cheap safety net for the instant between a waiter exiting and being re-armed
    onExpandedChanged: if (expanded) exec.connectSource(queryCmd)

    function syncNow() {
        exec.connectSource("systemctl --user start --no-block " + unit)
    }

    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: i18n("Sync now")
            icon.name: "view-refresh"
            enabled: root.effectiveState !== "syncing"
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
            visible: root.effectiveState === "syncing" && root.status.state === "syncing"
            text: i18n("Started %1", root.ago(root.status.since))
            opacity: 0.7
        }
        PlasmaComponents.Label {
            text: i18n("Last successful sync: %1", root.ago(root.status.lastOk))
            opacity: 0.7
        }
        PlasmaComponents.Label {
            visible: root.effectiveState === "error"
            text: (root.status.errors && root.status.errors.length ? root.status.errors.join("\n") : root.status.message)
            color: Kirigami.Theme.negativeTextColor
            wrapMode: Text.Wrap
            Layout.fillWidth: true
        }
        Item { Layout.fillHeight: true }
        PlasmaComponents.Button {
            text: i18n("Sync now")
            icon.name: "view-refresh"
            enabled: root.effectiveState !== "syncing"
            onClicked: root.syncNow()
        }
    }
}
