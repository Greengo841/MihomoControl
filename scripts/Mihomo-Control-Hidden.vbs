Set shell = CreateObject("WScript.Shell")
shell.Run """C:\Users\user\AppData\Local\Microsoft\WindowsApps\pwsh.exe"" -Sta -NoProfile -ExecutionPolicy Bypass -File ""C:\Mihomo\scripts\Mihomo-Control.ps1""", 0, False
