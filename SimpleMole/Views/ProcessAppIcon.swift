import AppKit
import SwiftUI

/// 运行中应用图标。按进程启动身份刷新，避免 PID 复用后沿用旧图标。
struct ProcessAppIcon: View {
    let row: ProcessRow
    let size: CGFloat
    let fallbackSystemName: String
    let fallbackTint: Color
    let validatesNativeStartIdentity: Bool
    var bundlePath: String? = nil

    @State private var icon: NSImage?

    private var effectiveBundlePath: String? {
        bundlePath ?? row.bundlePath
    }

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: fallbackSystemName)
                    .font(.system(size: size * 0.62, weight: .semibold))
                    .foregroundStyle(fallbackTint)
            }
        }
        .frame(width: size, height: size)
        .task(id: [row.signalToken, effectiveBundlePath ?? ""]) {
            icon = nil
            if let bundlePath = effectiveBundlePath {
                icon = NSWorkspace.shared.icon(forFile: bundlePath)
                return
            }
            guard let application = NSRunningApplication(processIdentifier: row.pid),
                  !application.isTerminated else { return }
            if validatesNativeStartIdentity {
                guard RuntimeStore.nativeStartIdentity(for: application) == row.startIdentity else {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            icon = application.icon
        }
        .accessibilityHidden(true)
    }
}
