param(
    [string]$ProviderName = '',
    [ValidateRange(1,10000)]
    [int]$Threshold = 50,
    [ValidateRange(1,1440)]
    [int]$DiscoveryIntervalMinutes = 60,
    [ValidateRange(1,1440)]
    [int]$FastIntervalMinutes = 5,
    [ValidateRange(1000,30000)]
    [int]$TimeoutMs = 5000,
    [ValidateRange(1,16)]
    [int]$ThrottleLimit = 4,
    [ValidateRange(1,500)]
    [int]$FastPoolLimit = 10,
    [switch]$ForceDiscovery
)

$ErrorActionPreference = 'Stop'

$Controller = 'http://127.0.0.1:9090'
$TestUrl = 'https://www.gstatic.com/generate_204'
$StateRoot = 'C:\Mihomo\state\provider-health'

function Read-PoolState {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 |
            ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Test-Due {
    param(
        [object]$Timestamp,
        [int]$Minutes
    )

    if ($null -eq $Timestamp) {
        return $true
    }

    try {
        if ($Timestamp -is [DateTimeOffset]) {
            $value = [DateTimeOffset]$Timestamp
        }
        elseif ($Timestamp -is [DateTime]) {
            $value = [DateTimeOffset]([DateTime]$Timestamp)
        }
        else {
            $text = [string]$Timestamp

            if ([string]::IsNullOrWhiteSpace($text)) {
                return $true
            }

            $value = [DateTimeOffset]::MinValue

            $ok = [DateTimeOffset]::TryParse(
                $text,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind,
                [ref]$value)

            if (-not $ok) {
                return $true
            }
        }
    }
    catch {
        return $true
    }

    return (
        [DateTimeOffset]::UtcNow -
        $value.ToUniversalTime()
    ).TotalMinutes -ge $Minutes
}

function Write-PoolState {
    param(
        [string]$Path,
        [object]$State
    )

    $dir = Split-Path -Parent $Path

    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force |
            Out-Null
    }

    $json = $State | ConvertTo-Json -Depth 10
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"

    try {
        [IO.File]::WriteAllText(
            $temp,
            $json,
            [Text.UTF8Encoding]::new($false))

        [IO.File]::Move(
            $temp,
            $Path,
            $true)
    }
    finally {
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-NodeChecks {
    param(
        [object[]]$Targets
    )

    if ($Targets.Count -eq 0) {
        return @()
    }

    $encodedTestUrl = [Uri]::EscapeDataString($TestUrl)
    $requestTimeoutSec =
        [Math]::Ceiling($TimeoutMs / 1000.0) + 3

    return @(
        $Targets |
            ForEach-Object -Parallel {
                $target = $_
                $name = [string]$target.Name
                $provider = [string]$target.Provider

                try {
                    $pn = [Uri]::EscapeDataString($provider)
                    $nn = [Uri]::EscapeDataString($name)

                    $uri =
                        "$using:Controller/providers/proxies/$pn/$nn/healthcheck" +
                        "?timeout=$using:TimeoutMs&url=$using:encodedTestUrl"

                    $response = Invoke-RestMethod `
                        -Method Get `
                        -Uri $uri `
                        -NoProxy `
                        -TimeoutSec $using:requestTimeoutSec

                    $delay = 0

                    if ($null -ne $response.delay) {
                        $delay = [int]$response.delay
                    }

                    [pscustomobject]@{
                        Name       = $name
                        Alive      = ($delay -gt 0)
                        Delay      = $delay
                        CheckedUtc = [DateTimeOffset]::UtcNow.ToString('o')
                    }
                }
                catch {
                    [pscustomobject]@{
                        Name       = $name
                        Alive      = $false
                        Delay      = 0
                        CheckedUtc = [DateTimeOffset]::UtcNow.ToString('o')
                    }
                }
            } `
            -ThrottleLimit $ThrottleLimit
    )
}

if (-not (Test-Path -LiteralPath $StateRoot)) {
    New-Item -ItemType Directory -Path $StateRoot -Force |
        Out-Null
}

$api = Invoke-RestMethod `
    -Method Get `
    -Uri "$Controller/providers/proxies" `
    -NoProxy `
    -TimeoutSec 10

$providers = @(
    $api.providers.PSObject.Properties |
        Where-Object {
            $_.Name -ne 'default' -and
            (
                [string]::IsNullOrWhiteSpace($ProviderName) -or
                $_.Name -eq $ProviderName
            )
        }
)

if (-not [string]::IsNullOrWhiteSpace($ProviderName) -and
    $providers.Count -eq 0)
{
    throw "Provider '$ProviderName' was not found."
}

$summaries = foreach ($providerProperty in $providers) {
    $name = [string]$providerProperty.Name
    $provider = $providerProperty.Value

    $nodes = @(
        $provider.proxies |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace([string]$_.name)
            } |
            ForEach-Object {
                [pscustomobject]@{
                    Provider = $name
                    Name     = [string]$_.name
                }
            }
    )

    if ($nodes.Count -le $Threshold) {
        [pscustomobject]@{
            Provider       = $name
            Nodes          = $nodes.Count
            Phase          = 'SKIP_SMALL'
            Checked        = 0
            Alive          = 0
            FastPool       = 0
            StateFile      = ''
        }

        continue
    }

    $safeName = $name -replace '[^A-Za-z0-9._-]', '_'
    $statePath = Join-Path $StateRoot "$safeName.json"
    $previous = Read-PoolState -Path $statePath

    $nodeCountChanged =
        $null -ne $previous -and
        [int]$previous.nodeCount -ne $nodes.Count

    $discoveryDue =
        $ForceDiscovery -or
        $null -eq $previous -or
        $nodeCountChanged -or
        (Test-Due `
            -Timestamp $previous.lastDiscoveryUtc `
            -Minutes $DiscoveryIntervalMinutes)

    $phase = 'NONE'
    $targets = @()

    if ($discoveryDue) {
        $phase = 'DISCOVERY'
        $targets = $nodes
    }
    else {
        $fastDue = Test-Due `
            -Timestamp $previous.lastFastCheckUtc `
            -Minutes $FastIntervalMinutes

        if (-not $fastDue) {
            [pscustomobject]@{
                Provider       = $name
                Nodes          = $nodes.Count
                Phase          = 'NOT_DUE'
                Checked        = 0
                Alive          = [int]$previous.fastPoolCount
                FastPool       = [int]$previous.fastPoolCount
                StateFile      = $statePath
            }

            continue
        }

        $currentNames =
            [System.Collections.Generic.HashSet[string]]::new(
                [StringComparer]::Ordinal)

        foreach ($node in $nodes) {
            [void]$currentNames.Add([string]$node.Name)
        }

        $targets = @(
            @($previous.fastPool) |
                Where-Object {
                    $currentNames.Contains([string]$_.name)
                } |
                ForEach-Object {
                    [pscustomobject]@{
                        Provider = $name
                        Name     = [string]$_.name
                    }
                }
        )

        $phase = 'FAST'
    }

    $results = @(Invoke-NodeChecks -Targets $targets)

    $aliveResults = @(
        $results |
            Where-Object { $_.Alive } |
            Sort-Object Delay, Name
    )

    $now = [DateTimeOffset]::UtcNow.ToString('o')

    if ($phase -eq 'DISCOVERY') {
        $discoveredAlive = $aliveResults

        $fastPool = @(
            $aliveResults |
                Select-Object -First $FastPoolLimit
        )

        $lastDiscoveryUtc = $now
    }
    else {
        $discoveredAlive = @($previous.discoveredAlive)
        $fastPool = $aliveResults
        $lastDiscoveryUtc = if ($previous.lastDiscoveryUtc -is [DateTime]) { ([DateTimeOffset]([DateTime]$previous.lastDiscoveryUtc)).ToUniversalTime().ToString('o') } elseif ($previous.lastDiscoveryUtc -is [DateTimeOffset]) { ([DateTimeOffset]$previous.lastDiscoveryUtc).ToUniversalTime().ToString('o') } else { $parsed=[DateTimeOffset]::MinValue; if (-not [DateTimeOffset]::TryParse([string]$previous.lastDiscoveryUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed)) { throw 'Invalid lastDiscoveryUtc in provider health state.' }; $parsed.ToUniversalTime().ToString('o') }
    }

    $state = [ordered]@{
        schemaVersion             = 1
        provider                  = $name
        nodeCount                 = $nodes.Count
        threshold                 = $Threshold
        discoveryIntervalMinutes  = $DiscoveryIntervalMinutes
        fastIntervalMinutes       = $FastIntervalMinutes
        timeoutMs                 = $TimeoutMs
        throttleLimit             = $ThrottleLimit
        fastPoolLimit             = $FastPoolLimit
        lastPhase                 = $phase
        lastDiscoveryUtc          = $lastDiscoveryUtc
        lastFastCheckUtc          = $now
        updatedUtc                = $now
        discoveredAliveCount      = @($discoveredAlive).Count
        fastPoolCount             = @($fastPool).Count
        lastCheckedCount          = $results.Count
        lastAliveCount            = $aliveResults.Count
        discoveredAlive           = @(
            $discoveredAlive |
                Select-Object Name, Delay, CheckedUtc
        )
        fastPool                  = @(
            $fastPool |
                Select-Object Name, Delay, CheckedUtc
        )
    }

    Write-PoolState `
        -Path $statePath `
        -State $state

    [pscustomobject]@{
        Provider       = $name
        Nodes          = $nodes.Count
        Phase          = $phase
        Checked        = $results.Count
        Alive          = $aliveResults.Count
        FastPool       = @($fastPool).Count
        StateFile      = $statePath
    }
}

$summaries | Format-Table -AutoSize