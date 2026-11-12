import Foundation

/*
  Tests for Core.swift (the macOS port of tests/Run-Tests.ps1). No network, never
  touches your real Claude login: every test uses a temp folder, an in-memory
  Keychain and fake HTTP responses.

    mac/build.sh test

  Exit code = number of failed tests.
*/

// ---------- tiny test harness ----------
var passed = 0
var failed: [String] = []
struct AssertFail: Error { let m: String }

func test(_ name: String, _ body: () throws -> Void) {
    do { try body(); passed += 1; print("  ok   \(name)") }
    catch let e as AssertFail { failed.append(name); print("  FAIL \(name)\n       \(e.m)") }
    catch { failed.append(name); print("  FAIL \(name)\n       threw: \(error)") }
}
func assertEqual<T: Equatable>(_ expected: T, _ actual: T, _ what: String = "value") throws {
    if expected != actual { throw AssertFail(m: "\(what): expected '\(expected)', got '\(actual)'") }
}
func assertTrue(_ cond: Bool, _ what: String) throws { if !cond { throw AssertFail(m: "expected: \(what)") } }
func section(_ s: String) { print(s) }

// ---------- fakes ----------
final class MemoryStore: SecretStore {
    var items: [String: String] = [:]          // "service|account" -> value
    var failReadsOf: String? = nil       // a service whose reads fail (e.g. a locked Keychain)
    func key(_ s: String, _ a: String) -> String { "\(s)|\(a)" }
    func read(service: String, account: String) throws -> String? {
        if service == failReadsOf { throw CoreError("locked") }
        return items[key(service, account)]
    }
    var failWritesOf: String? = nil
    func write(service: String, account: String, value: String) throws {
        if service == failWritesOf { throw CoreError("write refused") }
        items[key(service, account)] = value
    }
    func delete(service: String, account: String) { items[key(service, account)] = nil }
    func services(withPrefix prefix: String) -> [String] {
        items.keys.map { String($0.split(separator: "|")[0]) }.filter { $0.hasPrefix(prefix) }
    }
}

final class FakeHTTP: HTTPClient {
    var calls: [URLRequest] = []
    var reply: (URLRequest) -> HTTPResponse = { _ in HTTPResponse(status: 0, headers: [:], body: Data(), error: "offline") }
    func send(_ req: URLRequest) -> HTTPResponse { calls.append(req); return reply(req) }
    static func json(_ s: String, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(status: status, headers: headers, body: Data(s.utf8), error: nil)
    }
}

// ---------- fixtures ----------
let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-switcher-tests-\(UUID().uuidString)")
let testService = "Claude Usage Tray TEST"   // never the real service names
var store = MemoryStore()
var http = FakeHTTP()
var fakeIds: [String: String] = [:]
var acc: ClaudeAccounts!

func account(_ a: String, _ org: String, _ email: String) -> JSON {
    .object([("accountUuid", .string(a)), ("organizationUuid", .string(org)), ("emailAddress", .string(email)), ("organizationName", .string("Org"))])
}
func cred(_ token: String, refresh: String = "r-1", expiresInMs: Int64 = 3_600_000, extra: Bool = false) -> String {
    let exp = Int64(Date().timeIntervalSince1970 * 1000) + expiresInMs
    var pairs: [(String, JSON)] = []
    if extra { pairs.append(("mcpOAuth", .object([("srv", .string("mcp-token"))]))) }
    pairs.append(("claudeAiOauth", .object([("accessToken", .string(token)), ("refreshToken", .string(refresh)),
                                            ("expiresAt", .num(exp)), ("scopes", .array([.string("user:inference")]))])))
    return JSON.object(pairs).serialized(indent: nil)
}
let liveKey = "\(ClaudeAccounts.liveService)|tester"
func liveCred() -> String { store.items[liveKey] ?? "" }
func setLiveCred(_ s: String) { store.items[liveKey] = s }
func saved(_ id: String) -> String { store.items["\(testService)|\(id)"] ?? "" }

/// Fresh sandbox per test: a fake ~/.claude.json, Keychain and profiles dir.
func resetSandbox(_ configAccount: JSON, _ credText: String) {
    try? FileManager.default.removeItem(at: root)
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    store = MemoryStore(); http = FakeHTTP(); fakeIds = [:]
    acc = ClaudeAccounts(configFile: root.appendingPathComponent(".claude.json"),
                         credFile: root.appendingPathComponent(".credentials.json"),
                         profilesDir: root.appendingPathComponent("profiles"),
                         keychainAccount: "tester", profileService: testService,
                         store: store, http: http)
    acc.identify = { fakeIds[$0] }
    let cfg = """
    {
      "numStartups": 42,
      "projects": {
        "/x": {
          "allowedTools": []
        }
      },
      "unicode": "café <tag> & 'q' \\"quoted\\" / \\u0001 😀",
      "big": 1794520861414,
      "ratio": 0.5,
      "flag": false,
      "empty": {},
      "oauthAccount": \(configAccount.serialized(indent: nil))
    }
    """
    try! cfg.write(to: acc.configFile, atomically: true, encoding: .utf8)
    setLiveCred(credText)
}

let A = account("acctA", "org1", "a@example.com"); let AId = "acctA_org1"
let B = account("acctB", "org1", "b@example.com"); let BId = "acctB_org1"
func profile(_ id: String) -> Profile? { acc.profiles(activeId: acc.activeAccount()?.id).first { $0.id == id } }

section("Login files")

test("config JSON survives a read/write round-trip unchanged") {
    resetSandbox(A, cred("tokA"))
    let before = try readText(acc.configFile)
    let reparsed = try JSON.parse(before)
    try writeFileAtomic(acc.configFile, reparsed.serialized())
    try assertTrue(try JSON.parse(readText(acc.configFile)) == reparsed, "same value")
    // JSON.stringify(x, null, 2) of the pretty file reproduces it byte for byte
    let pretty = try JSON.parse(before).serialized()
    try writeFileAtomic(acc.configFile, pretty)
    try assertEqual(pretty, try JSON.parse(readText(acc.configFile)).serialized(), "stable text")
    try assertTrue(pretty.contains("\"big\": 1794520861414"), "big number kept exactly")
    try assertTrue(pretty.contains("café <tag> & 'q' \\\"quoted\\\" / \\u0001 😀"), "strings escaped like JSON.stringify")
}

test("active account is verified when the token matches the config") {
    resetSandbox(A, cred("tokA")); fakeIds["tokA"] = AId
    let a = acc.activeAccount()!
    try assertTrue(a.verified, "verified"); try assertTrue(!a.mismatch, "no mismatch"); try assertEqual(AId, a.id, "id")
}

test("a token belonging to another account is reported as a mismatch") {
    resetSandbox(A, cred("tokB")); fakeIds["tokB"] = BId
    let a = acc.activeAccount()!
    try assertTrue(a.mismatch, "mismatch"); try assertEqual(BId, a.id, "real owner"); try assertEqual(AId, a.configId, "config id")
}

test("unverifiable token (offline) falls back to config and is not trusted") {
    resetSandbox(A, cred("tokA"))
    let a = acc.activeAccount()!
    try assertTrue(!a.verified, "not verified"); try assertEqual(AId, a.id, "fallback id")
    try assertEqual(nil, acc.syncActiveProfile(active: a), "nothing saved")
    try assertTrue(!fileExists(acc.profilesDir.appendingPathComponent(AId)), "no profile created")
}

test("sync saves a verified login into its own profile") {
    resetSandbox(A, cred("tokA")); fakeIds["tokA"] = AId
    try assertEqual(AId, acc.syncActiveProfile(), "saved id")
    let p = profile(AId)!
    try assertEqual("a@example.com (Org)", p.name, "default name")
    try assertTrue(saved(AId).contains("tokA"), "tokens saved")
}

test("profiles keep only the Claude login, not other Keychain contents") {
    resetSandbox(A, cred("tokA", extra: true)); fakeIds["tokA"] = AId
    acc.syncActiveProfile()
    try assertTrue(!saved(AId).contains("mcp-token"), "MCP logins not copied")
    try assertTrue(!fileExists(acc.profilesDir.appendingPathComponent(AId).appendingPathComponent("credentials.json")), "no token file on disk")
}

test("on a mismatch, tokens go only to their real owner's profile") {
    resetSandbox(A, cred("tokA")); fakeIds["tokA"] = AId; acc.syncActiveProfile()
    try acc.saveProfileSnapshot(credText: cred("tokB-old"), account: B, name: nil)
    setLiveCred(cred("tokB-new")); fakeIds["tokB-new"] = BId
    try assertEqual(BId, acc.syncActiveProfile(), "saved to")
    try assertTrue(saved(AId).contains("tokA"), "A untouched")
    try assertTrue(saved(BId).contains("tokB-new"), "B updated")
}

test("sync saves exactly the credentials it verified, even if they changed since") {
    resetSandbox(A, cred("tokA")); fakeIds["tokA"] = AId
    let a = acc.activeAccount()
    setLiveCred(cred("tokB"))   // a switch happens mid-check
    acc.syncActiveProfile(active: a)
    try assertTrue(saved(AId).contains("tokA"), "A keeps its own token")
}

test("switching writes both halves, keeps other config keys and makes a backup") {
    resetSandbox(A, cred("tokA")); fakeIds["tokA"] = AId; acc.syncActiveProfile()
    try acc.saveProfileSnapshot(credText: cred("tokB"), account: B, name: nil)
    try acc.switchProfile("b@example.com")
    let cfg = try acc.readConfig()
    try assertEqual("acctB", cfg["oauthAccount"]?["accountUuid"]?.string, "config account")
    try assertEqual(JSON.number("42"), cfg["numStartups"], "other keys kept")
    try assertEqual("numStartups", { if case let .object(p) = cfg { return p[0].0 }; return "" }(), "key order kept")
    try assertTrue(liveCred().contains("tokB"), "credentials swapped")
    try assertTrue(fileExists(URL(fileURLWithPath: acc.configFile.path + ".switcher-backup")), "backup written")
}

test("switching keeps the Mac's other logins (MCP) in the live Keychain item") {
    resetSandbox(A, cred("tokA", extra: true)); fakeIds["tokA"] = AId; acc.syncActiveProfile()
    try acc.saveProfileSnapshot(credText: cred("tokB"), account: B, name: nil)
    try acc.switchProfile(BId)
    try assertTrue(liveCred().contains("tokB"), "switched")
    try assertTrue(liveCred().contains("mcp-token"), "MCP login kept")
}

test("switching keeps the config file's permissions") {
    resetSandbox(A, cred("tokA")); fakeIds["tokA"] = AId; acc.syncActiveProfile()
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: acc.configFile.path)
    try acc.saveProfileSnapshot(credText: cred("tokB"), account: B, name: nil)
    try acc.switchProfile(BId)
    let perms = try FileManager.default.attributesOfItem(atPath: acc.configFile.path)[.posixPermissions] as? Int
    try assertEqual(0o600, perms ?? 0, "mode")
}

test("switching uses the plaintext file when Claude Code has no Keychain item") {
    resetSandbox(A, cred("tokA")); store.items[liveKey] = nil
    try cred("tokA").write(to: acc.credFile, atomically: true, encoding: .utf8)
    fakeIds["tokA"] = AId; acc.syncActiveProfile()
    try acc.saveProfileSnapshot(credText: cred("tokB"), account: B, name: nil)
    try acc.switchProfile(BId)
    try assertTrue(try readText(acc.credFile).contains("tokB"), "file swapped")
    try assertEqual(nil, store.items[liveKey], "no Keychain item created")
}

test("a Keychain that can't be read stops the switch before anything changes") {
    resetSandbox(A, cred("tokA")); fakeIds["tokA"] = AId; acc.syncActiveProfile()
    try acc.saveProfileSnapshot(credText: cred("tokB"), account: B, name: nil)
    let before = try readText(acc.configFile)
    let p = acc.profiles(activeId: AId)
    store.failReadsOf = ClaudeAccounts.liveService
    var threw = false
    do { try acc.switchProfile(BId, active: acc.activeAccount() ?? ActiveAccount(id: AId, configId: AId, verified: true, mismatch: false, email: nil, org: nil, account: A, credText: nil)) } catch { threw = true }
    store.failReadsOf = nil
    try assertTrue(threw, "refused"); try assertEqual(2, p.count, "profiles")
    try assertEqual(before, try readText(acc.configFile), "config untouched")
}

test("a failed Keychain write puts the account details back") {
    resetSandbox(A, cred("tokA")); fakeIds["tokA"] = AId; acc.syncActiveProfile()
    try acc.saveProfileSnapshot(credText: cred("tokB"), account: B, name: nil)
    let before = try readText(acc.configFile)
    store.failWritesOf = ClaudeAccounts.liveService
    var threw = false
    do { try acc.switchProfile(BId) } catch { threw = true }
    store.failWritesOf = nil
    try assertTrue(threw, "reported")
    try assertEqual(before, try readText(acc.configFile), "config restored")
    try assertTrue(liveCred().contains("tokA"), "still signed in as A")
}

test("switching to the token owner during a mismatch repairs the config") {
    resetSandbox(A, cred("tokB")); fakeIds["tokB"] = BId
    try acc.saveProfileSnapshot(credText: cred("tokB"), account: B, name: nil)
    try acc.switchProfile(BId)
    try assertEqual("acctB", try acc.readConfig()["oauthAccount"]?["accountUuid"]?.string, "config repaired")
    try assertTrue(!(acc.activeAccount()!.mismatch), "consistent afterwards")
}

test("the active profile cannot be removed; others are removed with their Keychain item") {
    resetSandbox(A, cred("tokA")); fakeIds["tokA"] = AId; acc.syncActiveProfile()
    var threw = false
    do { try acc.removeProfile(AId, activeId: AId) } catch { threw = true }
    try assertTrue(threw, "refused")
    try acc.saveProfileSnapshot(credText: cred("tokB"), account: B, name: nil)
    try acc.removeProfile(BId, activeId: AId)
    try assertEqual("", saved(BId), "B's tokens deleted")
}

test("a login made in a separate config dir is imported from its own Keychain item") {
    resetSandbox(A, cred("tokA"))
    let dir = root.appendingPathComponent("login-tmp")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try JSON.object([("oauthAccount", B)]).serialized().write(to: dir.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
    let svc = ClaudeAccounts.keychainService(forConfigDir: dir.path)
    try store.write(service: svc, account: "tester", value: cred("tokB"))
    try assertEqual(BId, try acc.importLoginDir(dir, keychainService: svc, name: "Work"), "imported")
    try assertEqual("Work", profile(BId)?.name ?? "", "named")
    try assertTrue(liveCred().contains("tokA"), "active login untouched")
}

test("Keychain item name for a config dir matches Claude Code's") {
    // printf %s /tmp/x | shasum -a 256  ->  2e56aa36...
    try assertEqual("Claude Code-credentials-2e56aa36", ClaudeAccounts.keychainService(forConfigDir: "/tmp/x"), "name")
    try assertEqual(8, ClaudeAccounts.keychainService(forConfigDir: "/a").count - "Claude Code-credentials-".count, "8 hex chars")
}

section("Adding an account (sign-in window)")

/// A stand-in for `claude auth login` that speaks the same protocol: prints the
/// sign-in link (wrapped in a terminal hyperlink), waits for a pasted code on stdin,
/// rejects a malformed or wrong one, and on "good#..." writes a login into
/// CLAUDE_CONFIG_DIR and exits 0.
func fakeClaude() throws -> String {
    let path = root.appendingPathComponent("fake-claude").path
    let cfg = JSON.object([("oauthAccount", B)]).serialized()
    let script = """
    #!/bin/sh
    [ "$1 $2" = "auth login" ] || exit 2
    printf 'Opening browser to sign in\\342\\200\\246\\n'
    printf "If the browser didn't open, visit: \\033]8;;https://example.test/auth?x=1\\007https://example.test/auth?x=1\\033]8;;\\007\\n"
    printf 'Paste code here if prompted > '
    while IFS= read -r line; do
      case "$line" in
        good\\#*)
          cat > "$CLAUDE_CONFIG_DIR/.claude.json" <<'CFG'
    \(cfg)
    CFG
          printf '%s' '\(cred("tokB"))' > "$CLAUDE_CONFIG_DIR/.credentials.json"
          echo "Login successful."; exit 0;;
        *\\#*) echo "Login failed: That code wasn't accepted." >&2; exit 1;;
        *) echo "Invalid code. Please make sure the full code was copied." >&2;;
      esac
    done
    exit 130
    """
    try script.write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    return path
}

/// Collects a runner's events so a test can wait for them.
final class RunnerWatch {
    let lock = NSLock()
    var url: URL?
    var result: Result<String, Error>?
    let gotURL = DispatchSemaphore(value: 0), gotResult = DispatchSemaphore(value: 0)
    init(_ r: LoginRunner) {
        r.onEvent = { [self] e in
            lock.lock(); defer { lock.unlock() }
            switch e {
            case let .url(u): url = u; gotURL.signal()
            case .invalidCode: break
            case let .finished(res): result = res; gotResult.signal()
            }
        }
    }
    func waitURL() throws { if gotURL.wait(timeout: .now() + 10) == .timedOut { throw AssertFail(m: "no sign-in link") } }
    func waitResult() throws -> Result<String, Error> {
        if gotResult.wait(timeout: .now() + 10) == .timedOut { throw AssertFail(m: "sign-in never finished") }
        lock.lock(); defer { lock.unlock() }; return result!
    }
}

func loginDirs(_ base: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []).filter { $0.hasPrefix("login-") }
}

test("sign-in window: a pasted code signs in, saves the profile and cleans up") {
    resetSandbox(A, cred("tokA"))
    let base = root.appendingPathComponent("support")
    let r = LoginRunner(acc: acc, claude: try fakeClaude(), base: base, name: "Work")
    let w = RunnerWatch(r)
    try r.start()
    try w.waitURL()
    try assertEqual("https://example.test/auth?x=1", w.url?.absoluteString ?? "", "link without terminal escapes")
    try assertTrue(loginDirs(base).count == 1, "signs in inside a throwaway folder")
    try assertTrue(!r.submitCode("no-hash-here"), "a code without #state is refused before sending")
    try assertTrue(!r.submitCode("a#b c"), "a code with spaces is refused")
    try assertTrue(r.submitCode("  good#state\n"), "a whole code is sent")
    guard case let .success(id) = try w.waitResult() else { throw AssertFail(m: "expected success") }
    try assertEqual(BId, id, "profile id")
    try assertEqual("Work", profile(BId)?.name ?? "", "saved with its name")
    try assertTrue(saved(BId).contains("tokB"), "tokens saved")
    try assertTrue(liveCred().contains("tokA"), "active login untouched")
    try assertEqual(0, loginDirs(base).count, "throwaway folder removed")
}

test("sign-in window: a rejected code reports Claude Code's message and saves nothing") {
    resetSandbox(A, cred("tokA"))
    let base = root.appendingPathComponent("support")
    let r = LoginRunner(acc: acc, claude: try fakeClaude(), base: base)
    let w = RunnerWatch(r)
    try r.start()
    try w.waitURL()
    r.submitCode("bad#state")
    guard case let .failure(e) = try w.waitResult() else { throw AssertFail(m: "expected failure") }
    try assertEqual("That code wasn't accepted.", "\(e)", "message")
    try assertTrue(profile(BId) == nil, "nothing saved")
    try assertEqual(0, loginDirs(base).count, "throwaway folder removed")
}

test("sign-in window: cancelling stops Claude Code and cleans up") {
    resetSandbox(A, cred("tokA"))
    let base = root.appendingPathComponent("support")
    let r = LoginRunner(acc: acc, claude: try fakeClaude(), base: base)
    let w = RunnerWatch(r)
    try r.start()
    try w.waitURL()
    r.cancel()
    guard case let .failure(e) = try w.waitResult() else { throw AssertFail(m: "expected cancel") }
    try assertTrue(e is LoginCancelled, "reported as cancelled, got \(e)")
    try assertTrue(profile(BId) == nil, "nothing saved")
    try assertEqual(0, loginDirs(base).count, "throwaway folder removed")
}

test("a finished sign-in is imported from its own Keychain item, which is then deleted") {
    resetSandbox(A, cred("tokA"))
    let base = root.appendingPathComponent("support")
    try store.write(service: "Claude Code-credentials-0000abcd", account: "tester", value: "other")
    let d = try acc.prepareLogin(in: base)
    // What Claude Code leaves after `auth login` with CLAUDE_CONFIG_DIR=d.path
    try store.write(service: d.expectedService, account: "tester", value: cred("tokB", extra: true))
    try JSON.object([("oauthAccount", B)]).serialized().write(to: d.url.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
    try assertEqual(BId, try acc.finishLogin(d, name: nil), "imported")
    try assertTrue(saved(BId).contains("tokB") && !saved(BId).contains("mcp"), "Claude login saved, nothing else")
    try assertTrue(try store.read(service: d.expectedService, account: "tester") == nil, "sign-in's item deleted")
    try assertEqual("other", try store.read(service: "Claude Code-credentials-0000abcd", account: "tester") ?? "", "unrelated item kept")
    try assertTrue(liveCred().contains("tokA"), "active login untouched")
    try assertEqual(0, loginDirs(base).count, "folder removed")
}

test("a sign-in interrupted earlier is cleaned up: its folder and only its Keychain item") {
    resetSandbox(A, cred("tokA"))
    let base = root.appendingPathComponent("support")
    let old = base.appendingPathComponent("login-old")
    try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
    let oldSvc = ClaudeAccounts.keychainService(forConfigDir: old.resolvingSymlinksInPath().path)
    try store.write(service: oldSvc, account: "tester", value: cred("tokOld"))
    try store.write(service: "Claude Code-credentials-0000abcd", account: "tester", value: "other")
    let d = try acc.prepareLogin(in: base)
    try assertTrue(try store.read(service: oldSvc, account: "tester") == nil, "old item deleted")
    try assertEqual("other", try store.read(service: "Claude Code-credentials-0000abcd", account: "tester") ?? "", "unrelated item kept")
    try assertEqual([d.url.lastPathComponent], loginDirs(base), "only the new folder left")
    acc.discardLogin(d)
    try assertEqual(0, loginDirs(base).count, "discarded")
}

section("Tokens and usage")

test("inactive profile with a valid token is used without refreshing") {
    resetSandbox(A, cred("tokA")); fakeIds["tokA"] = AId
    try acc.saveProfileSnapshot(credText: cred("tokB", refresh: "r-B"), account: B, name: nil)
    try assertEqual("tokB", try acc.accessToken(for: profile(BId)!), "token")
    try assertEqual(0, http.calls.count, "no network")
}

test("expired inactive token is refreshed and the rotated tokens are saved") {
    resetSandbox(A, cred("tokA")); fakeIds["tokA"] = AId
    try acc.saveProfileSnapshot(credText: cred("tokB-old", refresh: "r-old", expiresInMs: -60000), account: B, name: nil)
    http.reply = { _ in FakeHTTP.json(#"{"access_token":"tokB-new","refresh_token":"r-new","expires_in":3600}"#) }
    try assertEqual("tokB-new", try acc.accessToken(for: profile(BId)!), "new token")
    let body = String(decoding: http.calls[0].httpBody ?? Data(), as: UTF8.self)
    try assertTrue(body.contains("r-old"), "used old refresh token")
    try assertTrue(body.contains("\"scope\":\"user:inference\""), "scopes sent")
    let s = try JSON.parse(saved(BId))["claudeAiOauth"]!
    try assertEqual("r-new", s["refreshToken"]?.string, "rotated refresh token saved")
    try assertEqual("user:inference", s["scopes"]?.array?.first?.string, "other fields kept")
}

test("the active account always uses the live token (never refreshed here)") {
    resetSandbox(A, cred("tokA", refresh: "r-A", expiresInMs: -60000)); fakeIds["tokA"] = AId; acc.syncActiveProfile()
    try assertEqual("tokA", try acc.accessToken(for: profile(AId)!), "live token")
    try assertEqual(0, http.calls.count, "no refresh")
}

test("usage response is parsed into labelled rows") {
    resetSandbox(A, cred("tokA"))
    http.reply = { _ in FakeHTTP.json("""
    {"limits":[{"kind":"session","percent":12,"resets_at":"2030-01-01T05:00:00+00:00"},
               {"kind":"weekly_all","percent":40,"resets_at":"2030-01-05T00:00:00.123456+00:00"},
               {"kind":"weekly_scoped","percent":3,"resets_at":null,"scope":{"model":{"display_name":"Fable"}}}]}
    """) }
    let rows = try acc.usageRows(token: "tok")
    try assertEqual(3, rows.count, "rows")
    try assertEqual("Session (5h)", rows[0].label, "label 1"); try assertEqual(12, rows[0].used, "used 1")
    try assertEqual("Weekly Fable", rows[2].label, "scoped label")
    try assertTrue(rows[1].resets != nil, "reset parsed (fractional seconds)")
    try assertEqual(nil, rows[2].resets, "no reset time")
    try assertEqual("api.anthropic.com", http.calls[0].url?.host ?? "", "token only sent to Anthropic")
}

test("older usage response shape is parsed too") {
    resetSandbox(A, cred("tokA"))
    http.reply = { _ in FakeHTTP.json(#"{"five_hour":{"utilization":7.5,"resets_at":"2030-01-01T05:00:00Z"},"seven_day":{"utilization":30,"resets_at":null},"seven_day_opus":null}"#) }
    let rows = try acc.usageRows(token: "tok")
    try assertEqual(["Session (5h)", "Weekly"], rows.map(\.label), "labels")
    try assertEqual(7.5, rows[0].used, "used")
}

test("429 reports a rate limit with the server's Retry-After") {
    resetSandbox(A, cred("tokA"))
    http.reply = { _ in FakeHTTP.json("{}", status: 429, headers: ["retry-after": "300"]) }
    do { _ = try acc.usageRows(token: "tok"); throw AssertFail(m: "should throw") }
    catch UsageError.rateLimited(let ra) { try assertEqual(300, ra, "retry after") }
}

section("Auto-switch rules")
let now = Date()
func row(_ label: String, _ used: Double, _ hrs: Double) -> UsageRow { UsageRow(label: label, used: used, resets: now.addingTimeInterval(hrs * 3600)) }
func others() -> [OtherAccount] { [
    OtherAccount(id: "A", name: "A", rows: [row("Session (5h)", 5, 3), row("Weekly", 96, 20)]),     // 4% weekly left, resets soonest
    OtherAccount(id: "B", name: "B", rows: [row("Session (5h)", 0, 5), row("Weekly", 20, 144)]),    // lots of room
    OtherAccount(id: "C", name: "C", rows: [row("Session (5h)", 100, 2), row("Weekly", 10, 30)]),   // session maxed
    OtherAccount(id: "D", name: "D", rows: [row("Session (5h)", 93, 2), row("Weekly", 10, 30)]),    // 7% session left
    OtherAccount(id: "E", name: "E", rows: [row("Session (5h)", 1, 2), row("Weekly", 99, 25)]),     // weekly at threshold
    OtherAccount(id: "F", name: "F", err: "boom"),
    OtherAccount(id: "G", name: "G", err: "Not checked yet", pending: true),
] }

test("defaults use a nearly-spent weekly allowance first and skip maxed sessions") {
    let s = sortSwitchCandidates(others(), SwitchRules())
    try assertEqual("A,B", s.filter(\.eligible).map(\.id).joined(separator: ","), "eligible order")
    var why: [String: String] = [:]; for o in s { why[o.id] = o.reason ?? "" }
    try assertEqual("SESSION FULL", why["C"], "C"); try assertEqual("LOW SESSION", why["D"], "D")
    try assertEqual("WEEKLY FULL", why["E"], "E"); try assertEqual("ERROR", why["F"], "F"); try assertEqual("NOT CHECKED", why["G"], "G")
}
test("\"most room\" preference picks the emptiest account") {
    try assertEqual("B", selectAutoSwitchTarget(others(), SwitchRules(fullAt: 99, minSession: 10, minWeekly: 0, prefer: "room"))?.id, "pick")
}
test("a weekly minimum excludes the nearly-spent account") {
    try assertEqual("B", selectAutoSwitchTarget(others(), SwitchRules(fullAt: 99, minSession: 10, minWeekly: 5))?.id, "pick")
}
test("a spent weekly limit collapses the display to one row") {
    let full = [row("Session (5h)", 40, 3), row("Weekly", 100, 30), row("Weekly Fable", 80, 30)]
    let d = displayRows(full)
    try assertEqual(1, d.count, "rows shown")
    try assertEqual("Weekly – used up", d[0].label, "label")
    try assertEqual(full[1].resets, d[0].resets, "reset time kept")
    try assertEqual(3, displayRows([row("Session (5h)", 40, 3), row("Weekly", 99, 30), row("Weekly Fable", 100, 30)]).count, "only a model limit spent")
}
test("no session minimum lets a low-session account qualify, still never a full one") {
    let s = sortSwitchCandidates(others(), SwitchRules(fullAt: 99, minSession: 0, minWeekly: 0))
    try assertEqual("A,D,B", s.filter(\.eligible).map(\.id).joined(separator: ","), "eligible order")
}
test("nothing qualifies -> no target") {
    try assertTrue(selectAutoSwitchTarget(others(), SwitchRules(fullAt: 99, minSession: 10, minWeekly: 90)) == nil, "no target")
}

section("Rate-limit pause")
let t0 = ISO8601DateFormatter().date(from: "2026-11-12T00:48:00Z")!
test("a pause in progress is active") { try assertTrue(backoffActive(until: t0.addingTimeInterval(100), sec: 120, now: t0), "active") }
test("a finished pause is not active") { try assertTrue(!backoffActive(until: t0.addingTimeInterval(-1), sec: 120, now: t0), "over") }
test("a cleared pause (length 0) is ignored even if its end time is in the future") {
    try assertTrue(!backoffActive(until: t0.addingTimeInterval(2400), sec: 0, now: t0), "cleared")
}
test("a pause saved while the clock was an hour fast is ignored") {
    // 2-minute pause whose end time now looks 40 minutes away after the clock was corrected
    try assertTrue(!backoffActive(until: t0.addingTimeInterval(2400), sec: 120, now: t0), "clock jump")
}

section("Notifications")
test("warns once when a limit crosses the threshold") {
    var st: [String: NoticeState] = [:]
    try assertEqual(0, usageNotices([row("Session (5h)", 50, 3)], state: &st, warnAt: 80, onReset: true).count, "below")
    let n = usageNotices([row("Session (5h)", 82, 3)], state: &st, warnAt: 80, onReset: true)
    try assertEqual(1, n.count, "warned"); try assertTrue(n[0].kind == .warn, "kind")
    try assertEqual(0, usageNotices([row("Session (5h)", 90, 3)], state: &st, warnAt: 80, onReset: true).count, "not repeated")
}
test("reports a reset and warns again in the next window") {
    var st: [String: NoticeState] = [:]
    _ = usageNotices([row("Session (5h)", 95, 1)], state: &st, warnAt: 80, onReset: true)
    let n = usageNotices([row("Session (5h)", 2, 5)], state: &st, warnAt: 80, onReset: true)
    try assertTrue(n.first?.kind == .reset, "reset")
    try assertTrue(usageNotices([row("Session (5h)", 85, 5)], state: &st, warnAt: 80, onReset: true).first?.kind == .warn, "warns again")
}
test("warnings off and reset notices off stay silent") {
    var st: [String: NoticeState] = [:]
    _ = usageNotices([row("Weekly", 95, 1)], state: &st, warnAt: 0, onReset: false)
    try assertEqual(0, usageNotices([row("Weekly", 1, 100)], state: &st, warnAt: 0, onReset: false).count, "silent")
}

section("Formatting")
test("time until reset") {
    try assertEqual("2d 3h", formatUntil(now.addingTimeInterval(2 * 86400 + 3 * 3600 + 60), now: now), "days")
    try assertEqual("1h 5m", formatUntil(now.addingTimeInterval(3900), now: now), "hours")
    try assertEqual("1m", formatUntil(now.addingTimeInterval(10), now: now), "minutes")
    try assertEqual("1h 0m", formatUntil(now.addingTimeInterval(3599.5), now: now), "never 60m")
    try assertEqual("resetting", formatUntil(now.addingTimeInterval(-5), now: now), "past")
}

try? FileManager.default.removeItem(at: root)
print("")
if failed.isEmpty { print("All \(passed) tests passed") } else { print("\(passed) passed, \(failed.count) failed") }
exit(Int32(failed.count))
