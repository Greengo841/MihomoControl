. "C:\Mihomo\scripts\_Common.ps1"

if (-not (Test-Path $SubscriptionFile)) {
    New-Item -ItemType File -Path $SubscriptionFile -Force | Out-Null
}

$url = Read-Host "Paste NEW subscription URL"
$url = $url.Trim()
if ($url -notmatch '^https?://') { throw "Expected http/https subscription URL." }

Set-Content -Path $SubscriptionFile -Value $url -Encoding UTF8
Write-Host "Saved locally to $SubscriptionFile"

if (Test-Path $Template) {
    $yaml = Get-Content $Template -Raw
    if ($yaml -match '__SUBSCRIPTION_URL__') {
        $escaped = $url.Replace('\','\\').Replace('"','\"')
        $yaml = $yaml.Replace('__SUBSCRIPTION_URL__',$escaped)
        Set-Content -Path $Config -Value $yaml -Encoding UTF8
        Write-Host "config.yaml regenerated from template."
    } else {
        Write-Warning "Template has no __SUBSCRIPTION_URL__ placeholder. config.yaml was not regenerated."
    }
} else {
    Write-Warning "config.template.yaml not found. subscription.txt updated only."
}

if (@(Get-MihomoProcess).Count -gt 0) {
    & "C:\Mihomo\scripts\Start-Mihomo.ps1" -Restart
}
