import AppKit

/// Follows Music and Spotify through their distributed notifications and
/// controls them with AppleScript (macOS asks for Automation permission once).
final class MusicController {
    private let model: IslandModel
    private let scriptQueue = DispatchQueue(label: "notchisland.applescript")
    private var lastError = 0

    init(model: IslandModel) {
        self.model = model

        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(musicChanged(_:)),
                           name: NSNotification.Name("com.apple.Music.playerInfo"), object: nil)
        center.addObserver(self, selector: #selector(spotifyChanged(_:)),
                           name: NSNotification.Name("com.spotify.client.PlaybackStateChanged"), object: nil)

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appQuit(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        for source in [MusicSource.music, .spotify] where isRunning(source) {
            queryState(source)
        }
    }

    // MARK: Notifications

    @objc private func musicChanged(_ note: Notification) { handle(note.userInfo, source: .music) }
    @objc private func spotifyChanged(_ note: Notification) { handle(note.userInfo, source: .spotify) }

    @objc private func appQuit(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if let source = model.track?.source, !source.bundleID.isEmpty, app?.bundleIdentifier == source.bundleID {
            model.track = nil
            model.artwork = nil
            model.position = nil
        }
    }

    private func handle(_ info: [AnyHashable: Any]?, source: MusicSource) {
        guard let info else { return }
        let state = info["Player State"] as? String ?? ""
        Commands.notes["last \(source.rawValue) notification"] = state
        if state == "Stopped" {
            if model.track?.source == source {
                model.track = nil
                model.artwork = nil
                model.position = nil
            }
            return
        }
        // Don't let a paused player replace the one that is playing.
        if state != "Playing", let current = model.track, current.source != source, current.isPlaying {
            return
        }
        apply(Track(title: info["Name"] as? String ?? "",
                    artist: info["Artist"] as? String ?? "",
                    album: info["Album"] as? String ?? "",
                    isPlaying: state == "Playing",
                    source: source))
    }

    private func apply(_ track: Track) {
        let old = model.track
        let sameSong = old?.title == track.title && old?.artist == track.artist && old?.source == track.source
        model.track = track
        if !sameSong {
            model.artwork = nil
            model.position = nil
            loadArtwork(for: track)
        }
        refreshPosition()
    }

    /// Asks the player where it is in the track; the view counts on from there.
    func refreshPosition() {
        guard let track = model.track, track.source == .music || track.source == .spotify,
              isRunning(track.source) else { return }
        let script = """
        tell application "\(track.source.rawValue)"
            try
                return (player position as text) & linefeed & ((duration of current track) as text)
            on error
                return ""
            end try
        end tell
        """
        scriptQueue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, let text = self.run(script)?.stringValue else { return }
            // AppleScript writes decimals with the system's separator.
            let numbers = text.components(separatedBy: "\n").map { Double($0.replacingOccurrences(of: ",", with: ".")) }
            guard numbers.count == 2, let elapsed = numbers[0], var duration = numbers[1], duration > 0 else { return }
            // Spotify reports the duration in milliseconds.
            if track.source == .spotify { duration /= 1000 }
            DispatchQueue.main.async {
                guard self.model.track?.title == track.title, self.model.track?.source == track.source else { return }
                self.model.position = PlaybackPosition(elapsed: elapsed, asOf: Date(), duration: duration)
            }
        }
    }

    // MARK: AppleScript

    private func isRunning(_ source: MusicSource) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleID).isEmpty
    }

    private func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error, let number = error[NSAppleScript.errorNumber] as? Int, number != lastError {
            // -1743 means the Automation permission for the player was refused.
            lastError = number
            NSLog("NotchIsland: player script error \(number)")
        }
        if let error, let number = error[NSAppleScript.errorNumber] as? Int {
            DispatchQueue.main.async { Commands.notes["player script error"] = "\(number)" }
        }
        return result
    }

    func send(_ command: String) {
        guard let source = model.track?.source, source == .music || source == .spotify, isRunning(source) else { return }
        scriptQueue.async { [weak self] in
            _ = self?.run("tell application \"\(source.rawValue)\" to \(command)")
        }
    }

    private func queryState(_ source: MusicSource) {
        let script = """
        tell application "\(source.rawValue)"
            try
                if player state is stopped then return "stopped"
                set s to "paused"
                if player state is playing then set s to "playing"
                return s & linefeed & (name of current track) & linefeed & (artist of current track) & linefeed & (album of current track)
            on error message number code
                return "error " & code
            end try
        end tell
        """
        scriptQueue.async { [weak self] in
            guard let self else { return }
            let text = self.run(script)?.stringValue ?? ""
            DispatchQueue.main.async {
                Commands.notes["\(source.rawValue) query"] = text.isEmpty ? "empty" : "\(text.components(separatedBy: .newlines).count) lines, state \(text.components(separatedBy: .newlines)[0])"
            }
            guard !text.isEmpty else { return }
            let parts = text.components(separatedBy: "\n")
            guard parts.count >= 4 else { return }
            let track = Track(title: parts[1], artist: parts[2], album: parts[3],
                              isPlaying: parts[0] == "playing", source: source)
            DispatchQueue.main.async {
                if self.model.track == nil || track.isPlaying { self.apply(track) }
            }
        }
    }

    private func loadArtwork(for track: Track) {
        // The player needs a moment after a track change before artwork is ready.
        scriptQueue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            switch track.source {
            case .music:
                let result = self.run("tell application \"Music\" to get raw data of artwork 1 of current track")
                if let data = result?.data, let image = NSImage(data: data) {
                    self.setArtwork(image, for: track)
                }
            case .spotify:
                let result = self.run("tell application \"Spotify\" to get artwork url of current track")
                guard let text = result?.stringValue, let url = URL(string: text) else { return }
                URLSession.shared.dataTask(with: url) { data, _, _ in
                    if let data, let image = NSImage(data: data) {
                        self.setArtwork(image, for: track)
                    }
                }.resume()
            default:
                break
            }
        }
    }

    private func setArtwork(_ image: NSImage, for track: Track) {
        DispatchQueue.main.async {
            guard self.model.track?.title == track.title, self.model.track?.source == track.source else { return }
            self.model.artwork = image
        }
    }
}
