. "C:\Mihomo\scripts\_Common.ps1"

$proc = @(Get-MihomoProcess)
Write-Host "Mihomo process: $(if($proc.Count -gt 0){'RUNNING'}else{'STOPPED'})"

try {
    $auto = Get-AutoProxyInfo
    Write-Host "AUTO active proxy: $($auto.now)"
    Write-Host "AUTO alive: $($auto.alive)"
} catch {
    Write-Warning "Controller unavailable: $($_.Exception.Message)"
}

$reg = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
Write-Host "System proxy enabled: $([bool]$reg.ProxyEnable)"
Write-Host "System proxy server: $($reg.ProxyServer)"

if ($proc.Count -gt 0) {
    Write-Host "`nLive health:"
    Test-ProxyHealth | Format-Table Name,OK -AutoSize
}

if (Test-Path $StateFile) {
    Write-Host "`nWatchdog state:"
    Get-Content $StateFile -Raw
}
