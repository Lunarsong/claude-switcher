<#
  Tests for ClaudeProfiles.ps1. No dependencies, no network, never touches your
  real Claude login: every test works on temp copies and fake responses.

    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1

  Exit code = number of failed tests.
#>
if ($PSVersionTable.PSEdition -eq 'Core') {
    # The module uses .NET Framework's JSON serializer.
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
    exit $LASTEXITCODE
}
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\ClaudeProfiles.ps1')

# ---------- tiny test harness ----------
$script:Passed = 0; $script:Failed = @()
function Test([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:Passed++; Write-Host "  ok   $Name" -ForegroundColor Green }
    catch { $script:Failed += $Name; Write-Host "  FAIL $Name`n       $($_.Exception.Message)" -ForegroundColor Red }
}
function Assert-Equal($Expected, $Actual, [string]$What = 'value') {
    if ($Expected -ne $Actual) { throw "$What`: expected '$Expected', got '$Actual'" }
}
function Assert-True($Cond, [string]$What) { if (-not $Cond) { throw "expected: $What" } }

# ---------- fakes ----------
# Token -> "<account>_<org>" as the real api/oauth/profile would answer.
$script:FakeIds = @{}
function Get-TokenIdentity([string]$Token) { if ($script:FakeIds.ContainsKey($Token)) { $script:FakeIds[$Token] } else { $null } }

# Invoke-RestMethod stand-in: functions win over cmdlets, so the module uses this.
$script:RestCalls = @(); $script:RestReply = $null
function Invoke-RestMethod { param($Uri, $Method, $Headers, $Body, $ContentType, $TimeoutSec, $UserAgent, [switch]$UseBasicParsing)
    $script:RestCalls += @{ Uri = $Uri; Method = $Method; Body = $Body }
    if ($script:RestReply -is [scriptblock]) { return (& $script:RestReply $Uri $Body) }
    return $script:RestReply
}

# ---------- fixtures ----------
$Root = Join-Path $env:TEMP ('claude-switcher-tests-' + [guid]::NewGuid().ToString('N'))
$js = New-JsonSerializer
function New-Account([string]$acct, [string]$org, [string]$email) {
    @{ accountUuid = $acct; organizationUuid = $org; emailAddress = $email; organizationName = 'Org' }
}
function New-Cred([string]$token, [string]$refresh = 'r-1', [int64]$expiresInMs = 3600000) {
    $exp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + $expiresInMs
    $js.Serialize(@{ claudeAiOauth = @{ accessToken = $token; refreshToken = $refresh; expiresAt = $exp; scopes = @('user:inference') } })
}
# Fresh sandbox per test: a fake ~/.claude.json, credentials file and profiles dir.
function Reset-Sandbox($ConfigAccount, [string]$CredText) {
    if (Test-Path $Root) { Remove-Item $Root -Recurse -Force }
    New-Item -ItemType Directory $Root | Out-Null
    $script:ConfigFile  = Join-Path $Root '.claude.json'
    $script:CredFile    = Join-Path $Root '.credentials.json'
    $script:ProfilesDir = Join-Path $Root 'profiles'
    $script:RequestLog  = Join-Path $Root 'requests.log'
    $cfg = @{ numStartups = 42; projects = @{ 'C:\x' = @{ allowedTools = @() } }; unicode = "caf$([char]0xE9) <tag> & 'q'"; oauthAccount = $ConfigAccount }
    [IO.File]::WriteAllText($script:ConfigFile, $js.Serialize($cfg))
    [IO.File]::WriteAllText($script:CredFile, $CredText)
    $script:FakeIds = @{}; $script:RestCalls = @(); $script:RestReply = $null
}

$A = New-Account 'acctA' 'org1' 'a@example.com'; $AId = 'acctA_org1'
$B = New-Account 'acctB' 'org1' 'b@example.com'; $BId = 'acctB_org1'

try {
Write-Host 'Login files' -ForegroundColor Cyan

Test 'config JSON survives a read/write round-trip unchanged' {
    Reset-Sandbox $A (New-Cred 'tokA')
    $before = [IO.File]::ReadAllText($script:ConfigFile)
    Write-FileAtomic $script:ConfigFile ($js.Serialize((Read-ClaudeConfig)))
    $a = $js.DeserializeObject($before); $b = $js.DeserializeObject([IO.File]::ReadAllText($script:ConfigFile))
    Assert-Equal ($js.Serialize($a)) ($js.Serialize($b)) 'config'
}

Test 'active account is verified when the token matches the config' {
    Reset-Sandbox $A (New-Cred 'tokA'); $script:FakeIds['tokA'] = $AId
    $a = Get-ActiveAccount
    Assert-True $a.Verified 'verified'; Assert-True (-not $a.Mismatch) 'no mismatch'; Assert-Equal $AId $a.Id 'id'
}

Test 'a token belonging to another account is reported as a mismatch' {
    Reset-Sandbox $A (New-Cred 'tokB'); $script:FakeIds['tokB'] = $BId
    $a = Get-ActiveAccount
    Assert-True $a.Mismatch 'mismatch'; Assert-Equal $BId $a.Id 'real owner'; Assert-Equal $AId $a.ConfigId 'config id'
}

Test 'unverifiable token (offline) falls back to config and is not trusted' {
    Reset-Sandbox $A (New-Cred 'tokA')
    $a = Get-ActiveAccount
    Assert-True (-not $a.Verified) 'not verified'; Assert-Equal $AId $a.Id 'fallback id'
    Assert-Equal $null (Sync-ActiveProfile $null $a) 'nothing saved'
    Assert-True (-not (Test-Path (Join-Path $script:ProfilesDir $AId))) 'no profile created'
}

Test 'sync saves a verified login into its own profile' {
    Reset-Sandbox $A (New-Cred 'tokA'); $script:FakeIds['tokA'] = $AId
    Assert-Equal $AId (Sync-ActiveProfile) 'saved id'
    $p = Get-ClaudeProfiles | Where-Object Id -eq $AId
    Assert-Equal 'a@example.com (Org)' $p.Name 'default name'
    Assert-True ([IO.File]::ReadAllText((Join-Path $p.Path 'credentials.json')) -match 'tokA') 'tokens saved'
}

Test 'on a mismatch, tokens go only to their real owner''s profile' {
    Reset-Sandbox $A (New-Cred 'tokA'); $script:FakeIds['tokA'] = $AId; Sync-ActiveProfile | Out-Null
    Save-ProfileSnapshot (New-Cred 'tokB-old') $B $null | Out-Null
    [IO.File]::WriteAllText($script:CredFile, (New-Cred 'tokB-new')); $script:FakeIds['tokB-new'] = $BId
    Assert-Equal $BId (Sync-ActiveProfile) 'saved to'
    Assert-True ([IO.File]::ReadAllText((Join-Path $script:ProfilesDir "$AId\credentials.json")) -match 'tokA') 'A untouched'
    Assert-True ([IO.File]::ReadAllText((Join-Path $script:ProfilesDir "$BId\credentials.json")) -match 'tokB-new') 'B updated'
}

Test 'sync saves exactly the credentials it verified, even if the file changed since' {
    Reset-Sandbox $A (New-Cred 'tokA'); $script:FakeIds['tokA'] = $AId
    $a = Get-ActiveAccount
    [IO.File]::WriteAllText($script:CredFile, (New-Cred 'tokB'))   # a switch happens mid-check
    Sync-ActiveProfile $null $a | Out-Null
    Assert-True ([IO.File]::ReadAllText((Join-Path $script:ProfilesDir "$AId\credentials.json")) -match 'tokA') 'A keeps its own token'
}

Test 'switching writes both files, keeps other config keys and makes a backup' {
    Reset-Sandbox $A (New-Cred 'tokA'); $script:FakeIds['tokA'] = $AId; Sync-ActiveProfile | Out-Null
    Save-ProfileSnapshot (New-Cred 'tokB') $B $null | Out-Null
    Switch-ClaudeProfile 'b@example.com' | Out-Null
    $cfg = Read-ClaudeConfig
    Assert-Equal 'acctB' $cfg['oauthAccount']['accountUuid'] 'config account'
    Assert-Equal 42 $cfg['numStartups'] 'other keys kept'
    Assert-True ([IO.File]::ReadAllText($script:CredFile) -match 'tokB') 'credentials swapped'
    Assert-True (Test-Path "$($script:ConfigFile).switcher-backup") 'backup written'
}

Test 'switching to the token owner during a mismatch repairs the config' {
    Reset-Sandbox $A (New-Cred 'tokB'); $script:FakeIds['tokB'] = $BId
    Save-ProfileSnapshot (New-Cred 'tokB') $B $null | Out-Null
    Switch-ClaudeProfile $BId | Out-Null
    Assert-Equal 'acctB' (Read-ClaudeConfig)['oauthAccount']['accountUuid'] 'config repaired'
    $script:FakeIds['tokB'] = $BId
    Assert-True (-not (Get-ActiveAccount).Mismatch) 'consistent afterwards'
}

Test 'the active profile cannot be removed' {
    Reset-Sandbox $A (New-Cred 'tokA'); $script:FakeIds['tokA'] = $AId; Sync-ActiveProfile | Out-Null
    $threw = $false; try { Remove-ClaudeProfile $AId } catch { $threw = $true }
    Assert-True $threw 'refused'
}

Write-Host 'Tokens and usage' -ForegroundColor Cyan

Test 'inactive profile with a valid token is used without refreshing' {
    Reset-Sandbox $A (New-Cred 'tokA'); $script:FakeIds['tokA'] = $AId
    Save-ProfileSnapshot (New-Cred 'tokB' 'r-B') $B $null | Out-Null
    $p = Get-ClaudeProfiles | Where-Object Id -eq $BId
    Assert-Equal 'tokB' (Get-ProfileAccessToken $p) 'token'
    Assert-Equal 0 $script:RestCalls.Count 'no network'
}

Test 'expired inactive token is refreshed and the rotated tokens are saved' {
    Reset-Sandbox $A (New-Cred 'tokA'); $script:FakeIds['tokA'] = $AId
    Save-ProfileSnapshot (New-Cred 'tokB-old' 'r-old' -60000) $B $null | Out-Null
    $script:RestReply = [pscustomobject]@{ access_token = 'tokB-new'; refresh_token = 'r-new'; expires_in = 3600 }
    $p = Get-ClaudeProfiles | Where-Object Id -eq $BId
    Assert-Equal 'tokB-new' (Get-ProfileAccessToken $p) 'new token'
    Assert-True ($script:RestCalls[0].Body -match 'r-old') 'used old refresh token'
    $saved = $js.DeserializeObject([IO.File]::ReadAllText((Join-Path $p.Path 'credentials.json')))['claudeAiOauth']
    Assert-Equal 'r-new' $saved['refreshToken'] 'rotated refresh token saved'
    Assert-Equal 'user:inference' (@($saved['scopes'])[0]) 'other fields kept'
}

# An HTTP error as Invoke-RestMethod throws it (only the bits the module reads).
function New-HttpError([int]$Status, [hashtable]$Headers = @{}) {
    $e = New-Object System.Exception "HTTP $Status"
    Add-Member -InputObject $e NoteProperty Response ([pscustomobject]@{ StatusCode = $Status; Headers = $Headers })
    return $e
}

Test 'a rate-limited refresh is reported as rate limited, not as an expired login' {
    Reset-Sandbox $A (New-Cred 'tokA'); $script:FakeIds['tokA'] = $AId
    Save-ProfileSnapshot (New-Cred 'tokB-old' 'r-old' -60000) $B $null | Out-Null
    $script:RestReply = { throw (New-HttpError 429 @{ 'Retry-After' = '300' }) }
    $p = Get-ClaudeProfiles | Where-Object Id -eq $BId
    $ex = $null; try { Get-ProfileAccessToken $p | Out-Null } catch { $ex = $_.Exception }
    Assert-True ($ex -and $ex.Data['RateLimited']) 'rate limited'
    Assert-Equal 300 $ex.Data['RetryAfter'] 'retry after'
    Assert-True ([IO.File]::ReadAllText((Join-Path $p.Path 'credentials.json')) -match 'r-old') 'saved login untouched'
}

Test 'a rejected refresh token asks to sign in again' {
    Reset-Sandbox $A (New-Cred 'tokA'); $script:FakeIds['tokA'] = $AId
    Save-ProfileSnapshot (New-Cred 'tokB-old' 'r-old' -60000) $B $null | Out-Null
    $script:RestReply = { throw (New-HttpError 400) }
    $p = Get-ClaudeProfiles | Where-Object Id -eq $BId
    $ex = $null; try { Get-ProfileAccessToken $p | Out-Null } catch { $ex = $_.Exception }
    Assert-True ($ex -and -not $ex.Data['RateLimited']) 'not rate limited'
    Assert-True ($ex.Message -match 'Add account') 'tells how to fix'
}

Test 'the active account always uses the live token (never refreshed here)' {
    Reset-Sandbox $A (New-Cred 'tokA' 'r-A' -60000); $script:FakeIds['tokA'] = $AId; Sync-ActiveProfile | Out-Null
    $p = Get-ClaudeProfiles | Where-Object Id -eq $AId
    Assert-Equal 'tokA' (Get-ProfileAccessToken $p) 'live token'
    Assert-Equal 0 $script:RestCalls.Count 'no refresh'
}

Test 'usage response is parsed into labelled rows' {
    $script:RestReply = [pscustomobject]@{ limits = @(
        [pscustomobject]@{ kind = 'session'; percent = 12; resets_at = '2030-01-01T05:00:00+00:00' },
        [pscustomobject]@{ kind = 'weekly_all'; percent = 40; resets_at = '2030-01-05T00:00:00+00:00' },
        [pscustomobject]@{ kind = 'weekly_scoped'; percent = 3; resets_at = $null; scope = [pscustomobject]@{ model = [pscustomobject]@{ display_name = 'Fable' } } }
    ) }
    $rows = Get-UsageRows 'tok'
    Assert-Equal 3 $rows.Count 'rows'
    Assert-Equal 'Session (5h)' $rows[0].Label 'label 1'; Assert-Equal 12 $rows[0].Used 'used 1'
    Assert-Equal 'Weekly Fable' $rows[2].Label 'scoped label'
    Assert-True ($rows[1].Resets -is [datetime]) 'reset parsed'
}

Write-Host 'Auto-switch rules' -ForegroundColor Cyan
$now = [datetime]::UtcNow
function Row($label, $used, $hrs) { @{ Label = $label; Used = $used; Resets = $now.AddHours($hrs) } }
function Others { @(
    @{ Id = 'A'; Err = $null; Rows = @((Row 'Session (5h)' 5 3),   (Row 'Weekly' 96 20)) }   # 4% weekly left, resets soonest
    @{ Id = 'B'; Err = $null; Rows = @((Row 'Session (5h)' 0 5),   (Row 'Weekly' 20 144)) }  # lots of room
    @{ Id = 'C'; Err = $null; Rows = @((Row 'Session (5h)' 100 2), (Row 'Weekly' 10 30)) }   # session maxed
    @{ Id = 'D'; Err = $null; Rows = @((Row 'Session (5h)' 93 2),  (Row 'Weekly' 10 30)) }   # 7% session left
    @{ Id = 'E'; Err = $null; Rows = @((Row 'Session (5h)' 1 2),   (Row 'Weekly' 99 25)) }   # weekly at threshold
    @{ Id = 'F'; Err = 'boom'; Rows = @() }
    @{ Id = 'G'; Err = 'Not checked yet'; Pending = $true; Rows = @() }
) }

Test 'defaults use a nearly-spent weekly allowance first and skip maxed sessions' {
    $s = Sort-SwitchCandidates (Others) (New-SwitchRules)
    Assert-Equal 'A,B' ((@($s | Where-Object Eligible) | ForEach-Object { $_.Id }) -join ',') 'eligible order'
    $why = @{}; foreach ($o in $s) { $why[$o.Id] = $o.Reason }
    Assert-Equal 'SESSION FULL' $why['C'] 'C'; Assert-Equal 'LOW SESSION' $why['D'] 'D'
    Assert-Equal 'WEEKLY FULL' $why['E'] 'E'; Assert-Equal 'ERROR' $why['F'] 'F'; Assert-Equal 'NOT CHECKED' $why['G'] 'G'
}
Test '"most room" preference picks the emptiest account' {
    Assert-Equal 'B' (Select-AutoSwitchTarget (Others) (New-SwitchRules 99 10 0 'room')).Id 'pick'
}
Test 'a weekly minimum excludes the nearly-spent account' {
    Assert-Equal 'B' (Select-AutoSwitchTarget (Others) (New-SwitchRules 99 10 5)).Id 'pick'
}
Test 'a spent weekly limit collapses the display to one row' {
    $full = @((Row 'Session (5h)' 40 3), (Row 'Weekly' 100 30), (Row 'Weekly Fable' 80 30))
    $d = @(Get-DisplayRows $full)
    Assert-Equal 1 @($d).Count 'rows shown'
    Assert-Equal 'Weekly - used up' $d[0].Label 'label'
    Assert-Equal $full[1].Resets $d[0].Resets 'reset time kept'
    Assert-Equal 3 @(Get-DisplayRows @((Row 'Session (5h)' 40 3), (Row 'Weekly' 99 30), (Row 'Weekly Fable' 100 30))).Count 'only a model limit spent'
}
Test 'no session minimum lets a low-session account qualify, still never a full one' {
    $s = Sort-SwitchCandidates (Others) (New-SwitchRules 99 0 0)
    $ids = (@($s | Where-Object Eligible) | ForEach-Object { $_.Id }) -join ','
    Assert-Equal 'A,D,B' $ids 'eligible order'
}
Test 'nothing qualifies -> no target' {
    Assert-Equal $null (Select-AutoSwitchTarget (Others) (New-SwitchRules 99 10 90)) 'target'
}

Write-Host 'Rate-limit pause' -ForegroundColor Cyan

$t0 = [datetime]'2026-11-12T00:48:00'
Test 'a pause in progress is active' {
    Assert-True (Test-BackoffActive $t0.AddSeconds(100) 120 $t0) 'active'
}
Test 'a finished pause is not active' {
    Assert-True (-not (Test-BackoffActive $t0.AddSeconds(-1) 120 $t0)) 'over'
}
Test 'a cleared pause (length 0) is ignored even if its end time is in the future' {
    Assert-True (-not (Test-BackoffActive $t0.AddMinutes(40) 0 $t0)) 'cleared'
}
Test 'a pause saved while the clock was an hour fast is ignored' {
    # 2-minute pause whose end time now looks 40 minutes away after the clock was corrected
    Assert-True (-not (Test-BackoffActive $t0.AddMinutes(40) 120 $t0)) 'clock jump'
}

Write-Host 'Notifications' -ForegroundColor Cyan

Test 'warns once when a limit crosses the threshold' {
    $st = @{}
    Assert-Equal 0 (Get-UsageNotices @((Row 'Session (5h)' 50 3)) $st 80 $true).Count 'below'
    $n = Get-UsageNotices @((Row 'Session (5h)' 82 3)) $st 80 $true
    Assert-Equal 1 $n.Count 'warned'; Assert-Equal 'warn' $n[0].Kind 'kind'
    Assert-Equal 0 (Get-UsageNotices @((Row 'Session (5h)' 90 3)) $st 80 $true).Count 'not repeated'
}
Test 'reports a reset and warns again in the next window' {
    $st = @{}
    Get-UsageNotices @((Row 'Session (5h)' 95 1)) $st 80 $true | Out-Null
    $n = Get-UsageNotices @((Row 'Session (5h)' 2 5)) $st 80 $true
    Assert-Equal 'reset' $n[0].Kind 'reset'
    Assert-Equal 'warn' (Get-UsageNotices @((Row 'Session (5h)' 85 5)) $st 80 $true)[0].Kind 'warns again'
}
Test 'warnings off and reset notices off stay silent' {
    $st = @{}
    Get-UsageNotices @((Row 'Weekly' 95 1)) $st 0 $false | Out-Null
    Assert-Equal 0 (Get-UsageNotices @((Row 'Weekly' 1 100)) $st 0 $false).Count 'silent'
}
}
finally {
    if (Test-Path $Root) { Remove-Item $Root -Recurse -Force }
}

Write-Host ''
if ($script:Failed.Count) {
    Write-Host ("{0} passed, {1} failed" -f $script:Passed, $script:Failed.Count) -ForegroundColor Red
} else {
    Write-Host ("All {0} tests passed" -f $script:Passed) -ForegroundColor Green
}
exit $script:Failed.Count
