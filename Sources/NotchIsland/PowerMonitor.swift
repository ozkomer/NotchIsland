import Foundation
import IOKit.ps
import SwiftUI

/// Shows a short banner when the charger is plugged in or removed, when the
/// battery runs low (20% and 10%) and when it finishes charging.
final class PowerMonitor {
    private struct State {
        var onAC: Bool
        var percent: Int
        var charged: Bool
    }

    private let model: IslandModel
    private var lastOnAC: Bool?
    private var warned20 = false
    private var warned10 = false
    private var announcedFull = false

    init(model: IslandModel) {
        self.model = model
        if let now = read() {
            lastOnAC = now.onAC
            // Don't announce what was already true at launch.
            announcedFull = now.charged
            warned20 = !now.onAC && now.percent <= 20
            warned10 = !now.onAC && now.percent <= 10
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue().check()
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    private func check() {
        guard let now = read() else { return }
        defer { lastOnAC = now.onAC }

        if let last = lastOnAC, last != now.onAC {
            if now.onAC {
                warned20 = false
                warned10 = false
                model.show(Banner(icon: "bolt.fill", tint: .green, text: "%\(now.percent)"), for: 4)
            } else {
                announcedFull = false
                model.show(Banner(icon: "battery.75percent", tint: .white, text: "%\(now.percent)"), for: 4)
            }
            return
        }

        if now.onAC {
            if now.charged, !announcedFull {
                announcedFull = true
                model.show(Banner(icon: "battery.100percent.bolt", tint: .green, text: "Doldu"), for: 5)
            }
        } else if now.percent <= 10, !warned10 {
            warned10 = true
            warned20 = true
            model.show(Banner(icon: "battery.0percent", tint: .red, text: "%\(now.percent)"), for: 8)
        } else if now.percent <= 20, !warned20 {
            warned20 = true
            model.show(Banner(icon: "battery.25percent", tint: .orange, text: "%\(now.percent)"), for: 6)
        }
    }

    private func read() -> State? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for item in list {
            guard let info = IOPSGetPowerSourceDescription(blob, item)?.takeUnretainedValue() as? [String: Any],
                  let percent = info[kIOPSCurrentCapacityKey] as? Int,
                  let state = info[kIOPSPowerSourceStateKey] as? String else { continue }
            return State(onAC: state == kIOPSACPowerValue, percent: percent,
                         charged: info[kIOPSIsChargedKey] as? Bool ?? false)
        }
        return nil
    }
}
