#Requires -RunAsAdministrator
# Deploys this folder's scripts to C:\ProgramData\rclone and installs/updates the
# "rclone-proton" Windows service via NSSM. Safe to re-run to pick up script changes.
$ErrorActionPreference = 'Stop'
$Root   = 'C:\ProgramData\rclone'
$Here   = $PSScriptRoot

New-Item -ItemType Directory -Force $Root | Out-Null

# Lock the folder down: SYSTEM, Administrators and the current user only.
# rc-auth.txt (the web-UI password) lives here, so this matters.
icacls $Root /inheritance:r /grant:r "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F" "${env:USERNAME}:(OI)(CI)F" | Out-Null

foreach ($f in 'rclone-service.ps1', 'Sync-Now.ps1', 'bisync-filters.txt') {
    Copy-Item "$Here\$f" "$Root\$f" -Force
}

if (-not (Test-Path "$Root\config.psd1")) {
    Copy-Item "$Here\config.example.psd1" "$Root\config.psd1"
    Write-Warning "Wrote a default $Root\config.psd1 - review it (LocalPath, Mode, etc.) before continuing."
}

if (-not (Test-Path "$Root\rclone.exe")) {
    $rc = Get-Command rclone -ErrorAction SilentlyContinue
    if (-not $rc) {
        winget install --id Rclone.Rclone --exact --accept-package-agreements --accept-source-agreements
        $rc = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter rclone.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        Copy-Item $rc.FullName "$Root\rclone.exe"
    } else {
        Copy-Item $rc.Source "$Root\rclone.exe"
    }
}

if (-not (Test-Path "$Root\rc-auth.txt")) {
    throw "Missing $Root\rc-auth.txt (line 1: web-UI username, line 2: password). " +
          "Copy rc-auth.txt.example there and edit it, then re-run this script."
}

if (-not (Test-Path "$Root\rclone.conf") -or -not (Select-String -Path "$Root\rclone.conf" -Pattern '^\[proton\]' -Quiet)) {
    throw "No [proton] remote in $Root\rclone.conf. Run:  $Root\rclone.exe config --config $Root\rclone.conf" +
          "`n(Proton's encryption keys must already exist - log in via the browser at least once first.)"
}

$nssm = (Get-Command nssm -ErrorAction SilentlyContinue).Source
if (-not $nssm) {
    winget install --id NSSM.NSSM --exact --accept-package-agreements --accept-source-agreements
    $nssm = (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter nssm.exe -ErrorAction SilentlyContinue |
        Where-Object FullName -match 'win64' | Select-Object -First 1).FullName
}
if (-not $nssm) { throw 'nssm.exe not found after install' }
Copy-Item $nssm "$Root\nssm.exe" -Force
$nssm = "$Root\nssm.exe"

$svc = 'rclone-proton'
if (Get-Service $svc -ErrorAction SilentlyContinue) { & $nssm stop $svc confirm | Out-Null; & $nssm remove $svc confirm | Out-Null }

$ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
& $nssm install $svc $ps "-NoProfile -ExecutionPolicy Bypass -File `"$Root\rclone-service.ps1`""
& $nssm set $svc DisplayName 'rclone - Proton Drive sync'
& $nssm set $svc Description 'Syncs a local folder with Proton Drive via rclone; web UI at http://127.0.0.1:5572'
& $nssm set $svc Start SERVICE_AUTO_START
& $nssm set $svc AppDirectory $Root
& $nssm set $svc AppStdout "$Root\service.log"
& $nssm set $svc AppStderr "$Root\service.log"
& $nssm set $svc AppRotateFiles 1
& $nssm set $svc AppRotateBytes 10485760
& $nssm set $svc AppExit Default Restart
& $nssm set $svc AppRestartDelay 30000
& $nssm set $svc AppStopMethodConsole 20000
& $nssm start $svc
Get-Service $svc

& "$Here\New-Shortcuts.ps1"
