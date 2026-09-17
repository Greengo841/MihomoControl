$ErrorActionPreference = "Stop"

$startScript = "C:\Mihomo\scripts\Start-Mihomo.ps1"
$watchScript = "C:\Mihomo\scripts\Watch-Mihomo.ps1"
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
$healthScript = "C:\Mihomo\scripts\Update-ProviderHealthPool-Hidden.vbs"

foreach($p in @($startScript,$watchScript,$healthScript)) {
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


$healthAction = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\wscript.exe" `
    -Argument "`"$healthScript`""
$healthTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 5) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
$healthSettings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask `
    -TaskName "Mihomo-HealthPool" `
    -Action $healthAction `
    -Trigger $healthTrigger `
    -Settings $healthSettings `
    -Description "Maintain Mihomo provider health pools every 5 minutes." `
    -Force | Out-Null

Write-Host "Installed scheduled tasks:"
Get-ScheduledTask -TaskName "Mihomo-Start","Mihomo-Watchdog","Mihomo-HealthPool" |
    Select-Object TaskName,State |
    Format-Table -AutoSize