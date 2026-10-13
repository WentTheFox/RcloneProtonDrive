#!/usr/bin/env bash
# Installs the user units, status helper and plasmoid. Safe to re-run.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)

install -Dm755 -t ~/.local/bin "$here"/bin/rclone-protondrive-*
install -Dm644 -t ~/.config/systemd/user "$here"/systemd/*

conf=~/.config/rclone-protondrive
install -dm700 "$conf"
install -Dm644 "$here/bisync-filters.txt" "$conf/bisync-filters.txt"
[[ -e $conf/config.env ]] || { install -Dm644 "$here/config.example.env" "$conf/config.env"; echo "Created $conf/config.env"; }

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
# The cloud outline is the path with the big arc ("7 7 0 1"); everything else is the
# glyph (check / arrows / !). Outline is uncoloured and masked with the Plasma text
# colour by StatusIcon.qml; the glyph gets a fixed colour. Keep colours in sync with
# Windows/Build-Icons.ps1.
icon() {  # <lucide-name> <state> <glyph-colour|->
    awk '/<path/ { if ($0 ~ /7 7 0 1/) print; next } { print }' "$lucide/$1.svg" > "$pkg/contents/icons/$2-outline.svg"
    [[ $3 == - ]] && return
    awk '/<path/ { if ($0 !~ /7 7 0 1/) print; next } { print }' "$lucide/$1.svg" | sed "s/currentColor/$3/" > "$pkg/contents/icons/$2-glyph.svg"
}
icon cloud-check synced '#2eb85c'
icon cloud-sync syncing '#3b82f6'
icon cloud-alert error '#e5484d'
icon cloud idle -

kpackagetool6 -t Plasma/Applet -u "$pkg" 2>/dev/null \
    || kpackagetool6 -t Plasma/Applet -i "$pkg"
echo "Done. Add the 'Proton Drive Sync' widget to your panel. To load an update, re-add the widget"
echo "or restart plasmashell, but first check ~/.config/plasma-org.kde.plasma.desktop-appletsrc has"
echo "saved your latest layout changes (and back it up)."
