import SwiftUI

/// The panel that opens from the menu-bar item: the active account on top (tinted,
/// with a blue stripe), then - with "All" on - every other saved account, dimmed,
/// in auto-switch priority order.
struct PopoverView: View {
    @ObservedObject var m: AppController

    static let accent = Color(nsColor: .systemBlue)   // adapts to light and dark mode
    static let warn = Color(nsColor: .systemRed)

    var body: some View {
        let _ = m.tick   // countdowns repaint every 30s
        VStack(alignment: .leading, spacing: 0) {
            activePanel
            if m.settings.showAll {
                othersList
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
            }
        }
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: active account

    var statusText: (String, Color) {
        if m.paused { return ("retry " + AppController.hhmm.string(from: m.backoffUntil), Self.warn) }
        if m.lastErr != nil { return ("stale", .secondary) }
        if let ok = m.lastOk { return ("checked " + AppController.hhmm.string(from: ok), .secondary) }
        return ("…", .secondary)
    }

    var activePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if m.mismatch {
                    Text("LOGIN OVERWRITTEN – restart Claude Code").font(.system(size: 10, weight: .bold)).foregroundColor(Self.warn)
                } else {
                    Text("ACTIVE").font(.system(size: 10, weight: .bold)).foregroundColor(Self.accent).fixedSize()
                    if m.settings.autoSwitch {
                        Text("AUTO @ \(Int(m.settings.autoSwitchAt))%").font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)
                            .lineLimit(1).fixedSize()
                    }
                }
                Spacer(minLength: 4)
                let (s, c) = statusText
                Text(s).font(.system(size: 10)).foregroundColor(c).monospacedDigit().lineLimit(1).fixedSize()
                HeaderButton(symbol: "arrow.clockwise", help: "Refresh now") { m.updateUsage(full: true) }
                Button { m.setShowAll(!m.settings.showAll) } label: {
                    Text("All").font(.system(size: 10, weight: .semibold)).lineLimit(1).fixedSize()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(m.settings.showAll ? Self.accent.opacity(0.35) : Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("Show every saved account")
                HeaderButton(symbol: "plus", help: "Add an account (without switching)") { m.startAddAccount() }
                HeaderButton(symbol: "ellipsis.circle", help: "Settings") { m.showMenu() }
            }

            Text(m.activeName ?? "Claude usage")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1).truncationMode(.tail)

            if m.oldSessions > 0 {
                Text("\(m.oldSessions) Claude Code \(m.oldSessions == 1 ? "session" : "sessions") still on \(m.switchedFrom ?? "the old account") – restart")
                    .font(.system(size: 11)).foregroundColor(Self.warn).lineLimit(2)
            }

            if m.rows.isEmpty {
                Text(m.statusMessage).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(3)
                    .padding(.vertical, 4)
            }
            ForEach(Array(m.rows.enumerated()), id: \.offset) { _, r in
                UsageRowView(row: r, showRemaining: m.settings.showRemaining, dim: false)
            }
        }
        .padding(.leading, 14).padding(.trailing, 12).padding(.vertical, 10)
        .background(
            ZStack(alignment: .leading) {
                Self.accent.opacity(0.10)
                Self.accent.frame(width: 3)
            }
        )
    }

    // MARK: other accounts

    var othersList: some View {
        VStack(alignment: .leading, spacing: 10) {
            if m.others.isEmpty {
                Text("No other saved accounts. Click + to add one.").font(.system(size: 11)).foregroundColor(.secondary)
            }
            ForEach(Array(m.others.enumerated()), id: \.element.id) { i, o in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(o.name).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        if m.settings.autoSwitch {
                            if i == 0 && o.eligible {
                                Text("NEXT").font(.system(size: 9, weight: .bold)).foregroundColor(Self.accent)
                            } else if let r = o.reason {
                                Text(r).font(.system(size: 9, weight: .bold)).foregroundColor(Self.warn)
                            }
                        }
                        Button { m.switchAccount(o.id) } label: {
                            Text("Switch").font(.system(size: 11, weight: .medium)).foregroundColor(Self.accent)
                        }
                        .buttonStyle(.plain)
                        .help("Make this the active account")
                    }
                    if let e = o.err {
                        Text(o.pending && m.paused ? "Not checked yet – rate limited, retrying at \(AppController.hhmm.string(from: m.backoffUntil))" : e)
                            .font(.system(size: 11)).foregroundColor(.secondary).lineLimit(2)
                    } else {
                        ForEach(Array(o.rows.enumerated()), id: \.offset) { _, r in
                            UsageRowView(row: r, showRemaining: m.settings.showRemaining, dim: true)
                        }
                    }
                }
            }
        }
    }
}

struct HeaderButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .help(help)
    }
}

/// One limit: label, "% used · time until reset", and a bar that fills as you use it
/// (or empties, with "Show remaining" on).
struct UsageRowView: View {
    let row: UsageRow
    let showRemaining: Bool
    let dim: Bool

    var body: some View {
        let left = max(0, min(100, 100 - row.used))
        let fill = showRemaining ? left : 100 - left
        let pct = showRemaining ? "\(Int(left))% left" : "\(Int(min(100, row.used)))% used"
        let until = formatUntil(row.resets)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(row.label).font(.system(size: 12)).foregroundColor(dim ? .secondary : .primary)
                Spacer()
                Text(until.isEmpty ? pct : "\(pct) · \(until)")   // unused limits have no reset time
                    .font(.system(size: 11)).foregroundColor(.secondary).monospacedDigit()
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(Color(nsColor: AppController.levelColor(left: left)).opacity(dim ? 0.55 : 1))
                        .frame(width: max(fill > 0 ? 4 : 0, g.size.width * fill / 100))
                }
            }
            .frame(height: 6)
        }
    }
}
