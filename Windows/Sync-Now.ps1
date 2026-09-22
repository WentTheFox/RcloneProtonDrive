# Asks the rclone-proton service to start a sync immediately.
$t = 'C:\ProgramData\rclone\sync-now'
New-Item -ItemType File -Force $t | Out-Null
Write-Host 'Sync requested. Waiting for the service to pick it up...'
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Seconds 3
    if (-not (Test-Path $t)) { Write-Host 'Sync started. Progress: http://127.0.0.1:5572'; Start-Sleep 3; exit }
}
Write-Host 'Service did not respond (a sync may be running, or the service is stopped).'
Start-Sleep 5
