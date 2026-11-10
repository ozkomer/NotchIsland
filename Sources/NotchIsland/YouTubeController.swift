import AppKit

/// Follows YouTube tabs in Safari. It only reads each tab's address and title;
/// nothing is run inside the page. Whether the video is playing comes from
/// CoreAudio (is Safari sending sound to the speakers), so there are no
/// transport buttons for YouTube.
final class YouTubeController {
    private let model: IslandModel
    private let scriptQueue = DispatchQueue(label: "notchisland.youtube")
    private var busy = false
    private var artworkVideoID: String?
    private var lastError = 0

    private static let safariID = "com.apple.Safari"

    /// Returns "url \n tab title" for the first YouTube video tab, or "".
    private static let findScript = """
    tell application "Safari"
        repeat with w in windows
            try
                set urls to URL of tabs of w
                repeat with i from 1 to count of urls
                    set u to item i of urls
                    if u is not missing value and (u contains "youtube.com/watch" or u contains "youtube.com/shorts/") then
                        return u & linefeed & (name of tab i of w)
                    end if
                end repeat
            end try
        end repeat
        return ""
    end tell
    """

    init(model: IslandModel) {
        self.model = model
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        poll()
    }

    private func poll() {
        guard !busy else { return }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Self.safariID).isEmpty else {
            clearIfOurs()
            return
        }
        busy = true
        scriptQueue.async { [weak self] in
            guard let self else { return }
            let text = self.run(Self.findScript)?.stringValue ?? ""
            let playing = AudioActivity.safariIsPlaying
            DispatchQueue.main.async {
                self.busy = false
                self.update(from: text, playing: playing)
            }
        }
    }

    private func update(from text: String, playing: Bool) {
        let parts = text.components(separatedBy: "\n")
        guard parts.count >= 2, !parts[0].isEmpty else {
            clearIfOurs()
            return
        }

        // Leave another player alone unless YouTube is the one making sound.
        if let current = model.track, current.source != .youtube, !playing { return }

        let isShort = parts[0].contains("/shorts/")
        let track = Track(title: Self.cleanTitle(parts[1]), artist: isShort ? "YouTube Shorts" : "YouTube",
                          album: "", isPlaying: playing, source: .youtube, canControl: false)
        if model.track != track { model.track = track }

        let videoID = Self.videoID(from: parts[0])
        if videoID != artworkVideoID {
            model.artwork = nil
            artworkVideoID = videoID
            loadThumbnail(videoID)
        }
    }

    private func clearIfOurs() {
        guard model.track?.source == .youtube else { return }
        model.track = nil
        model.artwork = nil
        artworkVideoID = nil
    }

    private static func cleanTitle(_ raw: String) -> String {
        var title = raw
        // "(3) Video name - YouTube" -> "Video name"
        if let range = title.range(of: #"^\(\d+\+?\)\s*"#, options: .regularExpression) {
            title.removeSubrange(range)
        }
        for suffix in [" - YouTube Music", " - YouTube"] where title.hasSuffix(suffix) {
            title.removeLast(suffix.count)
        }
        return title
    }

    private static func videoID(from url: String) -> String? {
        guard let parts = URLComponents(string: url) else { return nil }
        if parts.path.hasPrefix("/shorts/") {
            return parts.path.split(separator: "/").dropFirst().first.map(String.init)
        }
        return parts.queryItems?.first { $0.name == "v" }?.value
    }

    private func loadThumbnail(_ videoID: String?) {
        guard let videoID, let url = URL(string: "https://i.ytimg.com/vi/\(videoID)/mqdefault.jpg") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                guard let self, self.artworkVideoID == videoID, self.model.track?.source == .youtube else { return }
                self.model.artwork = image
            }
        }.resume()
    }

    private func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error, let number = error[NSAppleScript.errorNumber] as? Int, number != lastError {
            // -1743 means the Automation permission for Safari was refused.
            lastError = number
            NSLog("NotchIsland: Safari script error \(number)")
        }
        return result
    }
}
