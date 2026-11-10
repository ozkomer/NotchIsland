import AppKit

/// Follows players that do not announce their state (Apple TV, VLC,
/// QuickTime Player) by asking them with AppleScript while they are running.
final class PlayerPoller {
    private struct Player {
        var source: MusicSource
        var label: String
        /// Returns "state \n title \n artist \n position \n duration"; state is playing, paused or stopped.
        var query: String
        var commands: [String: String]
    }

    private static let players = [
        Player(source: .tv, label: "Apple TV", query: """
            tell application "TV"
                try
                    if player state is stopped then return "stopped"
                    set s to "paused"
                    if player state is playing then set s to "playing"
                    set t to current track
                    return s & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (player position as text) & linefeed & ((duration of t) as text)
                on error
                    return "stopped"
                end try
            end tell
            """, commands: ["playpause": "tell application \"TV\" to playpause",
                            "next track": "tell application \"TV\" to next track",
                            "previous track": "tell application \"TV\" to previous track"]),
        Player(source: .vlc, label: "VLC", query: """
            tell application "VLC"
                try
                    set n to name of current item
                    if n is missing value then return "stopped"
                    set s to "paused"
                    if playing then set s to "playing"
                    return s & linefeed & n & linefeed & "" & linefeed & (current time as text) & linefeed & ((duration of current item) as text)
                on error
                    return "stopped"
                end try
            end tell
            """, commands: ["playpause": "tell application \"VLC\" to play",
                            "next track": "tell application \"VLC\" to next",
                            "previous track": "tell application \"VLC\" to previous"]),
        Player(source: .quicktime, label: "QuickTime Player", query: """
            tell application "QuickTime Player"
                try
                    if (count of documents) is 0 then return "stopped"
                    set d to document 1
                    set s to "paused"
                    if playing of d then set s to "playing"
                    return s & linefeed & (name of d) & linefeed & "" & linefeed & ((current time of d) as text) & linefeed & ((duration of d) as text)
                on error
                    return "stopped"
                end try
            end tell
            """, commands: [
                "playpause": "tell application \"QuickTime Player\" to tell document 1\nif playing then\npause\nelse\nplay\nend if\nend tell",
                // QuickTime has no playlist; the side buttons skip ten seconds.
                "next track": "tell application \"QuickTime Player\" to tell document 1 to set current time to (current time + 10)",
                "previous track": "tell application \"QuickTime Player\" to tell document 1 to set current time to (current time - 10)",
            ]),
    ]

    private let model: IslandModel
    private let scriptQueue = DispatchQueue(label: "notchisland.players")
    private var busy = false
    /// A file that was only opened should not sit on the island as "paused".
    private var hasPlayed: Set<String> = []

    init(model: IslandModel) {
        self.model = model
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func isRunning(_ player: Player) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: player.source.bundleID).isEmpty
    }

    private func poll() {
        guard !busy else { return }
        let running = Self.players.filter(isRunning)
        for player in Self.players where !running.contains(where: { $0.source == player.source }) {
            clear(player.source)
        }
        guard !running.isEmpty else { return }
        busy = true
        scriptQueue.async { [weak self] in
            guard let self else { return }
            let results = running.map { ($0, self.run($0.query)) }
            DispatchQueue.main.async {
                self.busy = false
                for (player, text) in results { self.update(player, text) }
            }
        }
    }

    private func update(_ player: Player, _ text: String) {
        let parts = text.components(separatedBy: "\n")
        guard parts.count >= 5, parts[0] != "stopped" else {
            clear(player.source)
            return
        }
        let playing = parts[0] == "playing"
        // Leave another player alone unless this one is the one playing.
        if let current = model.track, current.source != player.source, !playing { return }

        if playing { hasPlayed.insert(player.label) }
        let track = Track(title: parts[1], artist: parts[2].isEmpty ? player.label : parts[2], album: "",
                          isPlaying: playing, source: player.source,
                          showWhenPaused: hasPlayed.contains(player.label))
        if model.track?.title != track.title || model.track?.source != track.source { model.artwork = nil }
        if model.track != track { model.track = track }

        // AppleScript writes decimals with the system's separator.
        let elapsed = Double(parts[3].replacingOccurrences(of: ",", with: "."))
        let duration = Double(parts[4].replacingOccurrences(of: ",", with: "."))
        if let elapsed, let duration, duration > 0 {
            model.position = PlaybackPosition(elapsed: elapsed, asOf: Date(), duration: duration)
        } else {
            model.position = nil
        }
    }

    private func clear(_ source: MusicSource) {
        guard model.track?.source == source else { return }
        model.track = nil
        model.artwork = nil
        model.position = nil
    }

    func handles(_ source: MusicSource) -> Bool {
        Self.players.contains { $0.source == source }
    }

    func send(_ command: String) {
        guard let source = model.track?.source,
              let player = Self.players.first(where: { $0.source == source }),
              let script = player.commands[command], isRunning(player) else { return }
        scriptQueue.async { [weak self] in
            _ = self?.run(script)
        }
    }

    private func run(_ source: String) -> String {
        var error: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue ?? "stopped"
    }
}
