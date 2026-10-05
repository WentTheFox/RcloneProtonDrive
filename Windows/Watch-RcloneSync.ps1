# Tray-icon watcher for the rclone-proton sync service. Event-driven: a
# FileSystemWatcher reacts to service.log being appended to (no polling loop).
# Green icon = last run succeeded. Red icon = last run failed; a balloon tip
# fires on the first failure and then every 4th one after that, so a stuck
# sync can't silently sit broken for days the way it did before this existed.
# Run via Register-Tray.ps1 (logon scheduled task), or manually:
#   powershell -NoProfile -WindowStyle Hidden -File Watch-RcloneSync.ps1

# Single instance: a theme-change restart launches the new copy while the old one is
# still shutting down, so wait (briefly) for the old one to release the mutex, and
# bail out if it never does rather than ever running two trays.
$global:RcloneTrayMutex = New-Object System.Threading.Mutex($false, 'Local\RcloneProtonTray')
try { $acquired = $global:RcloneTrayMutex.WaitOne(15000) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
if (-not $acquired) { exit }

# SystemEvents and FileSystemWatcher raise their events on background threads, which PowerShell
# script blocks can't handle safely (Register-ObjectEvent actions race with shutdown and throw
# PipelineStoppedException), so tiny C# shims marshal them onto the UI thread instead.
# (Compiled before FreeConsole: Add-Type needs a console handle.)
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @"
using System;
using System.IO;
using System.Windows.Forms;
using Microsoft.Win32;
public class WatcherBridge {
    public WatcherBridge(FileSystemWatcher w, Control ui, Action callback) {
        FileSystemEventHandler h = (s, e) => Post(ui, callback);
        w.Changed += h; w.Created += h; w.Deleted += h;
        w.Renamed += (s, e) => Post(ui, callback);
        w.Error += (s, e) => Post(ui, callback);
    }
    static void Post(Control ui, Action cb) {
        try { if (ui.IsHandleCreated && !ui.IsDisposed) ui.BeginInvoke(cb); } catch (Exception) { }
    }
}
public class ThemeWatcher {
    public ThemeWatcher(Control ui, Action callback) {
        SystemEvents.UserPreferenceChanged += (s, e) => {
            if (e.Category == UserPreferenceCategory.General && ui.IsHandleCreated) ui.BeginInvoke(callback);
        };
    }
}
"@

# Detach from the console so no PowerShell window lingers (and closing one
# can't kill the tray icon). -WindowStyle Hidden alone still flashes a window.
Add-Type -Namespace Win32 -Name Console -MemberDefinition '[DllImport("kernel32.dll")] public static extern bool FreeConsole();'
[Win32.Console]::FreeConsole() | Out-Null

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$Root = 'C:\ProgramData\rclone'
$LogFile = "$Root\logs\service.log"

# Icons are rendered from the Lucide submodule by Build-Icons.ps1 (called from Register-Tray.ps1).
function global:New-PngIcon([string]$name) {
    $src = [System.Drawing.Image]::FromFile("$Root\icons\$name.png")
    $size = [System.Windows.Forms.SystemInformation]::SmallIconSize
    $bmp = New-Object System.Drawing.Bitmap $size.Width, $size.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.SmoothingMode = 'HighQuality'
    $g.DrawImage($src, 0, 0, $size.Width, $size.Height)
    $g.Dispose(); $src.Dispose()
    [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}
# Theme state is read exactly once, here, and drives the tray icons, popup colours and the
# change check below, so they can never disagree with each other.
function global:Get-RcloneThemeKey {
    $p = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction SilentlyContinue
    $d = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\DWM' -ErrorAction SilentlyContinue
    "$($p.SystemUsesLightTheme)/$($p.AppsUseLightTheme)/$($d.AccentColor)"
}
$global:RcloneThemeKey = Get-RcloneThemeKey
$themeParts = $global:RcloneThemeKey -split '/'
$taskbarLight = $themeParts[0] -eq '1'
$tbSuffix = if ($taskbarLight) { 'black' } else { 'white' }
$iconOk      = New-PngIcon "synced-$tbSuffix"
$iconBad     = New-PngIcon "error-$tbSuffix"
$iconSyncing = New-PngIcon "syncing-$tbSuffix"
$iconIdle    = New-PngIcon "idle-$tbSuffix"
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = $iconIdle
$notify.Text = 'Proton Drive sync: starting up'
$notify.Visible = $true

function Get-WebGuiUrl {
    try {
        $auth = Get-Content "$Root\rc-auth.txt"
        $tok = [uri]::EscapeDataString([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($auth[0]):$($auth[1])")))
        "http://127.0.0.1:5572/?login_token=$tok"
    } catch { 'http://127.0.0.1:5572/' }
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$itemOpen = $menu.Items.Add('Open web UI')
$itemOpen.Add_Click({ Start-Process (Get-WebGuiUrl) })
$itemSync = $menu.Items.Add('Sync now')
$itemSync.Add_Click({ Request-RcloneSync })
$menu.Items.Add('-') | Out-Null
$itemRestart = $menu.Items.Add('Restart tray icon')
$itemRestart.Add_Click({ Restart-RcloneTray })
$itemExit = $menu.Items.Add('Exit')
$itemExit.Add_Click({ $notify.Visible = $false; [System.Windows.Forms.Application]::Exit() })
$notify.ContextMenuStrip = $menu
$notify.Add_MouseClick({ if ($_.Button -eq 'Left') { Toggle-RcloneTrayPopup } })

$global:RcloneTrayNotify = $notify
$global:RcloneTrayIconSyncing = $iconSyncing
$global:RcloneTrayRoot = $Root
$global:RcloneSyncing = $false
$global:RcloneSyncSince = $null
$global:RcloneLastOk = $null
$global:RcloneLastError = ''
$global:RcloneStats = $null
$global:RcloneTrayIconOk = $iconOk
$global:RcloneTrayIconBad = $iconBad
$global:RcloneTrayIconIdle = $iconIdle
$global:RcloneTrayLogFile = $LogFile
$global:consecutiveFailures = 0
$global:lastOffset = 0

function global:Update-RcloneTrayStatus([string]$state, [string]$detail, $when = (Get-Date)) {
    $stamp = Get-Date -Format 'HH:mm:ss'
    $global:RcloneSyncing = ($state -eq 'start')
    switch ($state) {
        'start' {
            $global:RcloneStopRequested = $false
            $global:RcloneStats = $null
            $global:RcloneSyncSince = $when
            $global:RcloneTrayNotify.Icon = $global:RcloneTrayIconSyncing
            $text = "Proton Drive sync: syncing ($stamp)"
            $global:RcloneTrayNotify.Text = $text.Substring(0, [Math]::Min(63, $text.Length))
        }
        'ok' {
            if ($global:RcloneJobGroup -and ((Get-Date) - $when).TotalSeconds -lt 30) {
                $s = Get-RcloneStatsNow
                if ($s -and $s.checks -gt 0) { Save-RcloneRun $s.checks (($when - $global:RcloneSyncSince).TotalSeconds) }
            }
            $global:RcloneJobGroup = $null
            $global:RcloneLastOk = $when
            $global:RcloneLastError = ''
            $global:consecutiveFailures = 0
            $global:RcloneTrayNotify.Icon = $global:RcloneTrayIconOk
            $text = "Proton Drive sync: OK ($stamp)"
            $global:RcloneTrayNotify.Text = $text.Substring(0, [Math]::Min(63, $text.Length))
        }
        'fail' {
            $global:RcloneJobGroup = $null
            if ($global:RcloneStopRequested) {  # user stopped it: not an error
                $global:RcloneStopRequested = $false
                Set-RcloneCurrentIcon
                $global:RcloneTrayNotify.Text = "Proton Drive sync: stopped ($stamp)"
                return
            }
            $global:RcloneLastError = $detail
            $global:consecutiveFailures++
            $global:RcloneTrayNotify.Icon = $global:RcloneTrayIconBad
            $text = "Proton Drive sync: FAILED x$($global:consecutiveFailures) (last $stamp)"
            $global:RcloneTrayNotify.Text = $text.Substring(0, [Math]::Min(63, $text.Length))
            if ($global:consecutiveFailures -eq 1 -or $global:consecutiveFailures % 4 -eq 0) {
                $global:RcloneTrayNotify.ShowBalloonTip(15000, 'Proton Drive sync is failing', $detail.Substring(0, [Math]::Min(200, $detail.Length)), [System.Windows.Forms.ToolTipIcon]::Error)
            }
        }
    }
}

function global:Read-RcloneTrayNewLines {
    try {
        $fi = Get-Item -LiteralPath $global:RcloneTrayLogFile -ErrorAction Stop
        if ($fi.Length -lt $global:lastOffset) { $global:lastOffset = 0 }  # rotated/truncated
        if ($fi.Length -eq $global:lastOffset) { return }
        $fs = [System.IO.File]::Open($global:RcloneTrayLogFile, 'Open', 'Read', 'ReadWrite')
        $fs.Seek($global:lastOffset, 'Begin') | Out-Null
        $sr = New-Object System.IO.StreamReader $fs, (New-Object System.Text.UTF8Encoding $false), $false
        $text = $sr.ReadToEnd()
        $sr.Close(); $fs.Close()
        # Only consume complete lines: a line caught mid-write would otherwise be split in two
        # and neither half would match, silently losing a "sync starting/finished" marker.
        $nl = $text.LastIndexOf("`n")
        if ($nl -lt 0) { return }
        $text = $text.Substring(0, $nl + 1)
        $global:lastOffset += [System.Text.Encoding]::UTF8.GetByteCount($text)
        foreach ($line in ($text -split "`r?`n")) {
            $when = Get-Date
            if ($line -match '^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)') { $when = [datetime]::Parse($Matches[1]) }
            if ($line -match 'sync FAILED:\s*(.*)$') { Update-RcloneTrayStatus 'fail' $Matches[1] $when }
            elseif ($line -match 'sync finished') { Update-RcloneTrayStatus 'ok' '' $when }
            elseif ($line -match 'sync starting') { Update-RcloneTrayStatus 'start' '' $when }
        }
    } catch { }
    Update-RcloneTrayPopup
}

# --- Status popup (left-click the tray icon) --------------------------------
# rc has no push API, so live transfer stats are fetched once a second, but
# only while the popup is open and a sync is running.
function global:Format-Bytes([double]$b) {
    $u = 'B', 'KiB', 'MiB', 'GiB', 'TiB'; $i = 0
    while ($b -ge 1024 -and $i -lt $u.Count - 1) { $b /= 1024; $i++ }
    ('{0:N1} {1}' -f $b, $u[$i]) -replace '\.0 B$', ' B'
}
function global:Format-Duration([double]$s) {
    $t = [TimeSpan]::FromSeconds([Math]::Round($s))
    if ($t.TotalHours -ge 1) { '{0}h {1}m {2}s' -f [int]$t.TotalHours, $t.Minutes, $t.Seconds }
    elseif ($t.TotalMinutes -ge 1) { '{0}m {1}s' -f $t.Minutes, $t.Seconds }
    else { '{0}s' -f $t.Seconds }
}
function global:Format-Ago($d) {
    if (-not $d) { return 'never' }
    $s = ((Get-Date) - $d).TotalSeconds
    if ($s -lt 60) { 'just now' } elseif ($s -lt 3600) { "$([int]($s / 60)) min ago" }
    elseif ($s -lt 86400) { "$([int]($s / 3600)) h ago" } else { "$([int]($s / 86400)) d ago" }
}

# Win11 look: follow the system light/dark setting and accent colour, rounded
# corners + shadow + hairline border via DWM, flat controls, Segoe UI.
Add-Type -Namespace Win32 -Name Dwm -MemberDefinition @'
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
[StructLayout(LayoutKind.Sequential)] public struct MARGINS { public int l, r, t, b; }
[DllImport("dwmapi.dll")] public static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref MARGINS m);
'@
function Get-RegValue($path, $name, $default) {
    try { $v = (Get-ItemProperty -Path $path -Name $name -ErrorAction Stop).$name; if ($null -ne $v) { return $v } } catch { }
    $default
}
function global:Get-RclonePalette([string]$key) {
    $parts = $key -split '/'
    $light = $parts[1] -eq '1'
    $abgr = if ($parts[2]) { [uint32]$parts[2] } else { [uint32]0xFFD47800 }
    $c = { param($r, $g, $b) [System.Drawing.Color]::FromArgb($r, $g, $b) }
    $p = @{
        TaskbarLight = $parts[0] -eq '1'; Light = $light
        Accent = & $c ($abgr -band 0xFF) (($abgr -shr 8) -band 0xFF) (($abgr -shr 16) -band 0xFF)
    }
    if ($light) {
        $p.Bg = & $c 249 249 249; $p.Fg = & $c 26 26 26; $p.Dim = & $c 96 96 96; $p.Track = & $c 215 215 215
        $p.Border = & $c 205 205 205; $p.Err = & $c 196 43 28
    } else {
        $p.Bg = & $c 43 43 43; $p.Fg = & $c 255 255 255; $p.Dim = & $c 171 171 171; $p.Track = & $c 70 70 70
        $p.Border = & $c 70 70 70; $p.Err = & $c 255 153 164
    }
    $p
}
$global:RclonePal = Get-RclonePalette $global:RcloneThemeKey
$light = $global:RclonePal.Light; $accent = $global:RclonePal.Accent
$cBg = $global:RclonePal.Bg; $cFg = $global:RclonePal.Fg; $cDim = $global:RclonePal.Dim
$cTrack = $global:RclonePal.Track; $cBorder = $global:RclonePal.Border; $cErr = $global:RclonePal.Err
$fontBody = New-Object System.Drawing.Font 'Segoe UI Variable Text', 9.5
$fontSmall = New-Object System.Drawing.Font 'Segoe UI Variable Small', 9
$fontTitle = New-Object System.Drawing.Font 'Segoe UI Variable Display Semibold', 13
$contentWidth = 330

$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = 'None'
$form.ShowInTaskbar = $false
$form.TopMost = $true
$form.StartPosition = 'Manual'
$form.BackColor = $cBg
$form.ForeColor = $cFg
$form.Font = $fontBody
$form.AutoSize = $true
$form.AutoSizeMode = 'GrowAndShrink'
$form.Padding = New-Object System.Windows.Forms.Padding 28, 26, 28, 28
function global:Set-PopupDwm($h) {
    $pal = $global:RclonePal
    $v = if ($pal.Light) { 0 } else { 1 }; [Win32.Dwm]::DwmSetWindowAttribute($h, 20, [ref]$v, 4) | Out-Null  # dark mode
    $v = 2; [Win32.Dwm]::DwmSetWindowAttribute($h, 33, [ref]$v, 4) | Out-Null                              # rounded corners
    $b = $pal.Border; $v = $b.B * 65536 + $b.G * 256 + $b.R; [Win32.Dwm]::DwmSetWindowAttribute($h, 34, [ref]$v, 4) | Out-Null  # border colour
    $m = New-Object Win32.Dwm+MARGINS; $m.l = 1; $m.r = 1; $m.t = 1; $m.b = 1                             # drop shadow
    [Win32.Dwm]::DwmExtendFrameIntoClientArea($h, [ref]$m) | Out-Null
}
$form.Add_HandleCreated({ Set-PopupDwm $this.Handle })
$panel = New-Object System.Windows.Forms.FlowLayoutPanel
$panel.FlowDirection = 'TopDown'
$panel.WrapContents = $false
$panel.AutoSize = $true
$panel.BackColor = $cBg
$panel.Location = New-Object System.Drawing.Point $form.Padding.Left, $form.Padding.Top
$form.Controls.Add($panel)

$global:PopupLabels = @()
function New-PopupLabel($font = $fontBody, $color = $cFg, [int]$top = 0, [int]$bottom = 10, $parent = $panel) {
    $l = New-Object System.Windows.Forms.Label
    $l.AutoSize = $true
    $l.Font = $font
    $l.ForeColor = $color
    $l.BackColor = $cBg
    $l.MaximumSize = New-Object System.Drawing.Size $contentWidth, 0
    $l.Margin = New-Object System.Windows.Forms.Padding 0, $top, 0, $bottom
    $parent.Controls.Add($l)
    $role = if ($color -eq $cDim) { 'Dim' } elseif ($color -eq $cErr) { 'Err' } else { 'Fg' }
    $global:PopupLabels += ,@($l, $role)
    $l
}
# Header: state icon beside "Proton Drive sync" and the state text
$header = New-Object System.Windows.Forms.FlowLayoutPanel
$header.FlowDirection = 'LeftToRight'
$header.WrapContents = $false
$header.AutoSize = $true
$header.BackColor = $cBg
$header.Margin = New-Object System.Windows.Forms.Padding 0, 0, 0, 4
$panel.Controls.Add($header)
$picState = New-Object System.Windows.Forms.PictureBox
$picState.Size = New-Object System.Drawing.Size 40, 40
$picState.SizeMode = 'Zoom'
$picState.Margin = New-Object System.Windows.Forms.Padding 0, 0, 12, 0
$header.Controls.Add($picState)
$titleCol = New-Object System.Windows.Forms.FlowLayoutPanel
$titleCol.FlowDirection = 'TopDown'
$titleCol.WrapContents = $false
$titleCol.AutoSize = $true
$titleCol.BackColor = $cBg
$titleCol.Margin = New-Object System.Windows.Forms.Padding 0
$header.Controls.Add($titleCol)
$lblTitle = New-PopupLabel $fontSmall $cDim 0 0 $titleCol
$lblTitle.Text = 'Proton Drive sync'
$lblState = New-PopupLabel $fontTitle $cFg 0 0 $titleCol
$global:PopupImages = @{}
$appSuffix = if ($light) { 'black' } else { 'white' }
foreach ($n in 'synced', 'syncing', 'error', 'idle') { $global:PopupImages[$n] = [System.Drawing.Image]::FromFile("$Root\icons\$n-$appSuffix.png") }
$lblSince = New-PopupLabel $fontSmall $cDim 0 16
$barTrack = New-Object System.Windows.Forms.Panel
$barTrack.Size = New-Object System.Drawing.Size $contentWidth, 4
$barTrack.BackColor = $cTrack
$barTrack.Margin = New-Object System.Windows.Forms.Padding 0, 6, 0, 12
$bar = New-Object System.Windows.Forms.Panel
$bar.Dock = 'Left'
$bar.Width = 0
$bar.BackColor = $accent
$barTrack.Controls.Add($bar)
$panel.Controls.Add($barTrack)
$lblBytes = New-PopupLabel $fontBody $cFg 0 4
$lblCounts = New-PopupLabel $fontSmall $cDim 0 10
$lblFiles = New-PopupLabel $fontSmall $cDim 0 10
$lblLastOk = New-PopupLabel $fontSmall $cDim 0 10
$lblError = New-PopupLabel $fontSmall $cErr 0 12
$btnSync = New-Object System.Windows.Forms.Button
$btnSync.Text = 'Sync now'
$btnSync.FlatStyle = 'Flat'
$btnSync.FlatAppearance.BorderSize = 0
$btnSync.Font = $fontBody
$btnSync.Size = New-Object System.Drawing.Size $contentWidth, 34
$btnSync.Margin = New-Object System.Windows.Forms.Padding 0, 14, 0, 0
$btnSync.Cursor = 'Hand'
$btnSync.UseVisualStyleBackColor = $false
$btnSync.Add_Click({ Invoke-RcloneSyncButton })
$panel.Controls.Add($btnSync)
$global:PopupAccent = $accent; $global:PopupTrack = $cTrack; $global:PopupDim = $cDim; $global:PopupFg = $cFg

$global:PopupPanel = $panel; $global:PopupHeader = $header; $global:PopupTitleCol = $titleCol
$global:RcloneTrayPopup = $form
$global:RcloneTrayPopupHiddenAt = [datetime]::MinValue
$global:PopupCtl = @{ Pic = $picState; State = $lblState; Since = $lblSince; Bar = $bar; BarTrack = $barTrack; Bytes = $lblBytes; Counts = $lblCounts
                      Files = $lblFiles; LastOk = $lblLastOk; Error = $lblError; Sync = $btnSync }

function global:Set-RcloneCurrentIcon {
    $g = $global:RcloneTrayNotify
    $g.Icon = if ($global:RcloneSyncing) { $global:RcloneTrayIconSyncing }
              elseif ($global:consecutiveFailures -gt 0) { $global:RcloneTrayIconBad }
              elseif ($global:RcloneLastOk) { $global:RcloneTrayIconOk }
              else { $global:RcloneTrayIconIdle }
}

# Re-applies the light/dark + accent theme in place: tray icons, popup colours and
# popup images. No restart needed. Called (debounced) after a system theme change.
function global:Update-RcloneTheme {
    $key = Get-RcloneThemeKey
    if ($key -eq $global:RcloneThemeKey) { return }
    $global:RcloneThemeKey = $key
    $pal = Get-RclonePalette $key
    $global:RclonePal = $pal

    $sfx = if ($pal.TaskbarLight) { 'black' } else { 'white' }
    $global:RcloneTrayIconOk = New-PngIcon "synced-$sfx"
    $global:RcloneTrayIconBad = New-PngIcon "error-$sfx"
    $global:RcloneTrayIconSyncing = New-PngIcon "syncing-$sfx"
    $global:RcloneTrayIconIdle = New-PngIcon "idle-$sfx"
    Set-RcloneCurrentIcon

    $appSfx = if ($pal.Light) { 'black' } else { 'white' }
    foreach ($n in 'synced', 'syncing', 'error', 'idle') {
        $old = $global:PopupImages[$n]
        $global:PopupImages[$n] = [System.Drawing.Image]::FromFile("$($global:RcloneTrayRoot)\icons\$n-$appSfx.png")
        $global:PopupCtl.Pic.Image = $null; if ($old) { $old.Dispose() }
    }

    $f = $global:RcloneTrayPopup
    $f.SuspendLayout()
    foreach ($c in $f, $global:PopupPanel, $global:PopupHeader, $global:PopupTitleCol) { $c.BackColor = $pal.Bg }
    $f.ForeColor = $pal.Fg
    foreach ($pair in $global:PopupLabels) { $pair[0].BackColor = $pal.Bg; $pair[0].ForeColor = $pal[$pair[1]] }
    $global:PopupCtl.BarTrack.BackColor = $pal.Track
    $global:PopupCtl.Bar.BackColor = $pal.Accent
    $global:PopupAccent = $pal.Accent; $global:PopupTrack = $pal.Track; $global:PopupDim = $pal.Dim; $global:PopupFg = $pal.Fg
    if ($f.IsHandleCreated) { Set-PopupDwm $f.Handle }
    $f.ResumeLayout()
    $f.Invalidate($true)
    Update-RcloneTrayPopup
}
# "Sync now" drops a trigger file that the service consumes (deletes) within a few seconds and
# then logs "sync starting". The file's existence *is* the pending state, so a file watcher on
# it (created/deleted: events, no polling) drives a loading state until the run really begins.
function global:Update-RcloneSyncRequested {
    $global:RcloneSyncRequested = Test-Path "$($global:RcloneTrayRoot)\sync-now"
    if ($global:RcloneSyncRequested -and -not $global:RcloneSyncing) {
        $global:RcloneTrayNotify.Icon = $global:RcloneTrayIconSyncing
        $global:RcloneTrayNotify.Text = 'Proton Drive sync: sync requested'
    } elseif (-not $global:RcloneSyncing) {
        Set-RcloneCurrentIcon
    }
    Update-RcloneTrayPopup
}
function global:Invoke-Rc([string]$path, $body = @{}) {
    $auth = Get-Content "$($global:RcloneTrayRoot)\rc-auth.txt"
    $basic = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($auth[0]):$($auth[1])"))
    Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:5572/$path" -Headers @{ Authorization = $basic } `
        -ContentType 'application/json' -Body ($body | ConvertTo-Json) -TimeoutSec 3
}
# Ground truth for "is a sync running": rclone's own job list. Every rc call (including this
# one) is a job, but those finish instantly, so only jobs running for more than a couple of
# seconds count. This does not depend on log-file change events, which Windows withholds
# while the service keeps the log open. Returns @{ Id; Start } per running job.
function global:Get-RcloneRunningJobs {
    try {
        $out = @()
        foreach ($id in @((Invoke-Rc 'job/list').runningIds)) {
            $st = Invoke-Rc 'job/status' @{ jobid = $id }
            # duration stays 0 until a job finishes, so age comes from its start time
            $start = [datetime]$st.startTime
            if (-not $st.finished -and ((Get-Date) - $start).TotalSeconds -ge 2) { $out += @{ Id = $id; Start = $start } }
        }
        , $out
    } catch { , @() }
}
# Reconcile the tray's idea of the state with rclone's: log events can be late or missed.
function global:Sync-RcloneStateFromRc {
    $jobs = Get-RcloneRunningJobs
    if ($jobs.Count -and -not $global:RcloneSyncing) {
        $global:RcloneJobGroup = "job/$($jobs[0].Id)"
        Update-RcloneTrayStatus 'start' '' $jobs[0].Start
    } elseif (-not $jobs.Count -and $global:RcloneSyncing) {
        Read-RcloneTrayNewLines  # the log knows how it ended
    }
    Update-RcloneTrayPopup
    , $jobs
}
function global:Request-RcloneSync {
    if ($global:RcloneSyncRequested) { return }
    # Never queue a run behind one that is already going: check rclone first
    if ((Sync-RcloneStateFromRc).Count -or $global:RcloneSyncing) { return }
    try { New-Item -ItemType File -Force "$($global:RcloneTrayRoot)\sync-now" | Out-Null } catch {
        $global:RcloneTrayNotify.ShowBalloonTip(5000, 'Proton Drive sync', "Could not request a sync: $($_.Exception.Message)", [System.Windows.Forms.ToolTipIcon]::Error)
        return
    }
    Update-RcloneSyncRequested
}
# Stop: drop any queued trigger (or the service would start the next run right away) and cancel the running job(s).
function global:Stop-RcloneSync {
    [System.IO.File]::Delete("$($global:RcloneTrayRoot)\sync-now")
    $jobs = Get-RcloneRunningJobs
    if ($jobs.Count) { $global:RcloneStopRequested = $true }
    foreach ($j in $jobs) { try { Invoke-Rc 'job/stop' @{ jobid = $j.Id } | Out-Null } catch { } }
    Update-RcloneSyncRequested
}
function global:Invoke-RcloneSyncButton {
    if ($global:RcloneSyncing -or $global:RcloneSyncRequested) { Stop-RcloneSync } else { Request-RcloneSync }
}
$global:RcloneStopRequested = $false
$global:RcloneSyncRequested = Test-Path "$Root\sync-now"
# rclone's global counters accumulate since rcd started, but every rc job has its own stats
# group ("job/<id>"), so asking for the running job's group gives exact per-run numbers with
# no baseline bookkeeping (and works however late the tray notices the run).
$global:RcloneJobGroup = $null
function global:Get-RcloneStatsNow {
    if (-not $global:RcloneJobGroup) { return $null }
    try {
        $auth = Get-Content "$($global:RcloneTrayRoot)\rc-auth.txt"
        $basic = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($auth[0]):$($auth[1])"))
        Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:5572/core/stats' -Headers @{ Authorization = $basic } `
            -ContentType 'application/json' -Body (@{ group = $global:RcloneJobGroup } | ConvertTo-Json) -TimeoutSec 2
    } catch { $null }  # keep the last snapshot rather than flicker
}
function global:Get-RcloneStats {
    if (-not $global:RcloneJobGroup) {
        $j = Get-RcloneRunningJobs
        if ($j.Count) { $global:RcloneJobGroup = "job/$($j[0].Id)" }
    }
    $s = Get-RcloneStatsNow
    if ($s) { $global:RcloneStats = $s }
}

# --- Rough progress across runs ----------------------------------------------
# A run's check count comes from its rc job's stats group (see Get-RcloneStatsNow), saved at the
# "sync finished" log event. The last few runs are kept in tray-state.json; their median is the
# estimate for how many checks the current run will make. bisync checks every file on both
# sides, so this is roughly twice the file count, hence "checks" in the UI.
$global:RcloneStateFile = "$Root\tray-state.json"
$global:RcloneRunHistory = @()
try { $global:RcloneRunHistory = @((Get-Content $global:RcloneStateFile -Raw -ErrorAction Stop | ConvertFrom-Json).runs) } catch { }
function global:Get-RcloneExpectedChecks {
    $h = @($global:RcloneRunHistory | ForEach-Object { $_.checks } | Where-Object { $_ -gt 0 } | Sort-Object)
    if ($h.Count) { return [double]$h[[int][Math]::Floor($h.Count / 2)] }
    # First run ever: the bisync listing from the last run is a decent guess at the file count
    $lst = Get-ChildItem "$($global:RcloneTrayRoot)\bisync\*.path1.lst" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($lst) { try { return [double]([System.IO.File]::ReadLines($lst.FullName) | Measure-Object).Count } catch { } }
    $null
}
function global:Save-RcloneRun([double]$checks, [double]$seconds) {
    $global:RcloneRunHistory = @($global:RcloneRunHistory + [pscustomobject]@{ checks = $checks; seconds = [int]$seconds }) | Select-Object -Last 5
    try { @{ runs = @($global:RcloneRunHistory) } | ConvertTo-Json -Depth 3 | Set-Content $global:RcloneStateFile } catch { }
}
function global:Get-RcloneRunChecks {
    if ($global:RcloneJobGroup -and $global:RcloneStats) { $global:RcloneStats.checks } else { $null }
}
function global:Update-RcloneTrayPopup([switch]$Force) {
    $f = $global:RcloneTrayPopup
    if (-not $f.Visible -and -not $Force) { return }
    $c = $global:PopupCtl
    $requested = (Test-Path "$($global:RcloneTrayRoot)\sync-now") -and -not $global:RcloneSyncing
    $syncing = $global:RcloneSyncing -or $requested
    $failed = (-not $syncing) -and $global:RcloneLastError
    $c.Pic.Image = $global:PopupImages[$(if ($syncing) { 'syncing' } elseif ($failed) { 'error' } elseif ($global:RcloneLastOk) { 'synced' } else { 'idle' })]
    $c.State.Text = if ($requested) { 'Sync requested...' } elseif ($syncing) { 'Syncing...' } elseif ($failed) { 'Sync failed' } elseif ($global:RcloneLastOk) { 'Up to date' } else { 'No sync run yet' }
    $c.Since.Visible = $syncing
    if ($requested) { $c.Since.Text = 'Waiting for the service to start the run' }
    elseif ($syncing) {
        $c.Since.Text = "Started $(Format-Ago $global:RcloneSyncSince)"
        if (Test-Path "$($global:RcloneTrayRoot)\sync-now") { $c.Since.Text += '; next run queued' }
    }
    $s = $global:RcloneStats
    $showStats = $syncing -and $s
    $bytesMode = $showStats -and $s.totalBytes -gt 0
    # Files-based progress: this run's checked count vs. the median of previous runs
    $done = if ($showStats) { Get-RcloneRunChecks } else { $null }
    $expected = if ($showStats) { Get-RcloneExpectedChecks } else { $null }
    $frac = if ($null -ne $done -and $expected) { [Math]::Min(0.99, $done / [Math]::Max(1.0, $expected)) } else { $null }
    $showBar = $bytesMode -or ($null -ne $frac)
    $c.BarTrack.Visible = $showBar
    $c.Bytes.Visible = $showBar
    if ($bytesMode) {
        $c.Bar.Width = [int]($c.BarTrack.Width * [Math]::Min(1.0, $s.bytes / [Math]::Max(1, $s.totalBytes)))
        $eta = if ($s.eta) { ", ETA $(Format-Duration $s.eta)" } else { '' }
        $c.Bytes.Text = "$(Format-Bytes $s.bytes) / $(Format-Bytes $s.totalBytes) at $(Format-Bytes $s.speed)/s$eta"
    } elseif ($showBar) {
        $c.Bar.Width = [int]($c.BarTrack.Width * $frac)
        $c.Bytes.Text = ('About {0:P0}: {1:N0} of ~{2:N0} checks' -f $frac, $done, $expected)
    }
    $c.Counts.Visible = $showStats
    $c.Files.Visible = $showStats -and $s.transferring
    if ($showStats) {
        $checked = if ($null -ne $done) { $done } else { $s.checks }
        $c.Counts.Text = "$('{0:N0}' -f $checked) checks, $($s.transfers) transfers, elapsed $(Format-Duration ((Get-Date) - $(if ($global:RcloneSyncSince) { $global:RcloneSyncSince } else { Get-Date })).TotalSeconds)"
        if ($s.transferring) { $c.Files.Text = (($s.transferring | ForEach-Object { "$($_.name) ($($_.percentage)%)" }) -join "`n") }
    }    $c.LastOk.Text = "Last successful sync: $(Format-Ago $global:RcloneLastOk)"
    $c.Error.Visible = [bool]$failed
    $c.Error.Text = $global:RcloneLastError
    $c.Sync.Text = if ($requested) { 'Cancel request' } elseif ($syncing) { 'Stop sync' } else { 'Sync now' }
    $c.Sync.BackColor = if ($syncing) { $global:PopupTrack } else { $global:PopupAccent }
    $c.Sync.ForeColor = if ($syncing) { $global:PopupFg } else { [System.Drawing.Color]::White }
    $f.Timer.Enabled = $syncing -and $f.Visible
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({ Get-RcloneStats; Update-RcloneTrayPopup })
$form | Add-Member -NotePropertyName Timer -NotePropertyValue $timer

$form.Add_Deactivate({ $global:RcloneTrayPopupHiddenAt = Get-Date; $this.Hide(); $this.Timer.Enabled = $false })
function global:Set-PopupPosition {
    $f = $global:RcloneTrayPopup
    $wa = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea
    $f.Location = New-Object System.Drawing.Point ($wa.Right - $f.Width - 8), ($wa.Bottom - $f.Height - 8)
}
$form.Add_SizeChanged({ if ($this.Visible) { Set-PopupPosition } })

function global:Toggle-RcloneTrayPopup {
    $f = $global:RcloneTrayPopup
    # The click that dismisses the popup arrives right after Deactivate hid it; don't reopen
    if ($f.Visible -or ((Get-Date) - $global:RcloneTrayPopupHiddenAt).TotalMilliseconds -lt 300) { $f.Hide(); return }
    # Lay out with the real content *before* the first Show: otherwise the first opening
    # is sized for every (still visible) control and only shrinks afterwards.
    Read-RcloneTrayNewLines            # the log watcher can lag while the service holds the file open
    Sync-RcloneStateFromRc | Out-Null  # and ask rclone itself what is running
    Update-RcloneTrayPopup -Force
    $f.PerformLayout()
    Set-PopupPosition
    $f.Show()
    $f.Activate()
    if ($global:RcloneSyncing) { Get-RcloneStats; Update-RcloneTrayPopup }
}

# Prime from whatever's already in the log so the icon isn't a guess at startup.
if (Test-Path $LogFile) { Read-RcloneTrayNewLines }
# The log only goes back to the last service restart. bisync rewrites its listings only after
# a successful run, so their timestamp is good evidence of the last success.
if (-not $global:RcloneLastOk) {
    $lst = Get-ChildItem "$Root\bisync\*.path1.lst" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($lst) { $global:RcloneLastOk = $lst.LastWriteTime; Set-RcloneCurrentIcon }
}
Sync-RcloneStateFromRc | Out-Null

$watcher = New-Object System.IO.FileSystemWatcher (Split-Path $LogFile), (Split-Path $LogFile -Leaf)
$watcher.NotifyFilter = [System.IO.NotifyFilters]'LastWrite, Size'
$global:RcloneLogBridge = New-Object WatcherBridge $watcher, $form, ([Action]{ try { Read-RcloneTrayNewLines } catch { } })
$watcher.EnableRaisingEvents = $true
$triggerWatcher = New-Object System.IO.FileSystemWatcher $Root, 'sync-now'
$triggerWatcher.NotifyFilter = [System.IO.NotifyFilters]'FileName'
$global:RcloneTriggerBridge = New-Object WatcherBridge $triggerWatcher, $form, ([Action]{ try { Read-RcloneTrayNewLines; Update-RcloneSyncRequested } catch { } })
$triggerWatcher.EnableRaisingEvents = $true
# While the service holds service.log open Windows delivers no change events for it, so the
# log watcher above can miss "sync starting/finished". bisync creates/renews/deletes a lock
# file for the whole run, and file-level events for *that* are reliable: use them as the cue
# to re-read the log and reconcile with rclone.
$lockDir = "$Root\bisync"
if (Test-Path $lockDir) {
    $lockWatcher = New-Object System.IO.FileSystemWatcher $lockDir, '*.lck'
    $global:RcloneLockBridge = New-Object WatcherBridge $lockWatcher, $form, ([Action]{ try { Read-RcloneTrayNewLines; Sync-RcloneStateFromRc | Out-Null } catch { } })
    $lockWatcher.EnableRaisingEvents = $true
}

# Theme switches: re-theme the tray icons and popup in place when the light/dark or accent
# setting changes. Event-driven (WM_SETTINGCHANGE via SystemEvents), no polling.
function global:Restart-RcloneTray {
    # A theme change raises several events; only the first may spawn a replacement
    if ($global:RcloneRestarting) { return }
    $global:RcloneRestarting = $true
    Start-Process "$env:SystemRoot\System32\wscript.exe" -ArgumentList "`"$($global:RcloneTrayRoot)\Launch-Tray.vbs`""
    $global:RcloneTrayNotify.Visible = $false
    [System.Windows.Forms.Application]::Exit()
}
$null = $form.Handle  # make sure the popup form has a handle to marshal onto
# Windows writes the taskbar/app/accent values one after another and raises several events,
# so debounce: only compare once things have been quiet for a moment.
$global:RcloneThemeDebounce = New-Object System.Windows.Forms.Timer
$global:RcloneThemeDebounce.Interval = 1500
$global:RcloneThemeDebounce.Add_Tick({
    $global:RcloneThemeDebounce.Stop()
    try { Update-RcloneTheme } catch { }
})
$global:RcloneThemeWatcher = New-Object ThemeWatcher $form, ([Action]{
    $global:RcloneThemeDebounce.Stop(); $global:RcloneThemeDebounce.Start()
})

[System.Windows.Forms.Application]::Run()

# Remove the icon on any way out so no ghost is left in the tray until the mouse passes over it
$notify.Visible = $false
$notify.Dispose()
