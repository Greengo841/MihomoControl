. "C:\Mihomo\scripts\_Common.ps1"
Ensure-Layout

Write-Host "== Process =="
@(Get-MihomoProcess) | Select-Object ProcessId,ExecutablePath | Format-Table -AutoSize

Write-Host "`n== Ports =="
[pscustomobject]@{
    Proxy7890 = Test-NetConnection 127.0.0.1 -Port 7890 -InformationLevel Quiet -WarningAction SilentlyContinue
    Api9090 = Test-NetConnection 127.0.0.1 -Port 9090 -InformationLevel Quiet -WarningAction SilentlyContinue
} | Format-List

Write-Host "`n== AUTO =="
try { Get-AutoProxyInfo | Select-Object name,now,alive,type | Format-List } catch { Write-Warning $_ }

Write-Host "`n== Health =="
try { Test-ProxyHealth | Format-Table Name,OK -AutoSize } catch { Write-Warning $_ }

Write-Host "`n== Tasks =="
Get-ScheduledTask -TaskName "Mihomo-Start","Mihomo-Watchdog" -ErrorAction SilentlyContinue |
    Select-Object TaskName,State |
    Format-Table -AutoSize
