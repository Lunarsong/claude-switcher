# Claude Usage Tray

A Windows tray icon and a small always-on-top overlay that show how much of your Claude subscription limits you have left.

- **Tray icon:** a coloured circle showing the % used on your *tightest* limit. It's green while under 70% used, amber at 70–90%, red above 90%, and grey when the data is stale or there was an error. Hover over it for every limit.
- **Overlay:** one bar per limit: the 5-hour session, weekly, and per-model weekly (such as "Weekly Fable"). Like claude.ai, bars start empty and fill as you use them, with the % used and time until reset. Turn on **Show remaining instead of used** in the menu to flip this. Drag the overlay to move it (its position is saved), and double-click it to refresh.
- New, removed or switched accounts are picked up automatically within 30 seconds, including ones changed from the CLI.
- **Right-click menu** (tray or overlay): Show overlay, Refresh now, Check usage every, Open claude.ai usage page, Start with Windows, Notifications, Auto-switch, Account, Exit. Left-clicking the tray icon toggles the overlay.
- Text is drawn at your screen's real resolution, so it stays sharp at any Windows display scaling.

### Notifications

Under **Tray → Notifications**:

- **Warn when a limit reaches** Off / 70 / **80** / 90 % used. Each limit warns once per reset window, with the time until it resets.
- **Tell me when a limit resets** (on by default): a notice when a limit that was at least half used drops back down.

## Switching accounts

There's no public profiles API. Claude Code keeps its login in two places: `~/.claude/.credentials.json` holds the tokens, and the `oauthAccount` block in `~/.claude.json` records which account and org you're signed in to. A **profile** is a snapshot of both, stored in `%APPDATA%\ClaudeUsageTray\profiles\`.

- The tray saves the signed-in account as a profile automatically and keeps its tokens fresh on every poll.

### Adding an account (without switching)

Click **+** on the overlay, choose **Account → Add account (without switching)…** from the tray, or run `claude-profile add`.

1. A console window opens and runs `claude auth login` with `CLAUDE_CONFIG_DIR` pointing at a throwaway temp folder. Your current login is never touched.
2. Sign in to the other account in the browser.
3. The new login is saved as a profile and the temp folder is deleted.
4. The console asks **"Switch to it now? [y/N]"**. Press Enter to stay on your current account.

### Seeing every account's usage

Click **All** on the overlay (or **Show all accounts** in the menu) to list usage for every saved account under the active one. You can also run `claude-profile usage` in a terminal. Inactive accounts use their saved tokens. When a saved access token expires, it's refreshed through the same OAuth endpoint Claude Code uses, and the new tokens are written straight back to that profile. The active account's tokens are never refreshed here; Claude Code owns those.

### Auto-switch

**Tray → Auto-switch → Enabled** (off by default) switches accounts for you when the active account runs out:

- **Switch away when any limit reaches:** 90 / 95 / **99** / 100 % used. This covers the session, weekly and per-model limits. An account at or past this point counts as **full**, and is never switched *to*.
- **Target needs session (5h) left:** Any / 5 / **10** / 25 / 50 %. A maxed-out session makes an account useless right now, so by default the target needs at least 10% of its session left.
- **Target needs weekly left:** **Any** / 5 / 10 / 25 %. The default is any (just not full), so an account with only 4% of its weekly allowance left still gets used up instead of wasted.
- **Prefer:** **Soonest weekly reset** (spend allowance before it expires) or **Most weekly room left**. The other option breaks ties.
- If no account qualifies, you get a single warning that says why for each account, and it doesn't repeat until usage drops and rises again.
- After an auto-switch it waits 1 minute; after a manual switch, 5 minutes, so it doesn't override a choice you just made. Since targets are never full, it can't ping-pong.
- The active account is checked every 2 minutes by default, so a very fast session can still pass the threshold before the switch happens. A lower threshold (such as 95%) gives more margin.

With **All** on, other accounts are listed in auto-switch priority order. The one it would pick is tagged **NEXT**, and accounts it would skip show why: **SESSION FULL**, **WEEKLY FULL**, **LOW SESSION**, **LOW WEEKLY** or **ERROR**.

**Running Claude Code sessions keep the old login until restarted**, so an auto-switch helps the next session you start, not one already in progress. After any switch, the overlay shows how many Claude Code sessions are still on the old account (for example "2 Claude Code sessions still on a@… – restart"), and the line goes away once they've all been restarted. It counts `claude.exe` processes from the CLI, IDE extensions and the desktop app's Code tab, and skips the desktop app's own windows. It never closes sessions for you.

### Switching

In the overlay, the active account is always at the top: a tinted panel with a blue stripe and an **ACTIVE** label. Other accounts are dimmed below it, each with a **Switch** link. **Tray → Account** lists the active account first, in bold and marked "(active)"; click any other to switch. The same submenu has rename and "open profiles folder". From the CLI:

```
claude-profile                  list (* = active)
claude-profile add [name]       add an account without switching
claude-profile use <name>       switch (name, email, or part of either)
claude-profile usage            usage for every saved account
claude-profile save [name]      save or refresh the current account
claude-profile rename <name> <new name>
claude-profile remove <name>
```

After switching, **restart any running Claude Code sessions**. A running session keeps the old login in memory and could write its refreshed tokens back over the switch. Before every switch, the previous `~/.claude.json` is kept as `~/.claude.json.switcher-backup`.

Profile folders contain live login tokens, so treat them like `~/.claude` itself: don't sync or share them.

## Run

Double-click `start-usage-tray.vbs`, or:

```
powershell -NoProfile -STA -ExecutionPolicy Bypass -File ClaudeUsageTray.ps1
```

It needs only Windows PowerShell 5.1, which is built in. There are no other dependencies.

## Tests

```
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
```

These cover the login-file handling (verification, mismatch protection, switching, token refresh), parsing of usage responses, the auto-switch rules and the notifications. They use temporary files and fake network responses, so they never touch your real login and need no internet. The exit code is the number of failures.

## How it works

It polls `https://api.anthropic.com/api/oauth/usage`, the same data Claude Code's `/usage` shows. Set the timing under **Tray → Check usage every**:

- **Active account:** every **2 minutes** by default (30 seconds to 5 minutes). This drives auto-switch. Shorter intervals react faster but are more likely to hit Anthropic's rate limit.
- **Other accounts:** every **10 minutes** by default (5 to 30 minutes), and only while **All** is on. Auto-switch always re-checks them right before choosing.
- **Refresh now** or double-clicking the overlay checks everything immediately.

All network calls run on a background thread, so the overlay and menus never freeze while checking. Saved accounts are listed by name straight away, marked **NOT CHECKED** until their numbers arrive.

The endpoint is rate-limited. If Anthropic answers *429 Too Many Requests*, the tray keeps showing the last numbers, marks them stale (**retry HH:mm** in the overlay header), and pauses: for the server's `Retry-After` time if it gives a useful one, otherwise for 2 minutes, doubling up to 15 minutes. The pause is saved in `state.json`, so restarting the tray doesn't reset it. Auto-switch is paused while rate-limited.

**Login safety:** Claude Code stores tokens and account details in separate files, and a Claude Code session still running on an old account can rewrite the tokens after a switch. So the tray checks who a token really belongs to (`api/oauth/profile`, cached per token) before saving it into a profile. If the files disagree, it saves the tokens only to their real owner's profile, shows **LOGIN OVERWRITTEN** on the overlay with a notification, and pauses auto-switch. Close the running Claude Code sessions and switch again; switching rewrites both files and clears the warning.

It authenticates with the OAuth token Claude Code keeps in `%USERPROFILE%\.claude\.credentials.json` and re-reads the token on every check. If the token expires, the icon turns grey. Open Claude Code once to refresh the token.

Settings (overlay position, check intervals, auto-switch rules, `Opacity`) are stored in `%APPDATA%\ClaudeUsageTray\settings.json`. Errors are logged to `error.log` in the same folder.

Note: this endpoint is not a documented public API, so a future Claude Code release could change it.
