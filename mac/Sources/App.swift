import AppKit
import SwiftUI
import UserNotifications

/*
  App.swift - the menu-bar app (the macOS counterpart of ClaudeUsageTray.ps1).

  A menu-bar item shows the % used on your tightest limit. Left-click opens a panel
  with a bar per limit (and every saved account when "All" is on); right-click opens
  the settings menu. All network calls run on a background queue; this class makes
  every decision on the main thread.
*/

// MARK: - Settings

struct TraySettings: Codable {
    var activeIntervalSec = 120   // how often the active account is checked (drives auto-switch)
    var othersIntervalMin = 10    // how often other accounts are checked while "All" is on
    var showAll = false
    var showRemaining = false
    var autoSwitch = false
    var autoSwitchAt: Double = 99           // switch away when any limit hits this % used
    var autoSwitchMinSession: Double = 10   // target's 5h session needs >= this % left
    var autoSwitchMinWeekly: Double = 0     // target's weekly limits need >= this % left (0 = any)
    var autoSwitchPrefer = "reset"          // "reset" | "room"
    var notifyAt: Double = 80               // warn when a limit reaches this % (0 = off)
    var notifyReset = true                  // tell me when a limit resets

    enum CodingKeys: String, CodingKey {
        case activeIntervalSec = "ActiveIntervalSec", othersIntervalMin = "OthersIntervalMin", showAll = "ShowAll"
        case showRemaining = "ShowRemaining", autoSwitch = "AutoSwitch", autoSwitchAt = "AutoSwitchAt"
        case autoSwitchMinSession = "AutoSwitchMinSession", autoSwitchMinWeekly = "AutoSwitchMinWeekly"
        case autoSwitchPrefer = "AutoSwitchPrefer", notifyAt = "NotifyAt", notifyReset = "NotifyReset"
    }

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = TraySettings()
        activeIntervalSec = (try? c.decodeIfPresent(Int.self, forKey: .activeIntervalSec)) ?? nil ?? def.activeIntervalSec
        othersIntervalMin = (try? c.decodeIfPresent(Int.self, forKey: .othersIntervalMin)) ?? nil ?? def.othersIntervalMin
        showAll = (try? c.decodeIfPresent(Bool.self, forKey: .showAll)) ?? nil ?? def.showAll
        showRemaining = (try? c.decodeIfPresent(Bool.self, forKey: .showRemaining)) ?? nil ?? def.showRemaining
        autoSwitch = (try? c.decodeIfPresent(Bool.self, forKey: .autoSwitch)) ?? nil ?? def.autoSwitch
        autoSwitchAt = (try? c.decodeIfPresent(Double.self, forKey: .autoSwitchAt)) ?? nil ?? def.autoSwitchAt
        autoSwitchMinSession = (try? c.decodeIfPresent(Double.self, forKey: .autoSwitchMinSession)) ?? nil ?? def.autoSwitchMinSession
        autoSwitchMinWeekly = (try? c.decodeIfPresent(Double.self, forKey: .autoSwitchMinWeekly)) ?? nil ?? def.autoSwitchMinWeekly
        autoSwitchPrefer = (try? c.decodeIfPresent(String.self, forKey: .autoSwitchPrefer)) ?? nil ?? def.autoSwitchPrefer
        notifyAt = (try? c.decodeIfPresent(Double.self, forKey: .notifyAt)) ?? nil ?? def.notifyAt
        notifyReset = (try? c.decodeIfPresent(Bool.self, forKey: .notifyReset)) ?? nil ?? def.notifyReset
        activeIntervalSec = max(30, activeIntervalSec)
        othersIntervalMin = max(1, othersIntervalMin)
    }

    var rules: SwitchRules {
        SwitchRules(fullAt: autoSwitchAt, minSession: autoSwitchMinSession, minWeekly: autoSwitchMinWeekly, prefer: autoSwitchPrefer)
    }
}

/// What one background check found.
struct FetchResult {
    var acct: ActiveAccount?
    var profiles: [Profile] = []
    var rows: [UsageRow]?
    var err: String?
    var rateLimited = false
    var retryAfter = 0
    var others: [OtherAccount]?
    var othersRateLimited = false
    var sig = ""   // accounts/login fingerprint, taken when `profiles` was listed
}

/// A menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private var handler: (() -> Void)?
    init(_ title: String, checked: Bool = false, indent: Int = 0, _ handler: (() -> Void)? = nil) {
        super.init(title: title, action: handler == nil ? nil : #selector(fire), keyEquivalent: "")
        self.handler = handler
        self.target = self
        self.state = checked ? .on : .off
        self.indentationLevel = indent
        self.isEnabled = handler != nil
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler?() }
}

// MARK: - Controller

final class AppController: NSObject, ObservableObject, NSMenuDelegate, UNUserNotificationCenterDelegate {
    let acc = ClaudeAccounts.live()
    let dir = ClaudeAccounts.appSupportDir
    var settingsURL: URL { dir.appendingPathComponent("settings.json") }
    var stateURL: URL { dir.appendingPathComponent("state.json") }
    var logURL: URL { dir.appendingPathComponent("error.log") }
    let launchAgentURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/local.claude-switcher.usage-tray.plist")

    // Shown in the panel
    @Published var settings = TraySettings()
    @Published var rows: [UsageRow] = []
    @Published var lastErr: String?
    @Published var lastOk: Date?
    @Published var others: [OtherAccount] = []
    @Published var activeName: String?
    @Published var mismatch = false
    @Published var oldSessions = 0
    @Published var switchedFrom: String?
    @Published var backoffUntil = Date.distantPast
    @Published var backoffSec = 0
    @Published var tick = 0   // bumps every 30s so countdowns repaint

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let menu = NSMenu()

    // Background work: one request at a time on a serial queue.
    private let worker = DispatchQueue(label: "claude-usage-tray.worker", qos: .utility)
    private var jobRunning = false
    private var queuedOthers: Bool?
    private var lastAcct: ActiveAccount?
    private var othersFetchedAt = Date.distantPast

    private var mismatchNotified = false
    private var autoCooldownUntil = Date.distantPast
    private var autoNotified = false
    private var noticeStates: [String: [String: NoticeState]] = [:]
    private var switchedAt: Date?
    private var quickRetries = 0
    private var profSig = ""

    private var pollTimer: Timer?
    private var tickTimer: Timer?
    private var backoffWork: DispatchWorkItem?
    private var retryWork: DispatchWorkItem?

    // MARK: startup

    func start() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        loadSettings()
        loadState()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.target = self
            b.action = #selector(statusClicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.imagePosition = .imageLeading
        }
        menu.delegate = self
        menu.autoenablesItems = false

        let host = NSHostingController(rootView: PopoverView(m: self))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = false

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        try? FileManager.default.removeItem(at: dir.appendingPathComponent("add-account.command"))   // from older versions
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.addModel?.cancelNow()
        }

        // The app was moved or rebuilt elsewhere: keep "Start at login" pointing at it.
        if autostartEnabled(), !autostartPointsHere() { try? enableAutostart() }

        // Coming back from sleep: numbers are stale, check soon (the network needs a moment).
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self?.updateUsage(full: false) }
        }

        // List every saved account by name immediately; numbers arrive from the worker.
        let known = acc.configActiveId()
        let profiles = acc.profiles(activeId: known)
        if settings.showAll { setOtherPlaceholders(profiles) }
        activeName = profiles.first(where: \.active)?.name
        profSig = profilesSignature()
        updateUI()
        // Still inside a saved pause from before a restart? Check again when it ends.
        if paused { startBackoffTimer(backoffUntil.timeIntervalSinceNow) }
        updateUsage(full: true)

        restartPollTimer()
        tickTimer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.onTick() }
        RunLoop.main.add(tickTimer!, forMode: .common)
    }

    func log(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(s)\n"
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: settings & state

    func loadSettings() {
        if let d = try? Data(contentsOf: settingsURL), let s = try? JSONDecoder().decode(TraySettings.self, from: d) { settings = s }
    }

    func saveSettings() {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? e.encode(settings) { try? writeFileAtomic(settingsURL, String(decoding: d, as: UTF8.self), mode: 0o644) }
    }

    func loadState() {
        guard let d = try? Data(contentsOf: stateURL), let j = try? JSON.parse(d) else { return }
        backoffSec = Int(j["BackoffSec"]?.double ?? 0)
        backoffUntil = ClaudeAccounts.parseDate(j["BackoffUntil"]?.string) ?? .distantPast
        // A saved pause that's over, or impossible after a clock change, is dropped.
        if !paused && (backoffSec != 0 || backoffUntil != .distantPast) {
            backoffSec = 0; backoffUntil = .distantPast   // restart doubling from 2 min
            saveState()
        }
    }

    func saveState() {
        let until = backoffUntil == .distantPast ? JSON.null : JSON.string(ISO8601DateFormatter().string(from: backoffUntil))
        let j = JSON.object([("BackoffSec", .num(Int64(backoffSec))), ("BackoffUntil", until)])
        try? writeFileAtomic(stateURL, j.serialized(), mode: 0o644)
    }

    // MARK: rate-limit backoff (persisted, so restarting doesn't reset it)

    var paused: Bool { backoffActive(until: backoffUntil, sec: backoffSec) }
    var stale: Bool { lastErr != nil || paused }

    /// Fires when a pause is over so we check straight away. Uses elapsed (monotonic)
    /// time, so changes to the system clock can't stretch or shrink the pause.
    func startBackoffTimer(_ seconds: Double) {
        backoffWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.updateUI(); self?.updateUsage(full: false) }
        backoffWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, seconds), execute: w)
    }

    func startBackoff(_ retryAfter: Int) {
        let next = backoffSec > 0 ? backoffSec * 2 : 120
        backoffSec = min(900, max(retryAfter, next))
        backoffUntil = Date().addingTimeInterval(Double(backoffSec))
        saveState()
        startBackoffTimer(Double(backoffSec))
    }

    func clearBackoff() {
        if backoffSec != 0 || backoffUntil != .distantPast {
            backoffSec = 0; backoffUntil = .distantPast; saveState()
        }
    }

    static let hhmm: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()

    var statusMessage: String {
        if paused { return "Rate limited - retrying at \(Self.hhmm.string(from: backoffUntil))" }
        if let e = lastErr { return e }
        return "Loading..."
    }

    // MARK: background checks

    func othersDue() -> Bool { Date().timeIntervalSince(othersFetchedAt) >= Double(settings.othersIntervalMin) * 60 }

    /// Ask for fresh numbers. full = also re-check other accounts now.
    func updateUsage(full: Bool) {
        // Accounts never checked yet (new, or skipped while rate limited) can't wait 10 minutes.
        var wantOthers = settings.showAll && (full || othersDue() || others.contains(where: \.pending))
        if full && settings.autoSwitch { wantOthers = true }
        requestRefresh(wantOthers)
    }

    func requestRefresh(_ wantOthers: Bool) {
        if paused { updateUI(); return }   // rate limited: stay off the network
        if jobRunning {
            // Busy: run again afterwards (merging "others" requests).
            queuedOthers = wantOthers || (queuedOthers ?? false)
            return
        }
        jobRunning = true
        let acc = self.acc
        worker.async {
            let r = Self.fetch(acc, wantOthers: wantOthers)
            DispatchQueue.main.async {
                self.jobRunning = false
                self.apply(r)
                if let q = self.queuedOthers { self.queuedOthers = nil; self.requestRefresh(q) }
            }
        }
    }

    /// Runs on the worker queue.
    static func fetch(_ acc: ClaudeAccounts, wantOthers: Bool) -> FetchResult {
        var out = FetchResult()
        // Identity comes from the tokens themselves (checked with Anthropic).
        let a = acc.activeAccount()
        acc.syncActiveProfile(active: a)   // keep the active profile's tokens current
        out.acct = a
        // Fingerprint first: anything added after this is seen as a change next tick.
        out.sig = acc.changeSignature()
        out.profiles = acc.profiles(activeId: a?.id ?? acc.configActiveId())
        do {
            guard let cred = try acc.readLiveCredentials() else { throw UsageError.message("No Claude Code login found. Run 'claude' and log in.") }
            guard let token = ClaudeAccounts.accessToken(in: cred.text) else { throw UsageError.message("No login token found. Run 'claude' and log in.") }
            out.rows = try acc.usageRows(token: token)
        } catch UsageError.rateLimited(let ra) {
            out.rateLimited = true; out.retryAfter = ra
            return out
        } catch {
            out.err = "\(error)"
        }
        if wantOthers {
            var list: [OtherAccount] = []
            for p in out.profiles where !p.active {
                var entry = OtherAccount(id: p.id, name: p.name)
                do { entry.rows = try acc.usageRows(token: try acc.accessToken(for: p)) }
                catch UsageError.rateLimited(let ra) { out.othersRateLimited = true; out.retryAfter = ra; break }
                catch { entry.err = "\(error)" }
                list.append(entry)
            }
            if !out.othersRateLimited { out.others = list }
        }
        return out
    }

    func apply(_ r: FetchResult) {
        if let a = r.acct {
            lastAcct = a
            activeName = r.profiles.first(where: \.active)?.name
            mismatch = a.mismatch
            if mismatch {
                let cfgName = r.profiles.first(where: { $0.id == a.configId })?.name ?? a.email ?? "another account"
                if activeName == nil { activeName = "Unknown account" }
                if !mismatchNotified {
                    notify("Claude login was overwritten",
                           "A Claude Code session still running on \(activeName!) rewrote the login after you switched to \(cfgName). New sessions will use \(activeName!). Close running Claude Code sessions, then switch again. Auto-switch is paused until this is fixed.")
                    mismatchNotified = true
                }
            } else { mismatchNotified = false }
            profSig = r.sig
        }

        if r.rateLimited {
            // Keep showing the last numbers; wait (server hint, else doubling from 2 min, max 15 min).
            startBackoff(r.retryAfter)
            setOtherPlaceholders(r.profiles)
            updateUI()
            return
        }
        if let e = r.err {
            lastErr = e
            // Starting at login often means no network yet: retry every 20s (up to ~3 min)
            // instead of waiting a full check interval with nothing to show.
            if rows.isEmpty && quickRetries < 9 {
                quickRetries += 1
                retryWork?.cancel()
                let w = DispatchWorkItem { [weak self] in self?.updateUsage(full: false) }
                retryWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: w)
            }
        } else if let newRows = r.rows {
            quickRetries = 0
            rows = newRows; lastErr = nil; lastOk = Date()
            clearBackoff()
            if !mismatch { showUsageNotices() }
        }

        var othersFresh = false
        if let o = r.others {
            others = sortSwitchCandidates(o, settings.rules)
            othersFetchedAt = Date()
            othersFresh = true
        } else if r.othersRateLimited {
            startBackoff(r.retryAfter)   // keep previous numbers; othersFetchedAt untouched so they're retried
        }
        setOtherPlaceholders(r.profiles)

        autoSwitch(othersFresh: othersFresh)
        updateUI()
    }

    /// Saved accounts we haven't been able to check yet still get listed (by name),
    /// and accounts that were removed disappear.
    func setOtherPlaceholders(_ profiles: [Profile]) {
        let inactive = profiles.filter { !$0.active }
        if inactive.isEmpty { if !profiles.isEmpty { others = [] }; return }
        var byId: [String: OtherAccount] = [:]
        for o in others { byId[o.id] = o }
        let list = inactive.map { p -> OtherAccount in
            if var o = byId[p.id] { o.name = p.name; return o }   // keep numbers, pick up renames
            return OtherAccount(id: p.id, name: p.name, err: "Not checked yet", pending: true)
        }
        others = sortSwitchCandidates(list, settings.rules)
    }

    // MARK: notifications

    func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)) { [weak self] err in
            if let err = err { self?.log("notification: \(err.localizedDescription) - \(title): \(body)") }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func showUsageNotices() {
        guard !rows.isEmpty, let id = lastAcct?.id else { return }
        var st = noticeStates[id] ?? [:]
        let n = usageNotices(rows, state: &st, warnAt: settings.notifyAt, onReset: settings.notifyReset)
        noticeStates[id] = st
        guard !n.isEmpty else { return }
        let lines = n.map { x -> String in
            x.kind == .warn
                ? "\(x.row.label) is at \(Int(x.row.used))% used (resets in \(formatUntil(x.row.resets)))."
                : "\(x.row.label) has reset (\(Int(x.row.used))% used now)."
        }
        let warned = n.contains { $0.kind == .warn }
        notify(warned ? "Claude usage: \(activeName ?? "")" : "Claude limit reset", lines.joined(separator: "\n"))
    }

    // MARK: switching

    /// Call right after a switch; returns how many Claude Code sessions are still on the old login.
    func registerSwitch(from: String?) -> Int {
        switchedAt = Date()
        switchedFrom = from
        updateOldSessions()
        return oldSessions
    }

    func updateOldSessions() {
        guard let at = switchedAt else { oldSessions = 0; return }
        oldSessions = claudeCodeProcesses(startedBefore: at).count
        if oldSessions == 0 { switchedAt = nil }   // all restarted: done
    }

    func formatOldSessions(_ n: Int, _ from: String?) -> String {
        guard n > 0 else { return "" }
        return " \(n) running Claude Code \(n == 1 ? "session is" : "sessions are") still on \(from ?? "the old account"); restart \(n == 1 ? "it" : "them") to use the new account."
    }

    /// Runs the switch on the worker queue (it may verify tokens over the network),
    /// then finishes on the main thread.
    func performSwitch(_ id: String, completion: @escaping (Result<Profile, Error>, Int) -> Void) {
        let from = activeName
        let acc = self.acc
        worker.async {
            let result = Result { try acc.switchProfile(id) }
            DispatchQueue.main.async {
                var old = 0
                if case .success = result { old = self.registerSwitch(from: from) }
                completion(result, old)
            }
        }
    }

    func switchAccount(_ id: String) {
        let from = activeName
        // Respect a manual choice: auto-switch won't override it for 5 minutes.
        autoCooldownUntil = Date().addingTimeInterval(300)
        performSwitch(id) { result, old in
            switch result {
            case let .success(p):
                self.activeName = p.name   // show it right away; numbers follow from the worker
                self.rows = []; self.lastAcct = nil
                self.updateUsage(full: true)
                self.updateUI()
                self.notify("Claude account switched", "New Claude Code sessions will use \(p.name)." + self.formatOldSessions(old, from))
            case let .failure(e):
                self.notify("Switch failed", "\(e)")
            }
        }
    }

    /// Decides on the main thread; asks the worker for fresh numbers when it needs them.
    func autoSwitch(othersFresh: Bool) {
        guard settings.autoSwitch, lastErr == nil, !rows.isEmpty, !mismatch else { return }   // mismatch: don't make it worse
        let used = maxUsed(rows)
        if used < settings.autoSwitchAt { autoNotified = false; return }
        if Date() < autoCooldownUntil { return }

        // Choose from fresh numbers. If we already found nobody qualifies, don't
        // re-check every account each minute - wait for their normal schedule.
        if !othersFresh && (!autoNotified || othersDue()) { requestRefresh(true); return }
        guard let target = selectAutoSwitchTarget(others, settings.rules) else {
            if !autoNotified {
                var why = others.map { "\($0.name): \($0.reason ?? "")" }.joined(separator: "; ")
                if why.isEmpty { why = "no other saved accounts" }
                notify("Claude auto-switch", "Current account is at \(Int(used))% but no other account qualifies (\(why)).")
                autoNotified = true
            }
            return
        }

        let from = activeName
        // Targets are never "full", so ping-pong can't happen; a short guard just
        // covers stale numbers. Kept short so a nearly-spent account can hand off fast.
        autoCooldownUntil = Date().addingTimeInterval(60)
        autoNotified = false
        performSwitch(target.id) { result, old in
            switch result {
            case .success:
                self.activeName = target.name
                self.notify("Claude auto-switched account",
                            "\(from ?? "The active account") reached \(Int(used))% used. New Claude Code sessions will use \(target.name)." + self.formatOldSessions(old, from))
                self.requestRefresh(true)
            case let .failure(e):
                self.notify("Claude auto-switch failed", "\(e)")
            }
            self.updateUI()
        }
    }

    // MARK: menu-bar item

    var tightest: UsageRow? { rows.max { $0.used < $1.used } }

    static func levelColor(left: Double) -> NSColor {
        if left <= 10 { return NSColor(srgbRed: 220 / 255, green: 53 / 255, blue: 69 / 255, alpha: 1) }   // red
        if left <= 30 { return NSColor(srgbRed: 230 / 255, green: 145 / 255, blue: 30 / 255, alpha: 1) }  // amber
        return NSColor(srgbRed: 46 / 255, green: 160 / 255, blue: 90 / 255, alpha: 1)                    // green
    }

    func pctText(_ r: UsageRow) -> String {
        settings.showRemaining ? "\(Int(max(0, 100 - r.used)))% left" : "\(Int(min(100, r.used)))% used"
    }

    func updateUI() {
        guard let b = statusItem?.button else { return }
        let color: NSColor
        let text: String
        if let t = tightest {
            let left = max(0, 100 - t.used)
            color = stale ? .systemGray : Self.levelColor(left: left)
            let shown = settings.showRemaining ? left : min(100, t.used)
            text = "\(Int(shown.rounded(.down)))%"
        } else {
            color = .systemGray
            text = stale ? "!" : "–"
        }
        b.image = Self.dot(color)
        b.attributedTitle = NSAttributedString(string: " " + text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .regular) - 1, weight: .medium),
            .baselineOffset: 0.5,
        ])

        if !rows.isEmpty {
            let parts = rows.map { r -> String in
                let lbl = r.label == "Session (5h)" ? "5h" : r.label == "Weekly" ? "Week" : r.label.replacingOccurrences(of: "Weekly ", with: "")
                let pct = settings.showRemaining ? 100 - r.used : r.used
                return "\(lbl) \(Int(max(0, min(100, pct))))%"
            }
            b.toolTip = (stale ? "(stale) " : "") + "Claude \(settings.showRemaining ? "left" : "used"): " + parts.joined(separator: ", ")
        } else {
            b.toolTip = "Claude: " + statusMessage
        }
    }

    static func dot(_ c: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { r in
            c.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        img.isTemplate = false
        return img
    }

    @objc func statusClicked() {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePopover()
        }
    }

    func togglePopover() {
        if popover.isShown { popover.performClose(nil); return }
        guard let b = statusItem.button else { return }
        tick += 1
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
    }

    func showMenu() {
        if popover.isShown { popover.performClose(nil) }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)   // opens the menu; returns once it closes
        statusItem.menu = nil
    }

    // MARK: menu

    func menuNeedsUpdate(_ m: NSMenu) {
        guard m === menu else { return }
        m.removeAllItems()
        m.addItem(ActionItem("Refresh now") { [unowned self] in updateUsage(full: true) })

        let rate = NSMenu()
        addRadio(rate, "Active account (drives auto-switch)",
                 [(30, "30 seconds (may hit rate limits)"), (60, "1 minute"), (120, "2 minutes"), (300, "5 minutes")],
                 get: { Double(self.settings.activeIntervalSec) }, set: { self.settings.activeIntervalSec = Int($0); self.restartPollTimer() })
        rate.addItem(.separator())
        addRadio(rate, "Other accounts (while All is on)", [(5, "5 minutes"), (10, "10 minutes"), (15, "15 minutes"), (30, "30 minutes")],
                 get: { Double(self.settings.othersIntervalMin) }, set: { self.settings.othersIntervalMin = Int($0) })
        rate.addItem(ActionItem("Auto-switch always re-checks them before switching"))
        m.addItem(submenu("Check usage every", rate))

        m.addItem(ActionItem("Open claude.ai usage page") { NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!) })
        m.addItem(ActionItem("Start at login", checked: autostartEnabled()) { [unowned self] in toggleAutostart() })
        m.addItem(ActionItem("Show all accounts", checked: settings.showAll) { [unowned self] in setShowAll(!settings.showAll) })
        m.addItem(ActionItem("Show remaining instead of used", checked: settings.showRemaining) { [unowned self] in
            settings.showRemaining.toggle(); saveSettings(); updateUI()
        })
        m.addItem(.separator())

        let notif = NSMenu()
        addRadio(notif, "Warn when a limit reaches", [(0, "Off"), (70, "70% used"), (80, "80% used"), (90, "90% used")],
                 get: { self.settings.notifyAt }, set: { self.settings.notifyAt = $0 })
        notif.addItem(.separator())
        notif.addItem(ActionItem("Tell me when a limit resets", checked: settings.notifyReset) { [unowned self] in
            settings.notifyReset.toggle(); saveSettings()
        })
        m.addItem(submenu("Notifications", notif))

        let auto = NSMenu()
        auto.addItem(ActionItem("Enabled", checked: settings.autoSwitch) { [unowned self] in
            settings.autoSwitch.toggle(); saveSettings()
            autoCooldownUntil = .distantPast
            updateUsage(full: false)
        })
        auto.addItem(.separator())
        addRadio(auto, "Switch away when any limit reaches", [(90, "90% used"), (95, "95% used"), (99, "99% used"), (100, "100% used")],
                 get: { self.settings.autoSwitchAt }, set: { self.settings.autoSwitchAt = $0 })
        auto.addItem(.separator())
        addRadio(auto, "Target needs session (5h) left", [(0, "Any (just not full)"), (5, "5%"), (10, "10%"), (25, "25%"), (50, "50%")],
                 get: { self.settings.autoSwitchMinSession }, set: { self.settings.autoSwitchMinSession = $0 })
        auto.addItem(.separator())
        addRadio(auto, "Target needs weekly left", [(0, "Any (just not full)"), (5, "5%"), (10, "10%"), (25, "25%")],
                 get: { self.settings.autoSwitchMinWeekly }, set: { self.settings.autoSwitchMinWeekly = $0 })
        auto.addItem(.separator())
        auto.addItem(ActionItem("Prefer"))
        for (v, label) in [("reset", "Soonest weekly reset (use it before it expires)"), ("room", "Most weekly room left")] {
            auto.addItem(ActionItem(label, checked: settings.autoSwitchPrefer == v, indent: 1) { [unowned self] in
                settings.autoSwitchPrefer = v; rulesChanged()
            })
        }
        m.addItem(submenu("Auto-switch", auto))

        m.addItem(submenu("Account", accountMenu()))
        m.addItem(.separator())
        m.addItem(ActionItem("Quit Claude Usage Tray") { NSApp.terminate(nil) })
    }

    func submenu(_ title: String, _ sub: NSMenu) -> NSMenuItem {
        sub.autoenablesItems = false
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.submenu = sub
        return it
    }

    func addRadio(_ m: NSMenu, _ heading: String, _ options: [(Double, String)], get: @escaping () -> Double, set: @escaping (Double) -> Void) {
        m.addItem(ActionItem(heading))
        let cur = get()
        for (v, label) in options {
            m.addItem(ActionItem(label, checked: cur == v, indent: 1) { [unowned self] in
                set(v); rulesChanged()
            })
        }
    }

    /// Re-rank with the new rules so NEXT / reasons update immediately.
    func rulesChanged() {
        saveSettings()
        if !others.isEmpty { others = sortSwitchCandidates(others, settings.rules) }
        updateUI()
    }

    func accountMenu() -> NSMenu {
        let m = NSMenu()
        // The worker keeps profiles in sync; reuse its last identity check (no network here).
        let profiles = acc.profiles(activeId: knownActiveId())
        if profiles.isEmpty { m.addItem(ActionItem("(no saved accounts)")) }
        // Active account first, bold, marked.
        for p in profiles.sorted(by: { ($0.active ? 0 : 1, $0.name) < ($1.active ? 0 : 1, $1.name) }) {
            let it = ActionItem(p.active ? "\(p.name)   (active)" : p.name, checked: p.active) { [unowned self] in switchAccount(p.id) }
            if p.active {
                it.attributedTitle = NSAttributedString(string: it.title, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
            }
            m.addItem(it)
        }
        m.addItem(.separator())
        m.addItem(ActionItem("Add account (without switching)…") { [unowned self] in startAddAccount() })
        m.addItem(ActionItem("Rename current account…") { [unowned self] in renameCurrent() })
        m.addItem(ActionItem("Open profiles folder") { [unowned self] in
            try? FileManager.default.createDirectory(at: acc.profilesDir, withIntermediateDirectories: true)
            NSWorkspace.shared.open(acc.profilesDir)
        })
        return m
    }

    /// Best-known active account without a network call: the worker's last check,
    /// else whatever ~/.claude.json says (good enough for listing names).
    func knownActiveId() -> String? { lastAcct?.id ?? acc.configActiveId() }

    func setShowAll(_ on: Bool) {
        settings.showAll = on
        saveSettings()
        // Turning it off only hides the list: the numbers are kept, so turning it back on
        // shows them straight away and checks again only when they're due.
        if on {
            setOtherPlaceholders(acc.profiles(activeId: knownActiveId()))
            if othersDue() || others.contains(where: \.pending) { requestRefresh(true) }
        }
        updateUI()
    }

    func renameCurrent() {
        guard let cur = acc.profiles(activeId: knownActiveId()).first(where: \.active) else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Rename account"
        alert.informativeText = "Display name for this account:"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = cur.name
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let new = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty else { return }
        do { try acc.renameProfile(cur.id, to: new); activeName = new } catch { notify("Rename failed", "\(error)") }
    }

    static let addWindowId = NSUserInterfaceItemIdentifier("add-account")
    private var addWindow: NSWindow?
    private var addModel: AddAccountModel?

    /// Opens the sign-in window. Claude Code's sign-in runs in the background in a
    /// temporary config dir, so the active account is untouched; the window shows
    /// progress and offers to switch at the end.
    func startAddAccount() {
        if popover.isShown { popover.performClose(nil) }
        NSApp.activate(ignoringOtherApps: true)
        if let w = addWindow { w.makeKeyAndOrderFront(nil); return }   // one sign-in at a time

        let model = AddAccountModel(acc: acc, controller: self)
        let host = NSHostingController(rootView: AddAccountView(m: model) { [weak self] in self?.addWindow?.close() })
        host.sizingOptions = [.preferredContentSize]
        let w = NSWindow(contentViewController: host)
        w.identifier = Self.addWindowId
        w.title = "Add Claude Account"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            model.closed = true
            model.cancel()   // closing the window cancels a sign-in in progress
            self?.addWindow = nil
            self?.addModel = nil
        }
        addWindow = w
        addModel = model
        w.makeKeyAndOrderFront(nil)
        model.start()
    }

    /// A sign-in saved a profile: list it now and fetch its numbers.
    func accountAdded() {
        profSig = profilesSignature()
        if !settings.showAll { setShowAll(true); return }
        setOtherPlaceholders(acc.profiles(activeId: knownActiveId()))
        requestRefresh(true)
        updateUI()
    }

    // MARK: start at login (a per-user LaunchAgent; no admin rights)

    func autostartEnabled() -> Bool { fileExists(launchAgentURL) }

    func autostartPointsHere() -> Bool {
        guard let t = try? readText(launchAgentURL) else { return false }
        return t.contains(Bundle.main.bundlePath)
    }

    func enableAutostart() throws {
        let plist: [String: Any] = [
            "Label": "local.claude-switcher.usage-tray",
            "ProgramArguments": ["/usr/bin/open", Bundle.main.bundlePath],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeFileAtomic(launchAgentURL, String(decoding: data, as: UTF8.self), mode: 0o644)
    }

    func toggleAutostart() {
        if autostartEnabled() {
            try? FileManager.default.removeItem(at: launchAgentURL)
        } else {
            do { try enableAutostart() } catch { notify("Start at login", "Couldn't set it up: \(error)") }
        }
    }

    // MARK: timers

    func restartPollTimer() {
        pollTimer?.invalidate()
        pollTimer = Timer(timeInterval: Double(max(30, settings.activeIntervalSec)), repeats: true) { [weak self] _ in
            self?.updateUsage(full: false)
        }
        RunLoop.main.add(pollTimer!, forMode: .common)
    }

    /// Profile folders + a fingerprint of the live token. Changes when an account is
    /// added, removed or switched - from here, the CLI, or anywhere else. No network.
    func profilesSignature() -> String { acc.changeSignature() }

    func profilesChanged() -> Bool {
        let sig = profilesSignature()
        if sig == profSig { return false }
        profSig = sig
        return true
    }

    /// Every 30s: repaint countdowns, and pick up accounts added/switched elsewhere.
    func onTick() {
        // Still waiting for old Claude Code sessions to be restarted? Re-count (local, cheap).
        if switchedAt != nil { updateOldSessions() }
        if profilesChanged() {
            if settings.showAll { setOtherPlaceholders(acc.profiles(activeId: knownActiveId())) }
            updateUsage(full: true)
        }
        tick += 1
        updateUI()
    }
}
