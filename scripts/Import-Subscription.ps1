param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('Detect','Test','Apply','Update','Remove')]
    [string]$Action,

    [string]$InputFile,

    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$ProviderName = 'subscription'
)

$ErrorActionPreference = 'Stop'

$BaseDir = 'C:\Mihomo'
$MihomoExe = Join-Path $BaseDir 'mihomo.exe'
$ConfigFiles = @(
    (Join-Path $BaseDir 'config.yaml'),
    (Join-Path $BaseDir 'config.tun.yaml')
)
$SubscriptionFile = Join-Path $BaseDir "$ProviderName.txt"
$ProvidersDir = Join-Path $BaseDir 'providers'
$LocalProviderFile = Join-Path $ProvidersDir "$ProviderName-local.txt"

function Write-JsonResult {
    param(
        [bool]$Success,
        [string]$Message,
        [string]$SourceType = '',
        [string]$Display = '',
        [Nullable[int]]$NodeCount = $null,
        [string]$RemoteContentType = '',
        [bool]$RestartRequired = $false,
        [string]$BackupPath = ''
    )

    [pscustomobject]@{
        success = $Success
        message = $Message
        source_type = $SourceType
        display = $Display
        node_count = $NodeCount
        remote_content_type = $RemoteContentType
        restart_required = $RestartRequired
        backup_path = $BackupPath
    } | ConvertTo-Json -Compress -Depth 8
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    $enc = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Get-InputText {
    if ([string]::IsNullOrWhiteSpace($InputFile)) {
        throw 'InputFile is required for this action.'
    }
    if (-not (Test-Path -LiteralPath $InputFile)) {
        throw 'Input file was not found.'
    }
    return [System.IO.File]::ReadAllText($InputFile)
}

function Test-IsHttpUrl {
    param([string]$Text)
    $value = $Text.Trim()
    if ($value -notmatch '^https?://\S+$') { return $false }
    $uri = $null
    return [System.Uri]::TryCreate($value, [System.UriKind]::Absolute, [ref]$uri) -and
           ($uri.Scheme -eq 'http' -or $uri.Scheme -eq 'https')
}

function Get-SafeUrlDisplay {
    param([string]$Url)
    try {
        $u = [System.Uri]$Url
        return "HTTP URL - $($u.Host)"
    } catch {
        return 'HTTP URL'
    }
}

function Get-MeaningfulLines {
    param([string]$Text)
    return @(
        ($Text -split '\r?\n') |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') }
    )
}

function Test-UriList {
    param([string]$Text)
    $lines = @(Get-MeaningfulLines $Text)
    if ($lines.Count -eq 0) { return $false }

    foreach ($line in $lines) {
        if ($line -notmatch '^[A-Za-z][A-Za-z0-9+.-]*://\S.*$') {
            return $false
        }
    }
    return $true
}

function Try-DecodeBase64Text {
    param([string]$Text)
    try {
        $compact = ($Text -replace '\s','')
        if ([string]::IsNullOrWhiteSpace($compact)) { return $null }
        $bytes = [System.Convert]::FromBase64String($compact)
        $decoded = [System.Text.Encoding]::UTF8.GetString($bytes)
        if (Test-UriList $decoded) { return $decoded }
        return $null
    } catch {
        return $null
    }
}

function Extract-YamlProxiesBlock {
    param([string]$Text)

    $normalized = $Text.TrimStart([char]0xFEFF)
    $lines = $normalized -split '\r?\n'
    $start = -1

    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^proxies\s*:') {
            $start = $i
            break
        }
    }

    if ($start -lt 0) { return $null }

    $result = [System.Collections.Generic.List[string]]::new()
    for ($i = $start; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($i -gt $start -and $line -match '^\S[^:]*\s*:') {
            break
        }
        $result.Add($line)
    }

    $block = ($result -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($block)) { return $null }
    return $block + "`n"
}

function Normalize-ProviderContent {
    param([string]$Text)

    $trimmed = $Text.Trim().TrimStart([char]0xFEFF)
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return [pscustomobject]@{ Kind='Unsupported'; Content=''; NodeCount=$null; Display='Empty input' }
    }

    try {
        $json = $trimmed | ConvertFrom-Json -Depth 100
        if ($null -ne $json) {
            $proxies = $null
            if ($json -is [System.Array]) {
                $proxies = @($json)
            } elseif ($json.PSObject.Properties.Name -contains 'proxies') {
                $proxies = @($json.proxies)
            }

            if ($null -ne $proxies -and $proxies.Count -gt 0) {
                $content = [pscustomobject]@{ proxies = $proxies } | ConvertTo-Json -Depth 100
                return [pscustomobject]@{
                    Kind='JSON'
                    Content=$content + "`n"
                    NodeCount=[int]$proxies.Count
                    Display='JSON proxy config'
                }
            }
        }
    } catch {
        # Not JSON; continue with the other native Mihomo provider formats.
    }

    $yamlBlock = Extract-YamlProxiesBlock $trimmed
    if ($null -ne $yamlBlock) {
        $matches = [regex]::Matches($yamlBlock, '(?m)^\s*-\s*(?:name\s*:|\{)')
        $count = if ($matches.Count -gt 0) { [int]$matches.Count } else { $null }
        return [pscustomobject]@{
            Kind='YAML'
            Content=$yamlBlock
            NodeCount=$count
            Display='YAML / Mihomo config'
        }
    }

    if (Test-UriList $trimmed) {
        $count = @(Get-MeaningfulLines $trimmed).Count
        return [pscustomobject]@{
            Kind='URI'
            Content=$trimmed + "`n"
            NodeCount=[int]$count
            Display='URI proxy list'
        }
    }

    $decoded = Try-DecodeBase64Text $trimmed
    if ($null -ne $decoded) {
        $count = @(Get-MeaningfulLines $decoded).Count
        return [pscustomobject]@{
            Kind='Base64'
            Content=$trimmed + "`n"
            NodeCount=[int]$count
            Display='Base64 URI subscription'
        }
    }

    return [pscustomobject]@{
        Kind='Unsupported'
        Content=''
        NodeCount=$null
        Display='Unsupported or unrecognized format'
    }
}

function Get-Detection {
    param([string]$Text)

    $trimmed = $Text.Trim()
    if (Test-IsHttpUrl $trimmed) {
        return [pscustomobject]@{
            Kind='URL'
            Content=''
            NodeCount=$null
            Display=(Get-SafeUrlDisplay $trimmed)
        }
    }

    return Normalize-ProviderContent $Text
}

function Get-UrlContent {
    param([string]$Url)

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor
                                      [System.Net.DecompressionMethods]::Deflate -bor
                                      [System.Net.DecompressionMethods]::Brotli
    $client = [System.Net.Http.HttpClient]::new($handler)
    try {
        $client.Timeout = [TimeSpan]::FromSeconds(20)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd('mihomo/1.19')
        $response = $client.GetAsync($Url).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            throw "Subscription server returned HTTP $([int]$response.StatusCode)."
        }
        return $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    } finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

function Invoke-MihomoTest {
    param([string]$ConfigFile, [string]$HomeDir)

    if (-not (Test-Path -LiteralPath $MihomoExe)) {
        throw 'C:\Mihomo\mihomo.exe was not found.'
    }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $MihomoExe
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    [void]$psi.ArgumentList.Add('-t')
    [void]$psi.ArgumentList.Add('-d')
    [void]$psi.ArgumentList.Add($HomeDir)
    [void]$psi.ArgumentList.Add('-f')
    [void]$psi.ArgumentList.Add($ConfigFile)

    $p = [System.Diagnostics.Process]::Start($psi)
    if ($null -eq $p) { throw 'Could not start mihomo.exe.' }
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()

    return [pscustomobject]@{
        Ok = ($p.ExitCode -eq 0)
        ExitCode = $p.ExitCode
        Output = (($stdout + "`n" + $stderr).Trim())
    }
}

function Test-ProviderContent {
    param([string]$Content)

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('MihomoImport-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    try {
        $providerPath = Join-Path $tempDir 'provider.txt'
        $configPath = Join-Path $tempDir 'config.yaml'
        Write-Utf8NoBom $providerPath $Content

        $testConfig = @'
mixed-port: 7890
allow-lan: false
mode: rule
log-level: silent
proxy-providers:
  imported:
    type: file
    path: ./provider.txt
proxy-groups:
  - name: TEST
    type: select
    use:
      - imported
rules:
  - MATCH,TEST
'@
        Write-Utf8NoBom $configPath $testConfig
        return Invoke-MihomoTest -ConfigFile $configPath -HomeDir $tempDir
    } finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-InputSource {
    param([string]$Text)

    $detected = Get-Detection $Text
    if ($detected.Kind -eq 'Unsupported') {
        return [pscustomobject]@{
            Success=$false
            Message='Format is not a native Mihomo provider format.'
            SourceType='Unsupported'
            Display=$detected.Display
            NodeCount=$null
            RemoteContentType=''
            ProviderContent=''
        }
    }

    $providerContent = $detected.Content
    $remoteKind = ''
    $nodeCount = $detected.NodeCount

    if ($detected.Kind -eq 'URL') {
        try {
            $downloaded = Get-UrlContent $Text.Trim()
        } catch {
            return [pscustomobject]@{
                Success=$false
                Message='Could not download the subscription URL.'
                SourceType='URL'
                Display=$detected.Display
                NodeCount=$null
                RemoteContentType=''
                ProviderContent=''
            }
        }

        $remote = Normalize-ProviderContent $downloaded
        if ($remote.Kind -eq 'Unsupported') {
            return [pscustomobject]@{
                Success=$false
                Message='The URL works, but its content is not a native Mihomo provider format.'
                SourceType='URL'
                Display=$detected.Display
                NodeCount=$null
                RemoteContentType='Unsupported'
                ProviderContent=''
            }
        }

        $providerContent = $remote.Content
        $remoteKind = $remote.Kind
        $nodeCount = $remote.NodeCount
    }

    $test = Test-ProviderContent $providerContent
    if (-not $test.Ok) {
        return [pscustomobject]@{
            Success=$false
            Message='Mihomo rejected the imported provider content.'
            SourceType=$detected.Kind
            Display=$detected.Display
            NodeCount=$nodeCount
            RemoteContentType=$remoteKind
            ProviderContent=''
        }
    }

    return [pscustomobject]@{
        Success=$true
        Message='Mihomo provider validation passed.'
        SourceType=$detected.Kind
        Display=$detected.Display
        NodeCount=$nodeCount
        RemoteContentType=$remoteKind
        ProviderContent=$providerContent
    }
}

function Escape-YamlDoubleQuoted {
    param([string]$Value)
    return $Value.Replace('\','\\').Replace('"','\"')
}

function Ensure-AutoUsesProvider {
    param([string]$Text,[string]$ProviderName)

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($Text -split '\r?\n')) { $lines.Add($line) }

    $groups = -1
    for ($i=0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^proxy-groups:\s*$') { $groups=$i; break }
    }
    if ($groups -lt 0) { throw 'proxy-groups section was not found.' }

    $auto = -1
    for ($i=$groups+1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\S') { break }
        if ($lines[$i] -match '^\s{2}-\s+name:\s*AUTO\s*$') { $auto=$i; break }
    }
    if ($auto -lt 0) { throw 'AUTO proxy group was not found.' }

    $groupEnd = $lines.Count
    for ($i=$auto+1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\S' -or $lines[$i] -match '^\s{2}-\s+name:') { $groupEnd=$i; break }
    }

    $use = -1
    for ($i=$auto+1; $i -lt $groupEnd; $i++) {
        if ($lines[$i] -match '^\s{4}use:\s*$') { $use=$i; break }
    }
    if ($use -lt 0) { throw 'AUTO.use was not found.' }

    $useEnd = $groupEnd
    for ($i=$use+1; $i -lt $groupEnd; $i++) {
        if ($lines[$i] -match '^\s{4}\S') { $useEnd=$i; break }
    }

    for ($i=$use+1; $i -lt $useEnd; $i++) {
        if ($lines[$i].Trim() -eq "- $ProviderName") { return ($lines -join "`r`n") }
    }

    $lines.Insert($useEnd, "      - $ProviderName")
    return ($lines -join "`r`n")
}

function Remove-AutoUsesProvider {
    param([string]$Text,[string]$ProviderName)

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($Text -split '\r?\n')) { $lines.Add($line) }

    $groups = -1
    for ($i=0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^proxy-groups:\s*$') { $groups=$i; break }
    }
    if ($groups -lt 0) { throw 'proxy-groups section was not found.' }

    $auto = -1
    for ($i=$groups+1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\S') { break }
        if ($lines[$i] -match '^\s{2}-\s+name:\s*AUTO\s*$') { $auto=$i; break }
    }
    if ($auto -lt 0) { throw 'AUTO proxy group was not found.' }

    $groupEnd = $lines.Count
    for ($i=$auto+1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\S' -or $lines[$i] -match '^\s{2}-\s+name:') { $groupEnd=$i; break }
    }

    $use = -1
    for ($i=$auto+1; $i -lt $groupEnd; $i++) {
        if ($lines[$i] -match '^\s{4}use:\s*$') { $use=$i; break }
    }
    if ($use -lt 0) { throw 'AUTO.use was not found.' }

    for ($i=$use+1; $i -lt $groupEnd; $i++) {
        if ($lines[$i] -match '^\s{4}\S') { break }
        if ($lines[$i].Trim() -eq "- $ProviderName") { $lines.RemoveAt($i); break }
    }

    return ($lines -join "`r`n")
}

function Set-SubscriptionProviderBlock {
    param(
        [string]$Text,
        [ValidateSet('http','file')][string]$ProviderType,
        [string]$Url,
        [string]$Path,
        [string]$ProviderName,
        [bool]$HealthCheckEnabled = $true
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($Text -split '\r?\n')) { $lines.Add($line) }

    $root = -1
    for ($i=0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^proxy-providers:\s*$') { $root=$i; break }
    }
    if ($root -lt 0) { throw 'proxy-providers section was not found.' }

    $sub = -1
    for ($i=$root+1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\S') { break }
        if ($lines[$i] -match ('^  ' + [regex]::Escape($ProviderName) + ':\s*$')) { $sub=$i; break }
    }
    if ($sub -lt 0) {
        $sectionEnd = $lines.Count
        for ($i=$root+1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\S') { $sectionEnd=$i; break }
        }

        $block = [System.Collections.Generic.List[string]]::new()
        $block.Add("  ${ProviderName}:")
        $block.Add("    type: $ProviderType")
        if ($ProviderType -eq 'http') {
            $escaped = Escape-YamlDoubleQuoted $Url
            $block.Add("    url: `"$escaped`"")
        }
        $block.Add('    interval: 900')
        $block.Add("    path: $Path")
        $block.Add('    proxy: DIRECT')
        $block.Add('    health-check:')
        $block.Add("      enable: $($HealthCheckEnabled.ToString().ToLowerInvariant())")
        $block.Add('      interval: 300')
        $block.Add('      url: https://www.gstatic.com/generate_204')

        for ($i=$block.Count-1; $i -ge 0; $i--) {
            $lines.Insert($sectionEnd,$block[$i])
        }

        return Ensure-AutoUsesProvider -Text ($lines -join "`r`n") -ProviderName $ProviderName
    }

    $end = $lines.Count
    for ($i=$sub+1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\S' -or $lines[$i] -match '^  \S[^:]*:\s*') {
            $end=$i
            break
        }
    }

    $kept = [System.Collections.Generic.List[string]]::new()
    for ($i=$sub+1; $i -lt $end; $i++) {
        if ($lines[$i] -match '^    (type|url|path):') { continue }
        $kept.Add($lines[$i])
    }

    $replacement = [System.Collections.Generic.List[string]]::new()
    $replacement.Add("  ${ProviderName}:")
    $replacement.Add("    type: $ProviderType")
    if ($ProviderType -eq 'http') {
        $escaped = Escape-YamlDoubleQuoted $Url
        $replacement.Add("    url: `"$escaped`"")
    }
    $replacement.Add("    path: $Path")
    foreach ($line in $kept) { $replacement.Add($line) }

    $out = [System.Collections.Generic.List[string]]::new()
    for ($i=0; $i -lt $sub; $i++) { $out.Add($lines[$i]) }
    foreach ($line in $replacement) { $out.Add($line) }
    for ($i=$end; $i -lt $lines.Count; $i++) { $out.Add($lines[$i]) }

    return Ensure-AutoUsesProvider -Text ($out -join "`r`n") -ProviderName $ProviderName
}

function Remove-SubscriptionProviderBlock {
    param([string]$Text,[string]$ProviderName)

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($Text -split '\r?\n')) { $lines.Add($line) }

    $root = -1
    for ($i=0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^proxy-providers:\s*$') { $root=$i; break }
    }
    if ($root -lt 0) { throw 'proxy-providers section was not found.' }

    $sub = -1
    for ($i=$root+1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\S') { break }
        if ($lines[$i] -match ('^  ' + [regex]::Escape($ProviderName) + ':\s*$')) { $sub=$i; break }
    }

    if ($sub -lt 0) { return Remove-AutoUsesProvider -Text $Text -ProviderName $ProviderName }

    $end = $lines.Count
    for ($i=$sub+1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\S' -or $lines[$i] -match '^  \S[^:]*:\s*$') { $end=$i; break }
    }

    for ($i=$end-1; $i -ge $sub; $i--) { $lines.RemoveAt($i) }

    return Remove-AutoUsesProvider -Text ($lines -join "`r`n") -ProviderName $ProviderName
}

function Backup-CurrentState {
    New-Item -ItemType Directory -Path (Join-Path $BaseDir 'backups') -Force | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $dir = Join-Path (Join-Path $BaseDir 'backups') "subscription-$stamp"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    foreach ($path in @($ConfigFiles + $SubscriptionFile + $LocalProviderFile)) {
        if (Test-Path -LiteralPath $path) {
            Copy-Item -LiteralPath $path -Destination (Join-Path $dir ([IO.Path]::GetFileName($path))) -Force
        }
    }

    [pscustomobject]@{
        Path=$dir
        HadSubscription=(Test-Path -LiteralPath $SubscriptionFile)
        HadLocalProvider=(Test-Path -LiteralPath $LocalProviderFile)
    }
}

function Restore-Backup {
    param($Backup)

    foreach ($path in $ConfigFiles) {
        $backupFile = Join-Path $Backup.Path ([IO.Path]::GetFileName($path))
        if (Test-Path -LiteralPath $backupFile) {
            Copy-Item -LiteralPath $backupFile -Destination $path -Force
        }
    }

    $subBackup = Join-Path $Backup.Path ([IO.Path]::GetFileName($SubscriptionFile))
    if (Test-Path -LiteralPath $subBackup) {
        Copy-Item -LiteralPath $subBackup -Destination $SubscriptionFile -Force
    } elseif (-not $Backup.HadSubscription) {
        Remove-Item -LiteralPath $SubscriptionFile -Force -ErrorAction SilentlyContinue
    }

    $localBackup = Join-Path $Backup.Path ([IO.Path]::GetFileName($LocalProviderFile))
    if (Test-Path -LiteralPath $localBackup) {
        Copy-Item -LiteralPath $localBackup -Destination $LocalProviderFile -Force
    } elseif (-not $Backup.HadLocalProvider) {
        Remove-Item -LiteralPath $LocalProviderFile -Force -ErrorAction SilentlyContinue
    }
}

function Apply-Source {
    param([string]$OriginalText, $Tested)

    foreach ($cfg in $ConfigFiles) {
        if (-not (Test-Path -LiteralPath $cfg)) {
            throw "Required config was not found: $cfg"
        }
    }

    New-Item -ItemType Directory -Path $ProvidersDir -Force | Out-Null
    $backup = Backup-CurrentState

    try {
        $healthCheckEnabled =
            $null -eq $Tested.NodeCount -or
            [int]$Tested.NodeCount -le 50

        if ($Tested.SourceType -eq 'URL' -and $Tested.RemoteContentType -notin @('URI','Base64')) {
            $url = $OriginalText.Trim()
            foreach ($cfg in $ConfigFiles) {
                $old = [IO.File]::ReadAllText($cfg)
                $new = Set-SubscriptionProviderBlock -Text $old -ProviderType http -Url $url -Path "./providers/$ProviderName.yaml" -ProviderName $ProviderName -HealthCheckEnabled $healthCheckEnabled
                Write-Utf8NoBom $cfg $new
            }
            Write-Utf8NoBom $SubscriptionFile ($url + "`r`n")
        } else {
            Write-Utf8NoBom $LocalProviderFile $Tested.ProviderContent
            foreach ($cfg in $ConfigFiles) {
                $old = [IO.File]::ReadAllText($cfg)
                $new = Set-SubscriptionProviderBlock -Text $old -ProviderType file -Url '' -Path "./providers/$ProviderName-local.txt" -ProviderName $ProviderName -HealthCheckEnabled $healthCheckEnabled
                Write-Utf8NoBom $cfg $new
            }
            if ($Tested.SourceType -eq 'URL') { Write-Utf8NoBom $SubscriptionFile ($OriginalText.Trim() + "`r`n") } else { Write-Utf8NoBom $SubscriptionFile ("file:providers/$ProviderName-local.txt`r`n") }
        }

        foreach ($cfg in $ConfigFiles) {
            $result = Invoke-MihomoTest -ConfigFile $cfg -HomeDir $BaseDir
            if (-not $result.Ok) {
                throw "Mihomo rejected $([IO.Path]::GetFileName($cfg))."
            }
        }

        return $backup.Path
    } catch {
        Restore-Backup $backup
        throw
    }
}

function Remove-Source {
    param([string]$ProviderName)

    foreach ($cfg in $ConfigFiles) {
        if (-not (Test-Path -LiteralPath $cfg)) {
            throw "Required config was not found: $cfg"
        }
    }

    $backup = Backup-CurrentState

    try {
        foreach ($cfg in $ConfigFiles) {
            $old = [IO.File]::ReadAllText($cfg)
            $new = Remove-SubscriptionProviderBlock -Text $old -ProviderName $ProviderName
            Write-Utf8NoBom $cfg $new
        }

        $providerFiles = @(
            (Join-Path $BaseDir "$ProviderName.txt"),
            (Join-Path $ProvidersDir "$ProviderName.yaml"),
            (Join-Path $ProvidersDir "$ProviderName-local.txt")
        )

        foreach ($file in $providerFiles) {
            if (Test-Path -LiteralPath $file) {
                Remove-Item -LiteralPath $file -Force
            }
        }

        foreach ($cfg in $ConfigFiles) {
            $result = Invoke-MihomoTest -ConfigFile $cfg -HomeDir $BaseDir
            if (-not $result.Ok) {
                throw "Mihomo rejected $([IO.Path]::GetFileName($cfg))."
            }
        }

        return $backup.Path
    }
    catch {
        Restore-Backup $backup
        throw
    }
}
function Invoke-ProviderUpdate {
    if (-not (Get-Process -Name 'mihomo' -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Success=$false; Message='Mihomo is stopped. Start Proxy or TUN first.'; NodeCount=$null }
    }

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.UseProxy = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    try {
        $client.Timeout = [TimeSpan]::FromSeconds(20)
        $encoded = [Uri]::EscapeDataString($ProviderName)
        $url = "http://127.0.0.1:9090/providers/proxies/$encoded"
        $content = [System.Net.Http.StringContent]::new('')
        $response = $client.PutAsync($url, $content).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            return [pscustomobject]@{ Success=$false; Message="Provider update returned HTTP $([int]$response.StatusCode)."; NodeCount=$null }
        }

        $info = $client.GetStringAsync($url).GetAwaiter().GetResult()
        $doc = $info | ConvertFrom-Json -Depth 100
        $count = if ($null -ne $doc.proxies) { @($doc.proxies).Count } else { $null }
        return [pscustomobject]@{ Success=$true; Message='Provider updated by the running Mihomo core.'; NodeCount=$count }
    } catch {
        return [pscustomobject]@{ Success=$false; Message='Could not update the running provider.'; NodeCount=$null }
    } finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

try {
    switch ($Action) {
        'Detect' {
            $text = Get-InputText
            $d = Get-Detection $text
            if ($d.Kind -eq 'Unsupported') {
                Write-JsonResult -Success $false -Message 'Format was not recognized.' -SourceType $d.Kind -Display $d.Display
            } else {
                Write-JsonResult -Success $true -Message 'Format detected.' -SourceType $d.Kind -Display $d.Display -NodeCount $d.NodeCount
            }
        }

        'Test' {
            $text = Get-InputText
            $t = Test-InputSource $text
            Write-JsonResult -Success $t.Success -Message $t.Message -SourceType $t.SourceType -Display $t.Display -NodeCount $t.NodeCount -RemoteContentType $t.RemoteContentType
        }

        'Apply' {
            $text = Get-InputText
            $t = Test-InputSource $text
            if (-not $t.Success) {
                Write-JsonResult -Success $false -Message $t.Message -SourceType $t.SourceType -Display $t.Display -NodeCount $t.NodeCount -RemoteContentType $t.RemoteContentType
                break
            }

            $backupPath = Apply-Source -OriginalText $text -Tested $t
            Write-JsonResult -Success $true -Message 'Subscription source applied and both configs passed mihomo -t.' -SourceType $t.SourceType -Display $t.Display -NodeCount $t.NodeCount -RemoteContentType $t.RemoteContentType -RestartRequired $true -BackupPath $backupPath
        }        'Remove' {
            $backupPath = Remove-Source -ProviderName $ProviderName
            Write-JsonResult -Success $true -Message 'Provider removed and both configs passed mihomo -t.' -SourceType 'Provider' -Display $ProviderName -BackupPath $backupPath
        }

        'Update' {
            $r = Invoke-ProviderUpdate
            Write-JsonResult -Success $r.Success -Message $r.Message -SourceType 'Current' -Display 'Current provider' -NodeCount $r.NodeCount
        }
    }
} catch {
    Write-JsonResult -Success $false -Message $_.Exception.Message
}