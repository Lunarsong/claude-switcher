<#
  ClaudeUsageTray.ps1
  Tray icon + optional always-on-top overlay showing how much of your Claude
  subscription usage limits you have left (5-hour session, weekly, per-model weekly).

  Data source: the same endpoint Claude Code's /usage uses
  (https://api.anthropic.com/api/oauth/usage), authenticated with the OAuth token
  Claude Code stores in %USERPROFILE%\.claude\.credentials.json. The token is only
  ever sent to api.anthropic.com.

  Run via start-usage-tray.vbs (no console window) or:
    powershell -NoProfile -STA -ExecutionPolicy Bypass -File ClaudeUsageTray.ps1
#>

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
# Never show the WinForms "unhandled exception" dialog; just log and carry on.
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
$LogPath = Join-Path $env:APPDATA 'ClaudeUsageTray\error.log'
[System.Windows.Forms.Application]::add_ThreadException({
    param($s, $e)
    try { Add-Content $LogPath ("{0}  {1}" -f (Get-Date -Format s), $e.Exception) } catch {}
})

Add-Type -Namespace Native -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr hIcon);
[DllImport("user32.dll")] public static extern bool ReleaseCapture();
[DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, int msg, int wParam, int lParam);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@

# ---------- single instance ----------
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\ClaudeUsageTray', [ref]$createdNew)
if (-not $createdNew) { exit }

# ---------- settings ----------
$CredPath     = Join-Path $env:USERPROFILE '.claude\.credentials.json'
$UsageUrl     = 'https://api.anthropic.com/api/oauth/usage'
$SettingsDir  = Join-Path $env:APPDATA 'ClaudeUsageTray'
$SettingsPath = Join-Path $SettingsDir 'settings.json'
$StartupLnk   = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Usage Tray.lnk'
$Launcher     = Join-Path $PSScriptRoot 'start-usage-tray.vbs'

$Settings = [ordered]@{ ShowOverlay = $true; X = -1; Y = -1; IntervalSec = 120; Opacity = 0.92 }
if (Test-Path $SettingsPath) {
    try {
        $s = Get-Content $SettingsPath -Raw | ConvertFrom-Json
        foreach ($p in $s.PSObject.Properties) { $Settings[$p.Name] = $p.Value }
    } catch {}
}
function Save-Settings {
    if (-not (Test-Path $SettingsDir)) { New-Item -ItemType Directory $SettingsDir | Out-Null }
    $Settings | ConvertTo-Json | Set-Content $SettingsPath -Encoding UTF8
}

# ---------- state ----------
$script:Rows      = @()      # @{ Label; Used; Resets }
$script:LastErr     = $null
$script:LastOk    = $null
$script:LastHIcon = [IntPtr]::Zero

# ---------- helpers ----------
function Format-Until($when) {
    if (-not ($when -is [datetime])) { return '' }
    $span = $when.ToUniversalTime() - [datetime]::UtcNow
    if ($span.TotalSeconds -le 0) { return 'resetting' }
    if ($span.TotalDays -ge 1) { return ('{0}d {1}h' -f [int][math]::Floor($span.TotalDays), $span.Hours) }
    if ($span.TotalHours -ge 1) { return ('{0}h {1}m' -f [int][math]::Floor($span.TotalHours), $span.Minutes) }
    return ('{0}m' -f [math]::Max(1, [int][math]::Ceiling($span.TotalMinutes)))
}

function Get-LevelColor([double]$left) {
    if ($left -le 10) { return [System.Drawing.Color]::FromArgb(220, 53, 69) }   # red
    if ($left -le 30) { return [System.Drawing.Color]::FromArgb(230, 145, 30) }  # amber
    return [System.Drawing.Color]::FromArgb(46, 160, 90)                          # green
}

function Parse-Date($s) {
    if (-not $s) { return $null }
    try { return [datetime]::Parse($s, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) } catch { return $null }
}

function Update-Usage {
    try {
        if (-not (Test-Path $CredPath)) { throw "No Claude Code login found ($CredPath). Run 'claude' and log in." }
        $cred = (Get-Content $CredPath -Raw | ConvertFrom-Json).claudeAiOauth
        if (-not $cred.accessToken) { throw 'No OAuth token in credentials file. Run ''claude'' and log in.' }

        $headers = @{ Authorization = "Bearer $($cred.accessToken)"; 'anthropic-beta' = 'oauth-2025-04-20' }
        try {
            $r = Invoke-RestMethod -Uri $UsageUrl -Headers $headers -TimeoutSec 15 -UseBasicParsing
        } catch {
            $code = $null
            try { $code = [int]$_.Exception.Response.StatusCode } catch {}
            if ($code -eq 401) { throw 'Token expired. Open Claude Code once to refresh it.' }
            throw "Request failed: $($_.Exception.Message)"
        }

        $rows = @()
        if ($r.limits) {
            foreach ($l in $r.limits) {
                $label = switch ($l.kind) {
                    'session'       { 'Session (5h)' }
                    'weekly_all'    { 'Weekly' }
                    'weekly_scoped' {
                        $n = $l.scope.model.display_name
                        if (-not $n) { $n = $l.scope.surface }
                        if ($n) { "Weekly $n" } else { 'Weekly (scoped)' }
                    }
                    default         { ($l.kind -replace '_', ' ') }
                }
                $rows += @{ Label = $label; Used = [double]$l.percent; Resets = (Parse-Date $l.resets_at) }
            }
        } else {
            if ($r.five_hour)  { $rows += @{ Label = 'Session (5h)'; Used = [double]$r.five_hour.utilization;  Resets = (Parse-Date $r.five_hour.resets_at) } }
            if ($r.seven_day)  { $rows += @{ Label = 'Weekly';       Used = [double]$r.seven_day.utilization;  Resets = (Parse-Date $r.seven_day.resets_at) } }
            if ($r.seven_day_opus)   { $rows += @{ Label = 'Weekly Opus';   Used = [double]$r.seven_day_opus.utilization;   Resets = (Parse-Date $r.seven_day_opus.resets_at) } }
            if ($r.seven_day_sonnet) { $rows += @{ Label = 'Weekly Sonnet'; Used = [double]$r.seven_day_sonnet.utilization; Resets = (Parse-Date $r.seven_day_sonnet.resets_at) } }
        }
        if (-not $rows) { throw 'Usage response contained no limits.' }

        $script:Rows   = $rows
        $script:LastErr  = $null
        $script:LastOk = Get-Date
    } catch {
        $script:LastErr = $_.Exception.Message
    }
    Update-Ui
}

# The binding limit = the one with the least left.
function Get-Tightest {
    if (-not $script:Rows) { return $null }
    return ($script:Rows | Sort-Object { $_.Used } -Descending | Select-Object -First 1)
}

function New-TrayIcon {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.Clear([System.Drawing.Color]::Transparent)

    $t = Get-Tightest
    if ($script:LastErr -and -not $t) {
        $bg = [System.Drawing.Color]::FromArgb(110, 110, 110); $text = '!'
    } else {
        $left = [math]::Max(0, 100 - $t.Used)
        $bg = Get-LevelColor $left
        $text = if ($left -ge 100) { '99' } else { [string][int][math]::Floor($left) }
        if ($script:LastErr) { $bg = [System.Drawing.Color]::FromArgb(110, 110, 110) }  # stale
    }

    $brush = New-Object System.Drawing.SolidBrush $bg
    $g.FillEllipse($brush, 0, 0, 31, 31)
    $size = if ($text.Length -ge 2) { 15 } else { 19 }
    $font = New-Object System.Drawing.Font('Segoe UI', $size, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
    $g.DrawString($text, $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF(0, 1, 32, 32)), $sf)
    $g.Dispose(); $font.Dispose(); $brush.Dispose()

    $h = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($h)
    $bmp.Dispose()
    return @{ Icon = $icon; Handle = $h }
}

function Update-Ui {
    # Tray icon
    $new = New-TrayIcon
    $old = $script:LastHIcon
    $tray.Icon = $new.Icon
    if ($old -ne [IntPtr]::Zero) { [Native.Win32]::DestroyIcon($old) | Out-Null }
    $script:LastHIcon = $new.Handle

    # Tooltip (max 127 chars)
    if ($script:Rows) {
        $parts = foreach ($r in $script:Rows) {
            $lbl = $r.Label -replace 'Session \(5h\)', '5h' -replace 'Weekly ', 'Wk '
            '{0}: {1}% left' -f $lbl, [int](100 - $r.Used)
        }
        $tip = 'Claude  ' + ($parts -join ' | ')
        if ($script:LastErr) { $tip = '[stale] ' + $tip }
    } else {
        $tip = 'Claude usage: ' + $script:LastErr
    }
    if ($tip.Length -gt 127) { $tip = $tip.Substring(0, 124) + '...' }
    $tray.Text = $tip

    $overlay.Height = [math]::Max(1, $script:Rows.Count) * 34 + 30
    $overlay.Invalidate()
}

# ---------- tray ----------
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Text = 'Claude usage: loading...'
$tray.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miOverlay = $menu.Items.Add('Show overlay')
$miOverlay.CheckOnClick = $true
$miOverlay.Checked = [bool]$Settings.ShowOverlay
$miRefresh = $menu.Items.Add('Refresh now')
$miWeb     = $menu.Items.Add('Open claude.ai usage page')
$miStartup = $menu.Items.Add('Start with Windows')
$miStartup.CheckOnClick = $true
$miStartup.Checked = Test-Path $StartupLnk
$menu.Items.Add('-') | Out-Null
$miExit = $menu.Items.Add('Exit')
$tray.ContextMenuStrip = $menu

# ---------- overlay ----------
$overlay = New-Object System.Windows.Forms.Form
$overlay.FormBorderStyle = 'None'
$overlay.ShowInTaskbar = $false
$overlay.TopMost = $true
$overlay.StartPosition = 'Manual'
$overlay.Width = 250
$overlay.Height = 100
$overlay.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 34)
$overlay.Opacity = [double]$Settings.Opacity
$overlay.Text = 'Claude Usage'
$overlay.ContextMenuStrip = $menu
# double buffering to stop flicker
$overlay.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic').SetValue($overlay, $true, $null)

$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
if ($Settings.X -lt 0 -or $Settings.Y -lt 0) {
    $overlay.Location = New-Object System.Drawing.Point(($wa.Right - $overlay.Width - 12), ($wa.Bottom - 140))
} else {
    $overlay.Location = New-Object System.Drawing.Point([int]$Settings.X, [int]$Settings.Y)
}

$fontTitle = New-Object System.Drawing.Font('Segoe UI', 8.5, [System.Drawing.FontStyle]::Bold)
$fontRow   = New-Object System.Drawing.Font('Segoe UI', 8.5)
$fontSmall = New-Object System.Drawing.Font('Segoe UI', 7.5)
$fgMain  = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(235, 235, 240))
$fgDim   = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(150, 150, 160))
$trackBr = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(60, 60, 68))

$overlay.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'ClearTypeGridFit'
    $w = $overlay.ClientSize.Width

    $g.DrawString('Claude usage left', $fontTitle, $fgMain, 10, 6)
    $status = if ($script:LastErr) { 'stale' } elseif ($script:LastOk) { $script:LastOk.ToString('HH:mm') } else { '...' }
    $sz = $g.MeasureString($status, $fontSmall)
    $g.DrawString($status, $fontSmall, $fgDim, ($w - $sz.Width - 8), 8)

    if (-not $script:Rows) {
        $msg = if ($script:LastErr) { $script:LastErr } else { 'Loading...' }
        $g.DrawString($msg, $fontSmall, $fgDim, (New-Object System.Drawing.RectangleF(10, 28, ($w - 20), 60)))
        return
    }

    $y = 28
    foreach ($r in $script:Rows) {
        $left = [math]::Max(0, [math]::Min(100, 100 - $r.Used))
        $g.DrawString($r.Label, $fontRow, $fgMain, 10, $y)
        $right = '{0}% - {1}' -f [int]$left, (Format-Until $r.Resets)
        $sz = $g.MeasureString($right, $fontSmall)
        $g.DrawString($right, $fontSmall, $fgDim, ($w - $sz.Width - 8), ($y + 1))

        $barW = $w - 20
        $g.FillRectangle($trackBr, 10, ($y + 18), $barW, 6)
        $fill = New-Object System.Drawing.SolidBrush (Get-LevelColor $left)
        $g.FillRectangle($fill, 10, ($y + 18), [float]($barW * $left / 100), 6)
        $fill.Dispose()
        $y += 34
    }
})

# drag to move
$overlay.Add_MouseDown({
    param($s, $e)
    if ($e.Button -eq 'Left') {
        [Native.Win32]::ReleaseCapture() | Out-Null
        [Native.Win32]::SendMessage($overlay.Handle, 0xA1, 0x2, 0) | Out-Null   # WM_NCLBUTTONDOWN, HTCAPTION
        $Settings.X = $overlay.Left; $Settings.Y = $overlay.Top
        Save-Settings
    }
})
$overlay.Add_MouseDoubleClick({ Update-Usage })

# ---------- menu handlers ----------
$miOverlay.Add_CheckedChanged({
    $Settings.ShowOverlay = $miOverlay.Checked
    $overlay.Visible = $miOverlay.Checked
    Save-Settings
})
$miRefresh.Add_Click({ Update-Usage })
$miWeb.Add_Click({ Start-Process 'https://claude.ai/settings/usage' })
$miStartup.Add_CheckedChanged({
    if ($miStartup.Checked) {
        $sh = New-Object -ComObject WScript.Shell
        $lnk = $sh.CreateShortcut($StartupLnk)
        $lnk.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
        $lnk.Arguments = '"' + $Launcher + '"'
        $lnk.WorkingDirectory = $PSScriptRoot
        $lnk.Save()
    } elseif (Test-Path $StartupLnk) {
        Remove-Item $StartupLnk
    }
})
$tray.Add_MouseClick({
    param($s, $e)
    if ($e.Button -eq 'Left') { $miOverlay.Checked = -not $miOverlay.Checked }
})
$miExit.Add_Click({
    $timer.Stop(); $tickTimer.Stop()
    $tray.Visible = $false
    $tray.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

# ---------- timers ----------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = [math]::Max(30, [int]$Settings.IntervalSec) * 1000
$timer.Add_Tick({ Update-Usage })

# repaint countdowns every 30s without hitting the API
$tickTimer = New-Object System.Windows.Forms.Timer
$tickTimer.Interval = 30000
$tickTimer.Add_Tick({ $overlay.Invalidate() })

# ---------- go ----------
$overlay.Show()
# When launched hidden (wscript/-WindowStyle Hidden) Windows swallows the first
# ShowWindow call, so force it visible explicitly (SW_SHOWNOACTIVATE = 4).
[Native.Win32]::ShowWindow($overlay.Handle, 4) | Out-Null
if (-not $Settings.ShowOverlay) { $overlay.Hide() }
Update-Usage
$timer.Start(); $tickTimer.Start()

[System.Windows.Forms.Application]::Run()
$mutex.ReleaseMutex()
