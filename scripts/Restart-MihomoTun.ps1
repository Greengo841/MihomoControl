$ErrorActionPreference = 'Stop'

$stop = 'C:\Mihomo\scripts\Stop-MihomoTun.ps1'
$start = 'C:\Mihomo\scripts\Start-MihomoTun.ps1'

if (-not (Test-Path $stop)) { throw "Missing: $stop" }
if (-not (Test-Path $start)) { throw "Missing: $start" }

& $stop
& $start
