import AppKit
import SwiftUI

/// Drives the "Add account" window: runs Claude Code's sign-in in the background
/// (no Terminal) and reports progress.
final class AddAccountModel: ObservableObject {
    enum Phase { case starting, waiting, checking, done, failed }

    @Published var phase: Phase = .starting
    @Published var url: URL?
    @Published var code = ""
    @Published var codeError: String?
    @Published var failure = ""
    @Published var addedId = ""
    @Published var addedName = ""
    @Published var alreadyActive = false
    @Published var wasSaved = false   // signed in to an account that was already saved

    private let acc: ClaudeAccounts
    private weak var controller: AppController?
    private var runner: LoginRunner?
    private var savedBefore: Set<String> = []

    init(acc: ClaudeAccounts, controller: AppController) {
        self.acc = acc
        self.controller = controller
    }

    func start() {
        cancel()
        phase = .starting; url = nil; code = ""; codeError = nil; failure = ""
        savedBefore = Set(acc.profileIds())
        let acc = self.acc
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            acc.syncActiveProfile()   // keep the account that's signed in now
            guard let claude = ClaudeAccounts.findClaude() else {
                DispatchQueue.main.async { self?.fail("Couldn't find the claude command. Install Claude Code first.") }
                return
            }
            let r = LoginRunner(acc: acc, claude: claude)
            r.onEvent = { e in DispatchQueue.main.async { self?.handle(e, from: r) } }
            // Cancelled (window closed) while we were getting ready? Then don't start.
            let go: Bool = DispatchQueue.main.sync {
                guard let self = self, self.phase == .starting, self.runner == nil, !self.closed else { return false }
                self.runner = r
                return true
            }
            guard go else { return }
            do { try r.start() } catch {
                DispatchQueue.main.async { if self?.runner === r { self?.runner = nil; self?.fail("\(error)") } }
            }
        }
    }

    /// Set when the window closes, so a sign-in still getting ready never starts.
    var closed = false

    private func fail(_ msg: String) {
        failure = msg
        phase = .failed
    }

    private func handle(_ e: LoginRunner.Event, from r: LoginRunner) {
        guard runner === r else { return }   // a cancelled earlier attempt
        switch e {
        case let .url(u):
            url = u
            if phase == .starting { phase = .waiting }
        case .invalidCode:
            codeError = "That code is incomplete. Copy the whole code and try again."
            phase = .waiting
        case let .finished(.success(id)):
            runner = nil
            let p = acc.profiles(activeId: controller?.knownActiveId()).first { $0.id == id }
            addedId = id
            addedName = p?.name ?? "The account"
            alreadyActive = p?.active ?? false
            wasSaved = savedBefore.contains(id)
            phase = .done
            controller?.accountAdded()
            // Come back from the browser. macOS may not let a background app take focus,
            // so the window is also brought forward without it, and a notification says so.
            if !NSApp.isActive, !alreadyActive {
                controller?.notify("Claude account added", "\(addedName) is saved. Your current account is still active.")
            }
            NSApp.activate(ignoringOtherApps: true)
            if let w = NSApp.windows.first(where: { $0.identifier == AppController.addWindowId }) {
                w.orderFrontRegardless()
                w.makeKeyAndOrderFront(nil)
            }
        case let .finished(.failure(err)):
            runner = nil
            if err is LoginCancelled { return }
            failure = "\(err)"
            phase = .failed
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func submitCode() {
        codeError = nil
        guard let r = runner else { return }
        if r.submitCode(code) { phase = .checking } else {
            codeError = "That doesn't look like the whole code. Copy all of it from the browser."
        }
    }

    func cancel() {
        runner?.cancel()
        runner = nil
    }

    /// Quitting: stop Claude Code's sign-in before the app exits.
    func cancelNow() {
        runner?.cancelNow()
        runner = nil
    }

    func switchToAdded() {
        controller?.switchAccount(addedId)
    }
}

struct AddAccountView: View {
    @ObservedObject var m: AddAccountModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .regular))
                    .foregroundColor(iconColor)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    Text(subtitle).font(.system(size: 12)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
            buttons
        }
        .padding(20)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: text per phase

    var icon: String {
        switch m.phase {
        case .done: return m.alreadyActive ? "person.crop.circle.badge.checkmark" : "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "person.crop.circle.badge.plus"
        }
    }
    var iconColor: Color {
        switch m.phase {
        case .done: return Color(nsColor: .systemGreen)
        case .failed: return Color(nsColor: .systemOrange)
        default: return PopoverView.accent
        }
    }
    var title: String {
        switch m.phase {
        case .starting: return "Opening the sign-in…"
        case .waiting: return "Sign in with your browser"
        case .checking: return "Checking the code…"
        case .done: return m.alreadyActive ? "Already signed in" : m.wasSaved ? "Account updated" : "Account added"
        case .failed: return "Sign-in didn't finish"
        }
    }
    var subtitle: String {
        switch m.phase {
        case .starting, .waiting, .checking:
            return "Sign in with the account you want to add. Your current account stays active."
        case .done:
            if m.alreadyActive { return "\(m.addedName) is the account you're already using." }
            return "\(m.addedName) is saved. Your current account is still active."
        case .failed:
            return m.failure
        }
    }

    // MARK: body per phase

    @ViewBuilder var content: some View {
        switch m.phase {
        case .starting, .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(m.phase == .starting ? "Starting Claude Code's sign-in…" : "Signing in…")
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
        case .waiting:
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for you to finish in the browser…").font(.system(size: 12)).foregroundColor(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Browser didn't open, or it shows a code?").font(.system(size: 12, weight: .medium))
                    HStack(spacing: 6) {
                        Button("Open sign-in page") { if let u = m.url { NSWorkspace.shared.open(u) } }
                            .disabled(m.url == nil)
                        Text("then paste the code it shows:").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    HStack(spacing: 6) {
                        TextField("Paste code", text: $m.code)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .onSubmit { m.submitCode() }
                        Button("Submit") { m.submitCode() }
                            .disabled(m.code.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let e = m.codeError {
                        Text(e).font(.system(size: 11)).foregroundColor(PopoverView.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .done, .failed:
            EmptyView()
        }
    }

    @ViewBuilder var buttons: some View {
        HStack {
            Spacer()
            switch m.phase {
            case .starting, .waiting, .checking:
                Button("Cancel") { m.cancel(); close() }.keyboardShortcut(.cancelAction)
            case .done:
                if m.alreadyActive {
                    Button("Done") { close() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Keep current account") { close() }.keyboardShortcut(.cancelAction)
                    Button("Switch to it") { m.switchToAdded(); close() }.keyboardShortcut(.defaultAction)
                }
            case .failed:
                Button("Close") { close() }.keyboardShortcut(.cancelAction)
                Button("Try again") { m.start() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}
