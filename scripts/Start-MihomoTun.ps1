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

Write-Host "Resetting Mihomo before TUN mode..."
Stop-AllMihomoVerified

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$stdout = Join-Path $LogDir "mihomo-tun-$stamp.out.log"
$stderr = Join-Path $LogDir "mihomo-tun-$stamp.err.log"

Start-Process `
    -FilePath $Exe `
    -ArgumentList @(
        "-d", $Base,
        "-f", "C:\Mihomo\config.tun.yaml"
    ) `
    -WorkingDirectory $Base `
    -WindowStyle Hidden `
    -RedirectStandardOutput $stdout `
    -RedirectStandardError $stderr

if (-not (Wait-LocalPort -Port 9090 -TimeoutSeconds 30)) {
    Stop-AllMihomoVerified
    throw "TUN Mihomo controller did not start."
}

# The TUN adapter/route is created by the core. Keep the Windows System Proxy OFF.
Set-SystemProxyOff
Set-MihomoMode tun

Write-WatchdogState @{
    status = "TUN"
    mode   = "tun"
}

Write-Host ""
Write-Host "MIHOMO TUN STARTED"
Write-Host "Windows System Proxy: OFF"
Write-Host "Mode: tun"
exit 0
