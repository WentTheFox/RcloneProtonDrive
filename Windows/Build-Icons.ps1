# Renders the tray status icons (PNG) from the Lucide SVGs in the
# third_party/lucide submodule, using headless Edge (ships with Windows 11), so
# no icon files are copied into this repo. Output: C:\ProgramData\rclone\icons.
# Run `git submodule update --init` first. Called by Register-Tray.ps1.
param([string]$Out = 'C:\ProgramData\rclone\icons')
$ErrorActionPreference = 'Stop'
$Lucide = Join-Path $PSScriptRoot '..\third_party\lucide\icons'
if (-not (Test-Path "$Lucide\cloud-sync.svg")) { throw 'Lucide submodule missing: run git submodule update --init' }
$edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { throw 'msedge.exe not found' }

# name -> Lucide icon, stroke colour. Keep in sync with the Linux plasmoid.
$icons = @{
    synced  = @('cloud-check', '#2eb85c')
    syncing = @('cloud-sync',  '#3b82f6')
    error   = @('cloud-alert', '#e5484d')
    idle    = @('cloud',       '#8b8b8b')
}
$size = 64
New-Item -ItemType Directory -Force $Out | Out-Null
$tmp = Join-Path ([IO.Path]::GetTempPath()) 'rclone-icons'
New-Item -ItemType Directory -Force $tmp | Out-Null
foreach ($name in $icons.Keys) {
    $svg = (Get-Content "$Lucide\$($icons[$name][0]).svg" -Raw) -replace 'currentColor', $icons[$name][1]
    $svg = $svg -replace '(?s)<svg', "<svg style=`"width:${size}px;height:${size}px;display:block`"" -replace 'width="24"\s+height="24"', ''
    $html = "$tmp\$name.html"
    Set-Content $html "<!doctype html><body style=`"margin:0;background:transparent`">$svg" -Encoding UTF8
    # Own profile dir so this never attaches to a running Edge; Start-Process keeps Edge's stderr noise out of $ErrorActionPreference
    $url = ([uri]$html).AbsoluteUri
    Start-Process $edge -Wait -WindowStyle Hidden -ArgumentList "--headless=new --disable-gpu --hide-scrollbars --user-data-dir=`"$tmp\profile`" --default-background-color=00000000 --window-size=$size,$size --screenshot=`"$Out\$name.png`" $url"
    if (-not (Test-Path "$Out\$name.png")) { throw "Failed to render $name" }
}
Remove-Item $tmp -Recurse -Force
Write-Host "Rendered tray icons to $Out"
