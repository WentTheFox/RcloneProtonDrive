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
    readonly property string queryCmd: "sh -c 'cat " + statusDir + "/status.json 2>/dev/null; echo; echo @@; systemctl --user show -p ActiveState --value " + unit + "; echo @@; { cat ~/.local/state/rclone-protondrive/last-ok 2>/dev/null; stat -c %Y ~/.cache/rclone/bisync/*.lst 2>/dev/null; } | sort -n | tail -1'"
    // Credentials are fed to curl on stdin so the password never shows up in `ps`
    readonly property string statsCmd: "sh -c '. ~/.config/rclone-protondrive/rc.env 2>/dev/null; printf \"user = \\\"%s:%s\\\"\\n\" \"$RCLONE_RC_USER\" \"$RCLONE_RC_PASS\" | curl -sS -m 5 -K - -X POST http://localhost:5573/core/stats'"
    property var stats: null
    // Refreshed about once a second, but only while the popup is open during a sync,
    // and never with a request already in flight (curl is capped at 5s by -m)
    property bool statsPending: false
    property double statsAt: 0
    property double now: Date.now()
    Timer {
        interval: 1000
        repeat: true
        running: root.expanded && root.running
        onTriggered: { root.now = Date.now(); root.requestStats() }
    }

    function fmtBytes(b) {
        const u = ["B", "KiB", "MiB", "GiB", "TiB"]
        let i = 0
        while (b >= 1024 && i < u.length - 1) { b /= 1024; i++ }
        return b.toFixed(i ? 1 : 0) + " " + u[i]
    }
    function fmtDur(sec) {
        sec = Math.round(sec)
        const h = Math.floor(sec / 3600), m = Math.floor(sec % 3600 / 60), s = sec % 60
        return (h ? h + "h " : "") + (h || m ? m + "m " : "") + s + "s"
    }
    function requestStats() {
        if (statsPending) return
        statsPending = true
        Qt.callLater(connectStats)
    }
    // Sources are (re)connected from a fresh event-loop turn, never from inside onNewData: the
    // executable engine can answer a just-disconnected, still-cached source synchronously,
    // which made these handlers call each other until the JS stack overflowed (widget stuck).
    // A trailing shell comment makes every run a distinct source, so a cached answer can never be
    // replayed for it (and the handlers below match sources by prefix).
    property int seq: 0
    function uniq(cmd) { return cmd + " # " + (++seq) }
    function connectStats() { exec.connectSource(uniq(statsCmd)) }
    function connectQuery() { exec.connectSource(uniq(queryCmd)) }
    function connectWaiter() { exec.connectSource(uniq("python3 " + waitScript + " " + statusDir + " " + unit)) }
    function refreshStats() {
        if (root.expanded && root.running) requestStats()
        else root.stats = null
    }

    // True while systemd says the unit is running, even if the status file predates it
    property bool running: false
    property double lastOkFallback: 0
    readonly property double lastOk: status.lastOk || lastOkFallback
    readonly property string effectiveState: running ? "syncing" : status.state

    // Lucide icons (see README), staged into contents/icons by install.sh and drawn by
    // StatusIcon.qml: cloud outline in the theme text colour, state-coloured glyph.
    readonly property string iconName: {
        switch (effectiveState) {
        case "syncing": return "syncing"
        case "idle": return "synced"
        case "error": return "error"
        case "paused": return "error"
        case "stopped": return "idle"
        default: return "idle"
        }
    }
    readonly property string stateText: {
        switch (effectiveState) {
        case "syncing": return status.resync ? i18n("Full resync…") : i18n("Syncing…")
        case "idle": return i18n("Up to date")
        case "error": return i18n("Sync failed")
        case "paused": return i18n("Sync paused")
        case "stopped": return i18n("Sync stopped")
        default: return i18n("No sync run yet")
        }
    }

    Plasmoid.icon: "folder-cloud"
    toolTipMainText: i18n("Proton Drive")
    toolTipSubText: (effectiveState === "error" || effectiveState === "paused") && status.message
        ? (status.failures > 1 ? i18n("Failed x%1: %2", status.failures, status.message) : status.message) : stateText
    Plasmoid.status: (effectiveState === "error" || effectiveState === "paused") ? PlasmaCore.Types.NeedsAttentionStatus
        : effectiveState === "syncing" ? PlasmaCore.Types.ActiveStatus
        : PlasmaCore.Types.PassiveStatus

    function ago(ts) {
        if (!ts) return i18n("never")
        // Reading root.now makes bindings that call ago() re-evaluate when it is refreshed
        const s = Math.max(0, Math.floor(root.now / 1000 - ts))
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
            if (source.startsWith(root.statsCmd)) {
                root.statsPending = false
                // On a failed request keep showing the last snapshot rather than flicker
                try { root.stats = JSON.parse(data.stdout); root.statsAt = Date.now(); root.now = root.statsAt } catch (e) {}
            } else if (source.startsWith(root.queryCmd)) {
                const parts = (data.stdout || "").split("@@")
                try { root.status = JSON.parse(parts[0]) } catch (e) { root.status = { state: "unknown" } }
                const active = (parts[1] || "").trim()
                // After a reboot the status file is gone: fall back to the last success on disk
                root.lastOkFallback = parseInt((parts[2] || "").trim()) || 0
                root.running = active === "active" || active === "activating" || active === "deactivating"
                root.refreshStats()
                // Re-arm: blocks until the status file or the unit's D-Bus state changes
                Qt.callLater(root.connectWaiter)
            } else {
                Qt.callLater(root.connectQuery)
            }
        }
    }

    Component.onCompleted: connectQuery()

    // Cheap safety net for the instant between a waiter exiting and being re-armed
    onExpandedChanged: { if (expanded) { now = Date.now(); connectQuery() } else stats = null }

    // The marker tells the status helper this was a user stop, not a failure
    function stopSync() {
        exec.connectSource("sh -c 'mkdir -p " + statusDir + " && touch " + statusDir + "/stop-requested && systemctl --user stop " + unit + "'")
    }

    // Rough progress without byte totals: files checked this run vs. the median of past runs
    // (rclone's counter restarts at 0 every run; the helper keeps the history)
    readonly property real fileFraction: (stats && status.expected > 0) ? Math.min(0.99, stats.checks / status.expected) : -1

    // Also clears a pause (the user has looked at the problem); the script re-pauses if it persists
    function syncNow() {
        exec.connectSource("sh -c 'rm -f ~/.local/state/rclone-protondrive/sync-paused.json; systemctl --user start --no-block " + unit + "'")
    }

    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: root.effectiveState === "paused" ? i18n("Resume sync") : i18n("Sync now")
            icon.name: "view-refresh"
            enabled: root.effectiveState !== "syncing"
            onTriggered: root.syncNow()
        },
        PlasmaCore.Action {
            text: i18n("Stop sync")
            icon.name: "process-stop"
            enabled: root.effectiveState === "syncing"
            onTriggered: root.stopSync()
        },
        PlasmaCore.Action {
            text: i18n("Open web UI")
            icon.name: "internet-web-browser"
            onTriggered: Qt.openUrlExternally("http://localhost:5573")
        }
    ]

    compactRepresentation: MouseArea {
        onClicked: root.expanded = !root.expanded
        StatusIcon {
            anchors.fill: parent
            name: root.iconName
        }
    }

    fullRepresentation: Item {
        // Layout.margins has no effect on a popup's root item, so the padding is an anchored inset
        readonly property int pad: Kirigami.Units.gridUnit
        Layout.minimumWidth: Kirigami.Units.gridUnit * 18 + 2 * pad
        Layout.preferredWidth: Kirigami.Units.gridUnit * 20 + 2 * pad
        implicitHeight: content.implicitHeight + 2 * pad

        ColumnLayout {
        id: content
        anchors.fill: parent
        anchors.margins: parent.pad
        // Sized by its content (no stretchy gap above the button); one spacing between groups
        spacing: Kirigami.Units.largeSpacing

        RowLayout {
            spacing: Kirigami.Units.largeSpacing
            StatusIcon { name: root.iconName; implicitWidth: Kirigami.Units.iconSizes.large; implicitHeight: implicitWidth }
            ColumnLayout {
                spacing: 0
                Layout.fillWidth: true
                PlasmaComponents.Label { text: i18n("Proton Drive sync"); opacity: 0.7; font: Kirigami.Theme.smallFont }
                PlasmaComponents.Label { text: root.stateText; font.bold: true; font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.2 }
            }
        }
        PlasmaComponents.Label {
            visible: root.effectiveState === "syncing" && root.status.state === "syncing"
            text: root.status.resync ? i18n("Started %1; rebuilding the sync baseline, no progress estimate", root.ago(root.status.since)) : i18n("Started %1", root.ago(root.status.since))
            opacity: 0.7
        }
        ColumnLayout {
            visible: root.effectiveState === "syncing" && root.stats !== null
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing
            PlasmaComponents.ProgressBar {
                Layout.fillWidth: true
                visible: (root.stats && root.stats.totalBytes > 0) || root.fileFraction >= 0
                from: 0
                to: (root.stats && root.stats.totalBytes > 0) ? root.stats.totalBytes : 1
                value: (root.stats && root.stats.totalBytes > 0) ? root.stats.bytes : Math.max(0, root.fileFraction)
            }
            PlasmaComponents.Label {
                visible: (root.stats && root.stats.totalBytes > 0) || root.fileFraction >= 0
                text: (root.stats && root.stats.totalBytes > 0)
                    ? i18n("%1 / %2 at %3/s%4", root.fmtBytes(root.stats.bytes), root.fmtBytes(root.stats.totalBytes),
                        root.fmtBytes(root.stats.speed), root.stats.eta ? i18n(", ETA %1", root.fmtDur(root.stats.eta)) : "")
                    : i18n("About %1%: %2 of ~%3 checks", Math.round(root.fileFraction * 100), root.stats ? root.stats.checks : 0, root.status.expected)
            }
            PlasmaComponents.Label {
                text: root.stats ? i18n("%1 checks, %2 transfers, elapsed %3",
                    root.stats.checks, root.stats.transfers, root.fmtDur(root.stats.elapsedTime + (root.now - root.statsAt) / 1000)) : ""
                opacity: 0.7
            }
            Repeater {
                model: root.stats && root.stats.transferring ? root.stats.transferring : []
                PlasmaComponents.Label {
                    required property var modelData
                    text: modelData.name + " (" + modelData.percentage + "%)"
                    elide: Text.ElideMiddle
                    Layout.fillWidth: true
                    opacity: 0.7
                }
            }
        }
        PlasmaComponents.Label {
            text: i18n("Last successful sync: %1", root.ago(root.lastOk))
            opacity: 0.7
        }
        PlasmaComponents.Label {
            visible: root.effectiveState === "error" || root.effectiveState === "paused"
            text: root.effectiveState === "paused" ? root.status.message : (root.status.errors && root.status.errors.length ? root.status.errors.join("\n") : root.status.message)
            color: Kirigami.Theme.negativeTextColor
            wrapMode: Text.Wrap
            Layout.fillWidth: true
        }
        PlasmaComponents.Button {
            Layout.alignment: Qt.AlignRight
            text: root.effectiveState === "syncing" ? i18n("Stop sync") : root.effectiveState === "paused" ? i18n("Resume sync") : i18n("Sync now")
            icon.name: root.effectiveState === "syncing" ? "process-stop" : "view-refresh"
            onClicked: root.effectiveState === "syncing" ? root.stopSync() : root.syncNow()
        }
        // Absorbs spare height so extra window size doesn't spread the content apart
        Item { Layout.fillHeight: true }
        }
    }
}
