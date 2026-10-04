import Darwin
import Foundation
import IOKit

/// 温度、GPU、功耗与内存压力。温度走 IOHIDEventSystem 的私有符号，运行时
/// dlsym 解析：符号缺失时只返回 nil，界面退回系统热状态，不会影响启动。
enum SensorMetrics {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatchingFn = @convention(c) (CFTypeRef, CFDictionary) -> Int32
    private typealias CopyServicesFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias GetFloatFn = @convention(c) (CFTypeRef, Int32) -> Double

    private struct TemperatureReader {
        let copyEvent: CopyEventFn
        let getFloat: GetFloatFn
        let client: CFTypeRef
        let dieSensors: [CFTypeRef]
    }

    private static let temperatureReader: TemperatureReader? = {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let createSymbol = dlsym(handle, "IOHIDEventSystemClientCreate"),
              let matchingSymbol = dlsym(handle, "IOHIDEventSystemClientSetMatching"),
              let servicesSymbol = dlsym(handle, "IOHIDEventSystemClientCopyServices"),
              let propertySymbol = dlsym(handle, "IOHIDServiceClientCopyProperty"),
              let eventSymbol = dlsym(handle, "IOHIDServiceClientCopyEvent"),
              let floatSymbol = dlsym(handle, "IOHIDEventGetFloatValue") else { return nil }
        let create = unsafeBitCast(createSymbol, to: CreateFn.self)
        let setMatching = unsafeBitCast(matchingSymbol, to: SetMatchingFn.self)
        let copyServices = unsafeBitCast(servicesSymbol, to: CopyServicesFn.self)
        let copyProperty = unsafeBitCast(propertySymbol, to: CopyPropertyFn.self)
        guard let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        _ = setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        guard let services = copyServices(client)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        let dies = services.filter { service in
            guard let name = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String
            else { return false }
            return name.hasPrefix("PMU tdie") || name.hasPrefix("PMU2 tdie")
                || name.hasPrefix("pACC MTR Temp") || name.hasPrefix("eACC MTR Temp")
        }
        guard !dies.isEmpty else { return nil }
        return TemperatureReader(copyEvent: unsafeBitCast(eventSymbol, to: CopyEventFn.self),
                                 getFloat: unsafeBitCast(floatSymbol, to: GetFloatFn.self),
                                 client: client, dieSensors: dies)
    }()

    /// CPU 芯片温度（°C，各核心传感器均值）；读不到时为 nil。
    static func cpuTemperature() -> Double? {
        guard let reader = temperatureReader else { return nil }
        let values = reader.dieSensors.compactMap { sensor -> Double? in
            guard let event = reader.copyEvent(sensor, 15, 0, 0)?.takeRetainedValue() else { return nil }
            let value = reader.getFloat(event, 15 << 16)
            return value > 0 && value < 130 ? value : nil
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// 0 正常 / 1 偏高 / 2 严重 / 3 危急（ProcessInfo.ThermalState）。
    static func thermalLevel() -> Int {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        @unknown default: return 0
        }
    }

    static func gpuUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString,
                                                           kCFAllocatorDefault, 0)?.takeRetainedValue()
                as? [String: Any],
               let value = (stats["Device Utilization %"] as? NSNumber)?.doubleValue {
                best = max(best ?? 0, min(100, max(0, value)))
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return best
    }

    /// 整机功耗（瓦）。来自电池电量计的遥测；台式机没有该服务时为 nil。
    static func systemPowerWatts() -> Double? {
        let battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard battery != 0 else { return nil }
        defer { IOObjectRelease(battery) }
        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(battery, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        if let telemetry = property("PowerTelemetryData") as? [String: Any],
           let load = (telemetry["SystemLoad"] as? NSNumber)?.doubleValue, load > 0 {
            return load / 1000
        }
        if let voltage = (property("Voltage") as? NSNumber)?.doubleValue,
           let amperage = (property("InstantAmperage") as? NSNumber)?.int64Value, amperage < 0 {
            return voltage * Double(-amperage) / 1_000_000
        }
        return nil
    }

    /// 内核内存压力：normal / warning / critical；读不到时为 nil。
    static func memoryPressure() -> String? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        switch level {
        case 4: return "critical"
        case 2: return "warning"
        case 1: return "normal"
        default: return nil
        }
    }
}

/// 蓝牙外设电量：妙控外设走 IOKit，AirPods 等音频设备走 system_profiler。
/// 后者较慢，后台节流刷新，采样只读缓存。
final class BluetoothBatteryMonitor: @unchecked Sendable {
    static let shared = BluetoothBatteryMonitor()
    private let lock = NSLock()
    private var cached: [BluetoothBattery] = []
    private var lastRefresh: Date = .distantPast
    private var refreshing = false

    func latest() -> [BluetoothBattery] {
        lock.lock()
        let value = cached
        let stale = !refreshing && Date().timeIntervalSince(lastRefresh) >= 60
        if stale { refreshing = true }
        lock.unlock()
        if stale {
            DispatchQueue.global(qos: .utility).async { [self] in
                let devices = Self.hidBatteries() + Self.profilerBatteries()
                lock.lock()
                var seen = Set<String>()
                cached = devices.filter { seen.insert($0.name).inserted }.sorted { $0.percent < $1.percent }
                lastRefresh = Date()
                refreshing = false
                lock.unlock()
            }
        }
        return value
    }

    private static func hidBatteries() -> [BluetoothBattery] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
            IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [BluetoothBattery] = []
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if let percent = (IORegistryEntryCreateCFProperty(entry, "BatteryPercent" as CFString,
                                                              kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue,
               let name = IORegistryEntryCreateCFProperty(entry, "Product" as CFString,
                                                          kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                result.append(BluetoothBattery(name: name, percent: min(100, max(0, percent))))
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return result
    }

    private static func profilerBatteries() -> [BluetoothBattery] {
        guard let output = SystemMetrics.commandOutput("/usr/sbin/system_profiler",
                                                       arguments: ["SPBluetoothDataType", "-json"]),
              let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        return parseProfiler(sections)
    }

    static func parseProfiler(_ sections: [[String: Any]]) -> [BluetoothBattery] {
        var result: [BluetoothBattery] = []
        for section in sections {
            for devices in (section["device_connected"] as? [[String: Any]]) ?? [] {
                for (name, value) in devices {
                    guard let info = value as? [String: Any] else { continue }
                    let levels = ["device_batteryLevelMain", "device_batteryLevelLeft",
                                  "device_batteryLevelRight", "device_batteryLevel"].compactMap { key in
                        (info[key] as? String).flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) }
                    }
                    if let lowest = levels.min() {
                        result.append(BluetoothBattery(name: name, percent: min(100, max(0, lowest))))
                    }
                }
            }
        }
        return result
    }
}
