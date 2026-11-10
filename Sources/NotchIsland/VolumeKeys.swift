import AppKit
import ApplicationServices

/// Optional: takes over the volume keys so the system's own volume display
/// never appears and only the island shows the level.
///
/// The tap listens to media keys only (system-defined events), never to
/// ordinary typing. macOS still requires the Accessibility permission for it.
final class VolumeKeys {
    private let volume: VolumeMonitor
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var waitTimer: Timer?
    private var handled = 0

    private static let key = "volumeKeys"
    /// NX_KEYTYPE_SOUND_UP, NX_KEYTYPE_SOUND_DOWN, NX_KEYTYPE_MUTE
    private static let soundUp = 0, soundDown = 1, mute = 7

    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.key) }

    init(volume: VolumeMonitor) {
        self.volume = volume
        if enabled { start() }
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.key)
        if on { start() } else { stop() }
    }

    private func start() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            install()
            return
        }
        // Wait for the user to grant the permission in System Settings.
        note("waiting for Accessibility permission")
        waitTimer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] timer in
            guard let self, self.enabled else { timer.invalidate(); return }
            if AXIsProcessTrusted() {
                timer.invalidate()
                self.install()
            }
        }
        waitTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stop() {
        waitTimer?.invalidate()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        note("off")
    }

    private func install() {
        guard tap == nil else { return }
        // 14 = system-defined events, which carry the media keys.
        let mask = CGEventMask(1 << 14)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let keys = Unmanaged<VolumeKeys>.fromOpaque(userInfo).takeUnretainedValue()
            return keys.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            note("tap could not be created")
            return
        }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        note("tap active")
    }

    /// Returns true when the event was a volume key we acted on and should be swallowed.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard type.rawValue == 14, let key = NSEvent(cgEvent: event), key.subtype.rawValue == 8 else { return false }
        let code = (key.data1 & 0xFFFF_0000) >> 16
        let isDown = ((key.data1 & 0xFF00) >> 8) == 0xA
        guard [Self.soundUp, Self.soundDown, Self.mute].contains(code) else { return false }
        // A device without software volume (some displays) stays with the system.
        guard volume.canSet else { return false }
        guard isDown else { return true }

        // Shift+Option gives quarter steps, as the system does.
        let fine = key.modifierFlags.contains([.shift, .option])
        let step: Float32 = fine ? 1.0 / 64 : 1.0 / 16
        switch code {
        case Self.soundUp: volume.adjust(by: step)
        case Self.soundDown: volume.adjust(by: -step)
        default: volume.toggleMute()
        }
        handled += 1
        note("tap active, handled \(handled) key presses")
        return true
    }

    private func note(_ text: String) {
        Commands.notes["volume keys"] = text
    }
}
