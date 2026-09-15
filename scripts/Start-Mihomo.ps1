param([switch]$Restart)

. "C:\Mihomo\scripts\_Common.ps1"

Ensure-Layout

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

Write-Host "Resetting Mihomo before Proxy mode..."
Stop-AllMihomoVerified
Remove-OldLogs

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$stdout = Join-Path $LogDir "mihomo-$stamp.out.log"
$stderr = Join-Path $LogDir "mihomo-$stamp.err.log"

Start-Process `
    -FilePath $Exe `
    -ArgumentList @("-d",$Base) `
    -WorkingDirectory $Base `
    -WindowStyle Hidden `
    -RedirectStandardOutput $stdout `
    -RedirectStandardError $stderr

# IMPORTANT:
# Proxy startup is now asynchronous from the UI point of view.
# We only declare the requested mode and return immediately.
# The background activator is responsible for waiting on local ports
# and enabling the Windows System Proxy after the core is actually ready.
Set-MihomoMode proxy
Set-SystemProxyOff

$activator = "C:\Mihomo\scripts\Activate-MihomoProxy.ps1"
Start-Process `
    -FilePath "pwsh.exe" `
    -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy","Bypass",
        "-WindowStyle","Hidden",
        "-File",$activator
    ) `
    -WindowStyle Hidden

Write-WatchdogState @{
    status = "STARTING"
    mode   = "proxy"
    reason = "Proxy core launched; background activation pending"
}

Write-Host ""
Write-Host "MIHOMO PROXY LAUNCHED"
Write-Host "Mode: proxy"
Write-Host "Windows System Proxy: pending background activation"
exit 0
