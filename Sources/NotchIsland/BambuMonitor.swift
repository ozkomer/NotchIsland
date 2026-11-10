import AppKit
import Security
import SwiftUI

/// The Bambu Lab account session, kept in the keychain.
enum BambuAccount {
    private static let query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: "local.notchisland.bambu",
        kSecAttrAccount: "token",
    ]

    static func save(_ token: String) -> Bool {
        delete()
        var item = query
        item[kSecValueData] = Data(token.utf8)
        item[kSecAttrLabel] = "NotchIsland Bambu oturumu"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func load() -> String? {
        var item = query
        item[kSecReturnData] = true
        item[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

/// Shows the progress of Bambu Lab 3D prints, read from Bambu's cloud with the
/// account the user signed in to (`notch bambu-login`). The printer itself is
/// never contacted. Only a request for the current status is ever published.
final class BambuMonitor {
    private static let key = "showBambu"
    private static let studioFolder = NSHomeDirectory() + "/Library/Application Support/BambuStudio"

    private let model: IslandModel
    private var client: MQTTClient?
    private var connecting = false
    /// A token the cloud turned down; not retried until a new one is saved.
    private var rejectedToken: String?
    private var names: [String: String] = [:]
    private var statuses: [String: [String: Any]] = [:]
    private var lastStates: [String: String] = [:]

    /// On unless the user turned it off; does nothing until signed in.
    var enabled: Bool { UserDefaults.standard.object(forKey: Self.key) as? Bool ?? true }

    init(model: IslandModel) {
        self.model = model
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.tick() }
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.key)
        if on {
            tick()
        } else {
            disconnect()
            Commands.notes["bambu"] = "off"
        }
    }

    /// Called after `notch bambu-login`, `bambu-token` or `bambu-logout`.
    func reload() {
        rejectedToken = nil
        disconnect()
        tick()
    }

    private func disconnect() {
        client?.stop()
        client = nil
        for serial in statuses.keys { model.removeActivity(Self.activityID(serial)) }
        statuses.removeAll()
        lastStates.removeAll()
    }

    // MARK: Connecting

    private func tick() {
        guard enabled, client == nil, !connecting else { return }
        guard let token = BambuAccount.load() else {
            Commands.notes["bambu"] = "not signed in (run: notch bambu-login)"
            return
        }
        guard token != rejectedToken else { return }
        connecting = true
        resolve(token) { [weak self] username, devices in
            guard let self else { return }
            self.connecting = false
            guard let username else {
                Commands.notes["bambu"] = "could not find the account id"
                return
            }
            guard !devices.isEmpty else {
                Commands.notes["bambu"] = "no printers on this account"
                return
            }
            self.names = devices
            self.connect(username: username, token: token)
        }
    }

    /// Finds the MQTT user name and the account's printers (serial: name).
    private func resolve(_ token: String, done: @escaping (String?, [String: String]) -> Void) {
        var username = Self.usernameInToken(token)
        var devices: [String: String] = [:]
        let group = DispatchGroup()

        if username == nil {
            group.enter()
            Self.get("https://api.bambulab.com/v1/design-user-service/my/preference", token: token) { json in
                if let uid = json?["uid"] { username = "u_\(uid)" }
                group.leave()
            }
        }
        group.enter()
        Self.get("https://api.bambulab.com/v1/iot-service/api/user/bind", token: token) { json in
            for device in (json?["devices"] as? [[String: Any]]) ?? [] {
                if let serial = device["dev_id"] as? String { devices[serial] = (device["name"] as? String) ?? "" }
            }
            group.leave()
        }
        group.notify(queue: .main) {
            // Bambu Studio's own files answer both questions when the web API does not.
            if username == nil, let uid = Self.studioUserID() { username = "u_\(uid)" }
            if devices.isEmpty { for serial in Self.studioSerials() { devices[serial] = "" } }
            done(username, devices)
        }
    }

    /// Newer tokens are opaque; older ones are JWTs that carry the user name.
    private static func usernameInToken(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["username"] as? String
    }

    private static func get(_ url: String, token: String, done: @escaping ([String: Any]?) -> Void) {
        var request = URLRequest(url: URL(string: url)!)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data else { return done(nil) }
            done(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        }.resume()
    }

    /// Bambu Studio keeps one folder per signed-in account, named after its numeric id.
    private static func studioUserID() -> String? {
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: studioFolder + "/user")) ?? []
        return folders.first { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    private static func studioSettings() -> [String: Any] {
        guard var text = try? String(contentsOfFile: studioFolder + "/BambuStudio.conf", encoding: .utf8),
              let end = text.range(of: "}", options: .backwards) else { return [:] }
        // The file ends with a checksum line after the JSON.
        text = String(text[..<end.upperBound])
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
    }

    /// Serial numbers of the printers Bambu Studio knows (only the names of the entries are read).
    private static func studioSerials() -> [String] {
        let settings = studioSettings()
        var serials = Set<String>()
        for name in ["user_access_code", "access_code"] {
            serials.formUnion(((settings[name] as? [String: Any]) ?? [:]).keys)
        }
        return serials.sorted()
    }

    private static var cloudHost: String {
        let region = (studioSettings()["app"] as? [String: Any])?["region"] as? String
        return region == "China" ? "cn.mqtt.bambulab.com" : "us.mqtt.bambulab.com"
    }

    private func connect(username: String, token: String) {
        let client = MQTTClient(host: Self.cloudHost, port: 8883, username: username, password: token)
        self.client = client
        let serials = names.keys.sorted()

        client.onConnected = {
            DispatchQueue.main.async {
                Commands.notes["bambu"] = "connected, watching \(serials.count) printer(s)"
            }
            for serial in serials {
                client.subscribe("device/\(serial)/report")
                // Ask once for the full status; after that the printer sends changes.
                let request = #"{"pushing":{"sequence_id":"0","command":"pushall"}}"#
                client.publish("device/\(serial)/request", Data(request.utf8))
            }
        }
        client.onMessage = { [weak self] topic, payload in
            let parts = topic.split(separator: "/")
            guard parts.count >= 3,
                  let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let print = json["print"] as? [String: Any] else { return }
            let serial = String(parts[1])
            DispatchQueue.main.async {
                guard let self else { return }
                self.statuses[serial, default: [:]].merge(print) { _, new in new }
                self.update(serial)
            }
        }
        client.onClosed = { [weak self, weak client] reason, refused in
            DispatchQueue.main.async {
                guard let self, self.client === client else { return }
                self.disconnect()
                if refused == 4 || refused == 5 {
                    // The session ended or was replaced; a new sign-in is needed.
                    self.rejectedToken = token
                    Commands.notes["bambu"] = "sign-in no longer valid (run: notch bambu-login)"
                    self.model.show(Banner(icon: "cube.fill", tint: .orange, text: "Bambu girişi gerekli"), for: 6)
                } else {
                    Commands.notes["bambu"] = "disconnected (\(reason)); will retry"
                }
            }
        }
        client.start()
    }

    // MARK: Showing the print

    private static func activityID(_ serial: String) -> String { "bambu-\(serial)" }

    private func update(_ serial: String) {
        guard let status = statuses[serial] else { return }
        let id = Self.activityID(serial)
        let state = (status["gcode_state"] as? String) ?? ""
        let previous = lastStates[serial] ?? ""
        lastStates[serial] = state
        let job = (status["subtask_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let printer = names[serial].flatMap { $0.isEmpty ? nil : $0 }
        let title = job ?? printer ?? "3D Baskı"
        Commands.notes["bambu state"] = "\(state.isEmpty ? "unknown" : state) \((status["mc_percent"] as? Int).map { "\($0)%" } ?? "")"

        switch state {
        case "RUNNING", "PAUSE", "PREPARE", "SLICING":
            let percent = (status["mc_percent"] as? Int) ?? 0
            var details: [String] = []
            if state == "PAUSE" {
                details.append("duraklatıldı")
            } else if state != "RUNNING" {
                details.append("hazırlanıyor")
            }
            if state == "RUNNING" || state == "PAUSE" {
                if let minutes = status["mc_remaining_time"] as? Int, minutes > 0 {
                    details.append("kalan " + Self.duration(minutes))
                }
                if let layer = status["layer_num"] as? Int, let total = status["total_layer_num"] as? Int, total > 0 {
                    details.append("katman \(layer)/\(total)")
                }
            }
            model.upsert(CustomActivity(id: id, title: title, detail: details.joined(separator: " · "),
                                        progress: Double(percent) / 100, icon: "cube.fill",
                                        tint: state == "PAUSE" ? .yellow : .green, started: Date()))
        case "FINISH":
            model.removeActivity(id)
            // Only a print that ended while we were watching is news.
            if previous == "RUNNING" {
                NSSound(named: "Glass")?.play()
                model.show(Banner(icon: "cube.fill", tint: .green, text: "Baskı bitti"), for: 8)
            }
        case "FAILED":
            model.removeActivity(id)
            if previous == "RUNNING" || previous == "PAUSE" {
                NSSound(named: "Basso")?.play()
                model.show(Banner(icon: "exclamationmark.triangle.fill", tint: .red, text: "Baskı durdu"), for: 8)
            }
        default:
            model.removeActivity(id)
        }
    }

    private static func duration(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) sa \(minutes % 60) dk" : "\(minutes) dk"
    }
}
