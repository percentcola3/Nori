import AppKit
import Combine
import CoreGraphics
import Darwin
import Foundation

/// macOS 隐私权限的统一状态入口。
///
/// Full Disk Access 没有公开的通用查询 API。使用用户和系统 TCC 数据库作为只读探针：
/// 成功可以确认已授权，失败只表示当前不能确认授权。不要用其他 App 的
/// Containers 做探针，否则检测权限这个动作本身就会触发系统授权弹窗。
///
/// 屏幕录制使用 Core Graphics 的公开预检 API，但它有三个让用户觉得
/// "授权了也没用"的特性，这里逐一兜住：
/// 1. `CGPreflightScreenCaptureAccess` 的结果在进程内缓存，授权后必须重启
///    才会变成 true —— 用一个子进程（`Nori --preflight-screen-capture`）
///    做实时复检，区分"真没授权"和"已授权、等重启"。
/// 2. `CGRequestScreenCaptureAccess` 对同一签名身份只弹一次窗，之后静默
///    返回 false —— 记住"已经为当前签名请求过"，第二次直接给出修复路径。
/// 3. 授权绑定代码签名的指定要求，ad-hoc 构建每次都换身份 —— 读取签名
///    类型给出诊断，并提供 `tccutil reset` 一键清掉过期记录后重新授权。
@MainActor
final class PermissionCenter: ObservableObject {
    static let shared = PermissionCenter()

    enum SettingsDestination {
        case fullDisk
        case screenRecording

        fileprivate var legacyAnchor: String {
            switch self {
            case .fullDisk: "Privacy_AllFiles"
            case .screenRecording: "Privacy_ScreenCapture"
            }
        }

        /// `tccutil reset` 使用的服务名。
        fileprivate var tccService: String {
            switch self {
            case .fullDisk: "SystemPolicyAllFiles"
            case .screenRecording: "ScreenCapture"
            }
        }
    }

    /// 子进程复检的命令行参数；`main.swift` 在创建 NSApplication 之前处理，
    /// 输出一行 `screen=<0|1> disk=<0|1>`。
    nonisolated static let preflightArgument = "--preflight-screen-capture"

    /// 子进程视角的两项授权；nil 表示该项无法判断。
    struct LiveProbe: Equatable {
        var screenRecording: Bool?
        var fullDiskAccess: Bool?

        /// 解析 helper 输出；兼容旧版只输出 `0`/`1`（屏幕录制）的格式。
        nonisolated static func parse(_ text: String) -> LiveProbe? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch trimmed {
            case "1": return LiveProbe(screenRecording: true, fullDiskAccess: nil)
            case "0": return LiveProbe(screenRecording: false, fullDiskAccess: nil)
            default: break
            }
            var probe = LiveProbe()
            var recognized = false
            for token in trimmed.split(separator: " ") {
                let pair = token.split(separator: "=", maxSplits: 1)
                guard pair.count == 2 else { continue }
                let value: Bool?
                switch pair[1] {
                case "1": value = true
                case "0": value = false
                default: value = nil
                }
                switch pair[0] {
                case "screen": probe.screenRecording = value; recognized = true
                case "disk": probe.fullDiskAccess = value; recognized = true
                default: continue
                }
            }
            return recognized ? probe : nil
        }
    }

    /// helper 模式的输出：主进程与子进程共用同一探针实现。
    nonisolated static func preflightReport() -> String {
        let screen = CGPreflightScreenCaptureAccess() ? "1" : "0"
        let disk = canOpenProtectedScanLocation() ? "1" : "0"
        return "screen=\(screen) disk=\(disk)"
    }

    @Published private(set) var fullDiskAccessGranted = false
    /// 系统视角的完全磁盘访问（子进程实时复检）。完全磁盘访问对"正在运行的
    /// 进程"同样按进程缓存决定，系统设置里刚打开开关时，只有新进程能看到。
    @Published private(set) var fullDiskLiveGranted: Bool?
    /// 系统已授予完全磁盘访问，但当前进程仍被拒绝，需要重启应用。
    @Published private(set) var fullDiskNeedsRelaunch = false
    /// 当前进程视角的屏幕录制状态（进程内缓存，决定截图快捷键是否可用）。
    @Published private(set) var screenRecordingGranted = false
    /// 系统视角的屏幕录制状态（子进程实时复检）。nil 表示尚未复检或复检失败。
    @Published private(set) var screenRecordingLiveGranted: Bool?
    /// 系统已授权但当前进程仍缓存着旧结果，需要重启应用。
    @Published private(set) var screenRecordingNeedsRelaunch = false
    /// 已为当前签名请求过一次，系统不会再弹窗；若设置里开关是开的，说明记录已过期。
    @Published private(set) var screenRecordingDecisionStale = false
    @Published private(set) var liveCheckInFlight = false
    @Published private(set) var repairInFlight = false
    @Published private(set) var diskAuthorizationErrorKey: String?
    /// 最近一次 `tccutil reset` 的结果提示 key（成功 / 失败）。
    @Published private(set) var repairMessageKey: String?

    let signing: SigningIdentitySnapshot

    private let defaults: UserDefaults
    private let requestedRequirementKey = "permissions.screen.requestedRequirement"
    private var liveCheckTask: Task<Void, Never>?
    private var lastLiveCheck: Date?

    private init() {
        signing = SigningIdentityInspector.current()
        defaults = .standard
        refresh()
    }

    var hasConfiguredScanAccess: Bool { fullDiskAccessGranted }

    /// 签名身份不稳定时，授权会在每次重新构建后失效。
    var signingWarningNeeded: Bool { !signing.kind.isStable }

    /// 是否已经为"当前这个签名身份"请求过屏幕录制授权。
    var hasRequestedScreenRecordingForCurrentSignature: Bool {
        guard let requirement = signing.requirement else { return false }
        return defaults.string(forKey: requestedRequirementKey) == requirement
    }

    /// 只读刷新权限状态，不访问 Desktop、Documents 等会触发 TCC 提示的目录。
    @discardableResult
    func refresh() -> Bool {
        fullDiskAccessGranted = Self.canOpenProtectedScanLocation()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        if fullDiskAccessGranted {
            diskAuthorizationErrorKey = nil
            fullDiskNeedsRelaunch = false
        }
        if screenRecordingGranted {
            screenRecordingNeedsRelaunch = false
            screenRecordingDecisionStale = false
        }
        if !fullDiskAccessGranted || !screenRecordingGranted {
            // 进程内说没有，不代表系统没有：异步问一次新进程。
            scheduleLiveCheck()
        }
        return fullDiskAccessGranted
    }

    /// 任一权限"系统已授予、本进程未生效"，重启即可解决。
    var relaunchUnlocksPermissions: Bool { fullDiskNeedsRelaunch || screenRecordingNeedsRelaunch }

    func reportDiskAccessNotDetected() {
        diskAuthorizationErrorKey = "permissions.disk.notDetected"
    }

    func clearDiskAuthorizationError() {
        diskAuthorizationErrorKey = nil
    }

    func clearRepairMessage() {
        repairMessageKey = nil
    }

    @discardableResult
    func requestScreenRecordingAccess() -> Bool {
        let alreadyRequested = hasRequestedScreenRecordingForCurrentSignature
        let granted = CGRequestScreenCaptureAccess()
        if let requirement = signing.requirement {
            defaults.set(requirement, forKey: requestedRequirementKey)
        }
        refresh()
        if granted || screenRecordingGranted { return true }
        // 同一签名第二次请求不会再弹窗。此时要么用户还没在设置里打开开关，
        // 要么开关是开的但记录绑定的是旧签名（过期）。两种情况的出路都在
        // 设置面板和"重置并重新授权"，由视图层呈现。
        screenRecordingDecisionStale = alreadyRequested
        return false
    }

    // MARK: - 实时复检

    /// 启动一次子进程复检；已有复检进行中或 2 秒内刚复检过时忽略
    /// （`refresh()` 在每次受保护操作前都会调用，不能每次都起子进程）。
    func scheduleLiveCheck(force: Bool = false) {
        guard liveCheckTask == nil else { return }
        if !force, let last = lastLiveCheck, Date().timeIntervalSince(last) < 2 { return }
        liveCheckTask = Task { [weak self] in
            await self?.refreshLive()
            self?.liveCheckTask = nil
        }
    }

    /// 用一个全新的进程评估两项授权，绕开当前进程的缓存。
    func refreshLive() async {
        guard !liveCheckInFlight else { return }
        liveCheckInFlight = true
        lastLiveCheck = Date()
        defer { liveCheckInFlight = false }
        let probe = await Self.probeInChildProcess()
        let screenInProcess = CGPreflightScreenCaptureAccess()
        let diskInProcess = Self.canOpenProtectedScanLocation()
        screenRecordingGranted = screenInProcess
        fullDiskAccessGranted = diskInProcess
        if diskInProcess { diskAuthorizationErrorKey = nil }
        screenRecordingLiveGranted = probe?.screenRecording
        fullDiskLiveGranted = probe?.fullDiskAccess
        screenRecordingNeedsRelaunch = (probe?.screenRecording == true && !screenInProcess)
        fullDiskNeedsRelaunch = (probe?.fullDiskAccess == true && !diskInProcess)
        if probe?.screenRecording == true || screenInProcess { screenRecordingDecisionStale = false }
    }

    /// 子进程环境标记：复检进程自己绝不能再派生复检进程。
    nonisolated static let preflightChildEnvironmentKey = "FORGESWEEP_PREFLIGHT_CHILD"

    nonisolated private static func probeInChildProcess() async -> LiveProbe? {
        await Task.detached(priority: .userInitiated) { () -> LiveProbe? in
            let environment = ProcessInfo.processInfo.environment
            guard environment[preflightChildEnvironmentKey] == nil,
                  let executable = Bundle.main.executableURL else { return nil }
            let process = Process()
            process.executableURL = executable
            process.arguments = [preflightArgument]
            var childEnvironment = environment
            childEnvironment[preflightChildEnvironmentKey] = "1"
            process.environment = childEnvironment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            guard waitForExit(process, timeout: 3) else { return nil }
            let data = try? pipe.fileHandleForReading.readToEnd()
            guard process.terminationStatus == 0, let data,
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return LiveProbe.parse(text)
        }.value
    }

    // MARK: - 一键修复

    /// 清掉系统里绑定旧签名的屏幕录制记录，再重新请求（系统会重新弹窗）。
    /// 返回值表示重置本身是否成功；授权仍需用户在系统设置中打开。
    @discardableResult
    func resetScreenRecordingDecision() async -> Bool {
        guard !repairInFlight else { return false }
        repairInFlight = true
        defer { repairInFlight = false }
        let ok = await Self.runTCCReset(service: SettingsDestination.screenRecording.tccService)
        repairMessageKey = ok ? "permissions.repair.done" : "permissions.repair.failed"
        guard ok else { return false }
        defaults.removeObject(forKey: requestedRequirementKey)
        screenRecordingDecisionStale = false
        screenRecordingLiveGranted = nil
        _ = CGRequestScreenCaptureAccess()
        if let requirement = signing.requirement {
            defaults.set(requirement, forKey: requestedRequirementKey)
        }
        refresh()
        return true
    }

    /// 清掉完全磁盘访问的过期记录；随后用户需要在系统设置中重新加入应用。
    @discardableResult
    func resetFullDiskDecision() async -> Bool {
        guard !repairInFlight else { return false }
        repairInFlight = true
        defer { repairInFlight = false }
        let ok = await Self.runTCCReset(service: SettingsDestination.fullDisk.tccService)
        repairMessageKey = ok ? "permissions.repair.done" : "permissions.repair.failed"
        if ok {
            fullDiskLiveGranted = nil
            fullDiskNeedsRelaunch = false
        }
        refresh()
        return ok
    }

    nonisolated private static func runTCCReset(service: String) async -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        return await Task.detached(priority: .userInitiated) { () -> Bool in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", service, bundleID]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return false }
            guard waitForExit(process, timeout: 5) else { return false }
            return process.terminationStatus == 0
        }.value
    }

    /// 同步等待子进程退出；超时则终止并返回 false。两个探针的输出都只有
    /// 几个字节，不存在管道写满导致的死锁。
    nonisolated private static func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            return false
        }
        return true
    }

    func openSystemSettings(_ destination: SettingsDestination) {
        let direct: URL?
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 13 {
            direct = URL(string:
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(destination.legacyAnchor)")
        } else {
            direct = URL(string:
                "x-apple.systempreferences:com.apple.preference.security?\(destination.legacyAnchor)")
        }
        if let direct, NSWorkspace.shared.open(direct) { return }
        if let privacy = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(privacy)
        }
    }

    /// 用户 TCC 数据库不一定存在，不能把 ENOENT 当成未授权。
    /// 两处都受完全磁盘访问保护；必须实际打开成功，文件存在本身不代表授权。
    /// paths 仅供测试传入临时文件，正常检测固定使用下面两处数据库。
    nonisolated static func canOpenProtectedScanLocation(paths: [String] = [
        NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db",
        "/Library/Application Support/com.apple.TCC/TCC.db"
    ]) -> Bool {
        for path in paths {
            let descriptor = open(path, O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            close(descriptor)
            return true
        }
        return false
    }
}
