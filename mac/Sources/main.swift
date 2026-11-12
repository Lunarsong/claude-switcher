import AppKit

// One binary, two jobs:
//   ClaudeUsageTray --cli <command> ...   the claude-profile command line
//   ClaudeUsageTray                       the menu-bar app
let args = CommandLine.arguments
if args.count > 1 && args[1] == "--cli" {
    exit(CLI.run(Array(args.dropFirst(2))))
}

// Single instance: if another copy is already in the menu bar, leave it be.
if let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != getpid() }) {
    exit(0)
}

// Writing to a sign-in that just exited must not kill the app.
signal(SIGPIPE, SIG_IGN)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu bar only: no Dock icon, no app menu
// No visible menu bar, but an Edit menu makes Cmd-C/V/X/A work in text fields.
let mainMenu = NSMenu()
let editItem = NSMenuItem()
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
editMenu.addItem(.separator())
editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editItem.submenu = editMenu
mainMenu.addItem(editItem)
app.mainMenu = mainMenu

let controller = AppController()
controller.start()
app.run()
