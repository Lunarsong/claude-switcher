import Foundation
import CryptoKit
import Darwin

/*
  Core.swift - the macOS port of ClaudeProfiles.ps1.

  On macOS, Claude Code keeps its login in two places:
    login Keychain, item "Claude Code-credentials" (account = $USER)   OAuth tokens
      (falls back to ~/.claude/.credentials.json when the Keychain can't be used)
    ~/.claude.json -> oauthAccount                                        which account/org is signed in

  A profile is a snapshot of both:
    ~/Library/Application Support/ClaudeUsageTray/profiles/<id>/profile.json, oauthAccount.json
    login Keychain, item "Claude Usage Tray" (account = <id>)            that account's tokens
  Saved tokens stay in the Keychain, like Claude Code's own, instead of in files.

  Switching = sync the live login back into its own profile (tokens rotate), then
  copy the target profile's snapshot into place.
*/

// MARK: - Small helpers

struct CoreError: Error, CustomStringConvertible, LocalizedError {
    let description: String
    init(_ m: String) { description = m }
    var errorDescription: String? { description }
}

struct ProcessResult {
    var code: Int32
    var out: String
    var err: String
}

/// Runs a program and waits (with a timeout). Never goes through a shell.
@discardableResult
func runProcess(_ path: String, _ args: [String], stdin: String? = nil, env: [String: String]? = nil, timeout: TimeInterval = 15) -> ProcessResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    if let env = env { p.environment = env }
    let outPipe = Pipe(), errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    let inPipe = Pipe()
    p.standardInput = stdin != nil ? inPipe : FileHandle.nullDevice
    do { try p.run() } catch { return ProcessResult(code: -1, out: "", err: "\(error)") }
    if let s = stdin {
        inPipe.fileHandleForWriting.write(Data(s.utf8))
        try? inPipe.fileHandleForWriting.close()
    }
    // Read both pipes concurrently so a chatty child can't block on a full pipe.
    var outData = Data(), errData = Data()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    group.enter()
    DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { usleep(20_000) }
    if p.isRunning { p.terminate() }
    group.wait()
    p.waitUntilExit()
    return ProcessResult(code: p.terminationStatus,
                         out: String(decoding: outData, as: UTF8.self),
                         err: String(decoding: errData, as: UTF8.self))
}

func hexEncode(_ s: String) -> String { Data(s.utf8).map { String(format: "%02x", $0) }.joined() }

func hexDecode(_ s: String) -> String? {
    let chars = Array(s.utf8)
    guard chars.count % 2 == 0, !chars.isEmpty else { return nil }
    var bytes = [UInt8](); bytes.reserveCapacity(chars.count / 2)
    var i = 0
    while i < chars.count {
        guard let v = UInt8(String(bytes: chars[i..<i + 2], encoding: .ascii) ?? "", radix: 16) else { return nil }
        bytes.append(v); i += 2
    }
    return String(bytes: bytes, encoding: .utf8)
}

func sha256Hex(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// Write text atomically (temp file + rename) so a crash never leaves a half-written
/// file. Keeps the existing file's permissions; new files get `mode`.
func writeFileAtomic(_ url: URL, _ text: String, mode: Int = 0o600) throws {
    let fm = FileManager.default
    var perms = mode
    if let attrs = try? fm.attributesOfItem(atPath: url.path), let p = attrs[.posixPermissions] as? Int { perms = p }
    let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp-\(getpid())")
    guard fm.createFile(atPath: tmp.path, contents: Data(text.utf8), attributes: [.posixPermissions: perms]) else {
        throw CoreError("Could not write \(tmp.path)")
    }
    if rename(tmp.path, url.path) != 0 {
        let e = String(cString: strerror(errno))
        try? fm.removeItem(at: tmp)
        throw CoreError("Could not replace \(url.path): \(e)")
    }
}

func readText(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
}

func fileExists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

// MARK: - Secret storage (Keychain via /usr/bin/security)

protocol SecretStore: AnyObject {
    /// nil = no such item. Throws when the Keychain can't be read (e.g. locked).
    func read(service: String, account: String) throws -> String?
    func write(service: String, account: String, value: String) throws
    func delete(service: String, account: String)
    /// Service names of generic-password items that start with `prefix`.
    func services(withPrefix prefix: String) -> [String]
}

/// Uses the `security` tool exactly the way Claude Code does. Claude Code's own
/// Keychain item already trusts /usr/bin/security, so reading and updating it
/// this way never shows a Keychain prompt and never changes the item's access list.
final class SecurityCLIStore: SecretStore {
    static let tool = "/usr/bin/security"
    static let notFound: Int32 = 44
    /// Same limit Claude Code uses for one `security -i` command line; longer ones go via argv.
    static let stdinLimit = 4032

    func read(service: String, account: String) throws -> String? {
        let r = runProcess(Self.tool, ["find-generic-password", "-a", account, "-s", service, "-w"])
        if r.code == Self.notFound { return nil }
        if r.code != 0 { throw CoreError("Keychain read failed (\(r.code)): \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))") }
        var v = r.out
        if v.hasSuffix("\n") { v.removeLast() }
        // `security -w` prints the value as hex when it isn't plain text.
        if !v.hasPrefix("{"), let decoded = hexDecode(v) { return decoded }
        return v
    }

    func write(service: String, account: String, value: String) throws {
        let hex = hexEncode(value)
        let line = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \"\(hex)\"\n"
        let r: ProcessResult
        if line.utf8.count <= Self.stdinLimit {
            r = runProcess(Self.tool, ["-i"], stdin: line)
        } else {
            r = runProcess(Self.tool, ["add-generic-password", "-U", "-a", account, "-s", service, "-X", hex])
        }
        if r.code != 0 { throw CoreError("Keychain write failed (\(r.code)): \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))") }
    }

    func delete(service: String, account: String) {
        runProcess(Self.tool, ["delete-generic-password", "-a", account, "-s", service])
    }

    func services(withPrefix prefix: String) -> [String] {
        let r = runProcess(Self.tool, ["dump-keychain"], timeout: 30)
        var out = Set<String>()
        for line in r.out.split(separator: "\n") {
            guard let range = line.range(of: "\"svce\"<blob>=\"") else { continue }
            let rest = line[range.upperBound...]
            if let end = rest.lastIndex(of: "\"") {
                let name = String(rest[..<end])
                if name.hasPrefix(prefix) { out.insert(name) }
            }
        }
        return out.sorted()
    }
}

// MARK: - HTTP

struct HTTPResponse {
    var status: Int              // 0 = no response (network error)
    var headers: [String: String]
    var body: Data
    var error: String?
}

protocol HTTPClient: AnyObject {
    func send(_ req: URLRequest) -> HTTPResponse
}

/// Synchronous HTTP; only call off the main thread in the app.
final class URLSessionHTTP: HTTPClient {
    let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 25
        c.httpCookieStorage = nil
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    func send(_ req: URLRequest) -> HTTPResponse {
        var result = HTTPResponse(status: 0, headers: [:], body: Data(), error: "No response")
        let sem = DispatchSemaphore(value: 0)
        session.dataTask(with: req) { data, resp, err in
            if let h = resp as? HTTPURLResponse {
                var headers: [String: String] = [:]
                for (k, v) in h.allHeaderFields { headers[String(describing: k).lowercased()] = String(describing: v) }
                result = HTTPResponse(status: h.statusCode, headers: headers, body: data ?? Data(), error: nil)
            } else if let err = err {
                result.error = err.localizedDescription
            }
            sem.signal()
        }.resume()
        sem.wait()
        return result
    }
}

// MARK: - Models

struct UsageRow: Equatable {
    var label: String
    var used: Double
    var resets: Date?
}

enum UsageError: Error, CustomStringConvertible {
    case rateLimited(retryAfter: Int)
    case message(String)
    var description: String {
        switch self {
        case .rateLimited: return "Rate limited by Anthropic; backing off."
        case let .message(m): return m
        }
    }
}

struct ActiveAccount {
    var id: String           // who the tokens really belong to (falls back to configId if unverified)
    var configId: String     // who ~/.claude.json says is signed in
    var verified: Bool       // the token check succeeded
    var mismatch: Bool       // verified and the two disagree
    var email: String?
    var org: String?
    var account: JSON        // the oauthAccount object
    var credText: String?    // exactly the credentials that were verified
}

struct Profile {
    var id: String
    var name: String
    var email: String?
    var org: String?
    var active: Bool
    var path: URL
}

struct OtherAccount {
    var id: String
    var name: String
    var rows: [UsageRow] = []
    var err: String?
    var pending = false
    var eligible = false
    var reason: String?
}

struct SwitchRules {
    var fullAt: Double = 99      // an account is "full" when any limit is at/above this % used
    var minSession: Double = 10  // target's session (5h) limit needs at least this % left
    var minWeekly: Double = 0    // target's weekly limits need at least this % left (0 = any)
    var prefer: String = "reset" // "reset": soonest weekly reset first; "room": most room left first
}

// MARK: - The profile store

final class ClaudeAccounts {
    static let liveService = "Claude Code-credentials"
    static let profileService = "Claude Usage Tray"
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!   // same endpoint/client Claude Code uses
    static let oauthClient = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let userAgent = "claude-usage-tray-mac/1.0"

    var configFile: URL      // ~/.claude.json
    var credFile: URL        // ~/.claude/.credentials.json (Claude Code's plaintext fallback)
    var profilesDir: URL
    var keychainAccount: String
    var profileService: String
    let store: SecretStore
    let http: HTTPClient

    /// Which account does an access token really belong to? Replaceable in tests.
    lazy var identify: (String) -> String? = { [unowned self] in self.fetchTokenIdentity($0) }
    private var tokenIdCache: [String: String] = [:]
    private let lock = NSLock()

    init(configFile: URL, credFile: URL, profilesDir: URL, keychainAccount: String,
         profileService: String = ClaudeAccounts.profileService,
         store: SecretStore, http: HTTPClient) {
        self.configFile = configFile
        self.credFile = credFile
        self.profilesDir = profilesDir
        self.keychainAccount = keychainAccount
        self.profileService = profileService
        self.store = store
        self.http = http
    }

    static var appSupportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeUsageTray", isDirectory: true)
    }

    /// The account name Claude Code files its Keychain item under ($USER, validated the same way).
    static func claudeKeychainAccount() -> String {
        let u = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        let ok = !u.isEmpty && u.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0) }
        return ok ? u : "claude-code-user"
    }

    static func live() -> ClaudeAccounts {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ClaudeAccounts(
            configFile: home.appendingPathComponent(".claude.json"),
            credFile: home.appendingPathComponent(".claude/.credentials.json"),
            profilesDir: appSupportDir.appendingPathComponent("profiles", isDirectory: true),
            keychainAccount: claudeKeychainAccount(),
            store: SecurityCLIStore(), http: URLSessionHTTP())
    }

    // MARK: config file

    func readConfig() throws -> JSON {
        try JSON.parse(try readText(configFile))
    }

    // MARK: live credentials

    enum CredSource { case keychain, file }

    /// The signed-in tokens: the Keychain item, or Claude Code's plaintext fallback file
    /// when there is no Keychain item. nil = not signed in.
    func readLiveCredentials() throws -> (text: String, source: CredSource)? {
        if let t = try store.read(service: Self.liveService, account: keychainAccount) { return (t, .keychain) }
        if fileExists(credFile) { return (try readText(credFile), .file) }
        return nil
    }

    /// Writes the live tokens back to wherever Claude Code keeps them.
    func writeLiveCredentials(_ text: String, source: CredSource) throws {
        switch source {
        case .keychain: try store.write(service: Self.liveService, account: keychainAccount, value: text)
        case .file: try writeFileAtomic(credFile, text)
        }
    }

    static func accessToken(in credText: String?) -> String? {
        guard let t = credText, let j = try? JSON.parse(t) else { return nil }
        return j["claudeAiOauth"]?["accessToken"]?.string
    }

    /// A short fingerprint of the live access token: changes on switches, sign-ins
    /// and token refreshes. No network.
    func liveTokenFingerprint() -> String {
        guard let c = try? readLiveCredentials(), let t = Self.accessToken(in: c.text) else { return "none" }
        return String(sha256Hex(t).prefix(16))
    }

    /// Changes when an account is added, removed or switched - from the app, the CLI
    /// or anywhere else - and when the live token is refreshed. No network.
    func changeSignature() -> String {
        profileIds().joined(separator: ",") + "|" + liveTokenFingerprint()
    }

    // MARK: identity

    func fetchTokenIdentity(_ token: String) -> String? {
        var req = URLRequest(url: Self.profileURL)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let r = http.send(req)
        guard r.status == 200, let j = try? JSON.parse(r.body),
              let a = j["account"]?["uuid"]?.string, let o = j["organization"]?["uuid"]?.string else { return nil }
        return "\(a)_\(o)"
    }

    /// Cached per token, so it's one call per token refresh. nil = unknown (offline / expired):
    /// callers must not trust it.
    func tokenIdentity(_ token: String?) -> String? {
        guard let token = token, !token.isEmpty else { return nil }
        lock.lock()
        if let c = tokenIdCache[token] { lock.unlock(); return c }
        lock.unlock()
        guard let id = identify(token) else { return nil }
        lock.lock()
        if tokenIdCache.count > 50 { tokenIdCache.removeAll() }
        tokenIdCache[token] = id
        lock.unlock()
        return id
    }

    static func profileId(_ acct: JSON) -> String {
        "\(acct["accountUuid"]?.string ?? "")_\(acct["organizationUuid"]?.string ?? "")"
    }

    // MARK: active account

    /// The signed-in account. The tokens are checked against the server, because a
    /// Claude Code session still running on an old account can rewrite them after a switch.
    func activeAccount() -> ActiveAccount? {
        guard fileExists(configFile), let cfg = try? readConfig(), let acct = cfg["oauthAccount"], case .object = acct else { return nil }
        guard let cred = try? readLiveCredentials() else { return nil }
        let configId = Self.profileId(acct)
        let tokenId = tokenIdentity(Self.accessToken(in: cred.text))
        return ActiveAccount(
            id: tokenId ?? configId, configId: configId,
            verified: tokenId != nil, mismatch: tokenId != nil && tokenId != configId,
            email: acct["emailAddress"]?.string, org: acct["organizationName"]?.string,
            account: acct, credText: cred.text)
    }

    /// Best-known active account without any network: what ~/.claude.json says.
    func configActiveId() -> String? {
        guard let cfg = try? readConfig(), let acct = cfg["oauthAccount"], case .object = acct else { return nil }
        return Self.profileId(acct)
    }

    // MARK: profiles

    func profiles(activeId: String?) -> [Profile] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: profilesDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var out: [Profile] = []
        for d in dirs {
            guard (try? d.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let metaPath = d.appendingPathComponent("profile.json")
            guard let m = try? JSON.parse(readText(metaPath)) else { continue }
            let id = d.lastPathComponent
            out.append(Profile(id: id, name: m["name"]?.string ?? id, email: m["email"]?.string, org: m["org"]?.string,
                               active: activeId == id, path: d))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func profileIds() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: profilesDir.path)) ?? []
        return names.filter { !$0.hasPrefix(".") && fileExists(profilesDir.appendingPathComponent($0).appendingPathComponent("profile.json")) }.sorted()
    }

    private func writeIfChanged(_ url: URL, _ text: String) throws {
        if let cur = try? readText(url), cur == text { return }
        try writeFileAtomic(url, text)
    }

    /// Only the Claude login is kept in a profile; other keys in Claude Code's
    /// credentials (such as MCP server logins) belong to this Mac, not an account.
    static func oauthOnly(_ credText: String) throws -> String {
        guard let oauth = try JSON.parse(credText)["claudeAiOauth"], case .object = oauth else {
            throw CoreError("The credentials contain no Claude login.")
        }
        return JSON.object([("claudeAiOauth", oauth)]).serialized(indent: nil)
    }

    func savedCredentials(_ id: String) throws -> String? {
        try store.read(service: profileService, account: id)
    }

    /// Store a login (credentials JSON + oauthAccount object) as a profile.
    @discardableResult
    func saveProfileSnapshot(credText: String, account: JSON, name: String?) throws -> String {
        let id = Self.profileId(account)
        let dir = profilesDir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        // Tokens first, so a profile.json never exists without its login.
        let secret = try Self.oauthOnly(credText)
        if (try? savedCredentials(id)) != secret {
            try store.write(service: profileService, account: id, value: secret)
        }

        let metaPath = dir.appendingPathComponent("profile.json")
        var meta = (try? JSON.parse(readText(metaPath))) ?? .object([])
        if case .object = meta {} else { meta = .object([]) }
        if let n = name, !n.isEmpty { meta["name"] = .string(n) }
        if (meta["name"]?.string ?? "").isEmpty {
            let email = account["emailAddress"]?.string ?? id
            if let org = account["organizationName"]?.string, !org.isEmpty {
                meta["name"] = .string("\(email) (\(org))")
            } else {
                meta["name"] = .string(email)
            }
        }
        meta["email"] = account["emailAddress"] ?? .null
        meta["org"] = account["organizationName"] ?? .null

        try writeIfChanged(dir.appendingPathComponent("oauthAccount.json"), account.serialized())
        try writeIfChanged(metaPath, meta.serialized())
        return id
    }

    /// Snapshot the signed-in account into its profile (creating it if new). Called on
    /// every poll so stored refresh tokens never go stale. Only saves tokens once the
    /// server has confirmed whose they are.
    @discardableResult
    func syncActiveProfile(name: String? = nil, active: ActiveAccount? = nil) -> String? {
        guard let a = active ?? activeAccount(), a.verified, let cred = a.credText else { return nil }
        if !a.mismatch { return try? saveProfileSnapshot(credText: cred, account: a.account, name: name) }

        // Tokens belong to a different account than ~/.claude.json says. If we know
        // that account, keep its (possibly just-refreshed) tokens in its own profile.
        let acctPath = profilesDir.appendingPathComponent(a.id).appendingPathComponent("oauthAccount.json")
        if let acct = try? JSON.parse(readText(acctPath)) {
            return try? saveProfileSnapshot(credText: cred, account: acct, name: nil)
        }
        return nil
    }

    /// Import a login made with CLAUDE_CONFIG_DIR=<dir> (see `claude-profile add`).
    /// Does not touch the active login.
    func importLoginDir(_ dir: URL, keychainService: String?, name: String?) throws -> String {
        var credText: String? = nil
        if let svc = keychainService { credText = try? store.read(service: svc, account: keychainAccount) }
        if credText == nil {
            let f = dir.appendingPathComponent(".credentials.json")
            if fileExists(f) { credText = try readText(f) }
        }
        guard let cred = credText else { throw CoreError("No login found (sign-in cancelled?).") }

        var cfgURL = [dir.appendingPathComponent(".claude.json"), dir.appendingPathComponent("config.json")].first(where: fileExists)
        if cfgURL == nil, let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) {
            for case let u as URL in e where u.pathExtension == "json" {
                if let t = try? readText(u), t.contains("\"oauthAccount\"") { cfgURL = u; break }
            }
        }
        guard let cfg = cfgURL else { throw CoreError("Signed in, but couldn't find the account details in \(dir.path).") }
        guard let acct = try JSON.parse(readText(cfg))["oauthAccount"], case .object = acct else {
            throw CoreError("Signed in, but no oauthAccount in \(cfg.path).")
        }
        return try saveProfileSnapshot(credText: cred, account: acct, name: name)
    }

    /// The Keychain item name Claude Code uses when CLAUDE_CONFIG_DIR is set.
    static func keychainService(forConfigDir dir: String) -> String {
        let norm = dir.precomposedStringWithCanonicalMapping   // NFC, as Claude Code does
        return liveService + "-" + String(sha256Hex(norm).prefix(8))
    }

    // MARK: tokens for any profile

    /// Access token for a profile. The active account always uses the live login
    /// (Claude Code owns refreshing it). Inactive profiles are refreshed here when
    /// expired and the rotated tokens are written straight back to the profile.
    func accessToken(for p: Profile, now: Date = Date()) throws -> String {
        if p.active {
            guard let t = Self.accessToken(in: try readLiveCredentials()?.text) else { throw CoreError("No login token found. Run 'claude' and log in.") }
            return t
        }
        guard let text = try savedCredentials(p.id), var cred = try? JSON.parse(text), var o = cred["claudeAiOauth"] else {
            throw CoreError("Saved login is missing. Switch to this account in Claude Code and sign in again.")
        }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        if let exp = o["expiresAt"]?.int64, exp - nowMs > 300_000, let t = o["accessToken"]?.string { return t }

        var body: [(String, JSON)] = [("grant_type", .string("refresh_token")),
                                      ("refresh_token", .string(o["refreshToken"]?.string ?? "")),
                                      ("client_id", .string(Self.oauthClient))]
        if let scopes = o["scopes"]?.array, !scopes.isEmpty {
            body.append(("scope", .string(scopes.compactMap { $0.string }.joined(separator: " "))))
        }
        var req = URLRequest(url: Self.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.httpBody = Data(JSON.object(body).serialized(indent: nil).utf8)
        let r = http.send(req)
        guard r.status == 200, let j = try? JSON.parse(r.body), let access = j["access_token"]?.string else {
            throw CoreError("Saved login expired and could not be refreshed. Switch to this account in Claude Code (or sign in again).")
        }
        o["accessToken"] = .string(access)
        if let rt = j["refresh_token"]?.string { o["refreshToken"] = .string(rt) }
        let expiresIn = j["expires_in"]?.int64 ?? 3600
        o["expiresAt"] = .num(nowMs + expiresIn * 1000)
        cred["claudeAiOauth"] = o
        // Rotated refresh token: persist immediately or the profile is lost.
        try store.write(service: profileService, account: p.id, value: cred.serialized(indent: nil))
        return access
    }

    // MARK: usage

    static func parseDate(_ s: String?) -> Date? {
        guard var s = s, !s.isEmpty else { return nil }
        // Drop fractional seconds of any length; ISO8601DateFormatter is picky about them.
        if let r = s.range(of: #"\.\d+"#, options: .regularExpression) { s.removeSubrange(r) }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// Usage rows for a token. Throws UsageError with a readable message.
    func usageRows(token: String) throws -> [UsageRow] {
        var req = URLRequest(url: Self.usageURL)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let r = http.send(req)
        if r.status == 401 { throw UsageError.message("Token expired. Open Claude Code once to refresh it.") }
        if r.status == 429 { throw UsageError.rateLimited(retryAfter: Int(r.headers["retry-after"] ?? "") ?? 0) }
        if r.status == 0 { throw UsageError.message("Request failed: \(r.error ?? "no response")") }
        if r.status != 200 { throw UsageError.message("Request failed: HTTP \(r.status)") }
        guard let j = try? JSON.parse(r.body) else { throw UsageError.message("Usage response was not JSON.") }
        let rows = Self.parseUsage(j)
        if rows.isEmpty { throw UsageError.message("Usage response contained no limits.") }
        return rows
    }

    static func parseUsage(_ j: JSON) -> [UsageRow] {
        var rows: [UsageRow] = []
        if let limits = j["limits"]?.array, !limits.isEmpty {
            for l in limits {
                let kind = l["kind"]?.string ?? ""
                let label: String
                switch kind {
                case "session": label = "Session (5h)"
                case "weekly_all": label = "Weekly"
                case "weekly_scoped":
                    let n = l["scope"]?["model"]?["display_name"]?.string ?? l["scope"]?["surface"]?.string
                    label = (n?.isEmpty == false) ? "Weekly \(n!)" : "Weekly (scoped)"
                default: label = kind.replacingOccurrences(of: "_", with: " ")
                }
                rows.append(UsageRow(label: label, used: l["percent"]?.double ?? 0, resets: parseDate(l["resets_at"]?.string)))
            }
        } else {
            for (key, label) in [("five_hour", "Session (5h)"), ("seven_day", "Weekly"), ("seven_day_opus", "Weekly Opus"), ("seven_day_sonnet", "Weekly Sonnet")] {
                guard let v = j[key], case .object = v else { continue }
                rows.append(UsageRow(label: label, used: v["utilization"]?.double ?? 0, resets: parseDate(v["resets_at"]?.string)))
            }
        }
        return rows
    }

    // MARK: find / switch / rename / remove

    func findProfile(_ nameOrId: String, activeId: String?) throws -> Profile {
        let all = profiles(activeId: activeId)
        if let p = all.first(where: { $0.id == nameOrId || $0.name == nameOrId }) { return p }
        if let p = all.first(where: { $0.email == nameOrId }) { return p }
        if let p = all.first(where: { $0.name.localizedCaseInsensitiveContains(nameOrId) }) { return p }
        throw CoreError("No profile matches '\(nameOrId)'.")
    }

    @discardableResult
    func switchProfile(_ nameOrId: String, active: ActiveAccount? = nil) throws -> Profile {
        let act = active ?? activeAccount()
        var target = try findProfile(nameOrId, activeId: act?.id)
        // Already active and consistent: nothing to do. (On a mismatch we still write
        // both, which repairs them.)
        if target.active && !(act?.mismatch ?? false) { return target }

        // Keep the outgoing account's (possibly refreshed) tokens - only once verified.
        syncActiveProfile(active: act)

        guard let saved = try savedCredentials(target.id), let targetOauth = try JSON.parse(saved)["claudeAiOauth"] else {
            throw CoreError("The saved login for \(target.name) is missing. Sign in to it again with 'claude-profile add'.")
        }
        let acct = try JSON.parse(readText(target.path.appendingPathComponent("oauthAccount.json")))

        // Re-read the live login right now and swap only the Claude login in it,
        // keeping everything else Claude Code stores there (e.g. MCP server logins).
        let live = try readLiveCredentials()
        var liveJSON: JSON = .object([])
        if let t = live?.text, let parsed = try? JSON.parse(t), case .object = parsed { liveJSON = parsed }
        liveJSON["claudeAiOauth"] = targetOauth
        let newCred = liveJSON.serialized(indent: nil)
        let source = live?.source ?? .keychain

        // One rolling backup of the config before touching it.
        let configText = try readText(configFile)
        let backup = URL(fileURLWithPath: configFile.path + ".switcher-backup")
        try writeFileAtomic(backup, configText)
        var cfg = try JSON.parse(configText)
        cfg["oauthAccount"] = acct
        try writeFileAtomic(configFile, cfg.serialized())

        do {
            try writeLiveCredentials(newCred, source: source)
            let check = try readLiveCredentials()
            guard Self.accessToken(in: check?.text) == targetOauth["accessToken"]?.string else {
                throw CoreError("The new login didn't stick (read-back mismatch).")
            }
        } catch {
            // Put the account details back so the two halves stay consistent.
            try? writeFileAtomic(configFile, configText)
            throw CoreError("Switch failed, nothing changed: \(error)")
        }

        target.active = true
        return target
    }

    func renameProfile(_ nameOrId: String, to newName: String) throws {
        let p = try findProfile(nameOrId, activeId: configActiveId())
        let metaPath = p.path.appendingPathComponent("profile.json")
        var meta = try JSON.parse(readText(metaPath))
        meta["name"] = .string(newName)
        try writeFileAtomic(metaPath, meta.serialized())
    }

    func removeProfile(_ nameOrId: String, activeId: String?) throws {
        let p = try findProfile(nameOrId, activeId: activeId)
        if p.active { throw CoreError("'\(p.name)' is the active account; switch away first.") }
        try FileManager.default.removeItem(at: p.path)
        store.delete(service: profileService, account: p.id)
    }
}

// MARK: - Rate-limit pause

/// Is a saved rate-limit pause still in effect? It must be active (sec > 0) and end in
/// the future - but no further ahead than its own length. That last check catches clock
/// jumps: a pause saved while the clock was an hour fast would otherwise look like it
/// still has an hour to go.
func backoffActive(until: Date, sec: Int, now: Date = Date()) -> Bool {
    if sec <= 0 { return false }
    let remaining = until.timeIntervalSince(now)
    return remaining > 0 && remaining <= Double(sec + 5)
}

// MARK: - Usage notifications

struct NoticeState {
    var warnedFor: String?
    var prevUsed: Double?
}

struct UsageNotice {
    enum Kind { case warn, reset }
    var kind: Kind
    var row: UsageRow
}

/// Which notices to show for one account's latest numbers. `state` is kept between
/// checks (per account) so each notice fires once:
///   warn  - a limit reached `warnAt` % (once per reset window)
///   reset - a limit that was at least half used dropped to under half of that
func usageNotices(_ rows: [UsageRow], state: inout [String: NoticeState], warnAt: Double, onReset: Bool) -> [UsageNotice] {
    var notices: [UsageNotice] = []
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyyMMddHH"
    for r in rows {
        var st = state[r.label] ?? NoticeState()
        let window = r.resets.map { f.string(from: $0) } ?? "none"
        if onReset, let prev = st.prevUsed, prev >= 50, r.used < prev / 2 {
            notices.append(UsageNotice(kind: .reset, row: r))
            st.warnedFor = nil
        }
        if warnAt > 0, r.used >= warnAt, st.warnedFor != window {
            notices.append(UsageNotice(kind: .warn, row: r))
            st.warnedFor = window
        }
        st.prevUsed = r.used
        state[r.label] = st
    }
    return notices
}

// MARK: - Auto-switch selection

func maxUsed(_ rows: [UsageRow]) -> Double { rows.map(\.used).max().map { max(0, $0) } ?? 0 }

/// Rows to draw. Once the all-models weekly limit is spent, the session and
/// per-model limits don't matter until it resets, so only that row is shown.
/// Display only: auto-switch and notifications still use every row.
func displayRows(_ rows: [UsageRow]) -> [UsageRow] {
    if let wk = rows.first(where: { $0.label == "Weekly" && $0.used >= 100 }) {
        return [UsageRow(label: "Weekly – used up", used: wk.used, resets: wk.resets)]
    }
    return rows
}

/// Soonest weekly reset (fallback: soonest of any limit). Accounts whose weekly
/// allowance resets soonest are used first, so that allowance isn't wasted.
func priorityReset(_ rows: [UsageRow]) -> Date {
    let weekly = rows.filter { $0.label.hasPrefix("Weekly") }.compactMap(\.resets)
    let pool = weekly.isEmpty ? rows.compactMap(\.resets) : weekly
    return pool.min() ?? .distantFuture
}

/// Why an account can't be switched to, or nil if it can.
func ineligibleReason(_ o: OtherAccount, _ rules: SwitchRules) -> String? {
    if o.pending { return "NOT CHECKED" }
    if o.err != nil { return "ERROR" }
    if o.rows.isEmpty { return "NO DATA" }
    for r in o.rows {
        let left = 100 - r.used
        let isSession = r.label.hasPrefix("Session")
        if r.used >= rules.fullAt { return isSession ? "SESSION FULL" : "WEEKLY FULL" }
        if isSession && left < rules.minSession { return "LOW SESSION" }
        if !isSession && left < rules.minWeekly { return "LOW WEEKLY" }
    }
    return nil
}

/// Least room left on any weekly limit (used for the "room" preference).
func weeklyLeft(_ rows: [UsageRow]) -> Double {
    let w = rows.filter { !$0.label.hasPrefix("Session") }
    return 100 - maxUsed(w.isEmpty ? rows : w)
}

/// Others ordered for switching: eligible first (by preference), then the rest.
/// Sets eligible and reason on each entry.
func sortSwitchCandidates(_ others: [OtherAccount], _ rules: SwitchRules) -> [OtherAccount] {
    let marked = others.map { o -> OtherAccount in
        var o = o
        o.reason = ineligibleReason(o, rules)
        o.eligible = o.reason == nil
        return o
    }
    let eligible = marked.enumerated().filter { $0.element.eligible }.sorted { a, b in
        let (ra, rb) = (priorityReset(a.element.rows), priorityReset(b.element.rows))
        let (wa, wb) = (weeklyLeft(a.element.rows), weeklyLeft(b.element.rows))
        if rules.prefer == "room" {
            if wa != wb { return wa > wb }
            if ra != rb { return ra < rb }
        } else {
            if ra != rb { return ra < rb }
            if wa != wb { return wa > wb }
        }
        return a.offset < b.offset
    }.map(\.element)
    return eligible + marked.filter { !$0.eligible }
}

/// The account to switch to, or nil. Does not check whether a switch is due.
func selectAutoSwitchTarget(_ others: [OtherAccount], _ rules: SwitchRules) -> OtherAccount? {
    guard let first = sortSwitchCandidates(others, rules).first, first.eligible else { return nil }
    return first
}

// MARK: - Formatting

func formatUntil(_ when: Date?, now: Date = Date()) -> String {
    guard let when = when else { return "" }
    let s = when.timeIntervalSince(now)
    if s <= 0 { return "resetting" }
    let days = Int(s / 86400), hours = Int(s.truncatingRemainder(dividingBy: 86400) / 3600)
    if s >= 86400 { return "\(days)d \(hours)h" }
    let mins = Int(s.truncatingRemainder(dividingBy: 3600) / 60)
    if s >= 3600 { return "\(Int(s / 3600))h \(mins)m" }
    let up = max(1, Int((s / 60).rounded(.up)))
    return up >= 60 ? "1h 0m" : "\(up)m"   // 59m 30s is "1h 0m", not "60m"
}
