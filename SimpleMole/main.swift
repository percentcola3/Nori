import AppKit
import CoreGraphics

if CommandLine.arguments.dropFirst().first == AdministratorCleanupPlan.workerArgument {
    exit(AdministratorCleanupPlan.runWorker(arguments: Array(CommandLine.arguments.dropFirst(2))))
}

if CommandLine.arguments.dropFirst().first == AdministratorUninstallPlan.workerArgument {
    exit(AdministratorUninstallPlan.runWorker(arguments: Array(CommandLine.arguments.dropFirst(2))))
}

// 权限中心的实时复检模式：屏幕录制（`CGPreflightScreenCaptureAccess`）与
// 完全磁盘访问的判定都按进程缓存，主进程授权后必须重启才能看到变化。主进程
// 用同一可执行文件拉起一个全新进程只做这一件事，输出一行状态后立刻退出——
// 绝不能创建 NSApplication，否则会出现第二个 Dock 图标，也不能触发品牌迁移
// 等启动副作用。
if CommandLine.arguments.dropFirst().contains(PermissionCenter.preflightArgument) {
    print(PermissionCenter.preflightReport())
    exit(0)
}

MainActor.assumeIsolated {
    BrandMigration.run()
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
