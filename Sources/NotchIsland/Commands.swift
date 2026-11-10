import AppKit
import SwiftUI

/// The `notch` command line. The same binary posts a message to the running
/// app and exits, so scripts can show their own activities on the island.
enum Commands {
    static let notification = NSNotification.Name("local.notchisland.command")
    static let names: Set<String> = ["show", "done", "fail", "clear", "run", "help", "debug",
                                     "bambu-login", "bambu-token", "bambu-logout"]
    /// Set by the app so a new Bambu sign-in takes effect at once.
    static var onBambuReload: (() -> Void)?
    static let debugFile = NSTemporaryDirectory() + "notchisland-state.txt"
    /// Notes the controllers leave for `notch debug` (last script results and errors).
    static var notes: [String: String] = [:]

    static let usage = """
    notch show <id> <başlık> [--progress 0-100] [--detail metin] [--icon sf.symbol] [--color renk]
    notch done <id> [metin]      etkinliği kapatır, yeşil onay gösterir (--silent 1: sessiz)
    notch fail <id> [metin]      etkinliği kapatır, kırmızı hata gösterir
    notch clear <id>             etkinliği sessizce kaldırır
    notch run <başlık> -- <komut...>   komutu çalıştırır; süresini ve sonucunu gösterir

    notch bambu-login            Bambu Lab hesabına giriş (3D baskı ilerlemesi için)
    notch bambu-token            girişi tarayıcıdan alınan oturum belirteciyle yapar
    notch bambu-logout           kayıtlı Bambu oturumunu siler

    Renkler: green red orange yellow blue cyan purple pink white
    """

    // MARK: Sending (command line side)

    /// Runs a command line invocation and returns the exit status.
    static func runCommandLine(_ arguments: [String]) -> Int32 {
        guard let action = arguments.first else { return 64 }
        var rest = Array(arguments.dropFirst())

        switch action {
        case "help":
            print(usage)
            return 0

        case "run":
            return runWrapped(rest)

        case "bambu-login", "bambu-token", "bambu-logout":
            return BambuLogin.run(action)

        case "debug":
            try? FileManager.default.removeItem(atPath: debugFile)
            post(["action": "debug", "id": "-"])
            Thread.sleep(forTimeInterval: 0.4)
            print((try? String(contentsOfFile: debugFile, encoding: .utf8)) ?? "Uygulama yanıt vermedi.")
            return 0

        case "show", "done", "fail", "clear":
            guard !rest.isEmpty else {
                FileHandle.standardError.write(Data((usage + "\n").utf8))
                return 64
            }
            var info = ["action": action, "id": rest.removeFirst()]
            var words: [String] = []
            var index = 0
            while index < rest.count {
                let word = rest[index]
                if word.hasPrefix("--"), index + 1 < rest.count {
                    info[String(word.dropFirst(2))] = rest[index + 1]
                    index += 2
                } else {
                    words.append(word)
                    index += 1
                }
            }
            if !words.isEmpty { info["title"] = words.joined(separator: " ") }
            post(info)
            return 0

        default:
            return 64
        }
    }

    private static func post(_ info: [String: String]) {
        DistributedNotificationCenter.default().postNotificationName(
            notification, object: nil, userInfo: info, deliverImmediately: true)
        // Give the notification a moment to leave before the process exits.
        Thread.sleep(forTimeInterval: 0.05)
    }

    private static func runWrapped(_ arguments: [String]) -> Int32 {
        var title: String
        var command: [String]
        if let split = arguments.firstIndex(of: "--") {
            title = arguments[..<split].joined(separator: " ")
            command = Array(arguments[(split + 1)...])
        } else {
            title = ""
            command = arguments
        }
        guard !command.isEmpty else {
            FileHandle.standardError.write(Data((usage + "\n").utf8))
            return 64
        }
        if title.isEmpty { title = (command[0] as NSString).lastPathComponent }

        let id = "run-\(getpid())"
        post(["action": "show", "id": id, "title": title, "icon": "terminal.fill"])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command

        // Ctrl-C reaches the child directly; stay alive to report how it ended.
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        terminate.setEventHandler { process.terminate() }
        terminate.resume()

        do {
            try process.run()
        } catch {
            post(["action": "fail", "id": id, "title": "Başlamadı"])
            FileHandle.standardError.write(Data("notch: \(error.localizedDescription)\n".utf8))
            return 127
        }
        process.waitUntilExit()

        let status = process.terminationStatus
        post(["action": status == 0 ? "done" : "fail", "id": id])
        return status
    }

    // MARK: Receiving (app side)

    static func handle(_ info: [AnyHashable: Any]?, model: IslandModel) {
        guard let info, let action = info["action"] as? String, let id = info["id"] as? String else { return }
        let text = (info["title"] as? String) ?? ""

        switch action {
        case "show":
            let existing = model.activities.first { $0.id == id }
            var progress = existing?.progress
            if let raw = info["progress"] as? String, let value = Double(raw.replacingOccurrences(of: "%", with: "")) {
                progress = min(max(value / 100, 0), 1)
            }
            var icon = existing?.icon ?? "bolt.horizontal.circle.fill"
            if let wanted = info["icon"] as? String,
               NSImage(systemSymbolName: wanted, accessibilityDescription: nil) != nil {
                icon = wanted
            }
            let tint = (info["color"] as? String).flatMap(color(named:)) ?? existing?.tint ?? .cyan
            model.upsert(CustomActivity(id: id,
                                        title: text.isEmpty ? (existing?.title ?? id) : text,
                                        detail: (info["detail"] as? String) ?? existing?.detail ?? "",
                                        progress: progress, icon: icon, tint: tint, started: Date()))

        case "done":
            model.removeActivity(id)
            if info["silent"] == nil { NSSound(named: "Glass")?.play() }
            model.show(Banner(icon: "checkmark.circle.fill", tint: .green, text: text.isEmpty ? "Bitti" : text), for: 5)

        case "fail":
            model.removeActivity(id)
            if info["silent"] == nil { NSSound(named: "Basso")?.play() }
            model.show(Banner(icon: "xmark.octagon.fill", tint: .red, text: text.isEmpty ? "Hata" : text), for: 8)

        case "clear":
            model.removeActivity(id)

        case "bambu-reload":
            onBambuReload?()

        case "debug":
            var lines = ["track: \(model.track.map { "\($0.source.rawValue) (\($0.artist)) playing=\($0.isPlaying) showWhenPaused=\($0.showWhenPaused)" } ?? "none")",
                         "call: \(model.call?.app ?? "-") unread: \(model.unread.map { "\($0.name)=\($0.count)" }.joined(separator: " "))",
                         "slots: \(model.slots.count) activities: \(model.activities.count) banner: \(model.banner != nil)",
                         "mic: \(model.micApp ?? "-") camera: \(model.cameraOn)"]
            lines += notes.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
            try? lines.joined(separator: "\n").write(toFile: debugFile, atomically: true, encoding: .utf8)

        default:
            break
        }
    }

    private static func color(named name: String) -> Color? {
        switch name.lowercased() {
        case "green": return .green
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "blue": return .blue
        case "cyan": return .cyan
        case "purple": return .purple
        case "pink": return .pink
        case "white": return .white
        default: return nil
        }
    }
}
