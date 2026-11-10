import AppKit
import Carbon
import CoreAudio
import CoreMediaIO
import Network
import SwiftUI

// MARK: - Microphone and camera in use

/// Reports which app holds the microphone and whether any camera is on.
/// Both come from public CoreAudio / CoreMediaIO properties; no permission needed.
final class PrivacyMonitor {
    private let model: IslandModel

    /// System services that keep an input stream open without the user recording anything.
    private static let ignored: Set<String> = [
        "com.apple.MediaRemoteUIService", "com.apple.CoreSpeech", "com.apple.corespeechd",
        "com.apple.assistantd", "com.apple.Siri", "com.apple.controlcenter",
        "com.apple.accessibility.heard", "com.apple.universalaccessd", "local.notchisland",
    ]

    init(model: IslandModel) {
        self.model = model
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(timer, forMode: .common)
        check()
    }

    private func check() {
        let mic = microphoneUser()
        if model.micApp != mic { model.micApp = mic }
        let camera = cameraIsOn()
        if model.cameraOn != camera { model.cameraOn = camera }
    }

    private func microphoneUser() -> String? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return nil }

        for process in processes {
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            address.mSelector = kAudioProcessPropertyIsRunningInput
            guard AudioObjectGetPropertyData(process, &address, 0, nil, &runningSize, &running) == noErr,
                  running != 0 else { continue }

            var bundle: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            address.mSelector = kAudioProcessPropertyBundleID
            _ = AudioObjectGetPropertyData(process, &address, 0, nil, &bundleSize, &bundle)
            let bundleID = (bundle?.takeRetainedValue() as String?) ?? ""
            if Self.ignored.contains(bundleID) { continue }

            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            address.mSelector = kAudioProcessPropertyPID
            _ = AudioObjectGetPropertyData(process, &address, 0, nil, &pidSize, &pid)

            if let name = NSRunningApplication(processIdentifier: pid)?.localizedName { return name }
            if bundleID.hasPrefix("com.apple.WebKit") { return "Safari" }
            return bundleID.components(separatedBy: ".").last.flatMap { $0.isEmpty ? nil : $0 } ?? "Bilinmeyen"
        }
        return nil
    }

    private func cameraIsOn() -> Bool {
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        var cameras = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &cameras) == noErr else { return false }

        address.mSelector = CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)
        for camera in cameras {
            var running: UInt32 = 0
            if CMIOObjectGetPropertyData(camera, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &running) == noErr,
               running != 0 {
                return true
            }
        }
        return false
    }
}

// MARK: - Volume

/// Shows a level bar when the output volume or mute changes.
final class VolumeMonitor {
    private let model: IslandModel
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var last: (volume: Float32, muted: Bool)?

    private static var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    /// 'vmvc', the device's overall output volume.
    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: 0x766d_7663, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    private static var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)

    init(model: IslandModel) {
        self.model = model
        bind()
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultDeviceAddress,
                                            DispatchQueue.main) { [weak self] _, _ in self?.bind() }
    }

    /// Follows whichever device is the current output.
    private func bind() {
        if let deviceListener, device != kAudioObjectUnknown {
            AudioObjectRemovePropertyListenerBlock(device, &Self.volumeAddress, DispatchQueue.main, deviceListener)
            AudioObjectRemovePropertyListenerBlock(device, &Self.muteAddress, DispatchQueue.main, deviceListener)
        }
        var current = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &Self.defaultDeviceAddress,
                                         0, nil, &size, &current) == noErr else { return }
        device = current
        last = read()

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.changed() }
        deviceListener = listener
        AudioObjectAddPropertyListenerBlock(device, &Self.volumeAddress, DispatchQueue.main, listener)
        AudioObjectAddPropertyListenerBlock(device, &Self.muteAddress, DispatchQueue.main, listener)
    }

    private func read() -> (volume: Float32, muted: Bool)? {
        guard AudioObjectHasProperty(device, &Self.volumeAddress) else { return nil }
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &Self.volumeAddress, 0, nil, &size, &volume) == noErr else { return nil }
        var muted: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(device, &Self.muteAddress, 0, nil, &size, &muted)
        return (volume, muted != 0)
    }

    private func changed() {
        guard let now = read() else { return }
        if let last, abs(last.volume - now.volume) < 0.005, last.muted == now.muted { return }
        last = now
        let silent = now.muted || now.volume < 0.005
        model.show(Banner(icon: silent ? "speaker.slash.fill" : "speaker.wave.2.fill", tint: .white, text: "",
                          level: silent ? 0 : Double(now.volume)), for: 1.5)
    }
}

// MARK: - Keyboard language

/// Shows the new language code when the keyboard layout is switched.
final class KeyboardMonitor {
    private let model: IslandModel
    private var last: String?

    init(model: IslandModel) {
        self.model = model
        last = current()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(changed),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil)
    }

    private func current() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return nil }
        let languages = Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String]
        return languages?.first?.uppercased()
    }

    @objc private func changed() {
        guard let now = current(), now != last else { return }
        last = now
        model.show(Banner(icon: "keyboard", tint: .white, text: now), for: 1.5)
    }
}

// MARK: - Network

/// Shows a short notice when the Mac goes offline or comes back.
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private var wasOnline: Bool?

    init(model: IslandModel) {
        monitor.pathUpdateHandler = { [weak self, weak model] path in
            guard let self, let model else { return }
            let online = path.status == .satisfied
            defer { self.wasOnline = online }
            guard let before = self.wasOnline, before != online else { return }
            if online {
                model.show(Banner(icon: "wifi", tint: .green, text: "Bağlı"), for: 3)
            } else {
                model.show(Banner(icon: "wifi.slash", tint: .red, text: "Koptu"), for: 4)
            }
        }
        monitor.start(queue: .main)
    }
}
