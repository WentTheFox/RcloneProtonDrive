#!/usr/bin/env bash
# Installs the user units, status helper and plasmoid. Safe to re-run.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)

install -Dm755 "$here/bin/rclone-protondrive-status" ~/.local/bin/rclone-protondrive-status
install -Dm644 -t ~/.config/systemd/user "$here"/systemd/*

rc=~/.config/rclone-protondrive/rc.env
if [[ ! -e $rc ]]; then
    install -dm700 "$(dirname "$rc")"
    umask 077
    printf 'RCLONE_RC_USER=%s\nRCLONE_RC_PASS=%s\n' "$USER" "$(head -c 24 /dev/urandom | base64 | tr -d '/+=')" > "$rc"
    echo "Created $rc (web UI login)"
fi

systemctl --user daemon-reload
systemctl --user enable --now rclone-protondrive-sync.timer

kpackagetool6 -t Plasma/Applet -u "$here/plasmoid/tf.went.rcloneprotondrive" 2>/dev/null \
    || kpackagetool6 -t Plasma/Applet -i "$here/plasmoid/tf.went.rcloneprotondrive"
echo "Done. Add the 'Proton Drive Sync' widget to your panel. To load an update, re-add the widget"
echo "or restart plasmashell, but first check ~/.config/plasma-org.kde.plasma.desktop-appletsrc has"
echo "saved your latest layout changes (and back it up)."
