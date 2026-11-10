import AppKit
import SwiftUI

/// Where a track comes from. The raw value is the app's AppleScript name.
enum MusicSource: String {
    case music = "Music"
    case spotify = "Spotify"
    case tv = "TV"
    case vlc = "VLC"
    case quicktime = "QuickTime Player"
    /// A media tab in a web browser (YouTube, Twitch, ...).
    case browser = "Browser"

    var bundleID: String {
        switch self {
        case .music: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        case .tv: return "com.apple.TV"
        case .vlc: return "org.videolan.vlc"
        case .quicktime: return "com.apple.QuickTimePlayerX"
        case .browser: return ""
        }
    }
}

struct Track: Equatable {
    var title: String
    var artist: String
    var album: String
    var isPlaying: Bool
    var source: MusicSource
    /// False when the player can be seen but not driven (no transport buttons).
    var canControl = true
    /// Whether the wings stay open while this track is paused.
    var showWhenPaused = true
}

/// Where the player was when it was last asked; the view advances it while playing.
struct PlaybackPosition: Equatable {
    var elapsed: Double
    var asOf: Date
    var duration: Double
}

/// A short notice that takes over the wings for a few seconds.
struct Banner: Equatable {
    var icon: String
    var tint: Color
    var text: String
    /// When set, a level bar (0...1) is drawn instead of the text.
    var level: Double?
    /// When set, drawn instead of the symbol (an app icon, for example).
    var image: NSImage?
}

/// An unread badge read from an app's Dock icon.
struct UnreadBadge: Identifiable, Equatable {
    var id: String
    var name: String
    var count: String
    var icon: NSImage
}

struct OngoingCall: Equatable {
    var app: String
    var start: Date
}

/// An activity pushed from outside with the `notch` command.
struct CustomActivity: Identifiable, Equatable {
    var id: String
    var title: String
    var detail: String
    var progress: Double?
    var icon: String
    var tint: Color
    var started: Date
}

struct UpcomingEvent: Equatable {
    var title: String
    var start: Date
}

/// What the wings can show, in priority order.
enum Slot {
    case custom(CustomActivity)
    case call(OngoingCall)
    case clock
    case event(UpcomingEvent)
    case music
}

final class IslandModel: ObservableObject {
    /// Size of the physical notch (or of the stand-in pill on screens without one).
    @Published var notch = CGSize(width: 190, height: 32)
    @Published var expanded = false
    @Published var banner: Banner?

    @Published var track: Track?
    @Published var artwork: NSImage?
    @Published var position: PlaybackPosition?

    @Published var timerEnd: Date?
    @Published var stopwatchStart: Date?
    @Published var timerChoice = 3
    /// Whether the timer / stopwatch row is offered in the panel (right-click menu).
    @Published var showClock = UserDefaults.standard.bool(forKey: "showClock") {
        didSet { UserDefaults.standard.set(showClock, forKey: "showClock") }
    }

    @Published var activities: [CustomActivity] = []

    @Published var nextEvent: UpcomingEvent?
    @Published var eventImminent = false

    @Published var stats: SystemStats?
    @Published var nextReminder: UpcomingEvent?
    @Published var call: OngoingCall?
    @Published var unread: [UnreadBadge] = []
    /// Name of the browser that has a Google Meet tab open, if any.
    var meetBrowser: String?

    /// Name of the app using the microphone, nil when it is free.
    @Published var micApp: String?
    @Published var cameraOn = false

    var onMusicCommand: ((String) -> Void)?

    static let timerChoices = [1, 2, 3, 5, 10, 15, 20, 25, 30, 45, 60, 90, 120]
    static let maxActivityRows = 3

    private var bannerDismiss: DispatchWorkItem?
    private var timerFinish: DispatchWorkItem?

    var isPlaying: Bool { track?.isPlaying == true }
    var hasIndicators: Bool { micApp != nil || cameraOn }
    /// The row stays while something is running so it can still be stopped.
    var showsClockRow: Bool { showClock || timerEnd != nil || stopwatchStart != nil }
    var showsProgress: Bool { position != nil && track != nil && track?.source != .browser }

    var slots: [Slot] {
        var result: [Slot] = []
        if let first = activities.first { result.append(.custom(first)) }
        if let call { result.append(.call(call)) }
        if timerEnd != nil || stopwatchStart != nil { result.append(.clock) }
        if eventImminent, let event = nextEvent { result.append(.event(event)) }
        if let track, track.isPlaying || track.showWhenPaused { result.append(.music) }
        return result
    }

    var showsCompact: Bool { banner != nil || !slots.isEmpty || hasIndicators }

    /// Width of each side wing in the compact state.
    var wing: CGFloat {
        if let banner {
            if banner.level != nil { return 72 }
            return min(max(CGFloat(banner.text.count) * 8 + 22, 62), 150)
        }
        guard let first = slots.first else { return notch.height + 6 }
        var width: CGFloat
        if case .music = first { width = notch.height + 6 } else { width = 62 }
        if hasIndicators { width += 14 }
        return width
    }

    /// Heights of the rows in the expanded panel, top to bottom.
    var expandedRows: [CGFloat] {
        var rows = activities.prefix(Self.maxActivityRows).map { _ in CGFloat(38) }
        rows.append(showsProgress ? 72 : 52)
        if showsClockRow {
            rows.append(1)
            rows.append(28)
        }
        if stats != nil { rows.append(1); rows.append(40) }
        if call != nil { rows.append(20) }
        if nextEvent != nil { rows.append(20) }
        if nextReminder != nil { rows.append(20) }
        if !unread.isEmpty { rows.append(24) }
        if hasIndicators { rows.append(18) }
        return rows
    }

    /// Current visual size of the island body.
    var size: CGSize {
        if expanded {
            let rows = expandedRows
            let height = notch.height - 4 + rows.reduce(0, +) + CGFloat(rows.count) * 10 + 14
            // A little wider when the figures row has to fit six tiles.
            let width: CGFloat = stats != nil ? 450 : 400
            return CGSize(width: max(notch.width + 200, width), height: height)
        }
        if showsCompact {
            return CGSize(width: notch.width + wing * 2, height: notch.height)
        }
        return notch
    }

    func show(_ banner: Banner, for seconds: TimeInterval) {
        bannerDismiss?.cancel()
        self.banner = banner
        let item = DispatchWorkItem { [weak self] in self?.banner = nil }
        bannerDismiss = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    // MARK: Timer and stopwatch

    func startTimer(minutes: Int) {
        timerFinish?.cancel()
        stopwatchStart = nil
        let seconds = TimeInterval(minutes * 60)
        timerEnd = Date().addingTimeInterval(seconds)
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.timerEnd = nil
            NSSound(named: "Glass")?.play()
            self.show(Banner(icon: "bell.fill", tint: .orange, text: "Bitti"), for: 6)
        }
        timerFinish = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    func cancelTimer() {
        timerFinish?.cancel()
        timerEnd = nil
    }

    func startStopwatch() {
        cancelTimer()
        stopwatchStart = Date()
    }

    func stopStopwatch() {
        stopwatchStart = nil
    }

    // MARK: Custom activities

    func upsert(_ activity: CustomActivity) {
        if let index = activities.firstIndex(where: { $0.id == activity.id }) {
            var updated = activity
            updated.started = activities[index].started
            activities[index] = updated
        } else {
            activities.insert(activity, at: 0)
        }
    }

    func removeActivity(_ id: String) {
        activities.removeAll { $0.id == id }
    }
}
