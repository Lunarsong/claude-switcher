<#
  claude-profile - switch Claude Code between saved accounts.

    claude-profile                 list profiles (* = active)
    claude-profile save [name]     save/refresh the signed-in account (optional display name)
    claude-profile use <name>      switch to a profile (name, email, or part of either)
    claude-profile rename <name> <new name>
    claude-profile remove <name>
    claude-profile login           sign in to another account (current one is saved first)
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

switch ($Command) {
    'list'   { Show-List }
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
    'login'  {
        Sync-ActiveProfile | Out-Null
        & claude auth login
        Sync-ActiveProfile | Out-Null
        Show-List
    }
    default  { Get-Help $PSCommandPath -Detailed | Out-Null; Write-Host (Get-Content $PSCommandPath -TotalCount 10 | Select-Object -Skip 1 | Out-String) }
}
