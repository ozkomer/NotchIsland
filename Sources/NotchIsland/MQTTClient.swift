import Foundation
import Network

/// A minimal MQTT 3.1.1 client over TLS: connect, subscribe, publish and
/// receive at QoS 0. Just enough to read a status feed.
final class MQTTClient {
    var onConnected: (() -> Void)?
    var onMessage: ((String, Data) -> Void)?
    /// Called once when the connection ends; `refused` is the broker's return
    /// code when it turned the login down (4 and 5 mean bad credentials).
    var onClosed: ((_ reason: String, _ refused: Int?) -> Void)?

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "notchisland.mqtt")
    private let clientID = "notchisland-\(UUID().uuidString.prefix(8))"
    private let username: String
    private let password: String
    private var buffer = Data()
    private var pingTimer: DispatchSourceTimer?
    private var closed = false
    private var packetID: UInt16 = 1

    init(host: String, port: UInt16, username: String, password: String) {
        self.username = username
        self.password = password
        // Default TLS settings: the server's certificate is checked by the system.
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tls)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendConnect()
                self.receive()
            case .failed(let error):
                self.close("failed: \(error.localizedDescription)")
            case .waiting(let error):
                self.close("unreachable: \(error.localizedDescription)")
            case .cancelled:
                self.close("cancelled")
            default:
                break
            }
        }
        connection.start(queue: queue)
        // Give up when the server accepts the connection but never answers.
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.pingTimer == nil else { return }
            self.close("timed out")
        }
    }

    func stop() {
        queue.async { self.close("stopped") }
    }

    func subscribe(_ topic: String) {
        queue.async {
            var body = Data([UInt8(self.packetID >> 8), UInt8(self.packetID & 0xFF)])
            self.packetID &+= 1
            body.append(Self.string(topic))
            body.append(0)
            self.send(type: 0x82, body: body)
        }
    }

    func publish(_ topic: String, _ payload: Data) {
        queue.async {
            var body = Self.string(topic)
            body.append(payload)
            self.send(type: 0x30, body: body)
        }
    }

    // MARK: Packets

    private func sendConnect() {
        var body = Self.string("MQTT")
        body.append(contentsOf: [0x04, 0xC2, 0x00, 60])  // level 4; user name, password, clean session; keep alive 60 s
        body.append(Self.string(clientID))
        body.append(Self.string(username))
        body.append(Self.string(password))
        send(type: 0x10, body: body)
    }

    private func send(type: UInt8, body: Data) {
        guard !closed else { return }
        var packet = Data([type])
        var length = body.count
        repeat {
            var byte = UInt8(length % 128)
            length /= 128
            if length > 0 { byte |= 0x80 }
            packet.append(byte)
        } while length > 0
        packet.append(body)
        connection.send(content: packet, completion: .contentProcessed { _ in })
    }

    private static func string(_ text: String) -> Data {
        let bytes = Array(text.utf8)
        return Data([UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)] + bytes)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drain()
            }
            if isComplete || error != nil {
                self.close("connection ended")
                return
            }
            self.receive()
        }
    }

    /// Splits the stream into packets and handles each one.
    private func drain() {
        while !closed {
            let bytes = [UInt8](buffer.prefix(5))
            guard bytes.count >= 2 else { return }
            var length = 0
            var shift = 0
            var index = 1
            var complete = false
            while index < bytes.count {
                length |= Int(bytes[index] & 0x7F) << shift
                shift += 7
                let more = bytes[index] & 0x80 != 0
                index += 1
                if !more { complete = true; break }
            }
            guard complete else {
                if bytes.count == 5 { close("bad packet") }
                return
            }
            guard buffer.count >= index + length else { return }
            let body = [UInt8](buffer.subdata(in: buffer.startIndex + index ..< buffer.startIndex + index + length))
            buffer.removeFirst(index + length)
            handle(type: bytes[0], body: body)
        }
    }

    private func handle(type: UInt8, body: [UInt8]) {
        switch type & 0xF0 {
        case 0x20:  // CONNACK
            guard body.count >= 2, body[1] == 0 else {
                let code = body.count >= 2 ? Int(body[1]) : -1
                close("refused (code \(code))", refused: code)
                return
            }
            startPing()
            onConnected?()
        case 0x30:  // PUBLISH
            guard body.count >= 2 else { return }
            let topicLength = Int(body[0]) << 8 | Int(body[1])
            var offset = 2 + topicLength
            guard body.count >= offset else { return }
            let topic = String(decoding: body[2 ..< offset], as: UTF8.self)
            if type & 0x06 != 0 { offset += 2 }  // packet id, present above QoS 0
            guard body.count >= offset else { return }
            onMessage?(topic, Data(body[offset...]))
        default:
            break  // SUBACK, PINGRESP
        }
    }

    private func startPing() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in self?.send(type: 0xC0, body: Data()) }
        timer.resume()
        pingTimer = timer
    }

    private func close(_ reason: String, refused: Int? = nil) {
        guard !closed else { return }
        closed = true
        pingTimer?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClosed?(reason, refused)
    }
}
