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

# SystemEvents is a static event raised on its own thread, which PowerShell script
# blocks can't handle directly, so a tiny C# shim marshals it onto the UI thread.
# (Compiled before FreeConsole: Add-Type needs a console handle.)
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @"
using System;
using System.Windows.Forms;
using Microsoft.Win32;
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
$LogFile = "$Root\service.log"

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
            $global:RcloneSyncSince = $when
            $global:RcloneTrayNotify.Icon = $global:RcloneTrayIconSyncing
            $text = "Proton Drive sync: syncing ($stamp)"
            $global:RcloneTrayNotify.Text = $text.Substring(0, [Math]::Min(63, $text.Length))
        }
        'ok' {
            $global:RcloneLastOk = $when
            $global:RcloneLastError = ''
            $global:consecutiveFailures = 0
            $global:RcloneTrayNotify.Icon = $global:RcloneTrayIconOk
            $text = "Proton Drive sync: OK ($stamp)"
            $global:RcloneTrayNotify.Text = $text.Substring(0, [Math]::Min(63, $text.Length))
        }
        'fail' {
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
        $sr = New-Object System.IO.StreamReader $fs
        $text = $sr.ReadToEnd()
        $global:lastOffset = $fs.Position
        $sr.Close(); $fs.Close()
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
$btnSync.Add_Click({ Request-RcloneSync })
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
function global:Request-RcloneSync {
    if ($global:RcloneSyncing -or $global:RcloneSyncRequested) { return }
    try { New-Item -ItemType File -Force "$($global:RcloneTrayRoot)\sync-now" | Out-Null } catch {
        $global:RcloneTrayNotify.ShowBalloonTip(5000, 'Proton Drive sync', "Could not request a sync: $($_.Exception.Message)", [System.Windows.Forms.ToolTipIcon]::Error)
        return
    }
    Update-RcloneSyncRequested
}
$global:RcloneSyncRequested = Test-Path "$Root\sync-now"
function global:Get-RcloneStats {
    try {
        $auth = Get-Content "$($global:RcloneTrayRoot)\rc-auth.txt"
        $basic = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($auth[0]):$($auth[1])"))
        $global:RcloneStats = Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:5572/core/stats' `
            -Headers @{ Authorization = $basic } -TimeoutSec 2
    } catch { }  # keep the last snapshot rather than flicker
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
    elseif ($syncing) { $c.Since.Text = "Started $(Format-Ago $global:RcloneSyncSince)" }
    $s = $global:RcloneStats
    $showStats = $syncing -and $s
    $showBar = $showStats -and $s.totalBytes -gt 0
    $c.BarTrack.Visible = $showBar
    $c.Bytes.Visible = $showBar
    if ($showBar) {
        $c.Bar.Width = [int]($c.BarTrack.Width * [Math]::Min(1.0, $s.bytes / [Math]::Max(1, $s.totalBytes)))
        $eta = if ($s.eta) { ", ETA $(Format-Duration $s.eta)" } else { '' }
        $c.Bytes.Text = "$(Format-Bytes $s.bytes) / $(Format-Bytes $s.totalBytes) at $(Format-Bytes $s.speed)/s$eta"
    }
    $c.Counts.Visible = $showStats
    $c.Files.Visible = $showStats -and $s.transferring
    if ($showStats) {
        $c.Counts.Text = "Checked $($s.checks) files, $($s.transfers) transfers, elapsed $(Format-Duration $s.elapsedTime)"
        if ($s.transferring) { $c.Files.Text = (($s.transferring | ForEach-Object { "$($_.name) ($($_.percentage)%)" }) -join "`n") }
    }
    $c.LastOk.Text = "Last successful sync: $(Format-Ago $global:RcloneLastOk)"
    $c.Error.Visible = [bool]$failed
    $c.Error.Text = $global:RcloneLastError
    $c.Sync.Text = if ($requested) { 'Starting...' } else { 'Sync now' }
    $c.Sync.Cursor = if ($syncing) { "Default" } else { "Hand" }
    $c.Sync.BackColor = if ($syncing) { $global:PopupTrack } else { $global:PopupAccent }
    $c.Sync.ForeColor = if ($syncing) { $global:PopupDim } else { [System.Drawing.Color]::White }
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
    Update-RcloneTrayPopup -Force
    $f.PerformLayout()
    Set-PopupPosition
    $f.Show()
    $f.Activate()
    if ($global:RcloneSyncing) { Get-RcloneStats; Update-RcloneTrayPopup }
}

# Prime from whatever's already in the log so the icon isn't a guess at startup.
if (Test-Path $LogFile) { Read-RcloneTrayNewLines }

$watcher = New-Object System.IO.FileSystemWatcher (Split-Path $LogFile), (Split-Path $LogFile -Leaf)
$watcher.NotifyFilter = [System.IO.NotifyFilters]'LastWrite, Size'
Register-ObjectEvent $watcher Changed -Action { Read-RcloneTrayNewLines } | Out-Null
$watcher.EnableRaisingEvents = $true
$triggerWatcher = New-Object System.IO.FileSystemWatcher $Root, 'sync-now'
$triggerWatcher.NotifyFilter = [System.IO.NotifyFilters]'FileName'
foreach ($ev in 'Created', 'Deleted', 'Renamed') { Register-ObjectEvent $triggerWatcher $ev -Action { Update-RcloneSyncRequested } | Out-Null }
$triggerWatcher.EnableRaisingEvents = $true

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
    Update-RcloneTheme
})
$global:RcloneThemeWatcher = New-Object ThemeWatcher $form, ([Action]{
    $global:RcloneThemeDebounce.Stop(); $global:RcloneThemeDebounce.Start()
})

[System.Windows.Forms.Application]::Run()
