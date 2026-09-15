Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$Base = "C:\Mihomo"
$Scripts = Join-Path $Base "scripts"
$StartScript = Join-Path $Scripts "Start-Mihomo.ps1"
$StopScript = Join-Path $Scripts "Stop-Mihomo.ps1"
$StateFile = Join-Path $Base "watchdog-state.json"

function Run-PwshHidden {
    param(
        [Parameter(Mandatory=$true)][string]$Script,
        [string[]]$Args = @()
    )

    $pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
    $argList = @("-NoProfile","-ExecutionPolicy","Bypass","-File",$Script) + $Args
    Start-Process -FilePath $pwsh -ArgumentList $argList -WindowStyle Hidden
}

function Get-MihomoUiState {
    $result = [ordered]@{
        Process = "STOPPED"
        SystemProxy = "OFF"
        ActiveProxy = "-"
        Health = "-"
        Watchdog = "-"
    }

    if (Get-Process mihomo -ErrorAction SilentlyContinue) {
        $result.Process = "RUNNING"
    }

    try {
        $reg = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
        if ([bool]$reg.ProxyEnable -and $reg.ProxyServer -eq "127.0.0.1:7890") {
            $result.SystemProxy = "ON"
        }
    } catch {}

    try {
        $auto = Invoke-RestMethod -Uri "http://127.0.0.1:9090/proxies/AUTO" -NoProxy -TimeoutSec 3
        if ($auto.now) { $result.ActiveProxy = [string]$auto.now }
    } catch {}

    try {
        $urls = @(
            "https://www.youtube.com",
            "https://api.github.com",
            "https://api.telegram.org"
        )
        $passed = 0
        foreach ($u in $urls) {
            & curl.exe -x "http://127.0.0.1:7890" -I -sS -o NUL --ssl-no-revoke --connect-timeout 3 --max-time 6 $u
            if ($LASTEXITCODE -eq 0) { $passed++ }
        }
        $result.Health = "$passed/3"
    } catch {}

    if (Test-Path $StateFile) {
        try {
            $state = Get-Content $StateFile -Raw | ConvertFrom-Json
            if ($state.status) { $result.Watchdog = [string]$state.status }
        } catch {}
    }

    [pscustomobject]$result
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "Mihomo Control"
$form.Size = New-Object System.Drawing.Size(520,330)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font("Segoe UI",10)

$title = New-Object System.Windows.Forms.Label
$title.Text = "Mihomo Proxy Control"
$title.Font = New-Object System.Drawing.Font("Segoe UI",14,[System.Drawing.FontStyle]::Bold)
$title.Location = New-Object System.Drawing.Point(20,15)
$title.AutoSize = $true
$form.Controls.Add($title)

$statusBox = New-Object System.Windows.Forms.TextBox
$statusBox.Location = New-Object System.Drawing.Point(20,55)
$statusBox.Size = New-Object System.Drawing.Size(470,120)
$statusBox.Multiline = $true
$statusBox.ReadOnly = $true
$statusBox.ScrollBars = "Vertical"
$statusBox.Font = New-Object System.Drawing.Font("Consolas",10)
$form.Controls.Add($statusBox)

$btnOn = New-Object System.Windows.Forms.Button
$btnOn.Text = "Proxy ON"
$btnOn.Location = New-Object System.Drawing.Point(20,195)
$btnOn.Size = New-Object System.Drawing.Size(105,38)
$form.Controls.Add($btnOn)

$btnOff = New-Object System.Windows.Forms.Button
$btnOff.Text = "Proxy OFF"
$btnOff.Location = New-Object System.Drawing.Point(135,195)
$btnOff.Size = New-Object System.Drawing.Size(105,38)
$form.Controls.Add($btnOff)

$btnRestart = New-Object System.Windows.Forms.Button
$btnRestart.Text = "Restart"
$btnRestart.Location = New-Object System.Drawing.Point(250,195)
$btnRestart.Size = New-Object System.Drawing.Size(105,38)
$form.Controls.Add($btnRestart)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = "Refresh"
$btnRefresh.Location = New-Object System.Drawing.Point(365,195)
$btnRefresh.Size = New-Object System.Drawing.Size(105,38)
$form.Controls.Add($btnRefresh)

$info = New-Object System.Windows.Forms.Label
$info.Text = "Uses existing tested scripts. TUN mode is not included yet."
$info.Location = New-Object System.Drawing.Point(20,250)
$info.Size = New-Object System.Drawing.Size(470,40)
$form.Controls.Add($info)

function Refresh-Ui {
    $s = Get-MihomoUiState
    $statusBox.Text = @"
Process      : $($s.Process)
System Proxy : $($s.SystemProxy)
Active Node  : $($s.ActiveProxy)
Health       : $($s.Health)
Watchdog     : $($s.Watchdog)
"@
}

$btnOn.Add_Click({
    try {
        Run-PwshHidden -Script $StartScript
        Start-Sleep -Milliseconds 800
        Refresh-Ui
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,"Proxy ON failed")
    }
})

$btnOff.Add_Click({
    try {
        Run-PwshHidden -Script $StopScript
        Start-Sleep -Milliseconds 800
        Refresh-Ui
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,"Proxy OFF failed")
    }
})

$btnRestart.Add_Click({
    try {
        Run-PwshHidden -Script $StartScript -Args @("-Restart")
        Start-Sleep -Milliseconds 800
        Refresh-Ui
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,"Restart failed")
    }
})

$btnRefresh.Add_Click({ Refresh-Ui })
$form.Add_Shown({ Refresh-Ui })

[void]$form.ShowDialog()
