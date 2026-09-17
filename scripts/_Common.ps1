$ErrorActionPreference = "Stop"

$Base = "C:\Mihomo"
$Exe = Join-Path $Base "mihomo.exe"
$Config = Join-Path $Base "config.yaml"
$Template = Join-Path $Base "config.template.yaml"
$SubscriptionFile = Join-Path $Base "subscription.txt"
$LogDir = Join-Path $Base "logs"
$ProviderDir = Join-Path $Base "providers"
$StateFile = Join-Path $Base "watchdog-state.json"
$Proxy = "http://127.0.0.1:7890"
$Controller = "http://127.0.0.1:9090"

function Ensure-Layout {
    foreach ($d in @($Base,$LogDir,$ProviderDir)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    }
    if (-not (Test-Path $Exe)) { throw "mihomo.exe not found: $Exe" }
}

function Get-MihomoProcess {
    @(Get-CimInstance Win32_Process -Filter "Name='mihomo.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -eq $Exe })
}

function Stop-MihomoProcess {
    foreach ($p in @(Get-MihomoProcess)) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 800
}

function Set-SystemProxyOn {
    $reg = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
    Set-ItemProperty $reg ProxyEnable 1
    Set-ItemProperty $reg ProxyServer "127.0.0.1:7890"
}

function Set-SystemProxyOff {
    $reg = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
    Set-ItemProperty $reg ProxyEnable 0
}

function Invoke-LocalApiGet([string]$Path) {
    Invoke-RestMethod -Method Get -Uri "$Controller$Path" -TimeoutSec 10 -NoProxy
}

function Invoke-LocalApiPut([string]$Path,[object]$Body) {
    $json = $Body | ConvertTo-Json -Compress
    Invoke-RestMethod -Method Put -Uri "$Controller$Path" -ContentType "application/json" -Body $json -TimeoutSec 10 -NoProxy
}

function Get-AutoProxyInfo {
    Invoke-LocalApiGet "/proxies/AUTO"
}

function Set-AutoProxy([string]$Name) {
    Invoke-LocalApiPut "/proxies/AUTO" @{ name = $Name } | Out-Null
    Start-Sleep -Milliseconds 600
}

function Get-SubscriptionProvider {
    Invoke-LocalApiGet "/providers/proxies"
}

function Wait-ProviderReady([int]$TimeoutSeconds = 120) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    do {
        try {
            $providers = (Get-SubscriptionProvider).providers

            foreach ($providerProp in $providers.PSObject.Properties) {
                $p = $providerProp.Value
                if ($null -eq $p) { continue }

                $ready = @(
                    $p.proxies | Where-Object {
                        $_.alive -and
                        $_.history -and
                        @($_.history).Count -gt 0 -and
                        [int](@($_.history)[-1].delay) -gt 0
                    }
                )

                if ($ready.Count -gt 0) {
                    return $true
                }
            }
        }
        catch {}

        Start-Sleep -Seconds 2
    }
    while ((Get-Date) -lt $deadline)

    return $false
}

function Get-RankedCandidates {
    $providers = (Get-SubscriptionProvider).providers
    if ($null -eq $providers) { throw "No proxy providers are ready." }

    $rows = foreach ($providerProp in $providers.PSObject.Properties) {
        $providerName = [string]$providerProp.Name
        $p = $providerProp.Value
        if ($null -eq $p) { continue }

        foreach ($node in @($p.proxies)) {
            if (-not $node.alive) { continue }
            $history = @($node.history)
            if ($history.Count -eq 0) { continue }
            $last = $history[-1]
            if ($null -eq $last.delay -or [int]$last.delay -le 0) { continue }

            [pscustomobject]@{
                Provider = $providerName
                Name     = [string]$node.name
                Delay    = [int]$last.delay
            }
        }
    }

    @($rows | Sort-Object Delay,Name)
}
function Test-ProxyEndpoint([string]$Url,[int]$TimeoutSeconds = 12) {
    & curl.exe -x $Proxy -I -sS -o NUL `
        --ssl-no-revoke `
        --connect-timeout 5 `
        --max-time $TimeoutSeconds `
        $Url
    return ($LASTEXITCODE -eq 0)
}

function Test-ProxyHealth {
    @(
        [pscustomobject]@{ Name="YouTube";  Url="https://www.youtube.com";      OK=(Test-ProxyEndpoint "https://www.youtube.com") }
        [pscustomobject]@{ Name="GitHub";   Url="https://api.github.com";       OK=(Test-ProxyEndpoint "https://api.github.com") }
        [pscustomobject]@{ Name="Telegram"; Url="https://api.telegram.org";     OK=(Test-ProxyEndpoint "https://api.telegram.org") }
    )
}

function Find-HealthyProxy {
    $ranked = @(Get-RankedCandidates)
    if ($ranked.Count -eq 0) {
        Write-Warning "No alive provider nodes with measured delay."
        return $null
    }

    Write-Host "`nFastest provider nodes:"
    $ranked | Select-Object -First 10 | Format-Table Delay,Name -AutoSize

    foreach ($row in $ranked) {
        try {
            Write-Host "`nFull check: $($row.Name) ($($row.Delay) ms)"
            Set-AutoProxy $row.Name
            $health = @(Test-ProxyHealth)
            $health | Format-Table Name,OK -AutoSize

            if (@($health | Where-Object { -not $_.OK }).Count -eq 0) {
                return [pscustomobject]@{
                    ProxyName = [string]$row.Name
                    Delay = [int]$row.Delay
                    Health = $health
                }
            }
        }
        catch {
            Write-Warning "Candidate failed: $($row.Name) :: $($_.Exception.Message)"
        }
    }
    return $null
}

function Wait-LocalPort([int]$Port,[int]$TimeoutSeconds=30) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (Test-NetConnection -ComputerName 127.0.0.1 -Port $Port -InformationLevel Quiet -WarningAction SilentlyContinue) {
            return $true
        }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Write-WatchdogState([hashtable]$State) {
    $State.time = (Get-Date).ToString("o")
    $State | ConvertTo-Json -Depth 6 | Set-Content $StateFile -Encoding UTF8
}

function Remove-OldLogs([int]$Keep=20) {
    if (-not (Test-Path $LogDir)) { return }
    Get-ChildItem $LogDir -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $Keep |
        Remove-Item -Force -ErrorAction SilentlyContinue
}


function Find-SignificantlyBetterProxy([double]$Factor = 2.0) {
    $currentName = (Get-AutoProxyInfo).now
    $ranked = @(Get-RankedCandidates)

    if ($ranked.Count -eq 0) {
        return $null
    }

    $current = $ranked |
        Where-Object { $_.Name -eq $currentName } |
        Select-Object -First 1

    # Текущий узел уже отсутствует среди healthy provider nodes.
    # Это не performance switch — обычный failover обработает watchdog.
    if ($null -eq $current) {
        return $null
    }

    foreach ($candidate in $ranked) {
        if ($candidate.Name -eq $currentName) {
            continue
        }

        # Список отсортирован от быстрого к медленному.
        # Как только кандидат уже недостаточно лучше — дальше проверять бессмысленно.
        if ([double]$current.Delay -lt ([double]$candidate.Delay * $Factor)) {
            break
        }

        Write-Host "2x candidate: $($candidate.Name) $($candidate.Delay) ms; current $($current.Delay) ms"

        try {
            Set-AutoProxy $candidate.Name

            $health = @(Test-ProxyHealth)

            if (@($health | Where-Object { -not $_.OK }).Count -eq 0) {
                return [pscustomobject]@{
                    ProxyName     = [string]$candidate.Name
                    Delay         = [int]$candidate.Delay
                    PreviousName  = [string]$currentName
                    PreviousDelay = [int]$current.Delay
                }
            }

            # Кандидат быстрее, но не проходит реальные сервисы.
            Set-AutoProxy $currentName
        }
        catch {
            try { Set-AutoProxy $currentName } catch {}
        }
    }

    return $null
}

$ModeFile = "C:\Mihomo\mode.txt"

function Get-MihomoMode {
    if (-not (Test-Path $ModeFile)) {
        return "proxy"
    }

    $mode = (Get-Content $ModeFile -Raw).Trim().ToLowerInvariant()

    if ($mode -notin @("proxy","tun","off")) {
        return "off"
    }

    return $mode
}

function Set-MihomoMode {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet("proxy","tun","off")]
        [string]$Mode
    )

    Set-Content -Path $ModeFile -Value $Mode -Encoding ASCII
}


$ServerSelectionModeFile = Join-Path $Base "server-selection-mode.txt"
$ManualServerFile = Join-Path $Base "manual-server.txt"

function Get-ServerSelectionMode {
    if (-not (Test-Path $ServerSelectionModeFile)) {
        return "auto"
    }

    $mode = (Get-Content $ServerSelectionModeFile -Raw).Trim().ToLowerInvariant()

    if ($mode -notin @("auto","manual")) {
        return "auto"
    }

    return $mode
}

function Set-ServerSelectionMode {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet("auto","manual")]
        [string]$Mode
    )

    Set-Content -Path $ServerSelectionModeFile -Value $Mode -Encoding ASCII
}

function Get-ManualServer {
    if (-not (Test-Path $ManualServerFile)) {
        return $null
    }

    $name = (Get-Content $ManualServerFile -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($name)) {
        return $null
    }

    return $name
}

function Set-ManualServer {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Name
    )

    Set-Content -Path $ManualServerFile -Value $Name -Encoding UTF8
}

function Restore-ManualServerSelection {
    if ((Get-ServerSelectionMode) -ne "manual") {
        return $false
    }

    $name = Get-ManualServer
    if ([string]::IsNullOrWhiteSpace($name)) {
        return $false
    }

    $auto = Get-AutoProxyInfo
    $available = @($auto.all)

    if ($name -notin $available) {
        return $false
    }

    Set-AutoProxy $name
    return $true
}

function Restart-MihomoForMode {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet("proxy","tun")]
        [string]$Mode
    )

    if ($Mode -eq "proxy") {
        & (Join-Path $Base "scripts\Start-Mihomo.ps1") -Restart | Out-Null
        return
    }

    Start-ScheduledTask -TaskName "Mihomo-TUN"
}
