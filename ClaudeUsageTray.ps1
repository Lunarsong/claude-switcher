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
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
'@

# Draw at the screen's real resolution instead of letting Windows stretch a
# 96-DPI bitmap (blurry text on scaled displays). Must happen before any window
# exists. Layout is written in 96-DPI units and scaled by $UiScale.
[Native.Win32]::SetProcessDPIAware() | Out-Null
$UiScale = 1.0
try { $sg = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $UiScale = $sg.DpiX / 96.0; $sg.Dispose() } catch {}

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

$Settings = [ordered]@{
    ShowOverlay       = $true; X = -1; Y = -1; Opacity = 0.92
    ActiveIntervalSec = 120   # how often the active account is checked (drives auto-switch); the endpoint is rate-limited
    OthersIntervalMin = 10    # how often other accounts are checked while "All" is on
}
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
if ($null -eq $Settings.AutoSwitchMinSession) { $Settings.AutoSwitchMinSession = 10 }   # target's 5h session needs >= this % left
if ($null -eq $Settings.AutoSwitchMinWeekly)  { $Settings.AutoSwitchMinWeekly = 0 }     # target's weekly limits need >= this % left (0 = any)
if ($null -eq $Settings.AutoSwitchPrefer)     { $Settings.AutoSwitchPrefer = 'reset' }  # 'reset' | 'room'
if ($Settings.Contains('AutoSwitchMinLeft'))  { $Settings.Remove('AutoSwitchMinLeft') }  # replaced by the two above
function Get-SwitchRules {
    New-SwitchRules $Settings.AutoSwitchAt $Settings.AutoSwitchMinSession $Settings.AutoSwitchMinWeekly $Settings.AutoSwitchPrefer
}
if ($Settings.Contains('IntervalSec')) { $Settings.Remove('IntervalSec') }  # replaced by ActiveIntervalSec
$script:OthersFetchedAt   = [datetime]::MinValue
$script:BackoffUntil      = [datetime]::MinValue
$script:BackoffSec        = 0
$script:Mismatch          = $false
$script:MismatchNotified  = $false
$script:AutoCooldownUntil = [datetime]::MinValue
$script:AutoNotified      = $false
$script:SwitchRects       = @()   # clickable account names in the overlay: @{ Rect; Id }
if ($null -eq $Settings.NotifyAt)    { $Settings.NotifyAt = 80 }      # warn when a limit reaches this % (0 = off)
if ($null -eq $Settings.NotifyReset) { $Settings.NotifyReset = $true } # tell me when a limit resets
$script:NoticeStates      = @{}   # per account id: state for Get-UsageNotices

function Show-UsageNotices {
    if (-not $script:Rows -or -not $script:LastAcct) { return }
    $id = $script:LastAcct.Id
    if (-not $script:NoticeStates.ContainsKey($id)) { $script:NoticeStates[$id] = @{} }
    $n = Get-UsageNotices $script:Rows $script:NoticeStates[$id] ([double]$Settings.NotifyAt) ([bool]$Settings.NotifyReset)
    if (-not $n) { return }
    # Windows shows one balloon at a time, so combine them.
    $lines = foreach ($x in $n) {
        if ($x.Kind -eq 'warn') {
            '{0} is at {1}% used (resets in {2}).' -f $x.Row.Label, [int]$x.Row.Used, (Format-Until $x.Row.Resets)
        } else {
            '{0} has reset ({1}% used now).' -f $x.Row.Label, [int]$x.Row.Used
        }
    }
    $title = if (@($n | Where-Object { $_.Kind -eq 'warn' })) { "Claude usage: $($script:ActiveName)" } else { 'Claude limit reset' }
    $icon = if (@($n | Where-Object { $_.Kind -eq 'warn' })) { 'Warning' } else { 'Info' }
    $tray.ShowBalloonTip(8000, $title, ($lines -join "`n"), $icon)
}
$script:SwitchedAt        = $null # when we last switched (to spot sessions still on the old login)
$script:SwitchedFrom      = $null
$script:OldSessions       = 0

# Call right after a switch; returns how many Claude Code sessions are still on the old login.
function Register-Switch([string]$fromName) {
    $script:SwitchedAt = Get-Date
    $script:SwitchedFrom = $fromName
    Update-OldSessions
    return $script:OldSessions
}
function Update-OldSessions {
    if (-not $script:SwitchedAt) { $script:OldSessions = 0; return }
    $script:OldSessions = @(Get-ClaudeCodeProcesses $script:SwitchedAt).Count
    if ($script:OldSessions -eq 0) { $script:SwitchedAt = $null }   # all restarted: done
}
function Format-OldSessions([int]$n, [string]$from) {
    if ($n -le 0) { return '' }
    $s = if ($n -eq 1) { 'session is' } else { 'sessions are' }
    return (' {0} running Claude Code {1} still on {2}; restart them to use the new account.' -f $n, $s, $from)
}
# Header grows a line while old sessions are still running.
function Get-HeaderH { if ($script:OldSessions -gt 0) { 60 } else { 44 } }

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

# ---------- rate-limit backoff (persisted, so restarting doesn't reset it) ----------
$StatePath = Join-Path $SettingsDir 'state.json'
try {
    if (Test-Path $StatePath) {
        $st = Get-Content $StatePath -Raw | ConvertFrom-Json
        $script:BackoffSec   = [int]$st.BackoffSec
        $script:BackoffUntil = [datetime]::Parse($st.BackoffUntil, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
    }
} catch {}
function Save-State {
    try {
        @{ BackoffSec = $script:BackoffSec; BackoffUntil = $script:BackoffUntil.ToUniversalTime().ToString('o') } |
            ConvertTo-Json | Set-Content $StatePath -Encoding UTF8
    } catch {}
}
function Start-Backoff([int]$retryAfter) {
    $next = if ($script:BackoffSec -gt 0) { $script:BackoffSec * 2 } else { 120 }
    $script:BackoffSec = [math]::Min(900, [math]::Max($retryAfter, $next))
    $script:BackoffUntil = (Get-Date).AddSeconds($script:BackoffSec)
    Save-State
}
function Clear-Backoff {
    if ($script:BackoffSec -ne 0) { $script:BackoffSec = 0; Save-State }
}
function Get-BackoffMessage { 'Rate limited - retrying at {0}' -f $script:BackoffUntil.ToString('HH:mm') }
function Test-Paused { (Get-Date) -lt $script:BackoffUntil }
function Test-Stale  { [bool]($script:LastErr -or (Test-Paused)) }
# What to say when there are no numbers to show.
function Get-StatusMessage {
    if (Test-Paused) { return (Get-BackoffMessage) }
    if ($script:LastErr) { return $script:LastErr }
    return 'Loading...'
}

# ---------- background worker ----------
# All network calls run in a separate runspace so the overlay never freezes.
# One request at a time; the UI thread applies results and makes all decisions.
$script:WorkerRs = [runspacefactory]::CreateRunspace()
$script:WorkerRs.Open()
$init = [powershell]::Create(); $init.Runspace = $script:WorkerRs
$init.AddScript(". '$((Join-Path $PSScriptRoot 'ClaudeProfiles.ps1') -replace "'", "''")'").Invoke() | Out-Null
$init.Dispose()

$FetchScript = {
    param([bool]$WantOthers, [string]$CredPath)
    $out = @{ Acct = $null; Profiles = @(); Rows = $null; Err = $null
              RateLimited = $false; RetryAfter = 0; Others = $null; OthersRateLimited = $false }
    try {
        # Identity comes from the tokens themselves (checked with Anthropic) - see Get-ActiveAccount.
        $acct = Get-ActiveAccount
        Sync-ActiveProfile $null $acct | Out-Null   # keep the active profile's tokens current
        $out.Acct = $acct
        $out.Profiles = @(Get-ClaudeProfiles $acct)
    } catch {}
    try {
        if (-not (Test-Path $CredPath)) { throw "No Claude Code login found. Run 'claude' and log in." }
        $token = ((New-JsonSerializer).DeserializeObject([IO.File]::ReadAllText($CredPath)))['claudeAiOauth']['accessToken']
        if (-not $token) { throw "No login token found. Run 'claude' and log in." }
        $out.Rows = Get-UsageRows $token
    } catch {
        if ($_.Exception.Data['RateLimited']) {
            $out.RateLimited = $true; $out.RetryAfter = [int]$_.Exception.Data['RetryAfter']
            return $out
        }
        $out.Err = $_.Exception.Message
    }
    if ($WantOthers) {
        $list = @()
        foreach ($p in ($out.Profiles | Where-Object { -not $_.Active })) {
            $entry = @{ Id = $p.Id; Name = $p.Name; Rows = @(); Err = $null; Eligible = $false; Reason = $null }
            try { $entry.Rows = Get-UsageRows (Get-ProfileAccessToken $p) } catch {
                if ($_.Exception.Data['RateLimited']) {
                    $out.OthersRateLimited = $true; $out.RetryAfter = [int]$_.Exception.Data['RetryAfter']
                    break
                }
                $entry.Err = $_.Exception.Message
            }
            $list += $entry
        }
        if (-not $out.OthersRateLimited) { $out.Others = $list }
    }
    return $out
}

$script:Job          = $null    # @{ PS; Handle; WantOthers }
$script:QueuedOthers = $null    # $null = nothing queued, else [bool] whether others are wanted
$script:LastAcct     = $null    # last Get-ActiveAccount result from the worker

function Test-OthersDue {
    ((Get-Date) - $script:OthersFetchedAt).TotalMinutes -ge [double]$Settings.OthersIntervalMin
}

# Ask for fresh numbers. -Full also re-checks other accounts now.
function Update-Usage([switch]$Full) {
    $wantOthers = [bool]($Settings.ShowAll -and ($Full -or (Test-OthersDue)))
    if ($Full -and $Settings.AutoSwitch) { $wantOthers = $true }
    Request-Refresh $wantOthers
}

function Request-Refresh([bool]$WantOthers) {
    if ((Get-Date) -lt $script:BackoffUntil) { Update-Ui; return }   # rate limited: stay off the network
    if ($script:Job) {
        # Busy: remember to run again afterwards (merging "others" requests).
        $script:QueuedOthers = [bool]($WantOthers -or $script:QueuedOthers)
        return
    }
    $ps = [powershell]::Create(); $ps.Runspace = $script:WorkerRs
    $ps.AddScript($FetchScript).AddArgument($WantOthers).AddArgument($CredPath) | Out-Null
    $script:Job = @{ PS = $ps; Handle = $ps.BeginInvoke(); WantOthers = $WantOthers }
    $jobWatch.Start()
}

# Runs on the UI thread when the worker finishes.
function Complete-Refresh {
    $job = $script:Job
    $r = $null
    try {
        $res = $job.PS.EndInvoke($job.Handle)
        if ($res -and $res.Count) { $r = $res[0] }
    } catch {
        $script:LastErr = $_.Exception.Message
    } finally {
        $job.PS.Dispose()
        $script:Job = $null
    }
    if ($r) { Apply-Result $r }

    if ($null -ne $script:QueuedOthers) {
        $q = $script:QueuedOthers; $script:QueuedOthers = $null
        Request-Refresh $q
    }
}

function Apply-Result($r) {
    if ($r.Acct) {
        $script:LastAcct = $r.Acct
        $script:ActiveName = ($r.Profiles | Where-Object Active | Select-Object -First 1).Name
        $script:Mismatch = [bool]$r.Acct.Mismatch
        if ($script:Mismatch) {
            $cfgName = ($r.Profiles | Where-Object Id -eq $r.Acct.ConfigId | Select-Object -First 1).Name
            if (-not $cfgName) { $cfgName = $r.Acct.Email }
            if (-not $script:ActiveName) { $script:ActiveName = 'Unknown account' }
            if (-not $script:MismatchNotified) {
                $tray.ShowBalloonTip(10000, 'Claude login was overwritten',
                    ("A Claude Code session still running on {0} rewrote the login after you switched to {1}. New sessions will use {0}. Close running Claude Code sessions, then switch again. Auto-switch is paused until this is fixed." -f $script:ActiveName, $cfgName), 'Warning')
                $script:MismatchNotified = $true
            }
        } else { $script:MismatchNotified = $false }
        $script:ProfSig = Get-ProfilesSignature
    }

    if ($r.RateLimited) {
        # Keep showing the last numbers; wait (server hint, else doubling from 2 min, max 15 min).
        Start-Backoff $r.RetryAfter
        Set-OtherPlaceholders $r.Profiles
        Update-Ui
        return
    }
    if ($r.Err) { $script:LastErr = $r.Err } else {
        $script:Rows = $r.Rows; $script:LastErr = $null; $script:LastOk = Get-Date
        Clear-Backoff
        if (-not $script:Mismatch) { Show-UsageNotices }
    }

    $othersFresh = $false
    if ($null -ne $r.Others) {
        $script:Others = Sort-SwitchCandidates @($r.Others) (Get-SwitchRules)
        $script:OthersFetchedAt = Get-Date
        $othersFresh = $true
    } elseif ($r.OthersRateLimited) {
        Start-Backoff $r.RetryAfter     # keep previous numbers; OthersFetchedAt untouched so they're retried
    }
    Set-OtherPlaceholders $r.Profiles

    Invoke-AutoSwitch $othersFresh
    Update-Ui
}

# Saved accounts we haven't been able to check yet still get listed (by name),
# and accounts that were removed disappear.
function Set-OtherPlaceholders($profiles) {
    $inactive = @($profiles | Where-Object { -not $_.Active })
    if (-not $inactive) { if ($profiles) { $script:Others = @() }; return }
    $byId = @{}; foreach ($o in @($script:Others)) { $byId[$o.Id] = $o }
    $list = foreach ($p in $inactive) {
        if ($byId.ContainsKey($p.Id)) { $o = $byId[$p.Id]; $o.Name = $p.Name; $o; continue }   # keep numbers, pick up renames
        @{ Id = $p.Id; Name = $p.Name; Rows = @(); Err = 'Not checked yet'; Pending = $true; Eligible = $false; Reason = $null }
    }
    $script:Others = Sort-SwitchCandidates @($list) (Get-SwitchRules)
}

# Decides on the UI thread; asks the worker for fresh numbers when it needs them.
function Invoke-AutoSwitch([bool]$OthersFresh) {
    if (-not $Settings.AutoSwitch -or $script:LastErr -or -not $script:Rows) { return }
    if ($script:Mismatch) { return }   # login files disagree: don't make it worse
    $used = Get-MaxUsed $script:Rows
    if ($used -lt [double]$Settings.AutoSwitchAt) { $script:AutoNotified = $false; return }
    if ((Get-Date) -lt $script:AutoCooldownUntil) { return }

    # Choose from fresh numbers. If we already found nobody qualifies, don't
    # re-check every account each minute - wait for their normal schedule.
    if (-not $OthersFresh -and (-not $script:AutoNotified -or (Test-OthersDue))) { Request-Refresh $true; return }
    $target = Select-AutoSwitchTarget $script:Others (Get-SwitchRules)
    if (-not $target) {
        if (-not $script:AutoNotified) {
            $why = ($script:Others | ForEach-Object { '{0}: {1}' -f $_.Name, $_.Reason }) -join '; '
            if (-not $why) { $why = 'no other saved accounts' }
            $tray.ShowBalloonTip(6000, 'Claude auto-switch',
                ("Current account is at {0}% but no other account qualifies ({1})." -f [int]$used, $why), 'Warning')
            $script:AutoNotified = $true
        }
        return
    }

    $from = $script:ActiveName
    try { Switch-ClaudeProfile $target.Id | Out-Null } catch {
        $tray.ShowBalloonTip(6000, 'Claude auto-switch failed', $_.Exception.Message, 'Error'); return
    }
    # Targets are never "full", so ping-pong can't happen; a short guard just
    # covers stale numbers. Kept short so a nearly-spent account can hand off fast.
    $script:AutoCooldownUntil = (Get-Date).AddMinutes(1)
    $script:AutoNotified = $false
    $old = Register-Switch $from
    $script:ActiveName = $target.Name
    $tray.ShowBalloonTip(8000, 'Claude auto-switched account',
        (("{0} reached {1}% used. New Claude Code sessions will use {2}." -f $from, [int]$used, $target.Name) + (Format-OldSessions $old $from)), 'Info')
    Request-Refresh $true
}

function Get-OverlayHeight {
    $h = (Get-HeaderH) + [math]::Max(1, @($script:Rows).Count) * 34
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
    if (-not $t) {
        # No numbers yet: grey "!" on error/rate limit, grey "-" while loading.
        $bg = [System.Drawing.Color]::FromArgb(110, 110, 110)
        $text = if (Test-Stale) { '!' } else { '-' }
    } else {
        $left = [math]::Max(0, 100 - $t.Used)
        $bg = Get-LevelColor $left
        $shown = if ($Settings.ShowRemaining) { $left } else { [math]::Min(100, $t.Used) }
        $text = if ($shown -ge 100) { if ($Settings.ShowRemaining) { '99' } else { '!' } } else { [string][int][math]::Floor($shown) }
        if (Test-Stale) { $bg = [System.Drawing.Color]::FromArgb(110, 110, 110) }  # stale
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

    # Tooltip: Windows (.NET Framework) allows at most 63 characters.
    if ($script:Rows) {
        $parts = foreach ($r in $script:Rows) {
            $lbl = $r.Label -replace '^Session \(5h\)$', '5h' -replace '^Weekly$', 'Wk' -replace '^Weekly ', ''
            $pct = if ($Settings.ShowRemaining) { 100 - $r.Used } else { $r.Used }
            '{0} {1}%' -f $lbl, [int][math]::Max(0, [math]::Min(100, $pct))
        }
        $kind = if ($Settings.ShowRemaining) { 'left' } else { 'used' }
        $tip = "Claude ${kind}: " + ($parts -join ', ')
        if (Test-Stale) { $tip = '(stale) ' + $tip }
    } else {
        $tip = 'Claude: ' + (Get-StatusMessage)
    }
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 60) + '...' }
    $tray.Text = $tip

    $overlay.Height = [int]((Get-OverlayHeight) * $UiScale)
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

# $options: array of @(value, label). Clicking one stores the value under $key.
function Add-RadioGroup($parent, [string]$heading, $options, [string]$key) {
    $h = $parent.DropDownItems.Add($heading); $h.Enabled = $false
    $items = @()
    foreach ($opt in $options) {
        $it = New-Object System.Windows.Forms.ToolStripMenuItem ('   ' + $opt[1])
        $it.Tag = @{ Key = $key; Value = $opt[0] }
        $it.Checked = ([string]$Settings[$key] -eq [string]$opt[0])
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
            if ($s.Tag.Key -eq 'ActiveIntervalSec') { $timer.Interval = [int]$s.Tag.Value * 1000 }
            # Re-rank with the new rules so NEXT / reasons update immediately.
            if ($script:Others) { $script:Others = Sort-SwitchCandidates $script:Others (Get-SwitchRules) }
            Update-Ui
        })
    }
}
Add-RadioGroup $miAuto 'Switch away when any limit reaches' @(@(90, '90% used'), @(95, '95% used'), @(99, '99% used'), @(100, '100% used')) 'AutoSwitchAt'
$miAuto.DropDownItems.Add('-') | Out-Null
Add-RadioGroup $miAuto 'Target needs session (5h) left' @(@(0, 'Any (just not full)'), @(5, '5%'), @(10, '10%'), @(25, '25%'), @(50, '50%')) 'AutoSwitchMinSession'
$miAuto.DropDownItems.Add('-') | Out-Null
Add-RadioGroup $miAuto 'Target needs weekly left' @(@(0, 'Any (just not full)'), @(5, '5%'), @(10, '10%'), @(25, '25%')) 'AutoSwitchMinWeekly'
$miAuto.DropDownItems.Add('-') | Out-Null
Add-RadioGroup $miAuto 'Prefer' @(@('reset', 'Soonest weekly reset (use it before it expires)'), @('room', 'Most weekly room left')) 'AutoSwitchPrefer'

# Refresh-rate submenu (inserted under the main menu's "Refresh now")
$miRate = New-Object System.Windows.Forms.ToolStripMenuItem 'Check usage every'
$menu.Items.Insert(($menu.Items.IndexOf($miRefresh) + 1), $miRate)
Add-RadioGroup $miRate 'Active account (drives auto-switch)' @(@(30, '30 seconds (may hit rate limits)'), @(60, '1 minute'), @(120, '2 minutes'), @(300, '5 minutes')) 'ActiveIntervalSec'
$miRate.DropDownItems.Add('-') | Out-Null
Add-RadioGroup $miRate 'Other accounts (while All is on)' @(@(5, '5 minutes'), @(10, '10 minutes'), @(15, '15 minutes'), @(30, '30 minutes')) 'OthersIntervalMin'
$note = $miRate.DropDownItems.Add('Auto-switch always re-checks them before switching'); $note.Enabled = $false

# Notifications submenu (placed just above Auto-switch)
$miNotify = New-Object System.Windows.Forms.ToolStripMenuItem 'Notifications'
$menu.Items.Insert($menu.Items.IndexOf($miAuto), $miNotify)
Add-RadioGroup $miNotify 'Warn when a limit reaches' @(@(0, 'Off'), @(70, '70% used'), @(80, '80% used'), @(90, '90% used')) 'NotifyAt'
$miNotify.DropDownItems.Add('-') | Out-Null
$miReset = New-Object System.Windows.Forms.ToolStripMenuItem 'Tell me when a limit resets'
$miReset.CheckOnClick = $true
$miReset.Checked = [bool]$Settings.NotifyReset
$miReset.Add_CheckedChanged({ $Settings.NotifyReset = $miReset.Checked; Save-Settings })
$miNotify.DropDownItems.Add($miReset) | Out-Null

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
    if ($on) {
        # List saved accounts by name straight away, then fetch their numbers.
        Set-OtherPlaceholders (Get-ClaudeProfiles (Get-KnownActive))
        Request-Refresh $true
    } else { $script:Others = @() }
    Update-Ui
}

function Invoke-SwitchAccount($id) {
    try {
        $from = $script:ActiveName
        $p = Switch-ClaudeProfile $id
        # Respect a manual choice: auto-switch won't override it for 5 minutes.
        $script:AutoCooldownUntil = (Get-Date).AddMinutes(5)
        $old = Register-Switch $from
        $script:ActiveName = $p.Name    # show it right away; numbers follow from the worker
        $script:Rows = @(); $script:LastAcct = $null
        Update-Usage -Full
        Update-Ui
        $tray.ShowBalloonTip(6000, 'Claude account switched', ("New Claude Code sessions will use $($p.Name)." + (Format-OldSessions $old $from)), 'Info')
    } catch {
        $tray.ShowBalloonTip(5000, 'Switch failed', $_.Exception.Message, 'Error')
    }
}

# Rebuild the account list every time the submenu opens.
$miAccount.Add_DropDownOpening({
    $miAccount.DropDownItems.Clear()
    # The worker keeps profiles in sync; reuse its last identity check (no network here).
    $profiles = Get-ClaudeProfiles (Get-KnownActive)
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
        $cur = Get-ClaudeProfiles (Get-KnownActive) | Where-Object Active | Select-Object -First 1
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
$overlay.Width = [int](250 * $UiScale)
$overlay.Height = [int](100 * $UiScale)
$overlay.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 34)
$overlay.Opacity = [double]$Settings.Opacity
$overlay.Text = 'Claude Usage'
$overlay.ContextMenuStrip = $menu
# double buffering to stop flicker
$overlay.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic').SetValue($overlay, $true, $null)

$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
# Positions saved by older versions were in Windows' stretched (96-DPI) coordinates.
if (-not $Settings.PosPhysical) {
    if ($Settings.X -ge 0 -and $Settings.Y -ge 0) { $Settings.X = [int]($Settings.X * $UiScale); $Settings.Y = [int]($Settings.Y * $UiScale) }
    $Settings.PosPhysical = $true
    Save-Settings
}
$startPos = New-Object System.Drawing.Point(($wa.Right - $overlay.Width - [int](12 * $UiScale)), ($wa.Bottom - [int](140 * $UiScale)))
if ($Settings.X -ge 0 -and $Settings.Y -ge 0) {
    $saved = New-Object System.Drawing.Point([int]$Settings.X, [int]$Settings.Y)
    # Only use the saved spot if it's still on a connected screen.
    $onScreen = [System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.WorkingArea.Contains($saved) }
    if ($onScreen) { $startPos = $saved }
}
$overlay.Location = $startPos

# Pixel-sized fonts so they scale with the drawing transform (8.5pt = 11.33px at 96 DPI).
$px = [System.Drawing.GraphicsUnit]::Pixel
$fontTitle = New-Object System.Drawing.Font('Segoe UI', 11.33, [System.Drawing.FontStyle]::Bold, $px)
$fontRow   = New-Object System.Drawing.Font('Segoe UI', 11.33, [System.Drawing.FontStyle]::Regular, $px)
$fontSmall = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Regular, $px)
$fgMain  = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(235, 235, 240))
$fgDim   = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(150, 150, 160))
$trackBr = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(60, 60, 68))
$btnBr   = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(55, 55, 64))
$btnOnBr = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(70, 95, 160))
$accentBr   = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(110, 155, 255))
$activeBgBr = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(38, 42, 56))
$warnBr     = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(225, 120, 110))
$fontTag    = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold, $px)

$overlay.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'ClearTypeGridFit'
    # Everything below is laid out in 96-DPI units; this scales it to the real screen.
    $g.ScaleTransform([float]$UiScale, [float]$UiScale)
    $w = [int]($overlay.ClientSize.Width / $UiScale)

    $tf = New-Object System.Drawing.StringFormat
    $tf.Trimming = 'EllipsisCharacter'; $tf.FormatFlags = 'NoWrap'
    $ef = New-Object System.Drawing.StringFormat      # wrapped text, cut with "..." at the box edge
    $ef.Trimming = 'EllipsisCharacter'; $ef.FormatFlags = 'LineLimit'
    $cf = New-Object System.Drawing.StringFormat
    $cf.Alignment = 'Center'; $cf.LineAlignment = 'Center'

    # ---- Active account block: always on top, tinted panel + accent stripe ----
    $headerH = Get-HeaderH
    $activeH = $headerH + [math]::Max(1, @($script:Rows).Count) * 34 - 4
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

    if ($script:Mismatch) {
        $g.DrawString('LOGIN OVERWRITTEN - restart Claude Code', $fontTag, $warnBr, 10, 8)
    } else {
        $g.DrawString('ACTIVE', $fontTag, $accentBr, 10, 8)
    }
    if ($Settings.AutoSwitch -and -not $script:Mismatch) {
        $tag = 'AUTO @ {0}%' -f $Settings.AutoSwitchAt
        $g.DrawString($tag, $fontTag, $fgDim, 58, 8)
    }
    $statusBr = $fgDim
    $status = if (Test-Paused) { $statusBr = $warnBr; 'retry ' + $script:BackoffUntil.ToString('HH:mm') }
              elseif ($script:LastErr) { 'stale' }
              elseif ($script:LastOk) { $script:LastOk.ToString('HH:mm') } else { '...' }
    $sz = $g.MeasureString($status, $fontSmall)
    $g.DrawString($status, $fontSmall, $statusBr, ($w - 60 - $sz.Width), 8)

    # Row 2: account name, full width
    $title = if ($script:ActiveName) { $script:ActiveName } else { 'Claude usage' }
    $g.DrawString($title, $fontTitle, $fgMain, (New-Object System.Drawing.RectangleF(10, 24, ($w - 18), 16)), $tf)

    # Row 3 (only after a switch): sessions still running on the old login
    if ($script:OldSessions -gt 0) {
        $s = if ($script:OldSessions -eq 1) { 'session' } else { 'sessions' }
        $msg = '{0} Claude Code {1} still on {2} - restart' -f $script:OldSessions, $s, $script:SwitchedFrom
        $g.DrawString($msg, $fontSmall, $warnBr, (New-Object System.Drawing.RectangleF(10, 41, ($w - 18), 15)), $tf)
    }

    $y = $headerH
    if (-not $script:Rows) {
        $g.DrawString((Get-StatusMessage), $fontSmall, $fgDim, (New-Object System.Drawing.RectangleF(10, $y, ($w - 20), 28)), $ef)
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
            $tag = $null; $tagBr = $accentBr
            if ($Settings.AutoSwitch) {
                if ($first -and $o.Eligible) { $tag = 'NEXT' }
                elseif ($o.Reason) { $tag = $o.Reason; $tagBr = $warnBr }
            }
            if ($tag) {
                $tsz = $g.MeasureString($tag, $fontTag)
                $g.DrawString($tag, $fontTag, $tagBr, ($w - 54 - $tsz.Width), ($y + 2))
                $nameW = $w - 60 - $tsz.Width - 4
            }
            $g.DrawString($o.Name, $fontRow, $fgDim, (New-Object System.Drawing.RectangleF(10, $y, $nameW, 16)), $tf)
            $first = $false
            $y += 20
            if ($o.Err) {
                # Long errors are cut to two lines with "..." instead of spilling into the next account.
                $g.DrawString($o.Err, $fontSmall, $fgDim, (New-Object System.Drawing.RectangleF(10, $y, ($w - 20), 26)), $ef)
                $y += 30
            } else {
                foreach ($r in $o.Rows) { Draw-UsageRow $g $r $y $w 16 $true; $y += 30 }
            }
        }
    }
    $tf.Dispose(); $cf.Dispose(); $ef.Dispose()
})

function Draw-UsageRow($g, $r, [int]$y, [int]$w, [int]$barOffset, [bool]$dim) {
    $left = [math]::Max(0, [math]::Min(100, 100 - $r.Used))
    $fillPct = if ($Settings.ShowRemaining) { $left } else { 100 - $left }
    $labelBr = if ($dim) { $fgDim } else { $fgMain }
    $g.DrawString($r.Label, $fontRow, $labelBr, 10, $y)
    $until = Format-Until $r.Resets
    $right = if ($until) { '{0} - {1}' -f (Format-Pct $r), $until } else { Format-Pct $r }   # unused limits have no reset time
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
        # Button rectangles are in layout units; convert the click from screen pixels.
        $pt = New-Object System.Drawing.Point([int]($e.X / $UiScale), [int]($e.Y / $UiScale))
        if ($script:BtnAll.Contains($pt)) { Set-ShowAll (-not $Settings.ShowAll); return }
        if ($script:BtnAdd.Contains($pt)) { Start-AddAccount; return }
        foreach ($sr in $script:SwitchRects) {
            if ($sr.Rect.Contains($pt)) { Invoke-SwitchAccount $sr.Id; return }
        }
        [Native.Win32]::ReleaseCapture() | Out-Null
        [Native.Win32]::SendMessage($overlay.Handle, 0xA1, 0x2, 0) | Out-Null   # WM_NCLBUTTONDOWN, HTCAPTION
        $Settings.X = $overlay.Left; $Settings.Y = $overlay.Top
        Save-Settings
    }
})
$overlay.Add_MouseDoubleClick({ Update-Usage -Full })

# ---------- menu handlers ----------
$miOverlay.Add_CheckedChanged({
    $Settings.ShowOverlay = $miOverlay.Checked
    $overlay.Visible = $miOverlay.Checked
    Save-Settings
})
$miRefresh.Add_Click({ Update-Usage -Full })
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
$timer.Interval = [math]::Max(30, [int]$Settings.ActiveIntervalSec) * 1000
$timer.Add_Tick({ Update-Usage })

# Profiles folder + active account fingerprint. Changes when an account is added,
# removed, or switched - from the tray, the CLI, or anywhere else.
# No network: profile folder names + when the credentials file last changed
# (it changes on switches, sign-ins and token refreshes).
function Get-ProfilesSignature {
    $ids = if (Test-Path $script:ProfilesDir) { (Get-ChildItem $script:ProfilesDir -Directory | ForEach-Object Name) -join ',' } else { '' }
    $cred = try { (Get-Item $CredPath).LastWriteTimeUtc.Ticks } catch { 0 }
    return "$ids|$cred"
}

# Best-known active account without a network call: the worker's last check,
# else whatever .claude.json says (good enough for listing names).
function Get-KnownActive {
    if ($script:LastAcct) { return $script:LastAcct }
    try {
        $a = (Read-ClaudeConfig)['oauthAccount']
        if ($a) { return [pscustomobject]@{ Id = '{0}_{1}' -f $a['accountUuid'], $a['organizationUuid'] } }
    } catch {}
    return $null
}

# Polls the background worker (cheap; only runs while a check is in flight).
$jobWatch = New-Object System.Windows.Forms.Timer
$jobWatch.Interval = 200
$jobWatch.Add_Tick({
    if (-not $script:Job) { $jobWatch.Stop(); return }
    if ($script:Job.Handle.IsCompleted) {
        $jobWatch.Stop()
        Complete-Refresh
    }
})
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
        if (-not $Settings.ShowAll) { Set-ShowAll $true } else {
            Set-OtherPlaceholders (Get-ClaudeProfiles (Get-KnownActive))
            Update-Usage -Full
        }
    }
})

# Every 30s: repaint countdowns, and pick up accounts added/switched elsewhere.
$tickTimer = New-Object System.Windows.Forms.Timer
$tickTimer.Interval = 30000
$tickTimer.Add_Tick({
    # Still waiting for old Claude Code sessions to be restarted? Re-count (local, cheap).
    if ($script:SwitchedAt) {
        $before = $script:OldSessions
        Update-OldSessions
        if ($script:OldSessions -ne $before) { Update-Ui }   # height may change
    }
    if (Test-ProfilesChanged) {
        if ($Settings.ShowAll) { Set-OtherPlaceholders (Get-ClaudeProfiles (Get-KnownActive)) }
        Update-Usage -Full
    } else { $overlay.Invalidate() }
})

# ---------- go ----------
$overlay.Show()
# When launched hidden (wscript/-WindowStyle Hidden) Windows swallows the first
# ShowWindow call, so force it visible explicitly (SW_SHOWNOACTIVATE = 4).
[Native.Win32]::ShowWindow($overlay.Handle, 4) | Out-Null
if (-not $Settings.ShowOverlay) { $overlay.Hide() }
# Startup runs before the message loop, where WinForms can't catch errors for us.
try {
    # List every saved account by name immediately; numbers arrive from the worker.
    if ($Settings.ShowAll) { Set-OtherPlaceholders (Get-ClaudeProfiles (Get-KnownActive)) }
    $script:ActiveName = (Get-ClaudeProfiles (Get-KnownActive) | Where-Object Active | Select-Object -First 1).Name
    Update-Ui
    Update-Usage -Full
} catch { try { Add-Content $LogPath ("{0}  startup: {1}" -f (Get-Date -Format s), $_.Exception) } catch {} }
$timer.Start(); $tickTimer.Start()

[System.Windows.Forms.Application]::Run()
$mutex.ReleaseMutex()
