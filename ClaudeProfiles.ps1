<#
  ClaudeProfiles.ps1 - dot-source this to get account profile functions.

  Claude Code keeps its login in two places:
    %USERPROFILE%\.claude\.credentials.json   OAuth tokens
    %USERPROFILE%\.claude.json  -> oauthAccount   which account/org is signed in
  A profile is a snapshot of both, stored in %APPDATA%\ClaudeUsageTray\profiles\<id>\.
  Switching = sync the live login back into its own profile (tokens rotate), then
  copy the target profile's snapshot into place.
#>

Add-Type -AssemblyName System.Web.Extensions

$script:ClaudeDir     = Join-Path $env:USERPROFILE '.claude'
$script:CredFile      = Join-Path $script:ClaudeDir '.credentials.json'
$script:ConfigFile    = Join-Path $env:USERPROFILE '.claude.json'
$script:ProfilesDir   = Join-Path $env:APPDATA 'ClaudeUsageTray\profiles'

function New-JsonSerializer {
    $js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $js.MaxJsonLength = [int]::MaxValue
    $js.RecursionLimit = 1000
    return $js
}

# Write text atomically (temp file + replace) so a crash never leaves a half-written file.
function Write-FileAtomic([string]$Path, [string]$Text) {
    $tmp = "$Path.tmp-$PID"
    [IO.File]::WriteAllText($tmp, $Text, (New-Object Text.UTF8Encoding($false)))
    if (Test-Path $Path) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { [IO.File]::Move($tmp, $Path) }
}

function Read-ClaudeConfig {
    # JavaScriptSerializer round-trips arbitrary JSON as dictionaries without
    # PowerShell's ConvertTo-Json depth/array quirks.
    return (New-JsonSerializer).DeserializeObject([IO.File]::ReadAllText($script:ConfigFile))
}

# Which account does an access token really belong to? Asks Anthropic
# (api/oauth/profile) and caches per token, so it's one call per token refresh.
# Returns "<accountUuid>_<orgUuid>" (same as profile ids), or $null if unknown.
$script:TokenIdCache = @{}
function Get-TokenIdentity([string]$Token) {
    if (-not $Token) { return $null }
    if ($script:TokenIdCache.ContainsKey($Token)) { return $script:TokenIdCache[$Token] }
    try {
        $r = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/profile' -TimeoutSec 15 -UseBasicParsing `
            -Headers @{ Authorization = "Bearer $Token"; 'anthropic-beta' = 'oauth-2025-04-20' }
        if (-not $r.account.uuid -or -not $r.organization.uuid) { return $null }
        $id = '{0}_{1}' -f $r.account.uuid, $r.organization.uuid
        if ($script:TokenIdCache.Count -gt 50) { $script:TokenIdCache.Clear() }
        $script:TokenIdCache[$Token] = $id
        return $id
    } catch { return $null }   # offline / expired: unknown, callers must not trust it
}

# The signed-in account. Claude Code keeps the tokens (.credentials.json) and
# the account details (.claude.json oauthAccount) in separate files, and a
# Claude Code session still running on an old account can rewrite the tokens
# after a switch. So the tokens are checked against the server:
#   Id         - who the tokens really belong to (falls back to ConfigId if the check fails)
#   ConfigId   - who .claude.json says is signed in
#   Verified   - the token check succeeded
#   Mismatch   - verified and the two disagree (tokens belong to a different account)
function Get-ActiveAccount {
    if (-not (Test-Path $script:ConfigFile) -or -not (Test-Path $script:CredFile)) { return $null }
    $acct = (Read-ClaudeConfig)['oauthAccount']
    if (-not $acct) { return $null }
    $configId = '{0}_{1}' -f $acct['accountUuid'], $acct['organizationUuid']
    # Read the credentials once; CredText is exactly what was verified, so callers
    # never save a file that changed after the check (e.g. a switch in between).
    $credText = $null; $token = $null
    try {
        $credText = [IO.File]::ReadAllText($script:CredFile)
        $token = ((New-JsonSerializer).DeserializeObject($credText))['claudeAiOauth']['accessToken']
    } catch {}
    $tokenId = Get-TokenIdentity $token
    return [pscustomobject]@{
        Id       = if ($tokenId) { $tokenId } else { $configId }
        ConfigId = $configId
        Verified = [bool]$tokenId
        Mismatch = [bool]($tokenId -and $tokenId -ne $configId)
        Email    = $acct['emailAddress']
        Org      = $acct['organizationName']
        Account  = $acct
        CredText = $credText
    }
}

function Get-ClaudeProfiles($Active = $null) {
    if (-not (Test-Path $script:ProfilesDir)) { return @() }
    $js = New-JsonSerializer
    $active = if ($Active) { $Active } else { Get-ActiveAccount }
    @(Get-ChildItem $script:ProfilesDir -Directory | ForEach-Object {
        $metaPath = Join-Path $_.FullName 'profile.json'
        if (Test-Path $metaPath) {
            $m = $js.DeserializeObject([IO.File]::ReadAllText($metaPath))
            [pscustomobject]@{
                Id     = $_.Name
                Name   = $m['name']
                Email  = $m['email']
                Org    = $m['org']
                Active = [bool]($active -and $active.Id -eq $_.Name)
                Path   = $_.FullName
            }
        }
    } | Sort-Object Name)
}

function Write-IfChanged([string]$Path, [string]$Text) {
    if (-not (Test-Path $Path) -or [IO.File]::ReadAllText($Path) -ne $Text) { Write-FileAtomic $Path $Text }
}

# Store a login (raw credentials JSON + oauthAccount dictionary) as a profile.
function Save-ProfileSnapshot([string]$CredText, $Account, [string]$Name) {
    $id = '{0}_{1}' -f $Account['accountUuid'], $Account['organizationUuid']
    $dir = Join-Path $script:ProfilesDir $id
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }

    $js = New-JsonSerializer
    $metaPath = Join-Path $dir 'profile.json'
    $meta = if (Test-Path $metaPath) { $js.DeserializeObject([IO.File]::ReadAllText($metaPath)) } else { @{} }
    if ($Name) { $meta['name'] = $Name }
    if (-not $meta['name']) {
        $meta['name'] = if ($Account['organizationName']) { '{0} ({1})' -f $Account['emailAddress'], $Account['organizationName'] } else { $Account['emailAddress'] }
    }
    $meta['email'] = $Account['emailAddress']
    $meta['org']   = $Account['organizationName']

    Write-IfChanged (Join-Path $dir 'credentials.json') $CredText
    Write-IfChanged (Join-Path $dir 'oauthAccount.json') ($js.Serialize($Account))
    Write-IfChanged $metaPath ($js.Serialize($meta))
    return $id
}

# Snapshot the currently signed-in account into its profile (creating it if new).
# Called on every tray poll so stored refresh tokens never go stale.
# Only saves tokens once the server has confirmed whose they are, so one
# account's login can never be stored under another account's profile.
function Sync-ActiveProfile([string]$Name, $Active = $null) {
    $active = if ($Active) { $Active } else { Get-ActiveAccount }
    if (-not $active -or -not $active.Verified -or -not $active.CredText) { return $null }
    $cred = $active.CredText
    if (-not $active.Mismatch) { return Save-ProfileSnapshot $cred $active.Account $Name }

    # Tokens belong to a different account than .claude.json says. If we know
    # that account, keep its (possibly just-refreshed) tokens in its own profile.
    $dir = Join-Path $script:ProfilesDir $active.Id
    $acctPath = Join-Path $dir 'oauthAccount.json'
    if (Test-Path $acctPath) {
        $acct = (New-JsonSerializer).DeserializeObject([IO.File]::ReadAllText($acctPath))
        return Save-ProfileSnapshot $cred $acct $null
    }
    return $null
}

# Import a login made in a separate CLAUDE_CONFIG_DIR (see claude-profile add).
# Does not touch the active login.
function Import-ClaudeLoginDir([string]$Dir, [string]$Name) {
    $credPath = Join-Path $Dir '.credentials.json'
    if (-not (Test-Path $credPath)) { throw "No login found in $Dir (sign-in cancelled?)." }
    $cfgPath = @((Join-Path $Dir '.claude.json'), (Join-Path $Dir 'config.json')) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $cfgPath) { $cfgPath = Get-ChildItem $Dir -Filter '*.json' -Recurse -Force | Where-Object { (Get-Content $_.FullName -Raw) -match '"oauthAccount"' } | Select-Object -First 1 -ExpandProperty FullName }
    if (-not $cfgPath) { throw "Signed in, but couldn't find the account details in $Dir." }
    $acct = (New-JsonSerializer).DeserializeObject([IO.File]::ReadAllText($cfgPath))['oauthAccount']
    if (-not $acct) { throw "Signed in, but no oauthAccount in $cfgPath." }
    return Save-ProfileSnapshot ([IO.File]::ReadAllText($credPath)) $acct $Name
}

# ---------- usage for any profile ----------
$script:UsageUrl     = 'https://api.anthropic.com/api/oauth/usage'
$script:TokenUrl     = 'https://platform.claude.com/v1/oauth/token'   # same endpoint/client Claude Code uses
$script:OAuthClient  = '9d1c250a-e61b-44d9-88ed-5944d1962f5e'

# Access token for a profile. The active account always uses the live file
# (Claude Code owns refreshing it). Inactive profiles are refreshed here when
# expired and the rotated tokens are written straight back to the profile.
function Get-ProfileAccessToken($P) {
    $js = New-JsonSerializer
    if ($P.Active) {
        return ($js.DeserializeObject([IO.File]::ReadAllText($script:CredFile)))['claudeAiOauth']['accessToken']
    }
    $credPath = Join-Path $P.Path 'credentials.json'
    $cred = $js.DeserializeObject([IO.File]::ReadAllText($credPath))
    $o = $cred['claudeAiOauth']
    $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if ($o['expiresAt'] -and ([int64]$o['expiresAt'] - $nowMs) -gt 300000) { return $o['accessToken'] }

    $body = @{ grant_type = 'refresh_token'; refresh_token = $o['refreshToken']; client_id = $script:OAuthClient }
    if ($o['scopes']) { $body.scope = (@($o['scopes']) -join ' ') }
    try {
        $r = Invoke-RestMethod -Method Post -Uri $script:TokenUrl -ContentType 'application/json' -Body ($body | ConvertTo-Json) -TimeoutSec 20 -UseBasicParsing
    } catch {
        throw 'Saved login expired and could not be refreshed. Switch to this account in Claude Code (or sign in again).'
    }
    $o['accessToken'] = $r.access_token
    if ($r.refresh_token) { $o['refreshToken'] = $r.refresh_token }
    $o['expiresAt'] = $nowMs + [int64]$r.expires_in * 1000
    # Rotated refresh token: persist immediately or the profile is lost.
    Write-FileAtomic $credPath ($js.Serialize($cred))
    return $o['accessToken']
}

# ---------- auto-switch selection ----------
function Get-MaxUsed($Rows) {
    $m = 0.0
    foreach ($r in @($Rows)) { if ($r.Used -gt $m) { $m = [double]$r.Used } }
    return $m
}

# Soonest weekly reset (fallback: soonest of any limit). Accounts whose weekly
# allowance resets soonest are used first, so that allowance isn't wasted.
function Get-PriorityReset($Rows) {
    $weekly = @($Rows | Where-Object { $_.Label -like 'Weekly*' -and $_.Resets -is [datetime] })
    $pool = if ($weekly) { $weekly } else { @($Rows | Where-Object { $_.Resets -is [datetime] }) }
    if (-not $pool) { return [datetime]::MaxValue }
    return ($pool | ForEach-Object { $_.Resets.ToUniversalTime() } | Sort-Object | Select-Object -First 1)
}

# Switch rules (hashtable):
#   FullAt     - an account is "full" when any limit is at/above this % used.
#                Targets must never be full (else we'd switch straight off them).
#   MinSession - target's session (5h) limit needs at least this % left.
#                A maxed session makes an account useless right now.
#   MinWeekly  - target's weekly limits need at least this % left (0 = any,
#                so a nearly-spent weekly allowance still gets used up).
#   Prefer     - 'reset': soonest weekly reset first (use it before it expires)
#                'room' : most room left first
function New-SwitchRules($FullAt = 99, $MinSession = 10, $MinWeekly = 0, $Prefer = 'reset') {
    return @{ FullAt = [double]$FullAt; MinSession = [double]$MinSession; MinWeekly = [double]$MinWeekly; Prefer = [string]$Prefer }
}

# Why an account can't be switched to, or $null if it can.
function Get-IneligibleReason($o, $Rules) {
    if ($o.Pending) { return 'NOT CHECKED' }
    if ($o.Err) { return 'ERROR' }
    if (-not @($o.Rows).Count) { return 'NO DATA' }
    foreach ($r in $o.Rows) {
        $left = 100 - [double]$r.Used
        $isSession = $r.Label -like 'Session*'
        if ([double]$r.Used -ge $Rules.FullAt) { if ($isSession) { return 'SESSION FULL' } else { return 'WEEKLY FULL' } }
        if ($isSession -and $left -lt $Rules.MinSession) { return 'LOW SESSION' }
        if (-not $isSession -and $left -lt $Rules.MinWeekly) { return 'LOW WEEKLY' }
    }
    return $null
}

# Least room left on any weekly limit (used for the 'room' preference).
function Get-WeeklyLeft($Rows) {
    $w = @($Rows | Where-Object { $_.Label -notlike 'Session*' })
    if (-not $w) { $w = @($Rows) }
    return (100 - (Get-MaxUsed $w))
}

# Others ordered for switching: eligible first (by preference), then the rest.
# Sets .Eligible and .Reason on each entry.
function Sort-SwitchCandidates($Others, $Rules) {
    foreach ($o in @($Others)) {
        $o.Reason = Get-IneligibleReason $o $Rules
        $o.Eligible = -not $o.Reason
    }
    $keys = if ($Rules.Prefer -eq 'room') {
        @(@{ e = { Get-WeeklyLeft $_.Rows }; Descending = $true }, @{ e = { Get-PriorityReset $_.Rows }; Descending = $false })
    } else {
        @(@{ e = { Get-PriorityReset $_.Rows }; Descending = $false }, @{ e = { Get-WeeklyLeft $_.Rows }; Descending = $true })
    }
    $eligible = @($Others | Where-Object { $_.Eligible } | Sort-Object $keys)
    $rest     = @($Others | Where-Object { -not $_.Eligible })
    return ,@($eligible + $rest)
}

# The account to switch to, or $null. Does not check whether a switch is due.
function Select-AutoSwitchTarget($Others, $Rules) {
    $sorted = Sort-SwitchCandidates $Others $Rules
    $first = $sorted | Select-Object -First 1
    if ($first -and $first.Eligible) { return $first }
    return $null
}

function ConvertFrom-UsageDate($s) {
    if (-not $s) { return $null }
    try { return [datetime]::Parse($s, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) } catch { return $null }
}

# Returns @( @{ Label; Used; Resets } ... ) for a token. Throws with a readable message.
function Get-UsageRows([string]$Token) {
    $headers = @{ Authorization = "Bearer $Token"; 'anthropic-beta' = 'oauth-2025-04-20' }
    try {
        $r = Invoke-RestMethod -Uri $script:UsageUrl -Headers $headers -TimeoutSec 15 -UseBasicParsing
    } catch {
        $code = $null
        try { $code = [int]$_.Exception.Response.StatusCode } catch {}
        if ($code -eq 401) { throw 'Token expired. Open Claude Code once to refresh it.' }
        if ($code -eq 429) {
            $retry = 0
            try { $retry = [int]$_.Exception.Response.Headers['Retry-After'] } catch {}
            $ex = New-Object System.Exception 'Rate limited by Anthropic; backing off.'
            $ex.Data['RateLimited'] = $true
            $ex.Data['RetryAfter'] = $retry
            throw $ex
        }
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
            $rows += @{ Label = $label; Used = [double]$l.percent; Resets = (ConvertFrom-UsageDate $l.resets_at) }
        }
    } else {
        foreach ($k in @(@('five_hour', 'Session (5h)'), @('seven_day', 'Weekly'), @('seven_day_opus', 'Weekly Opus'), @('seven_day_sonnet', 'Weekly Sonnet'))) {
            $v = $r.($k[0])
            if ($v) { $rows += @{ Label = $k[1]; Used = [double]$v.utilization; Resets = (ConvertFrom-UsageDate $v.resets_at) } }
        }
    }
    if (-not $rows) { throw 'Usage response contained no limits.' }
    return ,$rows
}

function Find-ClaudeProfile([string]$NameOrId) {
    $all = Get-ClaudeProfiles
    $p = $all | Where-Object { $_.Id -eq $NameOrId -or $_.Name -eq $NameOrId } | Select-Object -First 1
    if (-not $p) { $p = $all | Where-Object { $_.Email -eq $NameOrId } | Select-Object -First 1 }
    if (-not $p) { $p = $all | Where-Object { $_.Name -like "*$NameOrId*" } | Select-Object -First 1 }
    if (-not $p) { throw "No profile matches '$NameOrId'." }
    return $p
}

function Switch-ClaudeProfile([string]$NameOrId) {
    $active = Get-ActiveAccount
    $target = Find-ClaudeProfile $NameOrId
    # Already active and consistent: nothing to do. (On a mismatch we still write
    # both files, which repairs them.)
    if ($target.Active -and -not ($active -and $active.Mismatch)) { return $target }

    # Keep the outgoing account's (possibly refreshed) tokens - only once verified.
    Sync-ActiveProfile $null $active | Out-Null

    $js = New-JsonSerializer
    $cred = [IO.File]::ReadAllText((Join-Path $target.Path 'credentials.json'))
    $acct = $js.DeserializeObject([IO.File]::ReadAllText((Join-Path $target.Path 'oauthAccount.json')))

    # One rolling backup of the config before touching it.
    Copy-Item $script:ConfigFile "$($script:ConfigFile).switcher-backup" -Force
    $cfg = Read-ClaudeConfig
    $cfg['oauthAccount'] = $acct
    Write-FileAtomic $script:ConfigFile ($js.Serialize($cfg))
    Write-FileAtomic $script:CredFile $cred

    $target.Active = $true
    return $target
}

function Rename-ClaudeProfile([string]$NameOrId, [string]$NewName) {
    $p = Find-ClaudeProfile $NameOrId
    $js = New-JsonSerializer
    $metaPath = Join-Path $p.Path 'profile.json'
    $meta = $js.DeserializeObject([IO.File]::ReadAllText($metaPath))
    $meta['name'] = $NewName
    Write-FileAtomic $metaPath ($js.Serialize($meta))
}

function Remove-ClaudeProfile([string]$NameOrId) {
    $p = Find-ClaudeProfile $NameOrId
    if ($p.Active) { throw "'$($p.Name)' is the active account; switch away first." }
    Remove-Item $p.Path -Recurse -Force
}
