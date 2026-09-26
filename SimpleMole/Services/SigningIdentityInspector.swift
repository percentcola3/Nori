import Foundation
import Security

/// 当前进程代码签名的稳定性分类。
///
/// macOS 隐私授权（完全磁盘访问、屏幕录制）记录的是 App 的"指定要求"
/// （Designated Requirement）。ad-hoc 签名的指定要求只有 `cdhash`，每次
/// 重新构建都会改变，于是系统设置里的开关看起来还开着，实际授权却已经失效。
/// 带证书的签名把身份固定在证书上，重装后授权仍然有效。
enum SigningIdentityKind: Equatable {
    /// `designated => cdhash H"…"`：每次构建都会换身份。
    case adhoc
    /// `identifier "…" and certificate leaf = H"…"`：本地自签名证书，跨构建稳定。
    case local
    /// `anchor apple generic …`：Apple 签发的开发或发行证书，跨构建稳定。
    case apple
    /// 无法读取指定要求（例如测试宿主）。
    case unknown

    /// 授权是否能在重新安装后保留。
    var isStable: Bool { self == .local || self == .apple }
}

struct SigningIdentitySnapshot: Equatable {
    let kind: SigningIdentityKind
    /// 指定要求的文本形式，用来判断"这次的签名身份"是否和上次请求时相同。
    let requirement: String?
}

enum SigningIdentityInspector {
    /// 读取当前进程的指定要求并分类。只读操作，不触发任何授权提示。
    static func current() -> SigningIdentitySnapshot {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            return SigningIdentitySnapshot(kind: .unknown, requirement: nil)
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return SigningIdentitySnapshot(kind: .unknown, requirement: nil)
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
              let requirement else {
            return SigningIdentitySnapshot(kind: .unknown, requirement: nil)
        }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess,
              let text else {
            return SigningIdentitySnapshot(kind: .unknown, requirement: nil)
        }
        let string = text as String
        return SigningIdentitySnapshot(kind: classify(requirementString: string),
                                       requirement: string)
    }

    /// 根据指定要求文本分类。Apple 证书的要求同时包含 `anchor apple` 与
    /// `certificate leaf[...]`，所以必须先判 Apple 再判自签名。
    static func classify(requirementString: String) -> SigningIdentityKind {
        let text = requirementString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .unknown }
        if text.contains("anchor apple") { return .apple }
        if text.contains("certificate leaf") || text.contains("certificate root") { return .local }
        if text.contains("cdhash") { return .adhoc }
        return .unknown
    }
}
