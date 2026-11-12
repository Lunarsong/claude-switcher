import Foundation

/*
  Adding an account. `claude auth login` runs with CLAUDE_CONFIG_DIR pointing at a
  throwaway folder, so Claude Code keeps the new login in that folder's own Keychain
  item and never touches the active one. Afterwards the login is imported as a
  profile and the folder and its Keychain item are deleted.

  The terminal (`claude-profile add`) and the menu-bar app's sign-in window share
  this; they differ only in how `claude auth login` is run.
*/

/// A sign-in in progress.
struct LoginDir {
    let url: URL
    let path: String                 // as Claude Code sees it (symlinks resolved)
    let expectedService: String      // the Keychain item Claude Code should create
    let servicesBefore: Set<String>  // Claude Code items that existed before
}

struct LoginCancelled: Error, CustomStringConvertible {
    var description: String { "Sign-in cancelled." }
}

extension ClaudeAccounts {
    static func findClaude() -> String? {
        let fm = FileManager.default
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let home = fm.homeDirectoryForCurrentUser.path
        // Apps started from Finder get a minimal PATH, so also look where Claude Code installs.
        dirs += ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin"]
        for d in dirs {
            let p = (d as NSString).appendingPathComponent("claude")
            if fm.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Removes what an interrupted sign-in (a closed window, a quit app) left behind:
    /// its folder and the Keychain item Claude Code made for it.
    func cleanStaleLogins(in base: URL = ClaudeAccounts.appSupportDir) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: base.path) else { return }
        for n in names where n.hasPrefix("login-") {
            let url = base.appendingPathComponent(n, isDirectory: true)
            store.delete(service: Self.keychainService(forConfigDir: url.resolvingSymlinksInPath().path), account: keychainAccount)
            try? fm.removeItem(at: url)
        }
    }

    func prepareLogin(in base: URL = ClaudeAccounts.appSupportDir) throws -> LoginDir {
        let fm = FileManager.default
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        cleanStaleLogins(in: base)
        let url = base.appendingPathComponent("login-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = url.resolvingSymlinksInPath().path
        return LoginDir(url: url, path: path,
                        expectedService: Self.keychainService(forConfigDir: path),
                        servicesBefore: Set(store.services(withPrefix: Self.liveService + "-")))
    }

    /// The environment `claude auth login` runs with.
    static func loginEnvironment(_ d: LoginDir) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_CONFIG_DIR"] = d.path
        env.removeValue(forKey: "CLAUDE_SECURESTORAGE_CONFIG_DIR")
        return env
    }

    /// The Keychain item the sign-in made: the expected name, else the one new item.
    /// Only this item is ever deleted; anything else stays untouched.
    func createdService(_ d: LoginDir) -> String? {
        if (try? store.read(service: d.expectedService, account: keychainAccount)) != nil { return d.expectedService }
        let new = Set(store.services(withPrefix: Self.liveService + "-")).subtracting(d.servicesBefore)
        return new.count == 1 ? new.first : nil
    }

    /// After a successful sign-in: save it as a profile, then clean up. Returns the profile id.
    func finishLogin(_ d: LoginDir, name: String?) throws -> String {
        let svc = createdService(d)
        defer { discard(d, service: svc) }
        return try importLoginDir(d.url, keychainService: svc, name: name)
    }

    /// After a cancelled or failed sign-in.
    func discardLogin(_ d: LoginDir) { discard(d, service: createdService(d)) }

    private func discard(_ d: LoginDir, service: String?) {
        if let s = service { store.delete(service: s, account: keychainAccount) }
        try? FileManager.default.removeItem(at: d.url)
    }
}

/// Runs `claude auth login` without a terminal, for the app's sign-in window.
///
/// Claude Code opens the browser itself and gets the result back automatically.
/// It also prints a sign-in link; a browser that opens that link shows a code
/// instead, which is sent to Claude Code on stdin as `code#state`. Success is
/// exit status 0 plus a login that imports, not anything parsed from the output.
final class LoginRunner {
    enum Event {
        case url(URL)                                // the sign-in link Claude Code printed
        case invalidCode                             // Claude Code rejected a pasted code's format
        case finished(Result<String, Error>)         // profile id, or why not
    }

    let acc: ClaudeAccounts
    let claude: String
    let base: URL
    let name: String?
    /// Called on a background queue, in order.
    var onEvent: (Event) -> Void = { _ in }

    private let q = DispatchQueue(label: "claude-usage-tray.login")
    private var proc: Process?
    private var input: FileHandle?
    private var login: LoginDir?
    private var cancelled = false
    private var done = false
    private var sentURL = false
    private var outText = ""
    private var errLines: [String] = []

    init(acc: ClaudeAccounts, claude: String, base: URL = ClaudeAccounts.appSupportDir, name: String? = nil) {
        self.acc = acc
        self.claude = claude
        self.base = base
        self.name = name
    }

    func start() throws {
        let d = try acc.prepareLogin(in: base)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        p.arguments = ["auth", "login"]
        p.environment = ClaudeAccounts.loginEnvironment(d)
        let inP = Pipe(), outP = Pipe(), errP = Pipe()
        p.standardInput = inP      // kept open: Claude Code waits on it for a pasted code
        p.standardOutput = outP
        p.standardError = errP

        // Finish once the process has exited and both pipes are drained, so the
        // last error line is never lost. A child that keeps a pipe open can't
        // hold things up for more than 2 seconds after exit.
        let group = DispatchGroup()
        for (fh, isErr) in [(outP.fileHandleForReading, false), (errP.fileHandleForReading, true)] {
            group.enter()
            // These hold the runner until Claude Code exits, so it can always finish and clean up.
            DispatchQueue.global(qos: .utility).async { [self] in
                while true {
                    let data = fh.availableData
                    if data.isEmpty { break }
                    let s = String(decoding: data, as: UTF8.self)
                    q.async { isErr ? self.handleErr(s) : self.handleOut(s) }
                }
                group.leave()
            }
        }
        p.terminationHandler = { [self] p in
            let status = p.terminationStatus
            _ = group.wait(timeout: .now() + 2)
            q.async { self.finish(status: status) }
        }
        // Launch on q, so a cancel() can't slip in between and leave Claude Code running.
        let launchError: Error? = q.sync {
            if cancelled { return LoginCancelled() }
            do { try p.run() } catch { return CoreError("Couldn't start Claude Code's sign-in: \(error.localizedDescription)") }
            login = d; proc = p; input = inP.fileHandleForWriting
            return nil
        }
        if let e = launchError { acc.discardLogin(d); throw e }
    }

    /// Sends a code the browser showed. false = it isn't a whole code (needs "code#state").
    @discardableResult
    func submitCode(_ raw: String) -> Bool {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = code.split(separator: "#", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, !code.contains(where: \.isWhitespace) else { return false }
        q.async { [self] in
            guard !done else { return }
            try? input?.write(contentsOf: Data((code + "\n").utf8))   // Claude Code may have just exited
        }
        return true
    }

    func cancel() {
        q.async { [self] in
            guard !done else { return }
            cancelled = true   // not launched yet: start() sees this and stops
            if proc?.isRunning == true { proc?.terminate() } else if login != nil { finish(status: -1) }
        }
    }

    /// For quitting: stops Claude Code before returning. The folder it leaves is
    /// cleaned up the next time an account is added.
    func cancelNow() {
        q.sync {
            cancelled = true
            if proc?.isRunning == true { proc?.terminate() }
        }
    }

    // MARK: on q

    private static let escapes = try! NSRegularExpression(pattern: "\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)|\u{1B}\\[[0-9;?]*[A-Za-z]")

    static func stripEscapes(_ s: String) -> String {
        escapes.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }

    /// The link from "If the browser didn't open, visit: <url>" or "Sign in at: <url>".
    static func signInURL(in text: String) -> URL? {
        for line in stripEscapes(text).split(whereSeparator: \.isNewline) {
            guard line.contains("visit:") || line.contains("Sign in at:"),
                  let r = line.range(of: "https://") else { continue }
            let u = line[r.lowerBound...].prefix { !$0.isWhitespace }
            if let url = URL(string: String(u)) { return url }
        }
        return nil
    }

    private func handleOut(_ s: String) {
        outText += s
        if !sentURL, let u = Self.signInURL(in: outText) { sentURL = true; onEvent(.url(u)) }
    }

    private func handleErr(_ s: String) {
        for line in Self.stripEscapes(s).split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.isEmpty { continue }
            errLines.append(l)
            if l.hasPrefix("Invalid code") { onEvent(.invalidCode) }
        }
    }

    private func finish(status: Int32) {
        guard !done, let d = login else { return }
        done = true
        try? input?.close()
        let result: Result<String, Error>
        if cancelled {
            acc.discardLogin(d)
            result = .failure(LoginCancelled())
        } else if status == 0 {
            result = Result { try acc.finishLogin(d, name: name) }
        } else {
            acc.discardLogin(d)
            let msg = errLines.last(where: { $0.hasPrefix("Login failed:") }).map { String($0.dropFirst("Login failed:".count)).trimmingCharacters(in: .whitespaces) }
                ?? errLines.last ?? "Claude Code's sign-in stopped (exit \(status))."
            result = .failure(CoreError(msg))
        }
        onEvent(.finished(result))
        onEvent = { _ in }   // drop the caller's closure (it usually holds this runner)
    }
}
