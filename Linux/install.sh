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

# Stage the plasmoid with the Lucide status icons (git submodule, not copied into the
# repo) coloured to match the Windows tray icons. Keep colours in sync with Windows/Build-Icons.ps1.
lucide="$here/../third_party/lucide/icons"
[[ -e $lucide/cloud-sync.svg ]] || { echo "Lucide submodule missing: run 'git submodule update --init'" >&2; exit 1; }
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp -r "$here/plasmoid/tf.went.rcloneprotondrive" "$stage/"
pkg="$stage/tf.went.rcloneprotondrive"
mkdir -p "$pkg/contents/icons"
icon() { sed "s/currentColor/$3/" "$lucide/$1.svg" > "$pkg/contents/icons/$2.svg"; }
icon cloud-check synced '#2eb85c'
icon cloud-sync syncing '#3b82f6'
icon cloud-alert error '#e5484d'
icon cloud idle '#8b8b8b'

kpackagetool6 -t Plasma/Applet -u "$pkg" 2>/dev/null \
    || kpackagetool6 -t Plasma/Applet -i "$pkg"
echo "Done. Add the 'Proton Drive Sync' widget to your panel. To load an update, re-add the widget"
echo "or restart plasmashell, but first check ~/.config/plasma-org.kde.plasma.desktop-appletsrc has"
echo "saved your latest layout changes (and back it up)."
