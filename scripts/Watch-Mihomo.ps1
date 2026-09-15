. "C:\Mihomo\scripts\_Common.ps1"

Ensure-Layout

$IntervalSeconds = 10
$FailureConfirmSeconds = 5
$PerformanceFactor = 2.0

while ($true) {
    $mode = Get-MihomoMode

    if ($mode -ne "proxy") {
        Start-Sleep -Seconds $IntervalSeconds
        continue
    }

    try {
        if (@(Get-MihomoProcess).Count -eq 0) {
            & "C:\Mihomo\scripts\Start-Mihomo.ps1" | Out-Null
            Start-Sleep -Seconds 10
        }

        $health = @(Test-ProxyHealth)
        $bad = @($health | Where-Object { -not $_.OK })

        if ($bad.Count -ne 0) {
            # FAIL #1 is provisional. Confirm the same active node after 5 seconds.
            Start-Sleep -Seconds $FailureConfirmSeconds

            # If mode changed while waiting, leave this iteration without failover.
            if ((Get-MihomoMode) -ne "proxy") {
                continue
            }

            $health = @(Test-ProxyHealth)
            $bad = @($health | Where-Object { -not $_.OK })
        }

        if ($bad.Count -eq 0) {
            # Current node works (or recovered on confirmation).
            Set-SystemProxyOn

            $better = $null
            try {
                $better = Find-SignificantlyBetterProxy -Factor $PerformanceFactor
            }
            catch {}

            $active = $null
            try { $active = (Get-AutoProxyInfo).now } catch {}

            if ($null -ne $better) {
                Write-WatchdogState @{
                    status            = "SWITCHED_FOR_PERFORMANCE"
                    active_proxy      = $active
                    previous_proxy    = $better.PreviousName
                    previous_delay_ms = $better.PreviousDelay
                    delay_ms          = $better.Delay
                    factor            = $PerformanceFactor
                    youtube           = $true
                    github            = $true
                    telegram          = $true
                }
            }
            else {
                Write-WatchdogState @{
                    status       = "HEALTHY"
                    active_proxy = $active
                    youtube      = $true
                    github       = $true
                    telegram     = $true
                }
            }
        }
        else {
            # FAIL #2 confirmed: run existing failover immediately.
            Set-SystemProxyOff

            $result = $null
            try {
                $result = Find-HealthyProxy
            }
            catch {}

            if ($null -ne $result) {
                Set-SystemProxyOn
                $active = (Get-AutoProxyInfo).now

                Write-WatchdogState @{
                    status       = "RECOVERED_BY_FAILOVER"
                    active_proxy = $active
                    delay_ms     = $result.Delay
                    youtube      = $true
                    github       = $true
                    telegram     = $true
                }
            }
            else {
                & "C:\Mihomo\scripts\Start-Mihomo.ps1" -Restart | Out-Null
                Start-Sleep -Seconds 8

                $post = @(Test-ProxyHealth)
                $postBad = @($post | Where-Object { -not $_.OK })

                if ($postBad.Count -eq 0) {
                    Set-SystemProxyOn
                    $active = (Get-AutoProxyInfo).now

                    Write-WatchdogState @{
                        status       = "RECOVERED_AFTER_RESTART"
                        active_proxy = $active
                        youtube      = $true
                        github       = $true
                        telegram     = $true
                    }
                }
                else {
                    Set-SystemProxyOff

                    Write-WatchdogState @{
                        status = "UNHEALTHY"
                        failed = @($postBad | ForEach-Object { $_.Name })
                    }
                }
            }
        }
    }
    catch {
        Set-SystemProxyOff

        Write-WatchdogState @{
            status  = "WATCHDOG_ERROR"
            message = $_.Exception.Message
        }
    }

    Start-Sleep -Seconds $IntervalSeconds
}
