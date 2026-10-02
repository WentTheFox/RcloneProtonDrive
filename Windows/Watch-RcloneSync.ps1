# Tray-icon watcher for the rclone-proton sync service. Event-driven: a
# FileSystemWatcher reacts to service.log being appended to (no polling loop).
# Green icon = last run succeeded. Red icon = last run failed; a balloon tip
# fires on the first failure and then every 4th one after that, so a stuck
# sync can't silently sit broken for days the way it did before this existed.
# Run via Register-Tray.ps1 (logon scheduled task), or manually:
#   powershell -NoProfile -WindowStyle Hidden -File Watch-RcloneSync.ps1
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$Root = 'C:\ProgramData\rclone'
$LogFile = "$Root\service.log"

function New-DotIcon([System.Drawing.Color]$color) {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush $color
    $g.FillEllipse($brush, 2, 2, 28, 28)
    $g.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $icon
}
$iconOk   = New-DotIcon ([System.Drawing.Color]::FromArgb(40, 180, 90))
$iconBad  = New-DotIcon ([System.Drawing.Color]::FromArgb(210, 50, 45))
$iconWarn = New-DotIcon ([System.Drawing.Color]::FromArgb(230, 170, 30))

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = $iconWarn
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
$itemSync.Add_Click({ New-Item -ItemType File -Force "$Root\sync-now" | Out-Null })
$menu.Items.Add('-') | Out-Null
$itemExit = $menu.Items.Add('Exit')
$itemExit.Add_Click({ $notify.Visible = $false; [System.Windows.Forms.Application]::Exit() })
$notify.ContextMenuStrip = $menu
$notify.Add_DoubleClick({ Start-Process (Get-WebGuiUrl) })

$global:RcloneTrayNotify = $notify
$global:RcloneTrayIconOk = $iconOk
$global:RcloneTrayIconBad = $iconBad
$global:RcloneTrayLogFile = $LogFile
$global:consecutiveFailures = 0
$global:lastOffset = 0

function global:Update-RcloneTrayStatus([string]$state, [string]$detail) {
    $stamp = Get-Date -Format 'HH:mm:ss'
    switch ($state) {
        'ok' {
            $global:consecutiveFailures = 0
            $global:RcloneTrayNotify.Icon = $global:RcloneTrayIconOk
            $text = "Proton Drive sync: OK ($stamp)"
            $global:RcloneTrayNotify.Text = $text.Substring(0, [Math]::Min(63, $text.Length))
        }
        'fail' {
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
            if ($line -match 'sync FAILED:\s*(.*)$') { Update-RcloneTrayStatus 'fail' $Matches[1] }
            elseif ($line -match 'sync finished') { Update-RcloneTrayStatus 'ok' '' }
        }
    } catch { }
}

# Prime from whatever's already in the log so the icon isn't a guess at startup.
if (Test-Path $LogFile) { Read-RcloneTrayNewLines }

$watcher = New-Object System.IO.FileSystemWatcher (Split-Path $LogFile), (Split-Path $LogFile -Leaf)
$watcher.NotifyFilter = [System.IO.NotifyFilters]'LastWrite, Size'
Register-ObjectEvent $watcher Changed -Action { Read-RcloneTrayNewLines } | Out-Null
$watcher.EnableRaisingEvents = $true

[System.Windows.Forms.Application]::Run()
