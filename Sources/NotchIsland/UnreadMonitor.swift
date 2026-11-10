import AppKit
import ApplicationServices

/// Reads unread badges from the Dock icons of mail and chat apps. Only the
/// number on the badge is read, never any message. This uses the same
/// Accessibility permission as the volume keys; without it nothing is shown.
final class UnreadMonitor {
    private static let apps: Set<String> = [
        "com.apple.mail", "com.apple.MobileSMS", "com.tinyspeck.slackmacgap", "net.whatsapp.WhatsApp",
        "ru.keepcoder.Telegram", "com.microsoft.teams2", "com.microsoft.teams", "com.hnc.Discord",
        "com.microsoft.Outlook",
    ]
    private static let key = "showUnread"

    private let model: IslandModel
    private var lastCounts: [String: Int]?

    /// On unless the user turned it off.
    var enabled: Bool { UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true }

    init(model: IslandModel) {
        self.model = model
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(timer, forMode: .common)
        check()
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.key)
        if on, !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        check()
    }

    private func check() {
        guard enabled, AXIsProcessTrusted() else {
            if !model.unread.isEmpty { model.unread = [] }
            lastCounts = nil
            Commands.notes["unread"] = enabled ? "waiting for Accessibility permission" : "off"
            return
        }
        let badges = readDock()
        if model.unread != badges { model.unread = badges }
        Commands.notes["unread"] = "\(badges.count) apps with a badge"

        // Announce a count that went up, but not what was already there at launch.
        var counts: [String: Int] = [:]
        for badge in badges { counts[badge.id] = Int(badge.count) ?? 1 }
        if let before = lastCounts,
           let grown = badges.first(where: { (counts[$0.id] ?? 0) > (before[$0.id] ?? 0) }) {
            model.show(Banner(icon: "bell.badge.fill", tint: .white, text: grown.count, image: grown.icon), for: 3)
        }
        lastCounts = counts
    }

    private func readDock() -> [UnreadBadge] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return []
        }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        var badges: [UnreadBadge] = []
        for list in children(of: app) {
            for item in children(of: list) {
                var urlValue: CFTypeRef?
                var badgeValue: CFTypeRef?
                AXUIElementCopyAttributeValue(item, kAXURLAttribute as CFString, &urlValue)
                AXUIElementCopyAttributeValue(item, "AXStatusLabel" as CFString, &badgeValue)
                guard let count = badgeValue as? String, !count.isEmpty, let url = urlValue as? URL,
                      let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, Self.apps.contains(id) else { continue }
                let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                badges.append(UnreadBadge(id: id, name: name, count: count,
                                          icon: NSWorkspace.shared.icon(forFile: url.path)))
            }
        }
        return badges
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        return (value as? [AXUIElement]) ?? []
    }
}
