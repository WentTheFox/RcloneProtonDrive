# Service entry point (run by NSSM as LocalSystem, deployed to C:\ProgramData\rclone).
# Runs the rclone remote-control server + web UI, and a periodic sync between
# LocalPath and RemoteName (see config.psd1) through that server so jobs show
# up in the UI. Create C:\ProgramData\rclone\sync-now to trigger a run early.
$ErrorActionPreference = 'Stop'

$Root   = 'C:\ProgramData\rclone'
$LogRoot = "$Root\logs"
$Rclone = "$Root\rclone.exe"
$Config = "$Root\rclone.conf"
$Trigger = "$Root\sync-now"
$PauseFile = "$Root\sync-paused.json"

$cfg = Import-PowerShellDataFile "$Root\config.psd1"
$Local    = $cfg.LocalPath
$Remote   = $cfg.RemoteName
$Mode     = $cfg.Mode
$Interval = $cfg.IntervalSeconds
$Addr     = $cfg.RcAddr

$auth = Get-Content "$Root\rc-auth.txt"
$env:RCLONE_RC_USER = $auth[0]
$env:RCLONE_RC_PASS = $auth[1]
$env:RCLONE_CONFIG  = $Config

function Log($m) { Write-Output ("{0:s} {1}" -f (Get-Date), $m) }

# rc answers a failed sync with a bare "500 / bisync aborted"; what actually went wrong
# (e.g. "Access is denied") is only in rcd.log. Collect the ERROR lines written since $from.
function Get-RcdErrors([long]$from) {
    try {
        $fs = [IO.File]::Open("$LogRoot\rcd.log", 'Open', 'Read', 'ReadWrite')
        try {
            if ($fs.Length -lt $from) { $from = 0 }  # rotated during the run
            $fs.Seek($from, 'Begin') | Out-Null
            $text = (New-Object IO.StreamReader $fs, (New-Object Text.UTF8Encoding $false)).ReadToEnd()
        } finally { $fs.Dispose() }
        @($text -split "`r?`n" | Where-Object { $_ -match ' ERROR : ' } |
            ForEach-Object { $_ -replace '^\d{4}/\d\d/\d\d \d\d:\d\d:\d\d ERROR : ', '' } | Select-Object -Unique)
    } catch { @() }
}
function Get-RcdLogLength { try { (Get-Item "$LogRoot\rcd.log" -ErrorAction Stop).Length } catch { 0 } }

# Turns a raw rclone error into a plain-English line the tray can show as-is, and decides
# whether the problem is one more retry will fix (transient) or needs a human to look at a
# specific file/setting first (paused: the service stops touching Proton until resolved).
function Get-FailureGuidance([string]$raw, [string]$msg) {
    $all = "$raw $msg"
    if ($all -match 'file not found in Path2' -and $all -match 'file not found in Path1' -and $all -match 'out of sync|Must run --resync') {
        return @{ Pause = $true; Guidance =
            'Paused: a file differs only by letter case between local and Proton (e.g. .pdf vs .PDF) - ' +
            'this usually means duplicate copies exist on Proton. Check Proton''s web app for a ' +
            'duplicate-case filename, delete one copy, then choose "Resume sync" in the tray.' }
    }
    if ($all -match 'too many deletes') {
        return @{ Pause = $true; Guidance =
            "Paused: a sync would delete more files than the safety limit allows ($msg). " +
            'Review what changed on both sides, then choose "Resume sync" in the tray once you''re sure.' }
    }
    if ($all -match 'Access is denied|Permission denied') {
        return @{ Pause = $false; Guidance =
            'Some file(s) are not readable by the service account (SYSTEM). Grant it access, or ' +
            "exclude them in bisync-filters.txt. ($msg)" }
    }
    if ($all -match 'Invalid access token|401 GET') {
        return @{ Pause = $false; Guidance =
            'Proton session token expired; the service already retried once automatically. If this ' +
            'keeps recurring, your Proton password or 2FA may have changed - re-run rclone config.' }
    }
    @{ Pause = $false; Guidance = $msg }
}

$common = @('--config', $Config, '--cache-dir', "$Root\cache")

$rcd = Start-Process -FilePath $Rclone -PassThru -NoNewWindow -ArgumentList ($common + @(
    'rcd', '--rc-addr', $Addr, '--rc-web-gui', '--rc-web-gui-no-open-browser',
    '--rc-job-expire-duration', '24h',
    '--log-level', 'INFO', '--log-file', "$LogRoot\rcd.log", '--log-file-max-size', '20M'))
Log "rcd started (pid $($rcd.Id)) on http://$Addr"
Start-Sleep -Seconds 5

# Call the rc HTTP API directly: PowerShell 5.1 mangles JSON quotes passed to native exes.
$basic = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($auth[0]):$($auth[1])"))

while (-not $rcd.HasExited) {
    if (Test-Path $PauseFile) {
        if (Test-Path $Trigger) {
            # "Resume sync" in the tray: drop the pause and let this cycle try for real.
            Remove-Item $PauseFile -Force
            Log 'sync resumed (will re-pause if the same problem is still there)'
        } else {
            Log 'sync paused: resolve the issue, then choose "Resume sync" in the tray'
            $deadline = (Get-Date).AddSeconds($Interval)
            while ((Get-Date) -lt $deadline -and -not $rcd.HasExited) {
                if (Test-Path $Trigger) { break }
                Start-Sleep -Seconds 3
            }
            continue
        }
    }
    if ($Mode -eq 'download') {
        # One-way proton: -> LocalPath. copy never deletes locally; Update keeps
        # local files that are newer than the remote copy.
        $endpoint = 'sync/copy'
        $body = @{
            srcFs = $Remote; dstFs = $Local; createEmptySrcDirs = $true
            # Anything copy would overwrite is moved here first (outside the synced tree)
            _config = @{ Update = $true; BackupDir = "$Local.rclone-backup"; Suffix = ('.' + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
            _filter = @{ FilterFrom = @("$Root\bisync-filters.txt") }
        }
    } else {
        $endpoint = 'sync/bisync'
        $body = @{
            path1 = $Local; path2 = $Remote; workdir = "$Root\bisync"
            compare = 'size,modtime'; resilient = $true; recover = $true; maxLock = '2m'
            createEmptySrcDirs = $true; filtersFile = "$Root\bisync-filters.txt"
            conflictResolve = 'newer'
            # Local files bisync would overwrite/delete are kept here (Proton has its own trash)
            backupDir1 = "$Local.rclone-backup"
            # The rc endpoint does NOT fall back to bisync's documented 50% CLI default when this
            # is simply absent from the JSON body - it silently defaults to 0, so every run aborted
            # on even a single harmless delete. Set explicitly, as a percent of total file count.
            maxDelete = 5
        }
        if (-not (Test-Path "$Root\bisync\*.lst")) { $body.resync = $true; $body.resyncMode = 'newer'; Log 'first run: --resync (newer wins)' }
    }
    Log "$Mode sync starting"
    $started = Get-Date
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $rcdPos = Get-RcdLogLength
        try {
            $res = Invoke-RestMethod -Method Post -Uri "http://$Addr/$endpoint" -Headers @{ Authorization = $basic } `
                -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 5) -TimeoutSec 86400
            Log "$Mode sync finished: $($res | ConvertTo-Json -Compress)"
            break
        } catch {
            # PowerShell has already consumed the response stream: the body is in ErrorDetails.
            $raw = "$($_.ErrorDetails.Message)" -replace '\s+', ' '
            $reason = try { ($_.ErrorDetails.Message | ConvertFrom-Json).error } catch { $null }
            if (-not $reason) { $reason = $_.Exception.Message }
            $errs = Get-RcdErrors $rcdPos
            $msg = $reason
            if ($errs.Count) {
                $denied = @($errs | Where-Object { $_ -match 'Access is denied|Permission denied|being used by another process' })
                if ($denied.Count) { $msg += " - $($denied.Count) file(s) not accessible to the service account (SYSTEM); grant it read access or exclude them in bisync-filters.txt" }
                $shown = ($errs | Select-Object -First 3 | ForEach-Object { $_.Trim() }) -join ' | '
                $msg += ": $shown"
                if ($errs.Count -gt 3) { $msg += " | (+$($errs.Count - 3) more, see rcd.log)" }
            }
            # Proton session tokens expire; a 401 on refresh gets misreported by bisync as a
            # delete-count safety abort. One plain rclone call forces the backend to refresh
            # client_access_token/client_refresh_token in rclone.conf, then we retry once.
            $isAuthError = ("$raw $msg" -match 'Invalid access token|401 GET|invalid.?(access.?)?token')
            if ($isAuthError -and $attempt -eq 1) {
                Log "$Mode sync hit an expired Proton session token; refreshing and retrying once"
                & $Rclone @common lsf $Remote --max-depth 1 *>&1 | Out-Null
                continue
            }
            $g = Get-FailureGuidance $raw $msg
            if ($g.Pause) {
                @{ guidance = $g.Guidance; detail = $msg; since = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss') } |
                    ConvertTo-Json | Set-Content $PauseFile
            }
            # One line, because the tray reads this log line by line
            Log "$Mode sync FAILED: $($g.Guidance)"
            Log "$Mode sync failure response: $raw"
            break
        }
    }
    # Start-to-start schedule: sleep only what's left of the interval (0 if the run overran it)
    $wait = [math]::Max(0, $Interval - ((Get-Date) - $started).TotalSeconds)
    Log ("next run in {0:N0}s (or create $Trigger to run now)" -f $wait)
    $deadline = (Get-Date).AddSeconds($wait)
    while ((Get-Date) -lt $deadline -and -not $rcd.HasExited) {
        if (Test-Path $Trigger) { Remove-Item $Trigger -Force; Log 'sync-now requested'; break }
        Start-Sleep -Seconds 3
    }
}
Log 'rcd exited; stopping so the service manager restarts us'
exit 1
