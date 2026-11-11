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

function Get-ActiveAccount {
    if (-not (Test-Path $script:ConfigFile) -or -not (Test-Path $script:CredFile)) { return $null }
    $acct = (Read-ClaudeConfig)['oauthAccount']
    if (-not $acct) { return $null }
    return [pscustomobject]@{
        Id      = '{0}_{1}' -f $acct['accountUuid'], $acct['organizationUuid']
        Email   = $acct['emailAddress']
        Org     = $acct['organizationName']
        Account = $acct
    }
}

function Get-ClaudeProfiles {
    if (-not (Test-Path $script:ProfilesDir)) { return @() }
    $js = New-JsonSerializer
    $active = Get-ActiveAccount
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

# Snapshot the currently signed-in account into its profile (creating it if new).
# Called on every tray poll so stored refresh tokens never go stale.
function Sync-ActiveProfile([string]$Name) {
    $active = Get-ActiveAccount
    if (-not $active) { return $null }
    $dir = Join-Path $script:ProfilesDir $active.Id
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }

    $js = New-JsonSerializer
    $metaPath = Join-Path $dir 'profile.json'
    $meta = if (Test-Path $metaPath) { $js.DeserializeObject([IO.File]::ReadAllText($metaPath)) } else { @{} }
    if ($Name) { $meta['name'] = $Name }
    if (-not $meta['name']) {
        $meta['name'] = if ($active.Org) { '{0} ({1})' -f $active.Email, $active.Org } else { $active.Email }
    }
    $meta['email'] = $active.Email
    $meta['org']   = $active.Org

    $cred = [IO.File]::ReadAllText($script:CredFile)
    $credPath = Join-Path $dir 'credentials.json'
    if (-not (Test-Path $credPath) -or [IO.File]::ReadAllText($credPath) -ne $cred) { Write-FileAtomic $credPath $cred }
    $acctJson = $js.Serialize($active.Account)
    $acctPath = Join-Path $dir 'oauthAccount.json'
    if (-not (Test-Path $acctPath) -or [IO.File]::ReadAllText($acctPath) -ne $acctJson) { Write-FileAtomic $acctPath $acctJson }
    $metaJson = $js.Serialize($meta)
    if (-not (Test-Path $metaPath) -or [IO.File]::ReadAllText($metaPath) -ne $metaJson) { Write-FileAtomic $metaPath $metaJson }

    return $active.Id
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
    $target = Find-ClaudeProfile $NameOrId
    if ($target.Active) { return $target }

    # Keep the outgoing account's (possibly refreshed) tokens.
    Sync-ActiveProfile | Out-Null

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
