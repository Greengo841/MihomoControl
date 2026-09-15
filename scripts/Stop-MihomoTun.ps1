. "C:\Mihomo\scripts\_Common.ps1"

function Stop-AllMihomoVerified {
    Set-SystemProxyOff
    Set-MihomoMode off

    try { Stop-MihomoProcess } catch {}

    Get-Process mihomo -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue

    $deadline = (Get-Date).AddSeconds(10)

    while ((Get-Date) -lt $deadline) {
        $left = @(Get-Process mihomo -ErrorAction SilentlyContinue)

        if ($left.Count -eq 0) {
            return
        }

        $left |
            Stop-Process -Force -ErrorAction SilentlyContinue

        Start-Sleep -Milliseconds 250
    }

    $left = @(Get-Process mihomo -ErrorAction SilentlyContinue)

    if ($left.Count -gt 0) {
        throw "Could not stop all Mihomo processes. Remaining PID(s): $($left.Id -join ', ')"
    }
}

Write-Host "Switching Mihomo OFF..."
Stop-AllMihomoVerified

Write-WatchdogState @{
    status = "STOPPED"
    mode   = "off"
}

Write-Host "Mihomo stopped."
Write-Host "Windows System Proxy: OFF"
Write-Host "Mode: off"
exit 0
