$ErrorActionPreference = "Stop"

$startScript = "C:\Mihomo\scripts\Start-Mihomo.ps1"
$watchScript = "C:\Mihomo\scripts\Watch-Mihomo.ps1"
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source

foreach($p in @($startScript,$watchScript)) {
    if (-not (Test-Path $p)) { throw "Missing: $p" }
}

$startAction = New-ScheduledTaskAction -Execute $pwsh `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$startScript`""
$startTrigger = New-ScheduledTaskTrigger -AtLogOn
$startSettings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask `
    -TaskName "Mihomo-Start" `
    -Action $startAction `
    -Trigger $startTrigger `
    -Settings $startSettings `
    -Description "Start Mihomo and select a healthy proxy after user logon." `
    -Force | Out-Null

$watchAction = New-ScheduledTaskAction -Execute $pwsh `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watchScript`""
$watchTrigger = New-ScheduledTaskTrigger -AtLogOn
$watchTrigger.Delay = "PT30S"
$watchSettings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask `
    -TaskName "Mihomo-Watchdog" `
    -Action $watchAction `
    -Trigger $watchTrigger `
    -Settings $watchSettings `
    -Description "Monitor YouTube/GitHub/Telegram and fail over Mihomo nodes automatically." `
    -Force | Out-Null

Write-Host "Installed scheduled tasks:"
Get-ScheduledTask -TaskName "Mihomo-Start","Mihomo-Watchdog" |
    Select-Object TaskName,State |
    Format-Table -AutoSize
