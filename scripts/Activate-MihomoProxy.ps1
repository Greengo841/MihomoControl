. "C:\Mihomo\scripts\_Common.ps1"

$expectedMode = "proxy"

try {
    if ((Get-MihomoMode) -ne $expectedMode) {
        exit 0
    }

    if (-not (Wait-LocalPort -Port 7890 -TimeoutSeconds 30)) {
        if ((Get-MihomoMode) -eq $expectedMode) {
            Set-SystemProxyOff
            Write-WatchdogState @{
                status = "PROXY_START_FAILED"
                mode   = "proxy"
                reason = "Port 7890 did not open within 30 seconds"
            }
        }
        exit 2
    }

    if ((Get-MihomoMode) -ne $expectedMode) {
        exit 0
    }

    if (-not (Wait-LocalPort -Port 9090 -TimeoutSeconds 30)) {
        if ((Get-MihomoMode) -eq $expectedMode) {
            Set-SystemProxyOff
            Write-WatchdogState @{
                status = "PROXY_START_FAILED"
                mode   = "proxy"
                reason = "Controller port 9090 did not open within 30 seconds"
            }
        }
        exit 3
    }

    if ((Get-MihomoMode) -ne $expectedMode) {
        exit 0
    }

    try { Restore-ManualServerSelection | Out-Null } catch {}

    Set-SystemProxyOn

    $active = $null
    try { $active = (Get-AutoProxyInfo).now } catch {}

    Write-WatchdogState @{
        status       = "STARTING"
        mode         = "proxy"
        active_proxy = $active
        reason       = "Proxy ports ready; watchdog health validation pending"
    }

    exit 0
}
catch {
    if ((Get-MihomoMode) -eq $expectedMode) {
        Set-SystemProxyOff
        Write-WatchdogState @{
            status  = "PROXY_ACTIVATOR_ERROR"
            mode    = "proxy"
            message = $_.Exception.Message
        }
    }

    exit 10
}
