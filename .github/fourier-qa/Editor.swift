import AppKit
import Foundation

final class Target: NSTextView {
    var trial: String = ""
    var delivered = false
    override func didChangeText() {
        super.didChangeText()
        guard !delivered, !trial.isEmpty, !string.isEmpty else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        delivered = true
        let record: [String: Any] = ["trial": trial, "now": now, "text": string]
        if let data = try? JSONSerialization.data(withJSONObject: record) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/tap-external-result"), options: .atomic)
        }
    }
}

@MainActor
final class Receiver: NSObject, NSApplicationDelegate {
    var w: NSWindow?
    let target = Target()
    var timer: Timer?
    func applicationDidFinishLaunching(_ n: Notification) {
        let bar = NSMenu()
        let root = NSMenuItem(); bar.addItem(root); root.submenu = NSMenu(title: "Fixture editor")
        let slot = NSMenuItem(); bar.addItem(slot); let edit = NSMenu(title: "Edit"); slot.submenu = edit
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        NSApp.mainMenu = bar
        let window = NSWindow(contentRect: NSRect(x: 70, y: 80, width: 540, height: 210),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w = window; window.title = "Fourier benchmark external editor"
        window.contentView = target; target.isEditable = true; target.isRichText = false
        NSApp.setActivationPolicy(.regular)
        timer = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        check()
    }
    func check() {
        guard let id = try? String(contentsOfFile: "/tmp/tap-external-request", encoding: .utf8),
              let w else { return }
        if id != target.trial {
            target.trial = id; target.delivered = false; target.string = ""
        }
        if !target.delivered && !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        if !target.delivered && !w.isKeyWindow {
            w.makeKeyAndOrderFront(nil); w.makeFirstResponder(target)
        }
        if NSApp.isActive && w.isKeyWindow && w.firstResponder === target {
            if (try? String(contentsOfFile: "/tmp/tap-external-ready", encoding: .utf8)) != id {
                try? id.write(toFile: "/tmp/tap-external-ready", atomically: true, encoding: .utf8)
            }
        }
    }
}
@main
enum EditorMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let receiver = Receiver()
        app.delegate = receiver
        withExtendedLifetime(receiver) { app.run() }
    }
}
