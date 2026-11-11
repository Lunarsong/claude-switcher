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
$ProfileCli   = Join-Path $PSScriptRoot 'claude-profile.ps1'
. (Join-Path $PSScriptRoot 'ClaudeProfiles.ps1')
$script:ActiveName = $null

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
$script:Others    = @()      # @{ Id; Name; Rows; Err } for non-active saved accounts
$script:BtnAll    = [System.Drawing.Rectangle]::Empty
$script:BtnAdd    = [System.Drawing.Rectangle]::Empty
$script:AddProc   = $null
if ($null -eq $Settings.ShowAll) { $Settings.ShowAll = $false }
if ($null -eq $Settings.ShowRemaining) { $Settings.ShowRemaining = $false }
if ($null -eq $Settings.AutoSwitch)        { $Settings.AutoSwitch = $false }
if ($null -eq $Settings.AutoSwitchAt)      { $Settings.AutoSwitchAt = 99 }    # switch when any limit hits this % used
if ($null -eq $Settings.AutoSwitchMinLeft) { $Settings.AutoSwitchMinLeft = 10 } # target needs >= this % left on every limit
$script:AutoCooldownUntil = [datetime]::MinValue
$script:AutoNotified      = $false
$script:SwitchRects       = @()   # clickable account names in the overlay: @{ Rect; Id }

# ---------- helpers ----------
function Format-Until($when) {
    if (-not ($when -is [datetime])) { return '' }
    $span = $when.ToUniversalTime() - [datetime]::UtcNow
    if ($span.TotalSeconds -le 0) { return 'resetting' }
    if ($span.TotalDays -ge 1) { return ('{0}d {1}h' -f [int][math]::Floor($span.TotalDays), $span.Hours) }
    if ($span.TotalHours -ge 1) { return ('{0}h {1}m' -f [int][math]::Floor($span.TotalHours), $span.Minutes) }
    return ('{0}m' -f [math]::Max(1, [int][math]::Ceiling($span.TotalMinutes)))
}

# "3% used" by default (bars fill up as you use them, like claude.ai);
# "97% left" when ShowRemaining is on.
function Format-Pct($r) {
    if ($Settings.ShowRemaining) { return ('{0}% left' -f [int][math]::Max(0, 100 - $r.Used)) }
    return ('{0}% used' -f [int][math]::Min(100, $r.Used))
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
    # Keep the active account's profile snapshot current (tokens rotate on refresh).
    try {
        Sync-ActiveProfile | Out-Null
        $script:ActiveName = (Get-ClaudeProfiles | Where-Object Active | Select-Object -First 1).Name
        $script:ProfSig = Get-ProfilesSignature
    } catch {}
    try {
        if (-not (Test-Path $CredPath)) { throw "No Claude Code login found ($CredPath). Run 'claude' and log in." }
        $cred = (Get-Content $CredPath -Raw | ConvertFrom-Json).claudeAiOauth
        if (-not $cred.accessToken) { throw 'No OAuth token in credentials file. Run ''claude'' and log in.' }

        $script:Rows    = Get-UsageRows $cred.accessToken
        $script:LastErr = $null
        $script:LastOk  = Get-Date
    } catch {
        $script:LastErr = $_.Exception.Message
    }
    if ($Settings.ShowAll) { Update-OtherAccounts }
    if (Invoke-AutoSwitch) { return }   # switched: it already refreshed everything
    Update-Ui
}

# Usage for every saved account except the active one. Fetched each poll while
# "All" is on, otherwise only when auto-switch needs it.
function Update-OtherAccounts {
    $list = @()
    foreach ($p in (Get-ClaudeProfiles | Where-Object { -not $_.Active })) {
        $entry = @{ Id = $p.Id; Name = $p.Name; Rows = @(); Err = $null; Eligible = $false }
        try { $entry.Rows = Get-UsageRows (Get-ProfileAccessToken $p) } catch { $entry.Err = $_.Exception.Message }
        $list += $entry
    }
    # Order = auto-switch priority, so the top one is "next up".
    $script:Others = Sort-SwitchCandidates $list ([double]$Settings.AutoSwitchMinLeft)
}

# Returns $true if it switched accounts.
function Invoke-AutoSwitch {
    if (-not $Settings.AutoSwitch -or $script:LastErr -or -not $script:Rows) { return $false }
    $used = Get-MaxUsed $script:Rows
    if ($used -lt [double]$Settings.AutoSwitchAt) { $script:AutoNotified = $false; return $false }
    if ((Get-Date) -lt $script:AutoCooldownUntil) { return $false }

    if (-not $Settings.ShowAll) { Update-OtherAccounts }   # need fresh numbers to choose
    $target = Select-AutoSwitchTarget $script:Others ([double]$Settings.AutoSwitchMinLeft)
    if (-not $target) {
        if (-not $script:AutoNotified) {
            $tray.ShowBalloonTip(6000, 'Claude auto-switch',
                ("Current account is at {0}% but no other account has {1}% left on every limit." -f [int]$used, $Settings.AutoSwitchMinLeft), 'Warning')
            $script:AutoNotified = $true
        }
        return $false
    }

    $from = $script:ActiveName
    try { Switch-ClaudeProfile $target.Id | Out-Null } catch {
        $tray.ShowBalloonTip(6000, 'Claude auto-switch failed', $_.Exception.Message, 'Error'); return $false
    }
    $script:AutoCooldownUntil = (Get-Date).AddMinutes(5)   # no ping-ponging
    $script:AutoNotified = $false
    $tray.ShowBalloonTip(8000, 'Claude auto-switched account',
        ("{0} reached {1}% used. Now using {2}. Restart running Claude Code sessions to pick it up." -f $from, [int]$used, $target.Name), 'Info')
    Update-Usage
    return $true
}

function Get-OverlayHeight {
    $h = 44 + [math]::Max(1, @($script:Rows).Count) * 34
    if ($Settings.ShowAll) {
        $h += 6    # gap below the active panel
        if (-not $script:Others) { $h += 20 }
        foreach ($o in $script:Others) {
            $h += 20
            $h += if ($o.Err) { 30 } else { @($o.Rows).Count * 30 }
        }
        $h += 4
    }
    return $h
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
        $shown = if ($Settings.ShowRemaining) { $left } else { [math]::Min(100, $t.Used) }
        $text = if ($shown -ge 100) { if ($Settings.ShowRemaining) { '99' } else { '!' } } else { [string][int][math]::Floor($shown) }
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
            '{0}: {1}' -f $lbl, (Format-Pct $r)
        }
        $tip = 'Claude  ' + ($parts -join ' | ')
        if ($script:LastErr) { $tip = '[stale] ' + $tip }
    } else {
        $tip = 'Claude usage: ' + $script:LastErr
    }
    if ($tip.Length -gt 127) { $tip = $tip.Substring(0, 124) + '...' }
    $tray.Text = $tip

    $overlay.Height = Get-OverlayHeight
    # Grow upwards if the taller overlay would run off the bottom of its screen.
    $scr = [System.Windows.Forms.Screen]::FromControl($overlay).WorkingArea
    if ($overlay.Bottom -gt $scr.Bottom) { $overlay.Top = [math]::Max($scr.Top, $scr.Bottom - $overlay.Height - 8) }
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
$miShowAll = $menu.Items.Add('Show all accounts')
$miShowAll.Checked = [bool]$Settings.ShowAll
$miRemain  = $menu.Items.Add('Show remaining instead of used')
$miRemain.CheckOnClick = $true
$miRemain.Checked = [bool]$Settings.ShowRemaining
$miRemain.Add_CheckedChanged({ $Settings.ShowRemaining = $miRemain.Checked; Save-Settings; Update-Ui })
$menu.Items.Add('-') | Out-Null

# Auto-switch submenu
$miAuto = New-Object System.Windows.Forms.ToolStripMenuItem 'Auto-switch'
$menu.Items.Add($miAuto) | Out-Null
$miAutoOn = New-Object System.Windows.Forms.ToolStripMenuItem 'Enabled'
$miAutoOn.CheckOnClick = $true
$miAutoOn.Checked = [bool]$Settings.AutoSwitch
$miAutoOn.Add_CheckedChanged({
    $Settings.AutoSwitch = $miAutoOn.Checked; Save-Settings
    $script:AutoCooldownUntil = [datetime]::MinValue
    Update-Usage
})
$miAuto.DropDownItems.Add($miAutoOn) | Out-Null
$miAuto.DropDownItems.Add('-') | Out-Null

function Add-RadioGroup($parent, [string]$heading, [int[]]$values, [string]$fmt, [string]$key) {
    $h = $parent.DropDownItems.Add($heading); $h.Enabled = $false
    $items = @()
    foreach ($v in $values) {
        $it = New-Object System.Windows.Forms.ToolStripMenuItem ($fmt -f $v)
        $it.Tag = @{ Key = $key; Value = $v }
        $it.Checked = ([int]$Settings[$key] -eq $v)
        $parent.DropDownItems.Add($it) | Out-Null
        $items += $it
    }
    foreach ($it in $items) {
        $it.Add_Click({
            param($s, $e)
            $Settings[$s.Tag.Key] = $s.Tag.Value; Save-Settings
            foreach ($sib in $s.Owner.Items) {
                if ($sib.Tag -is [hashtable] -and $sib.Tag.Key -eq $s.Tag.Key) { $sib.Checked = ($sib -eq $s) }
            }
            if ($s.Tag.Key -eq 'AutoSwitchMinLeft' -and $script:Others) {
                $script:Others = Sort-SwitchCandidates $script:Others ([double]$Settings.AutoSwitchMinLeft)
            }
            Update-Ui
        })
    }
}
Add-RadioGroup $miAuto 'Switch when any limit reaches' @(90, 95, 99, 100) '   {0}% used' 'AutoSwitchAt'
$miAuto.DropDownItems.Add('-') | Out-Null
Add-RadioGroup $miAuto 'Only to accounts with at least' @(5, 10, 20, 30, 50) '   {0}% left on every limit' 'AutoSwitchMinLeft'

$miAccount = New-Object System.Windows.Forms.ToolStripMenuItem 'Account'
$menu.Items.Add($miAccount) | Out-Null
$miAccount.DropDownItems.Add('(loading)') | Out-Null   # placeholder so the arrow shows
$menu.Items.Add('-') | Out-Null
$miExit = $menu.Items.Add('Exit')

# Sign-in is interactive (browser + console), so run claude-profile add in its own
# window. It logs in to a temporary config dir, so the active account is untouched,
# then asks whether to switch. We refresh once that window closes.
function Start-AddAccount {
    if ($script:AddProc -and -not $script:AddProc.HasExited) { return }
    $cmd = "try { & '$ProfileCli' add } catch { Write-Host `$_.Exception.Message -ForegroundColor Red }; Read-Host 'Press Enter to close'"
    $script:AddProc = Start-Process powershell.exe -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd
    $addWatch.Start()
}

function Set-ShowAll([bool]$on) {
    $Settings.ShowAll = $on
    $miShowAll.Checked = $on
    Save-Settings
    if ($on) { Update-OtherAccounts } else { $script:Others = @() }
    Update-Ui
}

function Invoke-SwitchAccount($id) {
    try {
        $p = Switch-ClaudeProfile $id
        # Respect a manual choice: auto-switch won't override it for 5 minutes.
        $script:AutoCooldownUntil = (Get-Date).AddMinutes(5)
        Update-Usage
        $tray.ShowBalloonTip(4000, 'Claude account switched', "Now using $($p.Name). Restart any running Claude Code sessions.", 'Info')
    } catch {
        $tray.ShowBalloonTip(5000, 'Switch failed', $_.Exception.Message, 'Error')
    }
}

# Rebuild the account list every time the submenu opens.
$miAccount.Add_DropDownOpening({
    $miAccount.DropDownItems.Clear()
    try { Sync-ActiveProfile | Out-Null } catch {}
    $profiles = Get-ClaudeProfiles
    if (-not $profiles) { $x = $miAccount.DropDownItems.Add('(no saved accounts)'); $x.Enabled = $false }
    # Active account first, bold, marked.
    foreach ($p in @($profiles | Sort-Object @{ e = { -not $_.Active } }, Name)) {
        $label = if ($p.Active) { "$($p.Name)   (active)" } else { $p.Name }
        $item = New-Object System.Windows.Forms.ToolStripMenuItem $label
        $item.Checked = $p.Active
        if ($p.Active) { $item.Font = New-Object System.Drawing.Font($item.Font, [System.Drawing.FontStyle]::Bold) }
        $item.Tag = $p.Id
        $item.Add_Click({ param($s, $e) Invoke-SwitchAccount $s.Tag })
        $miAccount.DropDownItems.Add($item) | Out-Null
    }
    $miAccount.DropDownItems.Add('-') | Out-Null

    $add = $miAccount.DropDownItems.Add('Add account (without switching)...')
    $add.Add_Click({ Start-AddAccount })

    $ren = $miAccount.DropDownItems.Add('Rename current account...')
    $ren.Add_Click({
        Add-Type -AssemblyName Microsoft.VisualBasic
        $cur = Get-ClaudeProfiles | Where-Object Active | Select-Object -First 1
        if (-not $cur) { return }
        $new = [Microsoft.VisualBasic.Interaction]::InputBox('Display name for this account:', 'Rename account', $cur.Name)
        if ($new) { Rename-ClaudeProfile $cur.Id $new; $script:ActiveName = $new; $overlay.Invalidate() }
    })

    $folder = $miAccount.DropDownItems.Add('Open profiles folder')
    $folder.Add_Click({ if (-not (Test-Path $script:ProfilesDir)) { New-Item -ItemType Directory -Force $script:ProfilesDir | Out-Null }; Start-Process explorer.exe $script:ProfilesDir })
})
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
$btnBr   = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(55, 55, 64))
$btnOnBr = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(70, 95, 160))
$accentBr   = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(110, 155, 255))
$activeBgBr = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(38, 42, 56))
$fontTag    = New-Object System.Drawing.Font('Segoe UI', 6.75, [System.Drawing.FontStyle]::Bold)

$overlay.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'ClearTypeGridFit'
    $w = $overlay.ClientSize.Width

    $tf = New-Object System.Drawing.StringFormat
    $tf.Trimming = 'EllipsisCharacter'; $tf.FormatFlags = 'NoWrap'
    $cf = New-Object System.Drawing.StringFormat
    $cf.Alignment = 'Center'; $cf.LineAlignment = 'Center'

    # ---- Active account block: always on top, tinted panel + accent stripe ----
    $activeH = 44 + [math]::Max(1, @($script:Rows).Count) * 34 - 4
    $g.FillRectangle($activeBgBr, 0, 0, $w, $activeH)
    $g.FillRectangle($accentBr, 0, 0, 3, $activeH)

    # Row 1: ACTIVE [AUTO] ... [time] [All] [+]
    $script:BtnAdd = New-Object System.Drawing.Rectangle(($w - 26), 5, 20, 17)
    $script:BtnAll = New-Object System.Drawing.Rectangle(($w - 56), 5, 27, 17)
    $allBg = if ($Settings.ShowAll) { $btnOnBr } else { $btnBr }
    $g.FillRectangle($allBg, $script:BtnAll)
    $g.DrawString('All', $fontSmall, $fgMain, [System.Drawing.RectangleF]$script:BtnAll, $cf)
    $g.FillRectangle($btnBr, $script:BtnAdd)
    $g.DrawString('+', $fontTitle, $fgMain, [System.Drawing.RectangleF]$script:BtnAdd, $cf)

    $g.DrawString('ACTIVE', $fontTag, $accentBr, 10, 8)
    if ($Settings.AutoSwitch) {
        $tag = 'AUTO @ {0}%' -f $Settings.AutoSwitchAt
        $g.DrawString($tag, $fontTag, $fgDim, 58, 8)
    }
    $status = if ($script:LastErr) { 'stale' } elseif ($script:LastOk) { $script:LastOk.ToString('HH:mm') } else { '...' }
    $sz = $g.MeasureString($status, $fontSmall)
    $g.DrawString($status, $fontSmall, $fgDim, ($w - 60 - $sz.Width), 8)

    # Row 2: account name, full width
    $title = if ($script:ActiveName) { $script:ActiveName } else { 'Claude usage' }
    $g.DrawString($title, $fontTitle, $fgMain, (New-Object System.Drawing.RectangleF(10, 24, ($w - 18), 16)), $tf)

    $y = 44
    if (-not $script:Rows) {
        $msg = if ($script:LastErr) { $script:LastErr } else { 'Loading...' }
        $g.DrawString($msg, $fontSmall, $fgDim, (New-Object System.Drawing.RectangleF(10, $y, ($w - 20), 30)))
        $y += 34
    }
    foreach ($r in $script:Rows) { Draw-UsageRow $g $r $y $w 18 $false; $y += 34 }

    # ---- Other accounts: plain, dimmed, in auto-switch priority order ----
    $script:SwitchRects = @()
    if ($Settings.ShowAll) {
        $y += 6
        if (-not $script:Others) {
            $g.DrawString('No other saved accounts. Click + to add one.', $fontSmall, $fgDim, 10, $y)
        }
        $first = $true
        foreach ($o in $script:Others) {
            $link = New-Object System.Drawing.Rectangle(($w - 50), $y, 42, 16)
            $script:SwitchRects += @{ Rect = $link; Id = $o.Id }
            $g.DrawString('Switch', $fontSmall, $accentBr, [System.Drawing.RectangleF]$link, $cf)
            $nameW = $w - 64
            if ($first -and $o.Eligible -and $Settings.AutoSwitch) {
                $g.DrawString('NEXT', $fontTag, $accentBr, ($w - 82), ($y + 2))
                $nameW = $w - 96
            }
            $g.DrawString($o.Name, $fontRow, $fgDim, (New-Object System.Drawing.RectangleF(10, $y, $nameW, 16)), $tf)
            $first = $false
            $y += 20
            if ($o.Err) {
                $g.DrawString($o.Err, $fontSmall, $fgDim, (New-Object System.Drawing.RectangleF(10, $y, ($w - 20), 28)))
                $y += 30
            } else {
                foreach ($r in $o.Rows) { Draw-UsageRow $g $r $y $w 16 $true; $y += 30 }
            }
        }
    }
    $tf.Dispose(); $cf.Dispose()
})

function Draw-UsageRow($g, $r, [int]$y, [int]$w, [int]$barOffset, [bool]$dim) {
    $left = [math]::Max(0, [math]::Min(100, 100 - $r.Used))
    $fillPct = if ($Settings.ShowRemaining) { $left } else { 100 - $left }
    $labelBr = if ($dim) { $fgDim } else { $fgMain }
    $g.DrawString($r.Label, $fontRow, $labelBr, 10, $y)
    $right = '{0} - {1}' -f (Format-Pct $r), (Format-Until $r.Resets)
    $sz = $g.MeasureString($right, $fontSmall)
    $g.DrawString($right, $fontSmall, $fgDim, ($w - $sz.Width - 8), ($y + 1))
    $barW = $w - 20
    $g.FillRectangle($trackBr, 10, ($y + $barOffset), $barW, 6)
    $c = Get-LevelColor $left
    if ($dim) { $c = [System.Drawing.Color]::FromArgb(140, $c) }
    $fill = New-Object System.Drawing.SolidBrush $c
    $g.FillRectangle($fill, 10, ($y + $barOffset), [float]($barW * $fillPct / 100), 6)
    $fill.Dispose()
}

# drag to move
$overlay.Add_MouseDown({
    param($s, $e)
    if ($e.Button -eq 'Left') {
        if ($script:BtnAll.Contains($e.Location)) { Set-ShowAll (-not $Settings.ShowAll); return }
        if ($script:BtnAdd.Contains($e.Location)) { Start-AddAccount; return }
        foreach ($sr in $script:SwitchRects) {
            if ($sr.Rect.Contains($e.Location)) { Invoke-SwitchAccount $sr.Id; return }
        }
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
$miShowAll.Add_Click({ Set-ShowAll (-not $Settings.ShowAll) })
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

# Profiles folder + active account fingerprint. Changes when an account is added,
# removed, or switched - from the tray, the CLI, or anywhere else.
function Get-ProfilesSignature {
    $ids = if (Test-Path $script:ProfilesDir) { (Get-ChildItem $script:ProfilesDir -Directory | ForEach-Object Name) -join ',' } else { '' }
    $active = try { (Get-ActiveAccount).Id } catch { '' }
    return "$ids|$active"
}
function Test-ProfilesChanged {
    $sig = Get-ProfilesSignature
    if ($sig -eq $script:ProfSig) { return $false }
    $script:ProfSig = $sig
    return $true
}
$script:ProfSig = Get-ProfilesSignature

# While the add-account console is open, watch closely so the new account shows up
# as soon as it's saved (not when the window is closed).
$addWatch = New-Object System.Windows.Forms.Timer
$addWatch.Interval = 1500
$addWatch.Add_Tick({
    $done = (-not $script:AddProc -or $script:AddProc.HasExited)
    if ($done) { $addWatch.Stop() }
    if ((Test-ProfilesChanged) -or $done) {
        if (-not $Settings.ShowAll) { Set-ShowAll $true } else { Update-Usage }
    }
})

# Every 30s: repaint countdowns, and pick up accounts added/switched elsewhere.
$tickTimer = New-Object System.Windows.Forms.Timer
$tickTimer.Interval = 30000
$tickTimer.Add_Tick({
    if (Test-ProfilesChanged) { Update-Usage } else { $overlay.Invalidate() }
})

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
