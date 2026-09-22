# Creates Desktop shortcuts: one opens the rclone web UI pre-logged-in, the other
# triggers an immediate sync via the running service.
# NOTE: the web-UI shortcut embeds your rc-auth.txt password (base64-encoded, not
# encrypted) in a .url file. Fine for a single-user PC; don't let that file sync
# anywhere shared.
$Root = 'C:\ProgramData\rclone'
$auth = Get-Content "$Root\rc-auth.txt"
$tok  = [uri]::EscapeDataString([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($auth[0]):$($auth[1])")))
$desk = [Environment]::GetFolderPath('Desktop')

Set-Content "$desk\Proton Drive sync (web UI).url" -Encoding ASCII -Value "[InternetShortcut]`r`nURL=http://127.0.0.1:5572/?login_token=$tok`r`n"

$ws = New-Object -ComObject WScript.Shell
$s = $ws.CreateShortcut("$desk\Proton Drive - Sync now.lnk")
$s.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$s.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$Root\Sync-Now.ps1`""
$s.IconLocation = "$Root\rclone.exe,0"
$s.Save()

Write-Host "Created shortcuts on $desk"
