#!/usr/bin/env bash
# Removes everything install.sh put in place: the timer/units, the helper scripts and
# the plasmoid. Safe to re-run.
#
#   --purge   also delete ~/.config/rclone-protondrive (config.env, rc.env, filters) and
#             the saved state under ~/.local/state/rclone-protondrive.
#
# Never touched: the synced folder (LOCAL_PATH), your rclone remote (rclone.conf) and
# rclone's bisync cache (~/.cache/rclone/bisync), which belong to rclone, not to us.
set -euo pipefail

purge=0
case "${1:-}" in
    "") ;;
    --purge) purge=1 ;;
    *) echo "usage: $0 [--purge]" >&2; exit 2 ;;
esac

units=(rclone-protondrive-sync.timer rclone-protondrive-sync.service rclone-protondrive-download.service)

systemctl --user disable --now rclone-protondrive-sync.timer 2>/dev/null || true
systemctl --user stop rclone-protondrive-sync.service rclone-protondrive-download.service 2>/dev/null || true

for u in "${units[@]}"; do rm -f ~/.config/systemd/user/"$u"; done
rm -f ~/.local/bin/rclone-protondrive-sync ~/.local/bin/rclone-protondrive-status
rm -rf ~/.local/share/rclone-protondrive
rm -rf "${XDG_RUNTIME_DIR:-/nonexistent}/rclone-protondrive"
systemctl --user daemon-reload
systemctl --user reset-failed 'rclone-protondrive*' 2>/dev/null || true

kpackagetool6 -t Plasma/Applet -r tf.went.rcloneprotondrive 2>/dev/null || true

if (( purge )); then
    rm -rf ~/.config/rclone-protondrive "${XDG_STATE_HOME:-$HOME/.local/state}/rclone-protondrive"
    echo "Purged config and state."
else
    echo "Kept ~/.config/rclone-protondrive and ~/.local/state/rclone-protondrive (use --purge to delete)."
fi

echo "Done. Remove the 'Proton Drive Sync' widget from your panel (right-click > Remove); until"
echo "Plasma reloads it stays on screen as a stale widget. Your synced folder was not touched."
