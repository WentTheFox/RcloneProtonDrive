# RcloneProtonDrive

Syncs a local folder with Proton Drive using [rclone](https://rclone.org)'s
(beta) `protondrive` backend — no Proton Drive desktop app, no Linux-style
reparse-point/symlink games, files stay as plain files on disk.

On Windows this runs as a background service (via [NSSM](https://nssm.cc))
that hosts rclone's built-in remote-control web UI at `http://127.0.0.1:5572`
and drives a periodic sync through it, so runs show up as jobs in that UI.

A Linux equivalent lives in a sibling folder (see that folder's own notes).

Clone with `git clone --recurse-submodules` (or run `git submodule update --init`
afterwards): the sync status icons come from the [Lucide](https://lucide.dev)
submodule in `third_party/lucide`.

## Windows setup

All of this lives under `Windows/`.

1. **Install rclone** (skip if `Install-RcloneService.ps1` will do it for you):
   ```powershell
   winget install --id Rclone.Rclone --exact
   ```

2. **Create the data folder and drop your secrets in it.** The service reads
   everything from `C:\ProgramData\rclone`, which is created and locked down
   (SYSTEM, Administrators, and your user only) by the installer below.
   ```powershell
   New-Item -ItemType Directory -Force C:\ProgramData\rclone
   Copy-Item Windows\rc-auth.txt.example C:\ProgramData\rclone\rc-auth.txt
   notepad C:\ProgramData\rclone\rc-auth.txt   # line 1: web-UI username, line 2: password
   ```

3. **Create the `proton` remote.** You must have logged into Proton Drive via
   a browser at least once already — rclone needs your encryption keys to
   already exist, it can't create them.
   ```powershell
   rclone config --config C:\ProgramData\rclone\rclone.conf
   ```
   Remote name: `proton`, type: `protondrive`. Enter your email/password (and
   2FA / mailbox password if applicable) when prompted.

   Then add one more line under the `[proton]` section it just wrote, in
   `C:\ProgramData\rclone\rclone.conf`:
   ```ini
   replace_existing_draft = true
   ```
   Without this, an upload interrupted by a crash, a network blip, or two
   syncs racing each other leaves an orphaned "draft" on Proton's side; the
   *next* upload of that same file then fails with `a draft exist ...` and,
   inside bisync, that failure is treated as unsafe and aborts the whole run
   (forcing a `--resync`). This flag tells rclone to just replace the
   dangling draft instead of erroring out. See **Known gotchas** below.

4. **Copy and edit the config:**
   ```powershell
   Copy-Item Windows\config.example.psd1 C:\ProgramData\rclone\config.psd1
   notepad C:\ProgramData\rclone\config.psd1   # set LocalPath to your target folder
   ```
   Leave `Mode = 'download'` for the first run — see **Modes** below.

5. **Dry-run before trusting it with your files:**
   ```powershell
   rclone copy proton: <LocalPath> --config C:\ProgramData\rclone\rclone.conf `
     --update --filter-from Windows\bisync-filters.txt --dry-run -v
   ```
   Confirm the plan makes sense (should be "nothing to transfer" on a folder
   you've already been syncing another way).

6. **Install the service** (elevated PowerShell — re-run any time after
   editing scripts in this repo to redeploy them):
   ```powershell
   Windows\Install-RcloneService.ps1
   ```
   This copies the scripts into `C:\ProgramData\rclone`, installs rclone/NSSM
   via winget if missing, registers the `rclone-proton` service (auto-start),
   and creates two Desktop shortcuts (web UI pre-logged-in, and "Sync now").

7. Open `http://127.0.0.1:5572` (or the Desktop shortcut) to watch it run.

### Modes

- **`download`** (default, safe starting point): one-way `proton: ->
  LocalPath`. Never deletes local files. A remote file that would overwrite a
  differing local file is instead backed up to `<LocalPath>.rclone-backup`
  with a timestamp suffix, so nothing is silently clobbered.
- **`bisync`**: true two-way sync (local <-> remote), via rclone's
  [bisync](https://rclone.org/bisync/). The first run does an automatic
  `--resync` (newer file wins per side). Conflicts after that also resolve to
  the newer file. Anything bisync would overwrite/delete locally goes to
  `<LocalPath>.rclone-backup` first.

  Only switch to `bisync` after a few clean `download` cycles (check
  `C:\ProgramData\rclone\service.log` for `sync finished` with no errors).
  Bisync is still labelled "advanced" by rclone upstream — treat the backup
  folder as your safety net, not a formality.

### Everyday use

- **Trigger a sync immediately**: double-click the "Proton Drive - Sync now"
  Desktop shortcut, or `New-Item C:\ProgramData\rclone\sync-now`. The service
  polls for this file every few seconds and starts a run (queued if one is
  already in progress).
- **Web UI**: `http://127.0.0.1:5572`, login from `rc-auth.txt`. The Desktop
  shortcut embeds that login as a token so it opens pre-authenticated — that
  file is not encrypted, just base64, so don't let it sync anywhere shared.
- **Logs**: `C:\ProgramData\rclone\service.log` (sync start/finish/failure)
  and `rcd.log` (rclone server internals — this one briefly logs the web-UI
  password at startup, so don't share it as-is).

### Known gotchas (hit during development)

- **rclone's Proton backend is beta** (Tier 4/experimental upstream) and
  reverse-engineered — no official API docs. It has recovered cleanly from
  transient `401 Invalid access token` and `429 Too many recent API requests`
  errors mid-run in testing (via `--resilient`/`--recover`), but keep an eye
  on `service.log`.
- **`a draft exist` errors can abort a whole bisync run.** Seen in testing
  when uploading a newly-created local file hit a leftover Proton upload
  draft (e.g. from an earlier interrupted sync). `--resilient` retries a few
  times, but if it never clears, bisync treats it as unsafe and aborts,
  requiring a `--resync` to recover (the service does this automatically —
  see `rclone-service.ps1`'s `Test-Path *.lst` check). Set
  `replace_existing_draft = true` on the `[proton]` remote (step 3 above) to
  stop this from happening in the first place.
- **No modtime support**: Proton Drive doesn't store modification times, so
  comparisons fall back to size + SHA1 hash. This makes every full scan
  slower (rclone has to hash) but is the safest available comparison.
- **PowerShell 5.1 mangles JSON quotes** passed to `rclone.exe` as CLI args
  (e.g. `--filter` JSON blobs) — that's why the service talks to rclone's rc
  HTTP API directly via `Invoke-RestMethod` instead of shelling out per-sync.
- **Git Bash on Windows eats backslashes** in bare Windows paths typed at a
  bash prompt (`C:\ProgramData\...` becomes `C:ProgramData...`). Use forward
  slashes or run from PowerShell instead.
- **`icacls ... "$env:USERNAME:..."` fails to parse** — the colon needs to be
  outside the variable expansion, e.g. `"${env:USERNAME}:(OI)(CI)F"`.
- `--update` alone does not make a one-way copy fully non-destructive if a
  local file's mtime looks older/equal — hence the `BackupDir`/`Suffix`
  safety net in `download` mode rather than relying on `--update` alone.

## Linux setup

All of this lives under `Linux/`. It uses systemd user units (bisync every 15
minutes, rclone's web UI on `http://localhost:5573`) plus a KDE Plasma 6
widget that shows sync status and errors.

1. Create the `ProtonDrive` remote with `rclone config` (same notes as the
   Windows steps, including `replace_existing_draft = true`).
2. Run `Linux/install.sh`. It installs the units and the status helper, creates
   `~/.config/rclone-protondrive/rc.env` (web-UI login, mode 600) if missing,
   enables the timer, and installs the plasmoid.
3. Add the **Proton Drive Sync** widget to a panel.

The sync unit calls `rclone-protondrive-status` before and after each run, which
writes `$XDG_RUNTIME_DIR/rclone-protondrive/status.json`. The widget blocks on an
inotify watcher (no polling), so it updates the moment a run starts or ends. It
shows syncing / up to date / failed, the last successful sync time, and the last
error lines from the journal; right-click offers **Sync now** and **Open web UI**.

**Stop and progress:** the widget's button turns into **Stop sync** while a run is going
(it drops a `stop-requested` marker, then stops the unit, so a stop shows as "Sync
stopped" rather than a failure). While the listing phase has no byte totals, the progress
bar is files-based: rclone's check counter restarts at 0 every run, so the status
helper keeps the counts of the last five successful runs in
`~/.local/state/rclone-protondrive/history.json` and the widget compares against their
median (before any history exists it uses the size of bisync's last listing).

**Updating the widget:** re-running `install.sh` upgrades the files but doesn't
touch the running desktop. Plasma only loads new widget code when the widget is
(re)loaded, so either remove and re-add it, or restart Plasma
(`systemctl --user restart plasma-plasmashell.service`). Before restarting,
make sure your layout has been saved: Plasma writes widget/tray/desktop-icon
changes to `~/.config/plasma-org.kde.plasma.desktop-appletsrc` after a short
delay, and a restart before that discards them. Check that
`grep rcloneprotondrive ~/.config/plasma-org.kde.plasma.desktop-appletsrc`
finds the widget and that the file's modification time is newer than your last
layout change, and copy it somewhere as a backup first.

`rclone-protondrive-download.service` is a one-shot initial `rclone copy` that
disables itself once a clean pass finishes.

## Credits

The synced / syncing / error / idle status icons (Windows tray icon and Plasma
widget) are [Lucide](https://lucide.dev) icons (`cloud-check`, `cloud-sync`,
`cloud-alert`, `cloud`), © Lucide Icons and Contributors, licensed under the
[ISC License](https://github.com/lucide-icons/lucide/blob/main/LICENSE). They are
pulled in as the `third_party/lucide` git submodule rather than copied into this
repo, and coloured at install time (`Windows/Build-Icons.ps1` renders PNGs for
the tray, `Linux/install.sh` stages recoloured SVGs into the widget).
