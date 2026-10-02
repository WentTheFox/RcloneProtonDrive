# Deploys Watch-RcloneSync.ps1 to C:\ProgramData\rclone and registers it as a
# per-user logon scheduled task (tray icons need an interactive desktop
# session, so this can't run inside the LocalSystem rclone-proton service).
# Safe to re-run.
$Root = 'C:\ProgramData\rclone'
$Here = $PSScriptRoot
$TaskName = 'RcloneProtonTray'

Copy-Item "$Here\Watch-RcloneSync.ps1" "$Root\Watch-RcloneSync.ps1" -Force

$ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$action = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -WindowStyle Hidden -File `"$Root\Watch-RcloneSync.ps1`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
Write-Host "Registered scheduled task '$TaskName' (starts at next logon)."

Write-Host 'Starting it now...'
Start-ScheduledTask -TaskName $TaskName
