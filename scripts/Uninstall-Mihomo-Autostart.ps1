$ErrorActionPreference = "SilentlyContinue"
Unregister-ScheduledTask -TaskName "Mihomo-Start" -Confirm:$false
Unregister-ScheduledTask -TaskName "Mihomo-Watchdog" -Confirm:$false
& "C:\Mihomo\scripts\Stop-Mihomo.ps1"
Write-Host "Scheduled tasks removed."
