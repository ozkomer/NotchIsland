import AppKit

/// Follows media tabs (YouTube, YouTube Music, Twitch, SoundCloud, Netflix)
/// in Safari and Chromium browsers. It only reads each tab's address and
/// title; nothing is run inside the page. Whether something is playing comes
/// from CoreAudio (is that browser sending sound to the speakers), so there
/// are no transport buttons for browser tabs.
final class BrowserController {
    private struct Browser {
        var app: String
        var bundleID: String
        /// Bundle id prefixes of the processes that play the browser's audio.
        var audioPrefixes: [String]
        /// AppleScript property that holds a tab's title.
        var titleProperty: String
    }

    private struct Candidate {
        var url: String
        var title: String
        var site: String
        var browser: Browser
        var playing: Bool
    }

    private static let browsers = [
        Browser(app: "Safari", bundleID: "com.apple.Safari",
                audioPrefixes: ["com.apple.WebKit", "com.apple.Safari"], titleProperty: "name"),
        Browser(app: "Google Chrome", bundleID: "com.google.Chrome",
                audioPrefixes: ["com.google.Chrome"], titleProperty: "title"),
        Browser(app: "Brave Browser", bundleID: "com.brave.Browser",
                audioPrefixes: ["com.brave.Browser"], titleProperty: "title"),
        Browser(app: "Microsoft Edge", bundleID: "com.microsoft.edgemac",
                audioPrefixes: ["com.microsoft.edgemac"], titleProperty: "title"),
        Browser(app: "Arc", bundleID: "company.thebrowser.Browser",
                audioPrefixes: ["company.thebrowser.Browser"], titleProperty: "title"),
    ]

    private let model: IslandModel
    private let scriptQueue = DispatchQueue(label: "notchisland.browser")
    private var busy = false
    private var artworkKey: String?
    private var errors: [String: Int] = [:]
    /// A tab that was never played should not sit on the island as "paused".
    private var hasPlayed = false

    init(model: IslandModel) {
        self.model = model
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        poll()
    }

    // MARK: Polling

    private func poll() {
        guard !busy else { return }
        let running = Self.browsers.filter {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID).isEmpty
        }
        guard !running.isEmpty else {
            update(candidates: [], meetBrowser: nil)
            return
        }
        busy = true
        scriptQueue.async { [weak self] in
            guard let self else { return }
            var candidates: [Candidate] = []
            var meetBrowser: String?
            for browser in running {
                let playing = AudioActivity.isPlaying(prefixes: browser.audioPrefixes)
                let text = self.run(Self.script(for: browser), browser: browser)?.stringValue ?? ""
                for line in text.components(separatedBy: "\n") {
                    let parts = line.components(separatedBy: "\t")
                    guard parts.count >= 2 else { continue }
                    if Self.isMeeting(parts[0]) { meetBrowser = browser.app }
                    guard let site = Self.site(for: parts[0]) else { continue }
                    candidates.append(Candidate(url: parts[0], title: parts[1], site: site,
                                                browser: browser, playing: playing))
                }
            }
            DispatchQueue.main.async {
                self.busy = false
                self.update(candidates: candidates, meetBrowser: meetBrowser)
            }
        }
    }

    /// Returns one "url <tab> title" line per tab on a site we know.
    private static func script(for browser: Browser) -> String {
        """
        tell application "\(browser.app)"
            set found to ""
            repeat with w in windows
                try
                    set urls to URL of tabs of w
                    repeat with i from 1 to count of urls
                        set u to item i of urls
                        if u is not missing value then
                            if u contains "youtube.com/" or u contains "twitch.tv/" or u contains "soundcloud.com/" or u contains "netflix.com/watch" or u contains "meet.google.com/" then
                                set found to found & u & (character id 9) & (\(browser.titleProperty) of tab i of w) & linefeed
                            end if
                        end if
                    end repeat
                end try
            end repeat
            return found
        end tell
        """
    }

    private static func isMeeting(_ url: String) -> Bool {
        guard let parts = URLComponents(string: url), parts.host == "meet.google.com" else { return false }
        // A meeting code, not the landing page.
        return parts.path.count > 4 && !parts.path.hasPrefix("/landing")
    }

    /// Name of the media site a tab is on, or nil when the tab is not a player page.
    private static func site(for url: String) -> String? {
        guard let parts = URLComponents(string: url), let host = parts.host else { return nil }
        let path = parts.path
        if host == "music.youtube.com" { return path.hasPrefix("/watch") ? "YouTube Music" : nil }
        if host.hasSuffix("youtube.com") {
            if path.hasPrefix("/watch") { return "YouTube" }
            if path.hasPrefix("/shorts/") { return "YouTube Shorts" }
            return nil
        }
        if host.hasSuffix("twitch.tv") { return path.count > 1 && !path.hasPrefix("/directory") ? "Twitch" : nil }
        if host.hasSuffix("soundcloud.com") { return path.split(separator: "/").count >= 2 ? "SoundCloud" : nil }
        if host.hasSuffix("netflix.com") { return path.hasPrefix("/watch") ? "Netflix" : nil }
        return nil
    }

    private func update(candidates: [Candidate], meetBrowser: String?) {
        model.meetBrowser = meetBrowser

        // A tab in a browser that is making sound wins; otherwise the first one found.
        guard let pick = candidates.first(where: { $0.playing }) ?? candidates.first else {
            clearIfOurs()
            return
        }

        // Leave another player alone unless the browser is the one making sound.
        if let current = model.track, current.source != .browser, !pick.playing { return }

        if pick.playing { hasPlayed = true }
        let track = Track(title: Self.cleanTitle(pick.title), artist: pick.site, album: "",
                          isPlaying: pick.playing, source: .browser, canControl: false,
                          showWhenPaused: hasPlayed)
        if model.track != track {
            model.track = track
            model.position = nil
        }

        let key = Self.thumbnailURL(for: pick.url)?.absoluteString ?? pick.url
        if key != artworkKey {
            model.artwork = nil
            artworkKey = key
            loadThumbnail(for: pick.url, key: key)
        }
    }

    private func clearIfOurs() {
        hasPlayed = false
        guard model.track?.source == .browser else { return }
        model.track = nil
        model.artwork = nil
        artworkKey = nil
    }

    private static func cleanTitle(_ raw: String) -> String {
        var title = raw
        // "(3) Video name - YouTube" -> "Video name"
        if let range = title.range(of: #"^\(\d+\+?\)\s*"#, options: .regularExpression) {
            title.removeSubrange(range)
        }
        for suffix in [" - YouTube Music", " - YouTube", " - Twitch", " | Netflix"] where title.hasSuffix(suffix) {
            title.removeLast(suffix.count)
        }
        return title
    }

    /// Only YouTube has a thumbnail that can be built from the address.
    private static func thumbnailURL(for url: String) -> URL? {
        guard let parts = URLComponents(string: url), parts.host?.hasSuffix("youtube.com") == true else { return nil }
        let id: String?
        if parts.path.hasPrefix("/shorts/") {
            id = parts.path.split(separator: "/").dropFirst().first.map(String.init)
        } else {
            id = parts.queryItems?.first { $0.name == "v" }?.value
        }
        return id.flatMap { URL(string: "https://i.ytimg.com/vi/\($0)/mqdefault.jpg") }
    }

    private func loadThumbnail(for url: String, key: String) {
        guard let thumbnail = Self.thumbnailURL(for: url) else { return }
        URLSession.shared.dataTask(with: thumbnail) { [weak self] data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                guard let self, self.artworkKey == key, self.model.track?.source == .browser else { return }
                self.model.artwork = image
            }
        }.resume()
    }

    private func run(_ source: String, browser: Browser) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        let number = (error?[NSAppleScript.errorNumber] as? Int) ?? 0
        if errors[browser.app] != number {
            // -1743 means the Automation permission for this browser was refused.
            errors[browser.app] = number
            DispatchQueue.main.async {
                Commands.notes["\(browser.app) tabs"] = number == 0 ? "ok" : "script error \(number)"
            }
        }
        return result
    }
}
