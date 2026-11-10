import CoreAudio
import Foundation

/// Asks CoreAudio which processes are sending sound to an output device.
/// Needs no permission, so it works as a play/pause signal when the player
/// itself cannot be asked.
enum AudioActivity {
    static func isPlaying(bundleIDs: Set<String>) -> Bool {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return false }

        for process in processes {
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            address.mSelector = kAudioProcessPropertyIsRunningOutput
            guard AudioObjectGetPropertyData(process, &address, 0, nil, &runningSize, &running) == noErr,
                  running != 0 else { continue }

            var bundle: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            address.mSelector = kAudioProcessPropertyBundleID
            guard AudioObjectGetPropertyData(process, &address, 0, nil, &bundleSize, &bundle) == noErr,
                  let name = bundle?.takeRetainedValue() as String? else { continue }
            if bundleIDs.contains(name) { return true }
        }
        return false
    }

    /// Safari plays page audio from its WebKit helper process.
    static var safariIsPlaying: Bool {
        isPlaying(bundleIDs: ["com.apple.WebKit.GPU", "com.apple.Safari", "com.apple.WebKit.WebContent"])
    }
}
