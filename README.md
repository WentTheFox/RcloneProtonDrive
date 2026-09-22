# RcloneProtonDrive

Syncs a local folder with Proton Drive using [rclone](https://rclone.org)'s
(beta) `protondrive` backend — no Proton Drive desktop app, no Linux-style
reparse-point/symlink games, files stay as plain files on disk.

On Windows this runs as a background service (via [NSSM](https://nssm.cc))
that hosts rclone's built-in remote-control web UI at `http://127.0.0.1:5572`
and drives a periodic sync through it, so runs show up as jobs in that UI.

A Linux equivalent lives in a sibling folder (see that folder's own notes).

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
  transient `401 Invalid access token` errors mid-run in testing, but keep an
  eye on `service.log`.
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

See the sibling folder next to this one.
