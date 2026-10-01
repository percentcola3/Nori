#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-cli-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
source "$ROOT_DIR/script/test_developer_toolchain.sh"
swiftc -Onone -target "$(uname -m)-apple-macos13.0" \
    -module-cache-path "$TEST_DIR/module-cache" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperCLIService.swift" \
    "$ROOT_DIR/script/DeveloperCLIServiceTests.swift" \
    -o "$TEST_DIR/tests"
"$TEST_DIR/tests" "$TEST_DIR/fixtures"
cat > "$TEST_DIR/CLIUIStubs.swift" <<'SWIFT'
import SwiftUI
enum AppLanguage { case zhHans, zhHant, en }
final class L10n: ObservableObject {
    static let shared = L10n()
    var resolved: AppLanguage { .zhHans }
}
enum DeveloperWorkspaceSearchSource: Hashable { case shell, network, cli }
struct DeveloperWorkspaceSearchState: Equatable {
    let refreshToken: Int
    let isSearching: Bool
}
struct DeveloperWorkspaceSearchKey: PreferenceKey {
    static let defaultValue: [DeveloperWorkspaceSearchSource: DeveloperWorkspaceSearchState] = [:]
    static func reduce(value: inout [DeveloperWorkspaceSearchSource: DeveloperWorkspaceSearchState],
                       nextValue: () -> [DeveloperWorkspaceSearchSource: DeveloperWorkspaceSearchState]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}
// Shared UI contracts; the complete application build checks their rendering.
struct DeveloperWorkspaceContent<Content: View>: View {
    let isExpanded: Bool
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isExpanded { content.transition(.molePanelReveal) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}
struct ListRowGlass: ViewModifier {
    var selected = false
    var interactive = true
    func body(content: Content) -> some View { content }
}
enum MoleMotion {
    static let panel = Animation.spring(response: 0.46, dampingFraction: 0.78,
                                        blendDuration: 0.12)
}
extension AnyTransition {
    static var molePanelReveal: AnyTransition { .opacity }
}
SWIFT
CLI_SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
SDKROOT="$CLI_SDK" swiftc -typecheck -target "$(uname -m)-apple-macos13.0" \
    -module-cache-path "$TEST_DIR/module-cache" -framework SwiftUI -framework AppKit \
    "$ROOT_DIR/SimpleMole/Views/Theme.swift" \
    "$ROOT_DIR/SimpleMole/Services/DeveloperCLIService.swift" \
    "$ROOT_DIR/SimpleMole/Views/DeveloperCLIPanel.swift" \
    "$TEST_DIR/CLIUIStubs.swift"
echo "Developer CLI SwiftUI typecheck passed"
