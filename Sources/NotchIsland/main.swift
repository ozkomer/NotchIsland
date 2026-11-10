import AppKit
import ServiceManagement
import SwiftUI

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // Let the panel sit over the menu bar instead of being pushed below it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = IslandModel()
    private var panel: IslandPanel!
    private var music: MusicController!
    private var youtube: YouTubeController!
    private var power: PowerMonitor!
    private var privacy: PrivacyMonitor!
    private var volume: VolumeMonitor!
    private var keyboard: KeyboardMonitor!
    private var network: NetworkMonitor!
    private var calendar: CalendarMonitor!
    private var screen: NSScreen?
    private var hoverTicks = 0
    private var menuOpen = false

    private static let panelSize = CGSize(width: 720, height: 440)

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = IslandPanel(contentRect: CGRect(origin: .zero, size: Self.panelSize),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false

        let host = IslandHostingView(rootView: IslandView(model: model))
        host.menu = makeMenu()
        panel.contentView = host

        layout()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(self, selector: #selector(layout),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)

        music = MusicController(model: model)
        youtube = YouTubeController(model: model)
        power = PowerMonitor(model: model)
        privacy = PrivacyMonitor(model: model)
        volume = VolumeMonitor(model: model)
        keyboard = KeyboardMonitor(model: model)
        network = NetworkMonitor(model: model)
        calendar = CalendarMonitor(model: model)
        model.onMusicCommand = { [weak self] command in self?.music.send(command) }

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(command(_:)), name: Commands.notification, object: nil)

        // Test switch: --demo-expanded holds the island open without the pointer.
        if CommandLine.arguments.contains("--demo-expanded") {
            model.expanded = true
            return
        }

        // Polling the pointer needs no permission and lets clicks outside the
        // island pass through to whatever is underneath.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.trackPointer() }
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func command(_ note: Notification) {
        Commands.handle(note.userInfo, model: model)
    }

    @objc private func layout() {
        let target = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
        guard let target else { return }
        screen = target

        if target.safeAreaInsets.top > 0 {
            let left = target.auxiliaryTopLeftArea?.width ?? 0
            let right = target.auxiliaryTopRightArea?.width ?? 0
            let width = target.frame.width - left - right
            model.notch = CGSize(width: width > 60 ? width : 190, height: target.safeAreaInsets.top)
        } else {
            // No notch: draw a pill the height of the menu bar.
            let bar = target.frame.maxY - target.visibleFrame.maxY
            model.notch = CGSize(width: 180, height: max(bar, 24))
        }

        let size = Self.panelSize
        panel.setFrame(CGRect(x: target.frame.midX - size.width / 2,
                              y: target.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
    }

    private func trackPointer() {
        guard let screen, !menuOpen else { return }
        let size = model.size
        let rect = CGRect(x: screen.frame.midX - size.width / 2,
                          y: screen.frame.maxY - size.height,
                          width: size.width, height: size.height + 2).insetBy(dx: -4, dy: 0)
        let inside = rect.contains(NSEvent.mouseLocation)

        panel.ignoresMouseEvents = !inside
        if inside {
            hoverTicks += 1
            // A short dwell keeps the island from opening when the pointer just passes by.
            if hoverTicks >= 3, !model.expanded {
                model.expanded = true
                music.refreshPosition()
            }
        } else {
            hoverTicks = 0
            if model.expanded { model.expanded = false }
        }
    }

    // MARK: Right-click menu

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        let login = NSMenuItem(title: "Girişte Başlat", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        menu.addItem(login)
        let events = NSMenuItem(title: "Takvimi Göster", action: #selector(toggleCalendar(_:)), keyEquivalent: "")
        events.target = self
        menu.addItem(events)
        let clear = NSMenuItem(title: "Etkinlikleri Temizle", action: #selector(clearActivities), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "NotchIsland'dan Çık", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        menu.items[0].state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.items[1].state = calendar.enabled ? .on : .off
    }

    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("NotchIsland: login item change failed: \(error.localizedDescription)")
        }
    }

    @objc private func toggleCalendar(_ sender: NSMenuItem) { calendar.setEnabled(!calendar.enabled) }

    @objc private func clearActivities() { model.activities.removeAll() }

    @objc private func quit() { NSApp.terminate(nil) }
}

// `notch show ...` and friends: talk to the running app, then leave.
let commandArguments = Array(CommandLine.arguments.dropFirst())
if let first = commandArguments.first, Commands.names.contains(first) {
    exit(Commands.runCommandLine(commandArguments))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
