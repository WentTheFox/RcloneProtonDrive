# Deploys Watch-RcloneSync.ps1 to C:\ProgramData\rclone and registers it as a
# per-user logon scheduled task (tray icons need an interactive desktop
# session, so this can't run inside the LocalSystem rclone-proton service).
# The task launches via wscript + Launch-Tray.vbs so no console window ever
# flashes (powershell.exe -WindowStyle Hidden still does). Safe to re-run.
$Root = 'C:\ProgramData\rclone'
$Here = $PSScriptRoot
$TaskName = 'RcloneProtonTray'

Copy-Item "$Here\Watch-RcloneSync.ps1" "$Root\Watch-RcloneSync.ps1" -Force
Copy-Item "$Here\Launch-Tray.vbs" "$Root\Launch-Tray.vbs" -Force

$wscript = "$env:SystemRoot\System32\wscript.exe"
$action = New-ScheduledTaskAction -Execute $wscript -Argument "`"$Root\Launch-Tray.vbs`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
Write-Host "Registered scheduled task '$TaskName' (starts at next logon)."

Write-Host 'Starting it now...'
Start-ScheduledTask -TaskName $TaskName
