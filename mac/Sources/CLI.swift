import Foundation

/*
  claude-profile - manage and switch Claude Code accounts (macOS).

    claude-profile                 list profiles (* = active)
    claude-profile add [name]      sign in to another account WITHOUT switching to it
    claude-profile use <name>      switch to a profile (name, email, or part of either)
    claude-profile usage           show usage for every saved account
    claude-profile save [name]     save/refresh the signed-in account (optional display name)
    claude-profile rename <name> <new name>
    claude-profile remove <name>
*/

enum CLI {
    static let help = """
    claude-profile - manage and switch Claude Code accounts.

      claude-profile                 list profiles (* = active)
      claude-profile add [name]      sign in to another account WITHOUT switching to it
      claude-profile use <name>      switch to a profile (name, email, or part of either)
      claude-profile usage           show usage for every saved account
      claude-profile save [name]     save/refresh the signed-in account (optional display name)
      claude-profile rename <name> <new name>
      claude-profile remove <name>
    """

    static let tty = isatty(STDOUT_FILENO) != 0
    static func color(_ s: String, _ code: String) -> String { tty ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
    static func say(_ s: String) { print(s) }
    static func warn(_ s: String) { print(color(s, "33")) }

    static func run(_ args: [String]) -> Int32 {
        let acc = ClaudeAccounts.live()
        let cmd = args.first ?? "list"
        let rest = Array(args.dropFirst())
        do {
            switch cmd {
            case "list": showList(acc)
            case "add", "login": try addAccount(acc, name: rest.joined(separator: " "))
            case "usage": showAllUsage(acc)
            case "save":
                guard acc.syncActiveProfile(name: rest.isEmpty ? nil : rest.joined(separator: " ")) != nil else {
                    throw CoreError("Not signed in (or the login couldn't be verified - are you online?).")
                }
                showList(acc)
            case "use":
                guard !rest.isEmpty else { throw CoreError("Usage: claude-profile use <name>") }
                let p = try acc.switchProfile(rest.joined(separator: " "))
                switchResult(p.name)
            case "rename":
                guard rest.count >= 2 else { throw CoreError("Usage: claude-profile rename <name> <new name>") }
                try acc.renameProfile(rest[0], to: rest.dropFirst().joined(separator: " "))
                showList(acc)
            case "remove":
                guard !rest.isEmpty else { throw CoreError("Usage: claude-profile remove <name>") }
                try acc.removeProfile(rest.joined(separator: " "), activeId: acc.activeAccount()?.id)
                showList(acc)
            case "check-config":
                // Read-only: confirms ~/.claude.json would be rewritten byte-for-byte.
                let text = try readText(acc.configFile)
                let same = try JSON.parse(text).serialized() == text
                say(same ? "~/.claude.json round-trips unchanged." : "~/.claude.json would be reformatted on a switch (contents kept).")
            default:
                say(help)
            }
            return 0
        } catch {
            print(color("\(error)", "31"))
            return 1
        }
    }

    static func showList(_ acc: ClaudeAccounts) {
        let active = acc.activeAccount()
        acc.syncActiveProfile(active: active)
        let all = acc.profiles(activeId: active?.id)
        if all.isEmpty { say("No profiles yet. Sign in with `claude` and run: claude-profile save"); return }
        for p in all { say(" \(p.active ? "*" : " ") \(p.name)") }
        if active?.mismatch == true {
            warn("Login overwritten: the tokens belong to a different account than ~/.claude.json says. Close running Claude Code sessions, then switch again.")
        }
    }

    /// After a switch: confirm it and point out sessions still on the previous login.
    static func switchResult(_ name: String) {
        say("Switched to \(name). New Claude Code sessions will use it.")
        let old = claudeCodeProcesses(startedBefore: Date()).count
        if old > 0 {
            warn("\(old) running Claude Code \(old == 1 ? "session is" : "sessions are") still on the previous account; restart \(old == 1 ? "it" : "them") to use \(name).")
        }
    }

    /// Runs an interactive command in this terminal and waits for it.
    /// Foundation's Process puts the child in its own (background) process group, so a
    /// program that puts the terminal in raw mode - like Claude's sign-in screen - is
    /// stopped by SIGTTOU and hangs. posix_spawn without SETPGROUP keeps it in our
    /// foreground group with our stdin/stdout/stderr.
    static func runInteractive(_ path: String, _ args: [String], env: [String: String]) throws -> Int32 {
        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, nil, nil, argv, envp)
        guard rc == 0 else { throw CoreError("Couldn't start \(path): \(String(cString: strerror(rc)))") }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        return status
    }

    static func addAccount(_ acc: ClaudeAccounts, name: String) throws {
        // Keep whatever is signed in now.
        acc.syncActiveProfile()
        guard let claude = ClaudeAccounts.findClaude() else { throw CoreError("Couldn't find the `claude` command. Install Claude Code first.") }

        // Sign in inside a throwaway config dir so the active login is never touched.
        let login = try acc.prepareLogin()
        say(color("Opening the Claude sign-in. Sign in with the account you want to add.", "36"))
        say(color("(Your current account stays active.)", "90"))
        let status: Int32
        do { status = try runInteractive(claude, ["auth", "login"], env: ClaudeAccounts.loginEnvironment(login)) }
        catch { acc.discardLogin(login); throw error }
        guard status == 0 else { acc.discardLogin(login); throw CoreError("Sign-in didn't finish; nothing was added.") }
        let id = try acc.finishLogin(login, name: name.isEmpty ? nil : name)

        let activeId = acc.activeAccount()?.id
        guard let prof = acc.profiles(activeId: activeId).first(where: { $0.id == id }) else { return }
        if prof.active { say("That's the account you're already using (\(prof.name))."); return }
        say(color("Saved \(prof.name).", "32"))
        print("Switch to it now? [y/N] ", terminator: "")
        let ans = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if ans == "y" || ans == "yes" {
            try acc.switchProfile(id)
            switchResult(prof.name)
        } else {
            say("Not switched. Use the menu bar's Account menu or: claude-profile use \"\(prof.name)\"")
        }
    }

    static func showAllUsage(_ acc: ClaudeAccounts) {
        let active = acc.activeAccount()
        acc.syncActiveProfile(active: active)
        let f = DateFormatter()
        f.dateFormat = "EEE HH:mm"
        for p in acc.profiles(activeId: active?.id) {
            say(color(" \(p.active ? "*" : " ") \(p.name)", "36"))
            do {
                for r in try acc.usageRows(token: try acc.accessToken(for: p)) {
                    let reset = r.resets.map { f.string(from: $0) } ?? ""
                    let label = r.label.padding(toLength: max(16, r.label.count), withPad: " ", startingAt: 0)
                    say(String(format: "     %@ %3d%% used   resets %@", label, Int(min(100, r.used)), reset))
                }
            } catch {
                warn("     \(error)")
            }
        }
    }
}
