import Foundation

/// Reads the Mac's temperature sensors. macOS has no documented call for this;
/// like other system monitors, this uses the HID sensor functions in IOKit,
/// looked up by name so a system without them simply reports nothing.
final class TemperatureSensor {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
    private typealias MatchFn = @convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Int32
    private typealias ServicesFn = @convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFArray>?
    private typealias EventFn = @convention(c) (UnsafeRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    private typealias PropertyFn = @convention(c) (UnsafeRawPointer, CFString) -> Unmanaged<CFTypeRef>?
    private typealias FloatFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Double

    private static let temperatureEvent: Int64 = 15
    private static let temperatureField: Int32 = 15 << 16

    private var copyEvent: EventFn?
    private var floatValue: FloatFn?
    /// The processor's own sensors, or every board sensor when none are named that way.
    private var sensors: [AnyObject] = []

    init() {
        guard let kit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return }
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            dlsym(kit, name).map { unsafeBitCast($0, to: type) }
        }
        guard let create = symbol("IOHIDEventSystemClientCreate", CreateFn.self),
              let match = symbol("IOHIDEventSystemClientSetMatching", MatchFn.self),
              let services = symbol("IOHIDEventSystemClientCopyServices", ServicesFn.self),
              let property = symbol("IOHIDServiceClientCopyProperty", PropertyFn.self),
              let copyEvent = symbol("IOHIDServiceClientCopyEvent", EventFn.self),
              let floatValue = symbol("IOHIDEventGetFloatValue", FloatFn.self),
              let client = create(kCFAllocatorDefault) else { return }
        self.copyEvent = copyEvent
        self.floatValue = floatValue

        // Apple vendor page, temperature sensor usage.
        _ = match(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        let all = (services(client)?.takeRetainedValue() as? [AnyObject]) ?? []
        var named: [(name: String, service: AnyObject)] = []
        for service in all {
            let raw = Unmanaged.passUnretained(service).toOpaque()
            let name = (property(raw, "Product" as CFString)?.takeRetainedValue() as? String) ?? ""
            named.append((name, service))
        }
        let die = named.filter { $0.name.contains("tdie") }
        let board = named.filter { !$0.name.lowercased().contains("battery") && !$0.name.contains("NAND") }
        sensors = (die.isEmpty ? board : die).map(\.service)
    }

    /// The hottest processor sensor, in degrees Celsius.
    func read() -> Double? {
        guard let copyEvent, let floatValue else { return nil }
        var hottest: Double?
        for service in sensors {
            guard let event = copyEvent(Unmanaged.passUnretained(service).toOpaque(), Self.temperatureEvent, 0, 0) else { continue }
            let value = floatValue(event, Self.temperatureField)
            Unmanaged<AnyObject>.fromOpaque(event).release()
            if value > 0, value < 130 { hottest = max(hottest ?? 0, value) }
        }
        return hottest
    }
}
