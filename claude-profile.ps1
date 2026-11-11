<#
  claude-profile - manage and switch Claude Code accounts.

    claude-profile                 list profiles (* = active)
    claude-profile add [name]      sign in to another account WITHOUT switching to it
    claude-profile use <name>      switch to a profile (name, email, or part of either)
    claude-profile usage           show usage for every saved account
    claude-profile save [name]     save/refresh the signed-in account (optional display name)
    claude-profile rename <name> <new name>
    claude-profile remove <name>
#>
param([string]$Command = 'list', [Parameter(ValueFromRemainingArguments)][string[]]$Rest)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClaudeProfiles.ps1')

function Show-List {
    Sync-ActiveProfile | Out-Null
    $all = Get-ClaudeProfiles
    if (-not $all) { Write-Host 'No profiles yet. Sign in with `claude` and run: claude-profile save'; return }
    foreach ($p in $all) {
        $mark = if ($p.Active) { '*' } else { ' ' }
        Write-Host (' {0} {1}' -f $mark, $p.Name)
    }
}

function Add-Account([string]$Name) {
    # Keep whatever is signed in now.
    Sync-ActiveProfile | Out-Null

    # Sign in inside a throwaway config dir so the active login is never touched.
    $tmp = Join-Path $env:TEMP ('claude-profile-login-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory $tmp | Out-Null
    $prev = $env:CLAUDE_CONFIG_DIR
    try {
        $env:CLAUDE_CONFIG_DIR = $tmp
        Write-Host 'Opening the Claude sign-in. Sign in with the account you want to add.' -ForegroundColor Cyan
        Write-Host '(Your current account stays active.)' -ForegroundColor DarkGray
        & claude auth login
        $env:CLAUDE_CONFIG_DIR = $prev
        $id = Import-ClaudeLoginDir $tmp $Name
    } finally {
        $env:CLAUDE_CONFIG_DIR = $prev
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    $p = Get-ClaudeProfiles | Where-Object Id -eq $id
    if ($p.Active) { Write-Host "That's the account you're already using ($($p.Name))."; return }
    Write-Host "Saved $($p.Name)." -ForegroundColor Green
    $ans = Read-Host 'Switch to it now? [y/N]'
    if ($ans -match '^(y|yes)$') {
        Switch-ClaudeProfile $id | Out-Null
        Write-Host "Switched. Restart any running Claude Code sessions."
    } else {
        Write-Host "Not switched. Use the tray's Account menu or: claude-profile use `"$($p.Name)`""
    }
}

function Show-AllUsage {
    Sync-ActiveProfile | Out-Null
    foreach ($p in Get-ClaudeProfiles) {
        $mark = if ($p.Active) { '*' } else { ' ' }
        Write-Host (' {0} {1}' -f $mark, $p.Name) -ForegroundColor Cyan
        try {
            foreach ($r in (Get-UsageRows (Get-ProfileAccessToken $p))) {
                $reset = if ($r.Resets) { $r.Resets.ToLocalTime().ToString('ddd HH:mm') } else { '' }
                Write-Host ('     {0,-16} {1,3}% used   resets {2}' -f $r.Label, [int][math]::Min(100, $r.Used), $reset)
            }
        } catch { Write-Host "     $($_.Exception.Message)" -ForegroundColor Yellow }
    }
}

switch ($Command) {
    'list'   { Show-List }
    'add'    { Add-Account ($Rest -join ' ') }
    'login'  { Add-Account ($Rest -join ' ') }   # old name
    'usage'  { Show-AllUsage }
    'save'   { $id = Sync-ActiveProfile ($Rest -join ' '); if (-not $id) { throw 'Not signed in.' }; Show-List }
    'use'    {
        if (-not $Rest) { throw 'Usage: claude-profile use <name>' }
        $p = Switch-ClaudeProfile ($Rest -join ' ')
        Write-Host "Switched to $($p.Name). Restart any running Claude Code sessions."
    }
    'rename' {
        if ($Rest.Count -lt 2) { throw 'Usage: claude-profile rename <name> <new name>' }
        Rename-ClaudeProfile $Rest[0] (($Rest | Select-Object -Skip 1) -join ' '); Show-List
    }
    'remove' { Remove-ClaudeProfile ($Rest -join ' '); Show-List }
    default  { Get-Content $PSCommandPath -TotalCount 11 | Select-Object -Skip 1 | Write-Host }
}
