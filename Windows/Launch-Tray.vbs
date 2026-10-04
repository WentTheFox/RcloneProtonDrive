' Starts Watch-RcloneSync.ps1 with no console window at all. wscript.exe is a
' GUI-subsystem host, so unlike powershell.exe -WindowStyle Hidden nothing
' flashes on screen. Run 0 = hidden window, False = don't wait.
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""C:\ProgramData\rclone\Watch-RcloneSync.ps1""", 0, False
