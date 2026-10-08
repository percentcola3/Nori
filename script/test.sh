#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOLE_SRC="${MOLE_SRC:-$ROOT_DIR/vendor/mole}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nori-tests.XXXXXX")"
RUNTIME_DIR="$TEST_ROOT/runtime"
APP_STATE_CONTRACT_SOURCE="$TEST_ROOT/app-state-contract.swift"
cat "$ROOT_DIR"/SimpleMole/AppState*.swift > "$APP_STATE_CONTRACT_SOURCE"
PASSED=0
AUTO_CLEANUP_FIXTURE=""

cleanup() {
    rm -rf "$TEST_ROOT"
    case "$AUTO_CLEANUP_FIXTURE" in
        "$ROOT_DIR"/.auto-cleanup-planner-tests.*)
            rm -rf -- "$AUTO_CLEANUP_FIXTURE"
            ;;
    esac
}
trap cleanup EXIT

pass() {
    PASSED=$((PASSED + 1))
    printf 'ok %d - %s\n' "$PASSED" "$1"
}

fail() {
    printf 'not ok - %s\n' "$1" >&2
    exit 1
}

assert_status() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    [[ "$actual" -eq "$expected" ]] || fail "$message (expected $expected, got $actual)"
}

stage_bridge_runtime() {
    [[ -d "$MOLE_SRC/lib/core" ]] || fail "Mole library not found at $MOLE_SRC/lib"
    bash "$ROOT_DIR/script/stage_bridge_resources.sh" "$MOLE_SRC" "$RUNTIME_DIR"
}

test_shell_syntax() {
    local file
    for file in "$ROOT_DIR"/bridge/*.sh "$ROOT_DIR"/script/*.sh; do
        bash -n "$file" || fail "shell syntax: ${file#"$ROOT_DIR/"}"
    done
    pass "shell syntax"
}

test_native_core_ownership_contract() {
    local app_state="$APP_STATE_CONTRACT_SOURCE"
    local native_core="$ROOT_DIR/SimpleMole/Services/NativeCore.swift"
    local system_metrics="$ROOT_DIR/SimpleMole/Services/SystemMetrics.swift"
    local build_script="$ROOT_DIR/script/build.sh"

    /usr/bin/grep -Fq 'NativeCore.shared.scanCleanup(progress:' "$app_state" || \
        fail "clean does not use NativeCore progress scanner"
    /usr/bin/grep -Fq 'NativeCore.shared.applyCleanup' "$app_state" || \
        fail "clean apply does not use NativeCore"
    /usr/bin/grep -Fq 'NativeCore.shared.scanInstalledApps' "$app_state" || \
        fail "uninstall inventory does not use NativeCore"
    /usr/bin/grep -Fq 'NativeCore.shared.uninstallPlan' "$app_state" || \
        fail "uninstall preview does not use NativeCore"
    /usr/bin/grep -Fq 'uninstallExecutor.execute(job)' "$app_state" && \
        /usr/bin/grep -Fq 'NativeCore.shared.applyUninstall' "$ROOT_DIR/SimpleMole/Services/UninstallWorkflow.swift" || \
        fail "uninstall workflow does not use the native deletion engine"
    /usr/bin/grep -Fq 'AnalysisInventoryCache()' "$app_state" || \
        fail "analyze does not use the native inventory cache"
    /usr/bin/grep -Fq 'NativeCore.shared.runMaintenanceTask' "$app_state" || \
        fail "system maintenance does not use NativeCore"
    /usr/bin/grep -Fq 'SystemMetrics.sample(includeBluetooth:' "$app_state" || \
        fail "status sampling does not use SystemMetrics"

    if /usr/bin/grep -Eq 'MoleEngine|vendor/mole|bin/(clean|uninstall|analyze|optimize|status)\.sh|analyze-go|status-go' \
        "$native_core" "$system_metrics"; then
        fail "native core still references the Mole router, bridges, or Go helpers"
    fi
    if /usr/bin/grep -Eq 'FORGESWEEP_LEGACY_ORPHAN_BRIDGE|app_orphan_scan\.sh|app_uninstall_(list|preview|apply)\.sh' \
        "$app_state"; then
        fail "AppState still exposes a legacy Mole clean or uninstall route"
    fi
    if /usr/bin/grep -Eq 'cp .*bin/(mole|clean\.sh|uninstall\.sh|analyze-go|status-go)' \
        "$build_script"; then
        fail "build still packages a Mole core entrypoint"
    fi

    pass "native clean, uninstall, analyze, optimize and status ownership"
}

test_timeout_fallback() {
    bash "$ROOT_DIR/script/TimeoutFallbackTests.sh" || \
        fail "Perl timeout fallback performance and safety"
    pass "Perl timeout fallback performance and safety"
}

test_plists() {
    local found=0
    local plist
    while IFS= read -r -d '' plist; do
        found=1
        plutil -lint "$plist" >/dev/null || fail "plist: ${plist#"$ROOT_DIR/"}"
    done < <(find "$ROOT_DIR/SimpleMole" -type f -name '*.plist' -print0)
    [[ "$found" -eq 1 ]] || fail "no source plist found"
    pass "plist validation"
}

test_brand_contract() {
    local app_delegate="$ROOT_DIR/SimpleMole/AppDelegate.swift"
    local info_plist="$ROOT_DIR/SimpleMole/Support/Info.plist"

    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$info_plist")" == "Nori" ]] || \
        fail "bundle name is not Nori"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$info_plist")" == "Nori" ]] || \
        fail "bundle display name is not Nori"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")" == "com.nori.app" ]] || \
        fail "bundle identifier still uses the previous brand"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist")" == "Nori" ]] || \
        fail "bundle executable is not Nori"
    /usr/bin/grep -Fq 'appMenuItem.title = "Nori"' "$app_delegate" || \
        fail "system app menu does not use the Nori name"
    if /usr/bin/grep -Fq 'appMenuItem.image' "$app_delegate"; then
        fail "system app menu still displays a brand icon"
    fi

    pass "Nori brand, stable legacy identity and icon-free system menu contract"
}

test_tab_motion_contract() {
    local components="$ROOT_DIR/SimpleMole/Views/Components.swift"
    local main_window="$ROOT_DIR/SimpleMole/Views/MainWindowView.swift"
    local app_state="$APP_STATE_CONTRACT_SOURCE"

    /usr/bin/grep -Fq 'withAnimation(selectionAnimation)' "$components" || \
        fail "tab glass selection is not driven by an explicit animation transaction"
    /usr/bin/grep -Fq '.glassEffectID(index, in: selectionNamespace)' "$components" || \
        fail "tab glass effects do not have per-item identities"
    /usr/bin/grep -Fq 'interpolate(from, to, amount)' "$components" || \
        fail "Reduce Transparency tab motion skips progress interpolation"
    /usr/bin/grep -Fq 'withAnimation(animation)' "$main_window" || \
        fail "tab page replacement is not driven by an explicit animation transaction"
    /usr/bin/grep -Fq 'self.selectedTab == tab' "$app_state" || \
        fail "tab loading work is not deferred and stale-selection guarded"

    pass "tab glass and page motion contract"
}

test_control_motion_contract() {
    local components="$ROOT_DIR/SimpleMole/Views/Components.swift"
    local analyze="$ROOT_DIR/SimpleMole/Views/AnalyzeTabView.swift"
    local analyze_sections="$ROOT_DIR/SimpleMole/Views/AnalyzeSectionViews.swift"
    local analyze_media="$ROOT_DIR/SimpleMole/Views/MediaSlimViews.swift"
    local cleanup="$ROOT_DIR/SimpleMole/Views/CleanupTabView.swift"
    local dev_env="$ROOT_DIR/SimpleMole/Views/DeveloperRuntimePanel.swift"
    local uninstall="$ROOT_DIR/SimpleMole/Views/UninstallTabView.swift"

    /usr/bin/grep -Fq 'static let press = Animation' "$components" || \
        fail "ordinary controls do not share a short press animation"
    /usr/bin/grep -Fq 'struct MoleIconButtonStyle: ButtonStyle' "$components" || \
        fail "detail disclosure actions do not share an icon button style"
    /usr/bin/grep -Fq 'struct MolePlainButtonStyle: ButtonStyle' "$components" || \
        fail "surface-free buttons have no shared press feedback"
    /usr/bin/grep -Fq '.buttonStyle(MolePlainButtonStyle(pressedScale' "$analyze_sections" || \
        fail "disk analysis duplicate rows bypass the selectable-row interaction"
    /usr/bin/grep -Fq '.buttonStyle(MolePlainButtonStyle(pressedScale: 0.99))' "$analyze" && \
        /usr/bin/grep -Fq '.modifier(ListRowSurface(selected: selected))' "$analyze" || \
        fail "disk analysis content rows lack shared press feedback and selection semantics"
    /usr/bin/grep -Fq '.toggleStyle(.checkbox)' "$ROOT_DIR/SimpleMole/Views/DeveloperRuntimePanel.swift" && \
        /usr/bin/grep -Fq '.modifier(DevSelectionSurface(selected: selected))' "$ROOT_DIR/SimpleMole/Views/DeveloperRuntimePanel.swift" || \
        fail "development environment rows lack checkbox semantics or glass selection"
    /usr/bin/grep -Fq '.buttonStyle(MolePlainButtonStyle' "$cleanup" || \
        fail "cleanup detail titles still bypass Button semantics"
    /usr/bin/grep -Fq '.buttonStyle(MoleIconButtonStyle' "$uninstall" || \
        fail "uninstall disclosure action lacks press feedback"
    if /usr/bin/grep -Fq 'onTapGesture { state.toggleDupSelection(member) }' "$analyze" \
        || /usr/bin/grep -Fq 'onTapGesture { state.toggleDupSelection(member) }' "$analyze_sections"; then
        fail "duplicate rows still register overlapping selection gestures"
    fi

    pass "ordinary buttons and selectable-row motion contract"
}

test_header_layout_contract() {
    local main_window="$ROOT_DIR/SimpleMole/Views/MainWindowView.swift"
    local components="$ROOT_DIR/SimpleMole/Views/Components.swift"
    local icon="$ROOT_DIR/SimpleMole/Support/HeaderBrandIcon.png"

    /usr/bin/grep -Fq 'HeaderBrandIconView(size: 20,' "$main_window" || \
        fail "title-bar brand icon is not using the compact optical size"
    /usr/bin/grep -Fq 'isSearching: state.isScanning' "$main_window" || \
        fail "title-bar mascot does not react to cleanup scanning"
    /usr/bin/grep -Fq '.frame(height: 28)' "$main_window" || \
        fail "title-bar controls do not have a stable vertical alignment slot"
    /usr/bin/grep -Fq '.padding(.top, 2)' "$main_window" || \
        fail "title-bar controls can touch the top window edge"
    if /usr/bin/grep -Fq 'TitleBarButtonStyle' "$main_window"; then
        fail "retired title-bar actions are still rendered"
    fi
    /usr/bin/grep -Fq 'case .settings: SettingsTabView(state: state)' "$main_window" || \
        fail "settings is not a navigation tab"
    /usr/bin/grep -Fq 'NoriMascotView(mood:' "$ROOT_DIR/SimpleMole/Views/NoriMascotView.swift" || \
        fail "title-bar icon does not use the Nori semantic animation component"
    if [[ "${SM_TEST_SKIP_SWIFT:-0}" != "1" ]]; then
        bash "$ROOT_DIR/script/test_nori.sh" || fail "Nori motion and asset invariants"
    fi
    /usr/bin/grep -Fq 'struct MoleSwitchToggleStyle: ToggleStyle' "$components" || \
        fail "switch controls do not share the animated brand interaction"
    /usr/bin/grep -Fq 'static var molePanelReveal' "$components" || \
        fail "expandable panels do not share the reveal transition"
    [[ -f "$icon" ]] || fail "transparent title-bar brand icon is missing"

    pass "title-bar icon and control alignment contract"
}

test_process_icon_contract() {
    local component="$ROOT_DIR/SimpleMole/Views/ProcessAppIcon.swift"
    local processes="$ROOT_DIR/SimpleMole/Views/ProcessesTabView.swift"

    [[ -f "$component" ]] || fail "shared process app icon component is missing"
    /usr/bin/grep -Fq 'NSRunningApplication(processIdentifier: row.pid)' "$component" || \
        fail "process icons are not resolved from the running application"
    /usr/bin/grep -Fq '.task(id: row.signalToken)' "$component" || \
        fail "process icons are not refreshed across PID reuse"
    /usr/bin/grep -Fq 'RuntimeStore.nativeStartIdentity(for: application) == row.startIdentity' "$component" || \
        fail "native process icons are not bound to the application launch identity"
    /usr/bin/grep -Fq 'ProcessAppIcon(row: row,' "$processes" || \
        fail "process cleanup does not render real application icons"
    if /usr/bin/grep -Fq 'image.size =' "$component"; then
        fail "process icon rendering mutates shared NSImage dimensions"
    fi

    pass "process application icon identity and fallback contract"
}

test_island_contract() {
    local island="$ROOT_DIR/SimpleMole/Views/FloatingIslandView.swift"
    local app_delegate="$ROOT_DIR/SimpleMole/AppDelegate.swift"
    local app_state="$APP_STATE_CONTRACT_SOURCE"
    local components="$ROOT_DIR/SimpleMole/Views/Components.swift"
    local l10n="$ROOT_DIR/SimpleMole/L10n/TablesProductivity.swift"

    [[ -f "$island" ]] || fail "floating island view is missing"
    # 命中区域必须以视图根部命名坐标系上报：.global 在部分系统按屏幕原点解释，
    # 会让悬停(tracking area)可用而点击(hitTest)整体落空。
    /usr/bin/grep -Fq 'geo.frame(in: .named(IslandLayout.hitSpaceName))' "$island" || \
        fail "island hit frame is not reported in the root coordinate space (buttons become unclickable)"
    /usr/bin/grep -Fq 'coordinateSpace(name: IslandLayout.hitSpaceName)' "$island" || \
        fail "island root coordinate space is not declared"
    # 命中区只能由几何变化通道上报：onChange(of: expanded) 补报捕获的是形变前
    # 旧几何，且与 frame 通知同拍到达会把展开后的命中区覆盖回折叠手柄——
    # 表现为展开面板上的点击（更多/优化）全部穿透到桌面。
    if /usr/bin/grep -Fq 'onChange(of: expanded) { _ in onHitFrameChange' "$island"; then
        fail "island hit frame is re-reported from the stale expanded-flag handler"
    fi
    # codenotch 式深色胶囊不画投影：面板底层不允许再出现阴影层。
    if /usr/bin/grep -Fq '.shadow(' "$island"; then
        fail "island draws a shadow layer under the panel"
    fi
    /usr/bin/grep -Fq 'override func acceptsFirstMouse' "$ROOT_DIR/SimpleMole/Views/IslandWindow.swift" || \
        fail "island first-click support is missing"
    # 未显式设置 ignoresMouseEvents 时，窗口服务器按全透明的窗口缓冲区判定穿透，
    # 灵动岛上的点击会整片投给下方窗口（悬停可用、点击无效）。
    /usr/bin/grep -Fq 'panel.ignoresMouseEvents = true' "$app_delegate" || \
        fail "island panel leaves mouse pass-through to the window server's alpha test"
    /usr/bin/grep -Fq 'panel.ignoresMouseEvents = !inside' "$app_delegate" || \
        fail "island panel does not accept clicks while the cursor is over its visible shape"
    /usr/bin/grep -Fq 'struct NotchShape: Shape' "$ROOT_DIR/SimpleMole/Views/IslandWindow.swift" || \
        fail "island notch shape is missing"
    /usr/bin/grep -Fq 'let safeTop = islandSafeTop(on: screen)' "$app_delegate" || \
        fail "island safe-top does not use the captured screen"
    /usr/bin/grep -Fq 'safeTop: safeTop,' "$app_delegate" || \
        fail "island does not avoid physical notch content"
    /usr/bin/grep -Fq 'state.cleanIslandResource(resource)' "$island" || \
        fail "CPU/memory resource cleanup is disconnected"
    /usr/bin/grep -Fq 'onOpenMain()' "$island" || \
        fail "island advanced action does not open main panel"
    /usr/bin/grep -Fq 'IslandWindowGeometry.origin(' "$app_delegate" || \
        fail "island window does not use shared physical-edge geometry"
    /usr/bin/grep -Fq 'y: screenFrame.maxY - size.height' "$ROOT_DIR/SimpleMole/Views/IslandWindow.swift" || \
        fail "island is not anchored to the physical screen top"
    # 表面从物理顶边起画：刘海屏上若先垫一段 safeTop 空白，手柄就成了挂在
    # 刘海下沿的一条细条，肩角翘在刘海底边而不是屏幕顶边。
    if /usr/bin/grep -Fq 'Color.clear.frame(height: safeTop)' "$island"; then
        fail "island surface starts below the hardware notch instead of the screen top"
    fi
    # 内容避让量由 expandedTopInset 汇总：有刘海屏沿用 safeTop 原值避让硬件刘海，
    # 无刘海屏改用菜单栏内边距（见其定义处）。
    /usr/bin/grep -Fq 'hardwareNotch ? safeTop : IslandLayout.nonNotchExpandedTopInset' "$island" || \
        fail "island content does not avoid the hardware notch"
    /usr/bin/grep -Fq '.padding(.top, expandedTopInset)' "$island" || \
        fail "expanded island content is not inset below the notch"
    # 刘海手柄与展开面板共享玻璃材质：不允许实底黑 curtain 盖住玻璃。
    /usr/bin/grep -Fq 'shape.fill(Color.islandHandleVeil)' \
        "$ROOT_DIR/SimpleMole/Views/LiquidPresentation.swift" || \
        fail "collapsed handle no longer shares the expanded panel's glass material"
    if /usr/bin/grep -Fq 'Color.black' "$ROOT_DIR/SimpleMole/Views/LiquidPresentation.swift"; then
        fail "island paints an opaque black curtain over the glass"
    fi
    # 每次更新只捕获一块屏幕；主屏暂缺时用当前面板所在屏，无屏幕则保留面板。
    # 同一屏幕的指标同步传入新视图，不能在重建与定位之间重新读取 NSScreen.main。
    /usr/bin/grep -Fq 'guard let screen = NSScreen.main ?? islandPanel?.screen ?? NSScreen.screens.first else { return }' "$app_delegate" || \
        fail "island update does not preserve a single screen snapshot during screen transitions"
    /usr/bin/grep -Fq 'let collapsedWidth = islandCollapsedWidth(on: screen)' "$app_delegate" || \
        fail "island collapsed width does not use the captured screen"
    /usr/bin/grep -Fq 'collapsedWidth: collapsedWidth,' "$app_delegate" || \
        fail "island view does not receive the captured collapsed width"
    # 无刘海屏折叠时只挂顶边句柄，不画整块菜单栏高度的虚拟刘海；展开内容仍避让菜单栏。
    /usr/bin/grep -Fq 'screen.frame.maxY - screen.visibleFrame.maxY' "$app_delegate" || \
        fail "expanded island does not clear the menu bar on notchless screens"
    /usr/bin/grep -Fq 'hardwareNotch ? safeTop + IslandLayout.notchLipHeight : IslandLayout.handleHeight' "$island" || \
        fail "notchless screens draw a full virtual notch instead of a handle"
    /usr/bin/grep -Fq 'hardwareNotch ? collapsedWidth : IslandLayout.handleWidth' "$island" || \
        fail "notchless collapsed island is wider than a handle"
    # 激活策略切换后下一拍再抬升主窗口：同拍 activate 会被忽略（点更多只回到桌面）。
    /usr/bin/grep -Fq 'raiseMainWindowAfterPolicyChange()' "$app_delegate" || \
        fail "main window is not re-raised after the activation-policy change settles"
    # 主窗口跟随光标所在屏；屏幕重排后搁浅在不可见屏上的窗口要被救回，
    # 否则表现为"点更多没有任何面板出现"（窗口开在了另一块屏上）。
    /usr/bin/grep -Fq 'restoreMainWindow(to: targetScreen ?? cursorScreen, force: createdWindow)' "$app_delegate" || \
        fail "main window placement never follows the cursor's screen"
    # 从灵动岛点"更多"：主窗口开在灵动岛所在的屏上。
    /usr/bin/grep -Fq 'self?.showMainWindow(on: islandScreen)' "$app_delegate" || \
        fail "island advanced action does not open the main panel on the island's screen"
    if [[ "${SM_TEST_SKIP_SWIFT:-0}" != "1" ]]; then
        bash "$ROOT_DIR/script/test_island_window.sh" || fail "island window hit testing"
        bash "$ROOT_DIR/script/test_island_resources.sh" || fail "island resource policy"
    fi
    # 菜单栏图标可隐藏：设置驱动 + 状态项动态装拆 + 持久化。
    /usr/bin/grep -Fq 'settings.menubaricon' "$ROOT_DIR/SimpleMole/Views/SettingsTabView.swift" || \
        fail "settings has no menu bar icon visibility toggle"
    /usr/bin/grep -Fq 'NSStatusBar.system.removeStatusItem(statusItem)' "$app_delegate" || \
        fail "hiding the menu bar icon does not remove the status item"
    /usr/bin/grep -Fq 'SMMenuBarIconVisible' "$app_state" || \
        fail "menu bar icon visibility is not persisted"
    /usr/bin/grep -Fq '"settings.menubaricon"' "$l10n" || \
        fail "menu bar icon toggle has no localization"
    # 只禁止已退役的裸 island.edge.* 键；settings.island.edge.* 是设置页在用的活键。
    if /usr/bin/grep -Fq '"island.edge' "$l10n"; then
        fail "retired island edge dock keys are still localized"
    fi
    /usr/bin/grep -Fq 'networkUploadHistory' "$app_state" || \
        fail "upload throughput history is not sampled"
    /usr/bin/grep -Fq 'private var networkMeter' "$island" || \
        fail "network is not shown as a throughput meter"
    /usr/bin/grep -Fq 'struct IslandSparkline' "$island" || \
        fail "network throughput has no trend"
    /usr/bin/grep -Fq 'metricsStore.metrics.cpuPercent' "$island" || \
        fail "island does not surface CPU occupancy"
    /usr/bin/grep -Fq 'metricsStore.metrics.memoryPercent' "$island" || \
        fail "island does not surface memory occupancy"
    if /usr/bin/grep -Eq 'l10n\.t\("metric\.(load|uptime|battery|swap)"\)' "$island"; then
        fail "island still shows load, uptime, battery or swap"
    fi
    if awk '/private var networkMeter/,/private func rateLine/' "$island" \
        | /usr/bin/grep -Fq 'Circle('; then
        fail "network throughput is still drawn as a ring"
    fi

    pass "floating island notch contract"
}

test_productivity_feature_contract() {
    local main_window="$ROOT_DIR/SimpleMole/Views/MainWindowView.swift"
    local app_state="$APP_STATE_CONTRACT_SOURCE"
    local cleanup_view="$ROOT_DIR/SimpleMole/Views/CleanupTabView.swift"
    local app_delegate="$ROOT_DIR/SimpleMole/AppDelegate.swift"
    local screenshot_service="$ROOT_DIR/SimpleMole/Services/ScreenShotService.swift"
    local screenshot_editor="$ROOT_DIR/SimpleMole/Views/ScreenshotEditorView.swift"
    local clipboard="$ROOT_DIR/SimpleMole/Services/ClipboardHistoryManager.swift"
    local clipboard_view="$ROOT_DIR/SimpleMole/Views/ClipboardHistoryTabView.swift"
    local permission_center="$ROOT_DIR/SimpleMole/Services/PermissionCenter.swift"
    local authorization_coordinator="$ROOT_DIR/SimpleMole/Services/AuthorizationCoordinator.swift"
    local permission_view="$ROOT_DIR/SimpleMole/Views/PermissionCenterView.swift"
    local mole_engine="$ROOT_DIR/SimpleMole/Services/MoleEngine.swift"
    local analyze_view="$ROOT_DIR/SimpleMole/Views/AnalyzeTabView.swift"
    local models="$ROOT_DIR/SimpleMole/Models.swift"
    local system_metrics="$ROOT_DIR/SimpleMole/Services/SystemMetrics.swift"

    /usr/bin/grep -Fq 'pages.append(.settings)' "$app_state" || \
        fail "settings tab is not always available"
    /usr/bin/grep -Fq 'state.requestScanAccess(.quickOptimize)' \
        "$ROOT_DIR/SimpleMole/Views/CleanupTabView.swift" || \
        fail "main cleanup page does not expose Quick Clean"
    # 深度扫描入口已并入统一扫描流程；深度能力本身仍由 AppState 的
    # .deepCleanupScan 授权链路提供，不再要求清理页有独立按钮。
    if /usr/bin/grep -Fq '"bin/app_dev_scan.sh"' "$app_state"; then
        fail "unified cleanup still launches a duplicate developer-cache scan"
    fi
    /usr/bin/grep -Fq 'cleanupOrphanNames(home: home, mode: mode, control: control)' \
        "$ROOT_DIR/SimpleMole/Services/NativeCore.swift" || fail "cleanup lost orphan correlation"
    /usr/bin/grep -Fq 'button.action = #selector(openMainWindow(_:))' "$app_delegate" || \
        fail "menu bar icon does not open the main window directly"
    [[ ! -f "$ROOT_DIR/SimpleMole/Views/QuickPanelView.swift" ]] || \
        fail "retired quick panel view is still present"
    /usr/bin/grep -Fq 'static func memoryShort(_ bytes: UInt64)' "$models" || \
        fail "memory has no hardware-capacity formatter"
    /usr/bin/grep -Fq 'static func megabytesPerSecond' "$models" || \
        fail "network throughput has no rate formatter"
    /usr/bin/grep -Fq 'struct AnalyzeSidebar' "$analyze_view" || \
        fail "disk analysis does not expose independent sidebar sections"
    /usr/bin/grep -Fq 'ForEach(AnalyzeMode.menuOrder)' "$analyze_view" || \
        fail "analysis sidebar does not list disk browsing and file categories"
    /usr/bin/grep -Fq 'Button { selection = item }' "$analyze_view" || \
        fail "analysis navigation does not preserve the cached result"
    /usr/bin/grep -Fq 'state.scanAnalysisMode(mode, forceFull: true)' "$analyze_view" || \
        fail "the scan button does not start the selected independent analysis"
    /usr/bin/grep -Fq 'internalPages: UInt64(info.internal_page_count)' "$system_metrics" || \
        fail "memory usage still counts inactive file cache as occupied memory"
    /usr/bin/grep -Fq 'min(rawBytes, totalBytes)' "$system_metrics" || \
        fail "memory usage is not capped at physical memory"
    bash "$ROOT_DIR/script/test_cleanup_manual_trigger.sh" || \
        fail "cleanup manual-trigger lifecycle contract"
    /usr/bin/grep -Fq 'ForEach(sortedPaths, id: \.self)' "$ROOT_DIR/SimpleMole/Views/CleanupTabView.swift" && \
        /usr/bin/grep -Fq 'sortedPaths = category.pathsByDescendingSize' "$ROOT_DIR/SimpleMole/Views/CleanupTabView.swift" || \
        fail "expanded cleanup children are not selectable and sorted by size"
    /usr/bin/grep -Fq 'source.compactMap(\.selectedSubset)' "$app_state" || \
        fail "cleanup apply still submits whole categories instead of selected children"
    /usr/bin/grep -Fq '.sorted(by: CleanupCategory.sizeDescending)' "$app_state" || \
        fail "cleanup categories are not sorted by descending size"
    /usr/bin/grep -Fq 'let eligibleCount = eligible.reduce' "$app_state" || \
        fail "cleanup progress does not count the immutable eligible plan"
    /usr/bin/grep -Fq 'eligibleCount + (installers?.paths.count ?? 0) + maintenanceIDs.count' "$app_state" || \
        fail "cleanup progress still reports the pre-policy request count"
    /usr/bin/grep -Fq 'selectionEnabled: state.cleanupScanComplete' "$cleanup_view" || \
        fail "cleanup category selection is not routed through a shared applying-state gate"
    /usr/bin/grep -Fq '&& !state.isApplying' "$cleanup_view" || \
        fail "cleanup category and child selection remain mutable during apply"
    /usr/bin/grep -Fq '.disabled(!state.cleanupScanComplete || state.isApplying)' "$cleanup_view" || \
        fail "cleanup group selection remains mutable during apply"
    /usr/bin/grep -Fq '.liquidSurface(activeDialog)' "$main_window" || \
        fail "main dialogs do not use a native glass surface"
    /usr/bin/grep -Fq '.glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)' \
        "$ROOT_DIR/SimpleMole/Views/LiquidPresentation.swift" || \
        fail "glass dialogs do not use native matched-geometry transitions"
    /usr/bin/grep -Fq 'state.visiblePages.map' "$main_window" || \
        fail "visible page settings and tab labels use different data sources"
    /usr/bin/grep -Fq 'if let process = screenshotProcess, process.isRunning { process.terminate() }' "$app_delegate" || \
        fail "a new screenshot session does not cancel the previous capture process"
    /usr/bin/grep -Fq 'guard let self, self.screenshotSession == session else { return }' "$app_delegate" || \
        fail "a cancelled screenshot session can still present its result"
    /usr/bin/grep -Fq 'RatioCaptureController.shared.dismiss()' "$app_delegate" && \
        /usr/bin/grep -Fq 'closeScreenshotEditor()' "$app_delegate" || \
        fail "a previous ratio overlay or editor blocks the next screenshot session"
    /usr/bin/grep -Fq 'com.nori.screenshot.' "$screenshot_service" || \
        fail "screenshot capture does not use a private temporary directory"
    /usr/bin/grep -Fq 'removeItem(at: directory)' "$screenshot_service" || \
        fail "screenshot temporary directory is not cleaned"
    /usr/bin/grep -Fq 'private var exportSize' "$screenshot_editor" || \
        fail "screenshot export still renders only at preview size"
    /usr/bin/grep -Fq 'MosaicCache.shared.clear()' "$app_delegate" || \
        fail "closing the screenshot editor retains the source image cache"
    /usr/bin/grep -Fq 'private let maxTotalBytes' "$clipboard" || \
        fail "clipboard image history has no total memory bound"
    /usr/bin/grep -Fq 'org.nspasteboard.ConcealedType' "$clipboard" || \
        fail "clipboard history records concealed password-manager content"
    /usr/bin/grep -Fq 'case text, url, file, image' "$clipboard" || \
        fail "clipboard history does not classify text, URL, file and image entries"
    /usr/bin/grep -Fq 'SMClipboardHistoryCapacity' "$clipboard" || \
        fail "clipboard history capacity is not persisted"
    /usr/bin/grep -Fq 'clipboard-history.plist' "$clipboard" || \
        fail "clipboard entries are not persisted across app launches"
    /usr/bin/grep -Fq 'PropertyListEncoder()' "$clipboard" || \
        fail "clipboard history has no on-disk archive"
    /usr/bin/grep -Fq 'entries.lastIndex(where: { !$0.isPinned })' "$clipboard" || \
        fail "clipboard capacity cleanup can remove pinned entries"
    /usr/bin/grep -Fq 'case .clipboard: ClipboardHistoryTabView' "$main_window" || \
        fail "enabled clipboard history is not rendered as a standalone tab"
    /usr/bin/grep -Fq 'if clipboardHistoryEnabled { pages.append(.clipboard) }' "$app_state" || \
        fail "clipboard tab visibility is not controlled by the feature switch"
    /usr/bin/grep -Fq 'enum ProtectedOperation' "$authorization_coordinator" || \
        fail "protected scans do not use a persistent typed operation"
    /usr/bin/grep -Fq 'final class AuthorizationCoordinator' "$authorization_coordinator" || \
        fail "scan authorization has no central coordinator"
    /usr/bin/grep -Fq 'func requestScanAccess(_ operation: ProtectedOperation)' "$app_state" || \
        fail "protected scan entry points do not share the typed permission gate"
    /usr/bin/grep -Fq 'authorizationCoordinator.storePending(operation)' "$app_state" || \
        fail "denied scan intent is not persisted before opening the permission center"
    /usr/bin/grep -Fq 'func refreshAuthorizationAndResume()' "$app_state" || \
        fail "authorized scans cannot resume after returning from System Settings"
    /usr/bin/grep -Fq 'permissions.status.required' "$permission_view" || \
        fail "Full Disk Access is not presented as required for protected scans"
    /usr/bin/grep -Fq '.disabled(isWaitingForDiskAccess)' "$permission_view" || \
        fail "permission continue can execute a pending scan before authorization"
    if /usr/bin/grep -Fq 'SMScanAccessAsked' "$app_state"; then
        fail "scan access still treats a dismissed prompt as valid authorization"
    fi
    /usr/bin/grep -Fq 'extraEnvironment: [String: String] = [:]' "$mole_engine" || \
        fail "bridge runner cannot receive a scoped scan capability"
    /usr/bin/grep -Fq 'FORGESWEEP_FULL_DISK_AUTHORIZED' "$app_state" || \
        fail "authorized child processes do not receive the scoped scan capability"
    /usr/bin/grep -Fq 'guard permissionCenter.fullDiskAccessGranted else { return [:] }' \
        "$app_state" || fail "scan capability can be minted before authorization"
    /usr/bin/grep -Fq 'scanEnvironment["FORGESWEEP_FULL_DISK_AUTHORIZED"] == "1"' \
        "$app_state" || fail "protected scan entry points do not fail closed"
    /usr/bin/grep -Fq 'extraEnvironment: scanEnvironment' "$app_state" || \
        fail "protected scan calls do not pass the verified capability environment"
    /usr/bin/grep -Fq 'CGPreflightScreenCaptureAccess()' "$permission_center" || \
        fail "screen recording permission has no public preflight check"
    /usr/bin/grep -Fq 'CGRequestScreenCaptureAccess()' "$permission_center" || \
        fail "screen recording permission is not requested through Core Graphics"
    /usr/bin/grep -Fq 'fullDiskAccessGranted = Self.canOpenProtectedScanLocation()' "$permission_center" || \
        fail "full disk access is not refreshed from actual protected data access"
    /usr/bin/grep -Fq 'O_RDONLY | O_CLOEXEC' "$permission_center" || \
        fail "full disk access detection does not probe a protected scan location"
    /usr/bin/grep -Fq 'com.apple.TCC/TCC.db' "$permission_center" || \
        fail "full disk access detection is not using the non-interactive TCC probe"
    if /usr/bin/grep -Fq '/Library/Containers/' "$permission_center"; then
        fail "permission refresh still probes another App container and can trigger a system prompt"
    fi
    /usr/bin/grep -Fq 'com.apple.settings.PrivacySecurity.extension' "$permission_center" || \
        fail "permission settings still use only the legacy pre-macOS 13 deep link"
    /usr/bin/grep -Fq 'registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier' \
        "$permission_view" || fail "permission drag does not provide the original file URL as data"
    /usr/bin/grep -Fq 'Bundle.main.bundleURL.absoluteString' "$permission_view" || \
        fail "permission drag does not target the running App bundle"
    if /usr/bin/grep -Eq 'registerFileRepresentation|NSItemProvider\(object:' "$permission_view"; then
        fail "permission drag may export a temporary App copy instead of the original URL"
    fi
    /usr/bin/grep -Fq 'dragProvider: permissions.fullDiskAccessGranted ? nil : applicationDragProvider' \
        "$permission_view" || fail "Full Disk Access does not own its conditional drag source"
    /usr/bin/grep -Fq 'ConditionalDragModifier(provider: dragProvider' "$permission_view" || \
        fail "permission cards do not apply drag behavior conditionally"
    if /usr/bin/grep -Fq 'draggableApplication' "$permission_view"; then
        fail "permission center still renders a fixed first draggable app card"
    fi
    if /usr/bin/grep -Eq 'NSApplication\.didBecomeActiveNotification|\.onChange\(of: permissions\.fullDiskAccessGranted\)' \
        "$permission_view"; then
        fail "permission view still resumes protected work from view lifecycle callbacks"
    fi
    if /usr/bin/grep -Fq '.onAppear { permissions.refresh() }' "$permission_view"; then
        fail "permission view still owns authorization refresh lifecycle"
    fi
    /usr/bin/grep -Fq 'Button(l10n.t(hasPendingAction' "$permission_view" || \
        fail "permission view lost the explicit Continue button callback"
    local defaults_line publish_line
    defaults_line=$(/usr/bin/grep -nF 'defaults.set(data, forKey: Self.pendingOperationKey)' \
        "$authorization_coordinator" | /usr/bin/cut -d: -f1)
    publish_line=$(/usr/bin/grep -nF 'pendingOperation = operation' \
        "$authorization_coordinator" | /usr/bin/tail -n 1 | /usr/bin/cut -d: -f1)
    [[ -n "$defaults_line" && -n "$publish_line" && "$defaults_line" -lt "$publish_line" ]] || \
        fail "pending authorization is published before its durable write"
    if /usr/bin/grep -Eq 'homeFolderRow|appManagementRow' "$permission_view"; then
        fail "the initial permission center still shows duplicate disk or on-demand app permissions"
    fi
    /usr/bin/grep -Fq 'PermissionCenterView(state: state)' "$main_window" || \
        fail "the unified permission center is not presented by the main window"
    /usr/bin/grep -Fq 'permissionCenter.screenRecordingGranted' "$app_delegate" || \
        fail "the screenshot hotkey bypasses the unified permission preflight"
    /usr/bin/grep -Fq 'ClipboardFilterButtonStyle(isSelected: filter == item)' "$clipboard_view" || \
        fail "clipboard type filters do not use the themed icon capsules"
    /usr/bin/grep -Fq 'minHeight: 140, maxHeight: 140' "$clipboard_view" || \
        fail "clipboard card preview is not bounded against long-content overflow"
    /usr/bin/grep -Fq '.frame(height: 194, alignment: .topLeading)' "$clipboard_view" || \
        fail "clipboard cards do not keep a stable action-bar layout"
    if /usr/bin/grep -Fq '.pickerStyle(.segmented)' "$clipboard_view"; then
        fail "clipboard type filters still use the system segmented control"
    fi
    if /usr/bin/grep -Fq 'l10n.t("clip.hint")' "$clipboard_view"; then
        fail "clipboard history still renders explanatory copy"
    fi
    /usr/bin/grep -A28 -Fq 'guard permissionCenter.fullDiskAccessGranted else {' "$app_state" || \
        fail "background automation can still trigger protected-folder permission prompts"
    /usr/bin/grep -Fq 'auto.status.diskPermissionRequired' "$app_state" || \
        fail "skipped background scans do not expose their permission state"
    if /usr/bin/sed -n '/NSApplication.didBecomeActiveNotification/,/store(in: &observables)/p' \
        "$app_delegate" | /usr/bin/grep -Fq 'runScheduledAutoCleanup'; then
        fail "every app activation still launches a background filesystem scan"
    fi
    /usr/bin/grep -Fq 'AnalyzeReport(path: "/", overview: true' "$ROOT_DIR/SimpleMole/Services/AnalysisInventoryCache.swift" || \
        fail "disk analysis does not start from the native machine-wide overview"
    /usr/bin/grep -Fq '.sorted(by: AnalyzeEntry.analysisOrder)' "$ROOT_DIR/SimpleMole/Services/DiskAnalysisWorker.swift" || \
        fail "disk analysis results are not size ordered"
    if sed -n '/private func startAnalyze(/,/MARK: APFS/p' "$app_state" | grep -Fq '.prefix(10)'; then
        fail "disk analysis still hides children beyond Top 10"
    fi
    # 结果页按 大文件/图片/视频/重复文件 子分类一页展示，不再有目录层级浏览。
    local analyze_sections="$ROOT_DIR/SimpleMole/Views/AnalyzeSectionViews.swift"
    local analyze_worker="$ROOT_DIR/SimpleMole/Services/DiskAnalysisWorker.swift"
    /usr/bin/grep -Fq 'func slimCandidates(in section: AnalyzeSection)' "$ROOT_DIR/SimpleMole/AppState+Media.swift" || \
        fail "disk analysis results are not rendered as scan sub-categories"
    /usr/bin/grep -Fq 'DuplicateScanActivity(progress: state.duplicateScanProgress' "$analyze_view" || \
        fail "duplicate scanning has no animated SVG progress placeholder"
    /usr/bin/grep -Fq 'canSelect: DuplicateSelectionPolicy.canSelect(' "$analyze_sections" || \
        fail "duplicate groups do not enforce keep-one selection"
    # 子分类在扫描层过滤系统位置：不可清理的文件不进入结果。
    /usr/bin/grep -Fq 'MediaSlimPolicy.isEligible(itemPath, home: home)' "$analyze_worker" || \
        fail "large-file collection no longer filters system-managed locations"
    if /usr/bin/grep -Fq 'analyze.scope' "$analyze_view" \
        || /usr/bin/grep -Fq 'chooseAnalyzeFolder' "$app_state" \
        || /usr/bin/grep -Fq 'scanUserSpace' "$app_state"; then
        fail "disk analysis still exposes manual scan-scope selection"
    fi
    /usr/bin/grep -Fq 'CleanupCategory.manualCleanupCandidates(from:' "$app_state" && \
        /usr/bin/grep -Fq 'CleanupRiskPolicy.isEligible(subset, mode: mode, running: snapshot)' "$app_state" || \
        fail "manual disk cleanup bypasses its category and runtime eligibility filters"
    /usr/bin/grep -Fq 'environment["SIMPLEMOLE_DELETE_MODE"] = "permanent"' "$app_state" || \
        fail "disk cleanup does not explicitly request permanent deletion"
    # 2026-10 起清理不再弹确认：清单勾选即指令，执行层复核保持不变。
    if /usr/bin/grep -Fq 'confirm.cleanupPermanent.title' "$app_state"; then
        fail "manual cleanup still prompts for confirmation before applying"
    fi
    /usr/bin/grep -Fq 'performApply(categories: selectedCategories,' \
        "$app_state" || fail "manual cleanup no longer executes directly"
    if /usr/bin/grep -Fq 'private var quickRoots' "$analyze_view"; then
        fail "disk analysis still exposes confusing directory tabs"
    fi

    pass "settings, screenshot and clipboard lifecycle contracts"
}

test_scan_access_boundary() {
    local home="$TEST_ROOT/scan-access-home"
    local helper="$RUNTIME_DIR/bin/app_scan_access.sh"
    local safe_installer="$home/Public/safe.dmg"
    local protected_installer="$home/Downloads/protected.dmg"
    local output=""

    mkdir -p "$home/Public" "$home/Downloads" "$home/Desktop" "$home/Documents" \
        "$home/.cache"
    printf 'safe\n' > "$safe_installer"
    printf 'protected\n' > "$protected_installer"

    if env HOME="$home" bash -c 'source "$1"; nori_scan_path_allowed "$HOME/Documents"' \
        _ "$helper"; then
        fail "protected Documents root was accepted without Full Disk Access"
    fi
    env HOME="$home" bash -c 'source "$1"; nori_scan_path_allowed "$HOME/.cache"' \
        _ "$helper" || fail "ordinary dot-cache path was incorrectly permission-gated"
    env HOME="$home" FORGESWEEP_FULL_DISK_AUTHORIZED=1 \
        bash -c 'source "$1"; nori_scan_path_allowed "$HOME/Documents"' \
        _ "$helper" || fail "authorized protected root was rejected"

    output=$(env HOME="$home" TMPDIR="$TEST_ROOT" \
        bash "$RUNTIME_DIR/bin/app_installer_scan.sh") || \
        fail "permission-filtered installer scan failed"
    [[ "$output" == *"$safe_installer"* ]] || \
        fail "installer scan dropped an unprotected root"
    [[ "$output" != *"$protected_installer"* ]] || \
        fail "installer scan entered Downloads without authorization"
    output=$(env HOME="$home" TMPDIR="$TEST_ROOT" FORGESWEEP_FULL_DISK_AUTHORIZED=1 \
        bash "$RUNTIME_DIR/bin/app_installer_scan.sh") || \
        fail "authorized installer scan failed"
    [[ "$output" == *"$protected_installer"* ]] || \
        fail "authorized installer scan did not include Downloads"

    for scanner in app_dup_scan.sh app_env_scan.sh app_installer_scan.sh; do
        /usr/bin/grep -Fq 'app_scan_access.sh' "$ROOT_DIR/bridge/$scanner" || \
            fail "$scanner bypasses the shared protected-path boundary"
    done
    pass "protected scan roots fail closed until Full Disk Access is verified"
}

test_signing_policy_contract() {
    local package_script="$ROOT_DIR/script/package_dmg.sh"
    /usr/bin/grep -Fq 'SM_ALLOW_ADHOC' "$ROOT_DIR/script/build.sh" || \
        fail "build does not require an explicit ad-hoc opt-in"
    /usr/bin/grep -Fq 'Apple Development:' "$ROOT_DIR/script/build.sh" || \
        fail "build does not prefer a stable Apple Development identity"
    /usr/bin/grep -Fq 'Ad-hoc GUI builds do not provide a stable identity' \
        "$ROOT_DIR/script/build.sh" || fail "build does not explain TCC identity persistence"
    /usr/bin/grep -Fq 'TeamIdentifier' "$ROOT_DIR/script/build.sh" || \
        fail "build does not validate its stable signing team"
    /usr/bin/grep -Fq 'Developer ID Application certificate' "$ROOT_DIR/script/release.sh" || \
        fail "release accepts a non-Developer-ID signing identity"
    /usr/bin/grep -Fq 'SM_ALLOW_ADHOC=0' "$ROOT_DIR/script/release.sh" || \
        fail "release can opt into ad-hoc signing"
    /usr/bin/grep -Fq 'SM_ALLOW_ADHOC="${SM_ALLOW_ADHOC:-0}"' \
        "$ROOT_DIR/script/build_and_run.sh" || \
        fail "build_and_run does not preserve the explicit signing policy"
    [[ -f "$package_script" ]] || fail "open-source DMG packaging script is missing"
    /usr/bin/grep -Fq 'SIGN_IDENTITY="${SM_CODESIGN_IDENTITY:-}"' \
        "$package_script" || fail "DMG packaging overrides stable signing identity selection"
    /usr/bin/grep -Fq 'ALLOW_ADHOC="${SM_ALLOW_ADHOC:-0}"' \
        "$package_script" || fail "DMG packaging enables ad-hoc signing without explicit opt-in"
    /usr/bin/grep -Fq 'SM_CODESIGN_IDENTITY="$SIGN_IDENTITY"' \
        "$package_script" || fail "DMG packaging does not forward the requested signing identity"
    /usr/bin/grep -Fq 'SM_ALLOW_ADHOC="$ALLOW_ADHOC"' \
        "$package_script" || fail "DMG packaging does not preserve the ad-hoc opt-in"
    /usr/bin/grep -Fq '/usr/bin/hdiutil create' "$package_script" || \
        fail "DMG packaging does not create a disk image"
    pass "stable development signing and Developer ID release contracts"
}

# 本地自签名身份：授权绑定签名的指定要求，ad-hoc 每次构建都变；
# 没有 Apple 证书时必须能落到稳定的本地身份，而不是静默退回 ad-hoc。
test_local_signing_identity() {
    local build_script="$ROOT_DIR/script/build.sh"
    local identity_script="$ROOT_DIR/script/dev_identity.sh"
    local desktop_script="$ROOT_DIR/script/package_dmg_to_desktop.sh"
    local resolved status

    [[ -x "$identity_script" ]] || fail "dev_identity.sh is missing or not executable"
    /usr/bin/grep -Fq 'extendedKeyUsage = critical, codeSigning' "$identity_script" || \
        fail "dev_identity.sh does not mark the certificate for code signing"
    /usr/bin/grep -Fq -- '-T /usr/bin/codesign' "$identity_script" || \
        fail "dev_identity.sh does not grant codesign access to the private key"
    /usr/bin/grep -Fq 'add-trusted-cert -r trustRoot -p codeSign' "$identity_script" || \
        fail "dev_identity.sh does not trust the certificate for code signing"
    /usr/bin/grep -Fq 'set-key-partition-list -S apple-tool:,apple:,codesign:' "$identity_script" || \
        fail "dev_identity.sh does not let codesign use the key without a prompt"
    /usr/bin/grep -Fq 'chmod 600 "$PASSWORD_FILE"' "$identity_script" || \
        fail "dev_identity.sh does not protect the keychain password file"
    /usr/bin/grep -Fq -- '--keychain "$LOCAL_SIGN_KEYCHAIN"' "$build_script" || \
        fail "build.sh does not sign through the dedicated local keychain"
    /usr/bin/grep -Fq 'mktemp -d' "$identity_script" || \
        fail "dev_identity.sh does not keep key material in a private temp dir"
    /usr/bin/grep -Fq 'rm -rf "$WORK"' "$identity_script" || \
        fail "dev_identity.sh does not clean up key material"

    # dry-run never touches the keychain and reports the missing identity.
    resolved=$(SM_DEV_IDENTITY_DRY_RUN=1 SM_LOCAL_SIGN_LABEL="Nori Test Missing $$" \
        bash "$identity_script" --ensure) || fail "dev_identity.sh --ensure dry-run failed"
    [[ "$resolved" == *"dry-run: would create"* ]] || fail "dev_identity.sh dry-run did not describe creation"
    status=0
    SM_LOCAL_SIGN_LABEL="Nori Test Missing $$" bash "$identity_script" --print >/dev/null 2>&1 || status=$?
    assert_status 3 "$status" "dev_identity.sh --print must fail when the identity is absent"

    # build.sh identity selection, driven by a canned find-identity listing.
    resolved=$(SM_BUILD_RESOLVE_ONLY=1 SM_TEST_SIGNING_IDENTITIES=$'  1) AAAA "Nori Local Signing"\n     1 valid identities found' \
        bash "$build_script" 2>/dev/null) || fail "build.sh rejected the local signing identity"
    [[ "$resolved" == *"kind=local"* ]] || fail "build.sh did not classify the local identity (got: $resolved)"
    [[ "$resolved" == *"identity=AAAA"* ]] || fail "build.sh must sign the local identity by hash (got: $resolved)"

    resolved=$(SM_BUILD_RESOLVE_ONLY=1 SM_TEST_SIGNING_IDENTITIES=$'  1) AAAA "Nori Local Signing"\n  2) BBBB "Apple Development: Dev (TEAM1)"\n     2 valid identities found' \
        bash "$build_script" 2>/dev/null) || fail "build.sh failed with Apple + local identities"
    [[ "$resolved" == *"kind=development"* ]] || fail "build.sh must prefer Apple Development over the local identity"

    status=0
    SM_BUILD_RESOLVE_ONLY=1 SM_TEST_SIGNING_IDENTITIES='     0 valid identities found' \
        bash "$build_script" >/dev/null 2>&1 || status=$?
    assert_status 2 "$status" "build.sh must refuse ad-hoc without SM_ALLOW_ADHOC=1"

    resolved=$(SM_BUILD_RESOLVE_ONLY=1 SM_ALLOW_ADHOC=1 SM_TEST_SIGNING_IDENTITIES='     0 valid identities found' \
        bash "$build_script" 2>/dev/null) || fail "build.sh ad-hoc opt-in failed"
    [[ "$resolved" == *"kind=adhoc"* ]] || fail "build.sh did not fall back to ad-hoc when allowed"

    /usr/bin/grep -Fq 'certificate (leaf|root) = H"' "$build_script" || \
        fail "build.sh does not verify the local identity pins its certificate"
    /usr/bin/grep -Fq 'dev_identity.sh" --ensure' "$desktop_script" || \
        fail "desktop packaging does not create the local identity before falling back to ad-hoc"

    # App side: signing diagnosis and the child-process preflight helper.
    /usr/bin/grep -Fq 'SecCodeCopyDesignatedRequirement' "$ROOT_DIR/SimpleMole/Services/SigningIdentityInspector.swift" || \
        fail "app does not read its designated requirement"
    /usr/bin/grep -Fq 'PermissionCenter.preflightArgument' "$ROOT_DIR/SimpleMole/main.swift" || \
        fail "main.swift does not handle the preflight helper mode"
    /usr/bin/grep -Fq 'NSApplication.shared' "$ROOT_DIR/SimpleMole/main.swift" || fail "main.swift lost NSApplication"
    local helper_line app_line
    helper_line=$(/usr/bin/grep -n 'PermissionCenter.preflightArgument' "$ROOT_DIR/SimpleMole/main.swift" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)
    app_line=$(/usr/bin/grep -n 'NSApplication.shared' "$ROOT_DIR/SimpleMole/main.swift" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)
    [[ "$helper_line" -lt "$app_line" ]] || fail "preflight helper must exit before NSApplication is created"
    /usr/bin/grep -Fq '/usr/bin/tccutil' "$ROOT_DIR/SimpleMole/Services/PermissionCenter.swift" || \
        fail "permission center has no stale-grant repair"
    /usr/bin/grep -Fq 'PermissionCenter.preflightReport()' "$ROOT_DIR/SimpleMole/main.swift" || \
        fail "preflight helper does not report both permissions"
    /usr/bin/grep -Fq 'fullDiskNeedsRelaunch = (probe?.fullDiskAccess == true && !diskInProcess)' \
        "$ROOT_DIR/SimpleMole/Services/PermissionCenter.swift" || \
        fail "full disk access has no granted-but-needs-relaunch detection"
    /usr/bin/grep -Fq 'permissions.disk.needsRelaunch' "$ROOT_DIR/SimpleMole/Views/PermissionCenterView.swift" || \
        fail "permission center does not offer a restart when full disk access is granted at the system level"
    /usr/bin/grep -Fq 'Library/Logs/Nori' "$APP_STATE_CONTRACT_SOURCE" || \
        fail "relaunch helper still logs to a world-writable /tmp path"
    if /usr/bin/grep -Fq '/tmp/nori-relaunch.log' "$APP_STATE_CONTRACT_SOURCE"; then
        fail "relaunch helper still logs to /tmp"
    fi
    pass "local self-signed identity, build selection and permission self-healing contracts"
}

test_screenshot_presets() {
    if [[ "${SM_TEST_SKIP_SWIFT:-0}" == "1" ]]; then
        printf 'ok - screenshot presets skipped (SM_TEST_SKIP_SWIFT=1)\n'
        return
    fi
    local editor="$ROOT_DIR/SimpleMole/Views/ScreenshotEditorView.swift"
    /usr/bin/grep -Fq 'PresetFrameView(composition: composition, contentSize: exportSize)' "$editor" || \
        fail "screenshot export does not render the selected preset at full resolution"
    /usr/bin/grep -Fq 'renderer.scale = CGFloat(exportOptions.scale.rawValue)' "$editor" || \
        fail "screenshot export ignores the 1x/2x option"
    /usr/bin/grep -Fq 'NSSavePanel()' "$editor" || fail "screenshot editor has no Save As"
    /usr/bin/grep -Fq 'forType: .png' "$editor" || \
        fail "clipboard copy does not include a PNG representation (transparent presets turn black)"
    local arch binary
    arch="$(uname -m)"
    binary="$TEST_ROOT/screenshot-preset-tests"
    mkdir -p "$TEST_ROOT/screenshot-module-cache"
    swiftc -target "$arch-apple-macos13.0" \
        -module-cache-path "$TEST_ROOT/screenshot-module-cache" \
        -framework AppKit \
        "$ROOT_DIR/SimpleMole/Services/ScreenshotPreset.swift" \
        "$ROOT_DIR/script/ScreenshotPresetTests.swift" \
        -o "$binary" || fail "screenshot preset tests compile"
    "$binary" || fail "screenshot preset layout, preferences and export encoding"
    pass "screenshot presets: layout per aspect, preferences round-trip, PNG/JPEG export"
    bash "$ROOT_DIR/script/test_screenshot_editor.sh" || fail "screenshot editor window reuse"
    pass "screenshot editor: repeated sessions, window geometry and preview bounds"
    bash "$ROOT_DIR/script/test_cleanup_presentation.sh" || fail "cleanup presentation layout"
    pass "cleanup presentation: real view states retain screen-constrained window geometry"
    bash "$ROOT_DIR/script/test_agent_presentation.sh" || fail "agent cleanup presentation layout"
    pass "agent cleanup presentation: inline results and aligned actions retain window geometry"
}

test_destructive_sinks() {
    bash "$ROOT_DIR/script/audit_destructive_sinks.sh" || \
        fail "destructive calls escaped the audited deletion sinks"
    pass "deletion funnel: Swift sinks allowlisted, bridge identity checks enforced"
}

test_theme_contract() {
    local theme="$ROOT_DIR/SimpleMole/Views/Theme.swift"
    local app_delegate="$ROOT_DIR/SimpleMole/AppDelegate.swift"
    [[ -f "$theme" ]] || fail "Views/Theme.swift is missing"
    /usr/bin/grep -Fq 'struct GlassSurface' "$theme" || fail "single-layer GlassSurface is missing"
    /usr/bin/grep -Fq 'NSGlassEffectView' "$theme" || fail "GlassSurface does not use Liquid Glass on macOS 26"
    # 单层玻璃：不能再在玻璃上叠实色层或渐变层，否则模糊/折射被盖住。
    if /usr/bin/grep -Fq 'LinearGradient' "$theme"; then
        fail "GlassSurface stacks a gradient over the glass"
    fi
    if /usr/bin/grep -Fq 'moleGlassBase.opacity' "$theme"; then
        fail "GlassSurface stacks a solid tint over the glass"
    fi
    if /usr/bin/grep -rFq 'DarkGlassSurface(' "$ROOT_DIR/SimpleMole" --include='*.swift'; then
        fail "views still use the old multi-layer DarkGlassSurface"
    fi
    if /usr/bin/grep -rFq '.preferredColorScheme(.dark)' "$ROOT_DIR/SimpleMole" --include='*.swift'; then
        fail "a view still forces dark mode instead of following the system appearance"
    fi
    if /usr/bin/grep -Fq 'NSAppearance(named: .darkAqua)' "$app_delegate"; then
        fail "windows still force the dark appearance"
    fi
    /usr/bin/grep -Fq 'static let accent = adaptive(' "$theme" || fail "accent token is not appearance-adaptive"
    /usr/bin/grep -Fq 'static let moleAccent = accent' "$theme" || fail "legacy moleAccent alias is missing"
    # 硬编码白色透明度已收敛为 surface/hairline token（截图编辑器导出用的固定色除外）。
    local hardcoded
    hardcoded=$(/usr/bin/grep -rF 'Color.white.opacity(' "$ROOT_DIR/SimpleMole/Views" --include='*.swift' \
        | /usr/bin/grep -v 'ScreenshotEditorView.swift' | /usr/bin/grep -v 'Theme.swift' | /usr/bin/wc -l | /usr/bin/tr -d ' ')
    [[ "$hardcoded" -le 6 ]] || fail "too many hardcoded white opacities remain in views ($hardcoded)"

    if [[ "${SM_TEST_SKIP_SWIFT:-0}" != "1" ]]; then
        local arch binary
        arch="$(uname -m)"
        binary="$TEST_ROOT/theme-contrast-tests"
        mkdir -p "$TEST_ROOT/theme-module-cache"
        swiftc -target "$arch-apple-macos13.0" \
            -module-cache-path "$TEST_ROOT/theme-module-cache" \
            -framework AppKit -framework SwiftUI \
            "$theme" "$ROOT_DIR/script/ThemeContrastTests.swift" \
            -o "$binary" || fail "theme contrast tests compile"
        "$binary" || fail "Earth Blue palette contrast"
    fi
    pass "Earth Blue theme: single-layer glass, system appearance, token convergence, WCAG contrast"
}

test_process_sampler() {
    local app_state="$APP_STATE_CONTRACT_SOURCE"
    local processes_view="$ROOT_DIR/SimpleMole/Views/ProcessesTabView.swift"
    /usr/bin/grep -Fq 'ProcessSampler.shared.sample()' "$app_state" || \
        fail "app-level process view still depends on ps text"
    /usr/bin/grep -Fq 'ProcessTerminator.terminateThenKill' "$app_state" || \
        fail "process actions do not escalate SIGTERM → SIGKILL through identity checks"
    /usr/bin/grep -Fq 'application.terminate()' "$app_state" || \
        fail "apps are not offered a graceful quit before force quit"
    /usr/bin/grep -Fq 'ports.status.readFailed' "$app_state" || \
        fail "port read failures are still shown as an empty list"
    /usr/bin/grep -Fq 'state.processSearch' "$processes_view" || fail "process list has no search"
    /usr/bin/grep -Fq 'state.processSort' "$processes_view" || fail "process list has no sort"
    /usr/bin/grep -Fq 'ProcessSparkline(' "$processes_view" || fail "process list has no trend line"
    /usr/bin/grep -Fq 'state.processAlerts' "$processes_view" || fail "high-usage alerts are not surfaced"
    if [[ "${SM_TEST_SKIP_SWIFT:-0}" == "1" ]]; then
        pass "process sampler contracts (Swift run skipped)"
        return
    fi
    local arch binary
    arch="$(uname -m)"
    binary="$TEST_ROOT/process-sampler-tests"
    mkdir -p "$TEST_ROOT/process-module-cache"
    swiftc -target "$arch-apple-macos13.0" \
        -module-cache-path "$TEST_ROOT/process-module-cache" \
        -framework AppKit -framework IOKit \
        "$ROOT_DIR/SimpleMole/Models.swift" \
        "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift" \
        "$ROOT_DIR/SimpleMole/Services/CleanupRiskPolicy.swift" \
        "$ROOT_DIR/SimpleMole/Services/DeveloperCacheLocator.swift" \
        "$ROOT_DIR/SimpleMole/Services/ProcessSampler.swift" \
        "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift" \
        "$ROOT_DIR/script/ProcessSamplerTests.swift" \
        -o "$binary" || fail "process sampler tests compile"
    "$binary" || fail "process sampler: live CPU deltas, tree aggregation, identity-bound termination"
    pass "process sampler: libproc sampling, grouping, alerts, identity-bound termination"
}

test_signing_identity_classification() {
    if [[ "${SM_TEST_SKIP_SWIFT:-0}" == "1" ]]; then
        printf 'ok - signing identity classification skipped (SM_TEST_SKIP_SWIFT=1)\n'
        return
    fi
    local arch binary
    arch="$(uname -m)"
    binary="$TEST_ROOT/signing-identity-tests"
    mkdir -p "$TEST_ROOT/signing-module-cache"
    swiftc -target "$arch-apple-macos13.0" \
        -module-cache-path "$TEST_ROOT/signing-module-cache" \
        -framework Security -framework AppKit -framework Combine \
        "$ROOT_DIR/SimpleMole/Services/SigningIdentityInspector.swift" \
        "$ROOT_DIR/SimpleMole/Services/PermissionCenter.swift" \
        "$ROOT_DIR/script/SigningIdentityTests.swift" \
        -o "$binary" || fail "signing identity tests compile"
    "$binary" || fail "signing identity classification / preflight protocol"
    pass "signing identity classification and permission preflight protocol"
}

test_gc_runner() {
    local home="$TEST_ROOT/gc-home"
    local stub_dir="$TEST_ROOT/gc-bin"
    local args_file="$TEST_ROOT/gc-args"
    local output rc args
    mkdir -p "$home" "$stub_dir"

    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'printf "%s\\0" "$@" > "$MOLE_TEST_ARGS_FILE"' \
        'exit "${MOLE_TEST_COMMAND_RC:-0}"' > "$stub_dir/go"
    chmod +x "$stub_dir/go"

    set +e
    output=$(env HOME="$home" PATH="$stub_dir:$PATH" \
        MOLE_TEST_ARGS_FILE="$args_file" MOLE_TEST_COMMAND_RC=0 \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_gc_run.sh" go-build 2>&1)
    rc=$?
    set -e
    assert_status 0 "$rc" "gc runner did not execute the whitelisted command"
    args=$(tr '\0' '\n' < "$args_file")
    [[ "$args" == $'clean\n-cache' ]] || fail "gc runner passed unexpected arguments: $args"

    set +e
    output=$(env HOME="$home" PATH="$stub_dir:$PATH" \
        MOLE_TEST_ARGS_FILE="$args_file" MOLE_TEST_COMMAND_RC=37 \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_gc_run.sh" go-build 2>&1)
    rc=$?
    set -e
    assert_status 37 "$rc" "gc runner did not preserve command exit status"

    set +e
    output=$(env HOME="$home" PATH="$stub_dir:$PATH" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_gc_run.sh" not-allowed 2>&1)
    rc=$?
    set -e
    assert_status 2 "$rc" "gc runner accepted an unknown command id"
    [[ "$output" == *"unknown gc id"* ]] || fail "gc runner did not explain unknown command rejection"
    pass "gc runner dispatch and exit status"
}

test_node_cache_inventory() {
    local home="$TEST_ROOT/node-cache-home"
    local stub_dir="$TEST_ROOT/node-cache-bin"
    local output id
    mkdir -p "$home/.npm/_cacache" "$home/Library/pnpm/store/v10" \
        "$home/.yarn/cache" "$stub_dir"
    printf 'npm-cache' > "$home/.npm/_cacache/index"
    printf 'pnpm-cache' > "$home/Library/pnpm/store/v10/index"
    printf 'yarn-cache' > "$home/.yarn/cache/index"
    for id in npm pnpm yarn; do
        printf '%s\n' \
            '#!/bin/sh' \
            'case "${0##*/}:$*" in' \
            '    "npm:config get cache") printf "%s\n" "$HOME/.npm" ;;' \
            '    "pnpm:store path") printf "%s\n" "$HOME/Library/pnpm/store" ;;' \
            '    "yarn:cache dir") printf "%s\n" "$HOME/.yarn/cache" ;;' \
            '    *) exit 2 ;;' \
            'esac' > "$stub_dir/$id"
        chmod +x "$stub_dir/$id"
    done

    output=$(env HOME="$home" PATH="$stub_dir:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$RUNTIME_DIR/bin/app_gc_scan.sh") || fail "node cache inventory failed"
    for id in npm pnpm yarn; do
        [[ "$(printf '%s\n' "$output" | awk -F '\t' -v id="$id" \
            '$1 == id { print (($3 + 0) > 0 ? "sized" : "empty"); exit }')" == "sized" ]] || \
            fail "$id shared cache size was not reported: $output"
    done
    pass "nvm global-package and Node shared-cache inventory"
}

test_runtime_store_aggregation() {
    local arch binary module_cache
    arch="$(uname -m)"
    binary="$TEST_ROOT/runtime-store-tests"
    module_cache="$TEST_ROOT/runtime-store-module-cache"
    mkdir -p "$module_cache"
    swiftc -target "$arch-apple-macos13.0" \
        -module-cache-path "$module_cache" \
        -framework AppKit -framework IOKit \
        "$ROOT_DIR/SimpleMole/Models.swift" \
        "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift" \
        "$ROOT_DIR/SimpleMole/Services/CleanupRiskPolicy.swift" \
        "$ROOT_DIR/SimpleMole/Services/DeveloperCacheLocator.swift" \
        "$ROOT_DIR/SimpleMole/Services/SystemMetrics.swift" \
        "$ROOT_DIR/SimpleMole/Services/SensorMetrics.swift" \
        "$ROOT_DIR/SimpleMole/Services/RuntimeStore.swift" \
        "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift" \
        "$ROOT_DIR/script/RuntimeStoreTests.swift" \
        -o "$binary" || fail "compile runtime store aggregation tests"
    "$binary" || fail "runtime store aggregation tests"
    pass "application-level CPU and memory aggregation"
}

assert_single_final_runtime_guard() {
    local home="$1"
    local script="$2"
    local target="$3"
    local label="$4"
    local plan="$TEST_ROOT/single-final-guard-plan"
    local guard_log="$TEST_ROOT/single-final-guard.log"
    local identity output

    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target") || \
        fail "$label fixture has no identity"
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    : > "$guard_log"
    output=$(env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_PROCESS_STATE=idle SIMPLEMOLE_DELETE_MODE=permanent \
        SIMPLEMOLE_TEST_FINAL_GUARD_LOG="$guard_log" \
        MOLE_DELETE_LOG="$TEST_ROOT/single-final-guard-deletions.log" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/$script" < "$plan") || \
        fail "$label rejected an idle target at its final deletion edge: $output"
    [[ ! -e "$target" && "$output" == *"removed=1"* && "$output" == *"failed=0"* ]] || \
        fail "$label did not complete through its final runtime guard: $output"
    [[ "$(wc -l < "$guard_log" | tr -d ' ')" == "1" ]] || \
        fail "$label repeated its runtime guard before the final deletion edge"
}

test_identity_bound_apply() {
    local home="$TEST_ROOT/apply-home"
    local trash="$TEST_ROOT/trash"
    local plan="$TEST_ROOT/apply-plan"
    local target identity stale_identity stale_mtime output rc
    mkdir -p "$home/Library/Caches/simple-mole-test" "$trash"

    target="$home/Library/Caches/simple-mole-test/current item.cache"
    printf 'current\n' > "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    output=$(env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_TRASH_DIR="$trash" MOLE_DELETE_LOG="$TEST_ROOT/deletions.log" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_apply.sh" < "$plan") || fail "identity-bound apply rejected a current identity"
    [[ ! -e "$target" ]] || fail "identity-bound apply left the approved target in place"
    [[ "$output" == *"removed=1"* && "$output" == *"failed=0"* ]] || \
        fail "identity-bound apply returned unexpected counters: $output"
    [[ -n "$(find "$trash" -mindepth 1 -print -quit)" ]] || \
        fail "cleanup bridge default no longer uses recoverable Trash"

    # Recommended Trash candidates are handled as top-level items only; the
    # final sink rejects database families even when a stale plan tries to
    # submit them as ordinary files.
    mkdir -p "$home/.Trash"
    target="$home/.Trash/old-recording.mov"
    printf 'recording\n' > "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    output=$(env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_PROCESS_STATE=idle MOLE_TEST_TRASH_DIR="$trash" \
        MOLE_DELETE_LOG="$TEST_ROOT/deletions.log" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_apply.sh" < "$plan") || \
        fail "Trash candidate was rejected at the final cleanup edge"
    [[ ! -e "$target" && "$output" == *"removed=1"* ]] || \
        fail "ordinary Trash candidate was not permanently removed"

    target="$home/.Trash/old-history.db"
    printf 'database\n' > "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    set +e
    output=$(env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_PROCESS_STATE=idle MOLE_TEST_TRASH_DIR="$trash" \
        MOLE_DELETE_LOG="$TEST_ROOT/deletions.log" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_apply.sh" < "$plan" 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target" && "$output" == *"failed=1"* ]] || \
        fail "Trash database candidate crossed the final safety guard"

    # Disk cleanup opts into permanent deletion explicitly. It must not create
    # a Trash copy, while the bridge default above remains recoverable.
    local permanent_trash="$TEST_ROOT/permanent-trash"
    mkdir -p "$permanent_trash"
    target="$home/Library/Caches/simple-mole-test/permanent item.cache"
    printf 'permanent\n' > "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    output=$(env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_PROCESS_STATE=idle SIMPLEMOLE_DELETE_MODE=permanent \
        MOLE_TEST_TRASH_DIR="$permanent_trash" MOLE_DELETE_LOG="$TEST_ROOT/deletions.log" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_apply.sh" < "$plan") || \
        fail "disk cleanup permanent mode rejected a valid target"
    [[ ! -e "$target" && -z "$(find "$permanent_trash" -mindepth 1 -print -quit)" ]] || \
        fail "disk cleanup permanent mode created a Trash copy"
    /usr/bin/grep -Fq $'\tpermanent\t' "$TEST_ROOT/deletions.log" || \
        fail "permanent cleanup was not recorded in the deletion audit log"

    target="$home/Library/Caches/simple-mole-test/invalid mode.cache"
    printf 'keep\n' > "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    set +e
    output=$(env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        SIMPLEMOLE_DELETE_MODE=unknown MO_TIMEOUT_INITIALIZED=1 \
        MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_apply.sh" < "$plan" 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target" && "$output" == *"invalid cleanup delete mode"* ]] || \
        fail "cleanup bridge accepted an invalid delete mode: $output"

    target="$home/Library/Caches/simple-mole-test/stale item.cache"
    printf 'stale\n' > "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    stale_mtime=$((${identity##*:} + 1))
    stale_identity="${identity%:*}:$stale_mtime"
    printf '%s\0%s\0' "$target" "$stale_identity" > "$plan"
    set +e
    output=$(env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_TRASH_DIR="$trash" MOLE_DELETE_LOG="$TEST_ROOT/deletions.log" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_apply.sh" < "$plan" 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 ]] || fail "identity-bound apply accepted a stale identity"
    [[ -e "$target" ]] || fail "identity-bound apply removed a stale-identity target"
    [[ "$output" == *"failed=1"* ]] || fail "stale identity was not reported as failed: $output"

    # A reverse-DNS cache owner is rechecked at the final deletion sink. Both
    # an active owner and an unavailable process snapshot must fail closed.
    target="$home/Library/Caches/com.example.Editor/active item.cache"
    mkdir -p "${target%/*}"
    printf 'active owner\n' > "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    set +e
    output=$(env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_PROCESS_STATE=active SIMPLEMOLE_DELETE_MODE=permanent \
        MOLE_TEST_TRASH_DIR="$trash" MOLE_DELETE_LOG="$TEST_ROOT/active-final-guard.log" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_apply.sh" < "$plan" 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target" && "$output" == *"failed=1"* ]] || \
        fail "generic cleanup ignored an active reverse-DNS cache owner: $output"
    /usr/bin/grep -Fq $'\tfinal-guard\t' "$TEST_ROOT/active-final-guard.log" || \
        fail "active owner was not rejected by the mutation-edge guard"

    set +e
    output=$(env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_PROCESS_STATE=unknown MOLE_TEST_TRASH_DIR="$trash" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_apply.sh" < "$plan" 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target" && "$output" == *"failed=1"* ]] || \
        fail "generic cleanup treated an unknown reverse-DNS owner as idle: $output"

    output=$(env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_PROCESS_STATE=idle MOLE_TEST_TRASH_DIR="$trash" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_apply.sh" < "$plan") || \
        fail "generic cleanup rejected a conclusively idle reverse-DNS cache owner"
    [[ ! -e "$target" && "$output" == *"removed=1"* ]] || \
        fail "generic cleanup did not remove an idle reverse-DNS cache: $output"

    # Use a non-bundle cache root here so Mole's independent live-bundle
    # policy does not require a real process table in the shell sandbox. The
    # route guard still exercises its path-open branch and is counted below.
    target="$home/Library/Caches/simple-guard-cache/rebuild.cache"
    mkdir -p "${target%/*}"
    printf 'single guard\n' > "$target"
    assert_single_final_runtime_guard "$home" app_apply.sh "$target" \
        "generic cleanup"

    target="$home/Library/Caches/com.example.ModelTool/rebuild-cache"
    mkdir -p "$target"
    printf 'model\n' > "$target/weights.safetensors"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    set +e
    output=$(env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        SIMPLEMOLE_EXECUTION_MODE=automatic MOLE_TEST_PROCESS_STATE=idle \
        MOLE_TEST_TRASH_DIR="$trash" MO_TIMEOUT_INITIALIZED=1 \
        MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_apply.sh" < "$plan" 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target/weights.safetensors" && \
       "$output" == *"failed=1"* ]] ||
        fail "automatic Quick Clean accepted a model nested in a Safe cache: $output"

    target="$home/Library/Caches/com.example.SessionTool/rebuild-cache"
    mkdir -p "$target/sessions"
    printf 'conversation\n' > "$target/sessions/current.json"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    set +e
    output=$(env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        SIMPLEMOLE_EXECUTION_MODE=quickClean MOLE_TEST_PROCESS_STATE=idle \
        MOLE_TEST_TRASH_DIR="$trash" MO_TIMEOUT_INITIALIZED=1 \
        MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_apply.sh" < "$plan" 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target/sessions/current.json" && \
       "$output" == *"failed=1"* ]] ||
        fail "automatic Quick Clean accepted a generic user-session directory: $output"

    target="$home/Library/DiagnosticReports/active.crash"
    mkdir -p "${target%/*}"
    printf 'diagnostic\n' > "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    set +e
    output=$(env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_PROCESS_STATE=active MOLE_TEST_TRASH_DIR="$trash" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_apply.sh" < "$plan" 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target" && "$output" == *"failed=1"* ]] ||
        fail "generic Warning cleanup ignored an open target: $output"
    pass "cleanup plan path and identity binding"
}

test_auto_cleanup_apply() {
    local home
    local trash="$TEST_ROOT/auto-trash"
    local plan="$TEST_ROOT/auto-plan"
    local root target identity stale_identity output rc actual link_target
    home="$(cd "$TEST_ROOT" && pwd -P)/auto-home"
    mkdir -p "$home/.config/mole" "$trash"

    run_auto_apply_fixture() {
        env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
            MOLE_TEST_LSOF_STATE=idle \
            MOLE_TEST_TRASH_DIR="$trash" MOLE_DELETE_LOG="$TEST_ROOT/auto-deletions.log" \
            MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
            bash "$RUNTIME_DIR/bin/app_auto_apply.sh" < "$plan"
    }

    write_auto_plan() {
        local plan_root="$1" plan_path="$2" plan_identity="$3"
        local plan_token="${4:-safe-trash-v4}"
        local newest=0 item item_mtime authorized_root_identity
        authorized_root_identity=$(/usr/bin/stat -f '%d:%i:%B' "$plan_root") || \
            fail "could not identify auto-cleanup rule root"
        if [[ -d "$plan_path" && ! -L "$plan_path" ]]; then
            while IFS= read -r -d '' item; do
                [[ "$item" == "$plan_path" || ! -L "$item" ]] || continue
                item_mtime=$(/usr/bin/stat -f '%m' "$item") || fail "could not stat auto-plan fixture"
                (( item_mtime > newest )) && newest="$item_mtime"
            done < <(/usr/bin/find -P "$plan_path" -xdev -print0)
        else
            newest=$(/usr/bin/stat -f '%m' "$plan_path") || fail "could not stat auto-plan fixture"
        fi
        printf '%s\0%s\0%s\0%s\0%s\0%s\0' \
            "$plan_root" "$authorized_root_identity" "$plan_path" \
            "$plan_identity" "$newest" "$plan_token" > "$plan"
    }

    # A current direct child reaches the final Trash deletion sink.
    root="$home/current-root"
    target="$root/current.cache"
    mkdir -p "$root"
    printf 'current\n' > "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    write_auto_plan "$root" "$target" "$identity"
    output=$(run_auto_apply_fixture) || fail "automatic cleanup rejected a current direct child"
    [[ ! -e "$target" && "$output" == *"removed=1"* && "$output" == *"failed=0"* ]] || \
        fail "automatic cleanup did not remove a current direct child: $output"

    # A nested descendant is outside the direct-child contract.
    root="$home/nested-root"
    target="$root/nested/item.cache"
    mkdir -p "${target%/*}"
    printf 'nested\n' > "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    write_auto_plan "$root" "$target" "$identity"
    set +e
    output=$(run_auto_apply_fixture 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target" && "$output" == *"failed=1"* ]] || \
        fail "automatic cleanup accepted a non-direct child: $output"

    # Preview/apply identity changes fail closed.
    root="$home/stale-root"
    target="$root/stale.cache"
    mkdir -p "$root"
    printf 'stale\n' > "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    stale_identity="${identity%:*}:$(( ${identity##*:} + 1 ))"
    write_auto_plan "$root" "$target" "$stale_identity"
    set +e
    output=$(run_auto_apply_fixture 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target" && "$output" == *"failed=1"* ]] || \
        fail "automatic cleanup accepted a stale identity: $output"

    # HOME itself can never become a disposable rule root.
    target="$home/home-child.cache"
    printf 'home\n' > "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    write_auto_plan "$home" "$target" "$identity"
    set +e
    output=$(run_auto_apply_fixture 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target" && "$output" == *"failed=1"* ]] || \
        fail "automatic cleanup accepted HOME as a rule root: $output"

    # The configured root itself must not be a symlink.
    actual="$home/actual-root"
    root="$home/root-link"
    target="$root/link-root-item.cache"
    mkdir -p "$actual"
    printf 'linked root\n' > "$actual/link-root-item.cache"
    ln -s "$actual" "$root"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    write_auto_plan "$root" "$target" "$identity"
    set +e
    output=$(run_auto_apply_fixture 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$actual/link-root-item.cache" && "$output" == *"failed=1"* ]] || \
        fail "automatic cleanup accepted a symlink rule root: $output"

    # Symlinks in any ancestor of the configured root are rejected too.
    actual="$home/actual-parent"
    root="$home/parent-link/managed"
    target="$root/ancestor-link-item.cache"
    mkdir -p "$actual/managed"
    printf 'linked ancestor\n' > "$actual/managed/ancestor-link-item.cache"
    ln -s "$actual" "$home/parent-link"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    write_auto_plan "$root" "$target" "$identity"
    set +e
    output=$(run_auto_apply_fixture 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$actual/managed/ancestor-link-item.cache" && \
        "$output" == *"failed=1"* ]] || \
        fail "automatic cleanup accepted a symlinked root ancestor: $output"

    # Whitelisted children are reported as skipped and kept.
    root="$home/whitelist-root"
    target="$root/keep.cache"
    mkdir -p "$root"
    printf 'keep\n' > "$target"
    printf '%s\n' "$target" > "$home/.config/mole/whitelist"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    write_auto_plan "$root" "$target" "$identity"
    output=$(run_auto_apply_fixture) || fail "automatic cleanup failed on a whitelisted child"
    [[ -e "$target" && "$output" == *"removed=0"* && \
        "$output" == *"skipped=1"* && "$output" == *"failed=0"* ]] || \
        fail "automatic cleanup did not preserve a whitelisted child: $output"

    # A direct symlink child is moved as a link; its target is never followed.
    root="$home/symlink-child-root"
    link_target="$home/symlink-target"
    target="$root/rebuildable-link"
    mkdir -p "$root" "$link_target"
    printf 'target data\n' > "$link_target/item"
    ln -s "$link_target" "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    write_auto_plan "$root" "$target" "$identity"
    output=$(run_auto_apply_fixture) || fail "automatic cleanup rejected a direct symlink child"
    [[ ! -L "$target" && -e "$link_target/item" && "$output" == *"removed=1"* ]] || \
        fail "automatic cleanup followed or retained a direct symlink child: $output"

    # Project/session/model markers make an otherwise authorized item Protected.
    root="$home/protected-content-root"
    target="$root/project-snapshot"
    mkdir -p "$target"
    printf '{}\n' > "$target/package.json"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    write_auto_plan "$root" "$target" "$identity"
    set +e
    output=$(run_auto_apply_fixture 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target/package.json" && "$output" == *"protected"* ]] || \
        fail "automatic cleanup accepted protected project content: $output"

    # Model payloads are protected even when their parent directory has a
    # generic cache name rather than a recognizable `models` component.
    root="$home/protected-model-root"
    target="$root/rebuild-cache"
    mkdir -p "$target"
    printf 'model\n' > "$target/weights.gguf"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    write_auto_plan "$root" "$target" "$identity"
    set +e
    output=$(run_auto_apply_fixture 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target/weights.gguf" && "$output" == *"protected model"* ]] || \
        fail "automatic cleanup accepted a model outside a named model directory: $output"

    root="$home/protected-session-root"
    target="$root/generic-cache"
    mkdir -p "$target/.gemini/tmp"
    printf 'session\n' > "$target/.gemini/tmp/history.jsonl"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    write_auto_plan "$root" "$target" "$identity"
    set +e
    output=$(run_auto_apply_fixture 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target/.gemini/tmp/history.jsonl" && \
        "$output" == *"session"* ]] || \
        fail "automatic cleanup accepted a Gemini user session: $output"

    # Running/open and unknown open-file states both fail closed.
    root="$home/open-root"
    target="$root/active.cache"
    mkdir -p "$root"
    printf 'active\n' > "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    write_auto_plan "$root" "$target" "$identity"
    set +e
    output=$(env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_LSOF_STATE=open MOLE_TEST_TRASH_DIR="$trash" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_auto_apply.sh" < "$plan" 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target" && "$output" == *"in use"* ]] || \
        fail "automatic cleanup accepted an open item: $output"

    set +e
    output=$(env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_LSOF_STATE=unknown MOLE_TEST_TRASH_DIR="$trash" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_auto_apply.sh" < "$plan" 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target" && "$output" == *"verify"* ]] || \
        fail "automatic cleanup accepted an unknown open-file state: $output"

    # Consent is bound to the directory object, not only its pathname.
    root="$home/replaced-authorization-root"
    target="$root/generated.cache"
    mkdir -p "$root"
    printf 'same candidate\n' > "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    write_auto_plan "$root" "$target" "$identity"
    mv "$target" "$home/generated.cache.staged"
    rmdir "$root"
    mkdir -p "$root"
    mv "$home/generated.cache.staged" "$target"
    set +e
    output=$(run_auto_apply_fixture 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target" && "$output" == *"changed after authorization"* ]] || \
        fail "automatic cleanup let a replacement root inherit authorization: $output"

    # A nested write may leave the top-level directory identity unchanged.
    # The recursive freshness token must still invalidate the plan.
    root="$home/freshness-root"
    target="$root/generated-output"
    mkdir -p "$target/nested"
    printf 'old\n' > "$target/nested/data.cache"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    write_auto_plan "$root" "$target" "$identity"
    /usr/bin/touch -t 203001010000 "$target/nested/data.cache"
    set +e
    output=$(run_auto_apply_fixture 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target/nested/data.cache" &&
        "$output" == *"changed after planning"* ]] || \
        fail "automatic cleanup ignored a nested write after planning: $output"

    # Old callers without the current Safe authorization token cannot execute.
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    write_auto_plan "$root" "$target" "$identity" safe-trash-v2
    set +e
    output=$(run_auto_apply_fixture 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target" && "$output" == *"renewed Safe authorization"* ]] || \
        fail "automatic cleanup accepted a stale safety authorization: $output"

    pass "automatic cleanup Safe, runtime, root, identity, whitelist and symlink guards"
}

test_installer_apply() {
    local home trash plan target identity output rc outside state trash_before
    home="$(cd "$TEST_ROOT" && pwd -P)/installer-home"
    trash="$TEST_ROOT/installer-trash"
    plan="$TEST_ROOT/installer-plan"
    mkdir -p "$home/.config/mole" "$home/Downloads" "$home/Desktop" "$trash"

    run_installer_apply_fixture() {
        local delete_mode="${1:-trash}" process_state="${2:-idle}"
        env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
            SIMPLEMOLE_DELETE_MODE="$delete_mode" MOLE_TEST_PROCESS_STATE="$process_state" \
            MOLE_TEST_TRASH_DIR="$trash" MOLE_DELETE_LOG="$TEST_ROOT/installer-deletions.log" \
            MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
            bash "$RUNTIME_DIR/bin/app_installer_apply.sh" < "$plan"
    }

    target="$home/Downloads/Tool.DMG"
    printf 'installer\n' > "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    output=$(run_installer_apply_fixture) || fail "installer apply rejected an allowed current file"
    [[ ! -e "$target" && "$output" == *"removed=1"* && "$output" == *"failed=0"* ]] || \
        fail "installer apply did not Trash an allowed file: $output"
    [[ "$(find "$trash" -type f | wc -l | tr -d ' ')" == "1" ]] || \
        fail "recoverable installer apply did not use the isolated Trash fixture"

    target="$home/Downloads/Permanent.pkg"
    printf 'permanent installer\n' > "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    trash_before=$(find "$trash" -type f | wc -l | tr -d ' ')
    output=$(run_installer_apply_fixture permanent) || \
        fail "permanent installer apply rejected an allowed current file: $output"
    [[ ! -e "$target" && "$output" == *"removed=1"* && "$output" == *"failed=0"* ]] || \
        fail "permanent installer apply did not delete the selected file: $output"
    [[ "$(find "$trash" -type f | wc -l | tr -d ' ')" == "$trash_before" ]] || \
        fail "permanent installer apply incorrectly moved the file to Trash"
    /usr/bin/grep -Fq $'\tpermanent\t' "$TEST_ROOT/installer-deletions.log" || \
        fail "permanent installer apply did not reach the permanent deletion sink"

    # A mounted/open installer, or an unavailable process snapshot, must stay
    # in place even after the user confirmed permanent deletion.
    for state in active unknown; do
        target="$home/Downloads/$state.dmg"
        printf '%s installer\n' "$state" > "$target"
        identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
        printf '%s\0%s\0' "$target" "$identity" > "$plan"
        set +e
        output=$(run_installer_apply_fixture permanent "$state" 2>&1)
        rc=$?
        set -e
        [[ "$rc" -eq 0 && -e "$target" && "$output" == *"removed=0"* && \
            "$output" == *"skipped=1"* && "$output" == *"failed=0"* ]] || \
            fail "permanent installer apply ignored $state runtime state: $output"
        [[ "$(find "$trash" -type f | wc -l | tr -d ' ')" == "$trash_before" ]] || \
            fail "runtime-protected installer was moved to Trash"
        /usr/bin/grep -F $'\tfinal-guard\t' "$TEST_ROOT/installer-deletions.log" | \
            /usr/bin/grep -Fq "$target" || \
            fail "$state installer was not protected at the final deletion edge"
    done

    outside="$home/not-allowed"
    target="$outside/Outside.dmg"
    mkdir -p "$outside"
    printf 'outside\n' > "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    set +e
    output=$(run_installer_apply_fixture permanent 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target" && "$output" == *"failed=1"* ]] || \
        fail "permanent installer apply accepted a file outside configured roots: $output"

    target="$home/Downloads/notes.txt"
    printf 'not an installer\n' > "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    set +e
    output=$(run_installer_apply_fixture 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target" && "$output" == *"failed=1"* ]] || \
        fail "installer apply accepted an unsupported extension: $output"

    target="$home/Downloads/plain.zip"
    printf 'not a zip archive\n' > "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    set +e
    output=$(run_installer_apply_fixture 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target" && "$output" == *"failed=1"* ]] || \
        fail "installer apply accepted a non-installer zip: $output"

    target="$home/Downloads/stale.pkg"
    printf 'stale\n' > "$target"
    identity=$(stale_identity_for "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    set +e
    output=$(run_installer_apply_fixture permanent 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target" && "$output" == *"failed=1"* ]] || \
        fail "permanent installer apply accepted a stale identity: $output"

    target="$home/Downloads/keep.xip"
    printf 'keep\n' > "$target"
    printf '%s\n' "$target" > "$home/.config/mole/whitelist"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    output=$(run_installer_apply_fixture permanent) || fail "installer apply failed on a whitelisted file"
    [[ -e "$target" && "$output" == *"skipped=1"* && "$output" == *"failed=0"* ]] || \
        fail "installer apply did not preserve a whitelisted file: $output"
    : > "$home/.config/mole/whitelist"

    target="$home/Downloads/link.dmg"
    printf 'target\n' > "$outside/link-target.dmg"
    ln -s "$outside/link-target.dmg" "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    set +e
    output=$(run_installer_apply_fixture permanent 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -L "$target" && -e "$outside/link-target.dmg" && \
        "$output" == *"failed=1"* ]] || \
        fail "installer apply accepted a symlink leaf: $output"

    mkdir -p "$home/Desktop" "$outside/escaped-parent"
    ln -s "$outside/escaped-parent" "$home/Desktop/escape"
    target="$home/Desktop/escape/Escaped.iso"
    printf 'escape\n' > "$outside/escaped-parent/Escaped.iso"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    set +e
    output=$(run_installer_apply_fixture permanent 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$outside/escaped-parent/Escaped.iso" && \
        "$output" == *"failed=1"* ]] || \
        fail "installer apply followed a symlinked ancestor outside its root: $output"

    pass "installer apply permanent/Trash modes, runtime, root, type, identity, whitelist and symlink guards"
}

test_packaged_apply_layout() {
    local home="$TEST_ROOT/layout-home"
    local output
    [[ -d "$ROOT_DIR/vendor/mole/lib" ]] || \
        fail "vendored bridge support libraries are incomplete"
    [[ -s "$ROOT_DIR/vendor/mole/LICENSE" && -s "$ROOT_DIR/vendor/mole/UPSTREAM_COMMIT" ]] || \
        fail "vendored Mole license or audited revision is missing"
    /usr/bin/grep -Fq 'MOLE_SRC="${MOLE_SRC:-$ROOT_DIR/vendor/mole}"' \
        "$ROOT_DIR/script/build.sh" || \
        fail "build still depends on an external sibling Mole checkout"
    mkdir -p "$home"

    output=$(env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_TRASH_DIR="$TEST_ROOT/layout-trash" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_installer_apply.sh" < /dev/null) || \
        fail "packaged installer apply could not load Mole libraries"
    [[ "$output" == *"failed=0"* ]] || fail "unexpected installer apply result: $output"
    pass "packaged apply resource layout"
}

stale_identity_for() {
    local identity
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$1") || return 1
    printf '%s:%s\n' "${identity%:*}" "$(( ${identity##*:} + 1 ))"
}

test_uninstall_space_breakdown() {
    local native_core="$ROOT_DIR/SimpleMole/Services/NativeCore.swift"
    /usr/bin/grep -Fq 'bytes: directorySize(appURL), label: "app"' \
        "$ROOT_DIR/SimpleMole/Services/UninstallPlanningService.swift" || fail "native uninstall plan does not size the app bundle separately"
    /usr/bin/grep -q 'uninstall.action' "$ROOT_DIR/SimpleMole/Views/UninstallTabView.swift" || \
        fail "uninstall list action is not wired to the uninstall label"
    /usr/bin/grep -Fq 'return matches.sorted' "$ROOT_DIR/SimpleMole/Services/UninstallListProjection.swift" || \
        fail "uninstall list is not sorted by estimated reclaimable bytes"
    /usr/bin/grep -Fq 'scheduler: uninstallPresentationQueue' "$APP_STATE_CONTRACT_SOURCE" || \
        fail "uninstall list sorting is not moved off the UI actor"
    /usr/bin/grep -Fq 'let space: UninstallSpaceBreakdown' "$ROOT_DIR/SimpleMole/Models.swift" || \
        fail "uninstall space is still recomputed during rendering"
    /usr/bin/grep -Fq '.task(id: isActive)' "$ROOT_DIR/SimpleMole/Views/UninstallTabView.swift" || \
        fail "uninstall loading is not cancelled on navigation"
    if /usr/bin/grep -Fq 'NSWorkspace.shared.icon(forFile:' "$ROOT_DIR/SimpleMole/Views/UninstallTabView.swift"; then
        fail "uninstall icon lookup still runs inside the SwiftUI task"
    fi
    /usr/bin/grep -Fq 'UninstallFileDrawer(files: plan.files,' \
        "$ROOT_DIR/SimpleMole/Views/UninstallTabView.swift" || \
        fail "uninstall details are not available as an inline drawer"
    /usr/bin/grep -Fq 'onUninstall: { state.previewUninstall(app) }' \
        "$ROOT_DIR/SimpleMole/Views/UninstallTabView.swift" || \
        fail "first-level uninstall action is not wired directly"
    if /usr/bin/grep -Fq 'UninstallDetailView' "$ROOT_DIR/SimpleMole/Views/UninstallTabView.swift"; then
        fail "obsolete second-level uninstall page still exists"
    fi
    if /usr/bin/grep -q 'uninstall.preview"' "$ROOT_DIR/SimpleMole/Views/UninstallTabView.swift"; then
        fail "uninstall list still exposes the preview label"
    fi
    /usr/bin/grep -Fq 'NativeCore.shared.scanInstalledApps' "$APP_STATE_CONTRACT_SOURCE" || \
        fail "AppState does not use the native app inventory"
    /usr/bin/grep -Fq 'startUninstallInventoryMonitoring(includeProtectedPaths: false)' "$APP_STATE_CONTRACT_SOURCE" || \
        fail "external installs and uninstalls do not trigger an inventory refresh"
    /usr/bin/grep -Fq 'startUninstallInventoryMonitoring(includeProtectedPaths: true)' "$APP_STATE_CONTRACT_SOURCE" || \
        fail "Trash inventory monitoring is not activated after Full Disk Access"
    /usr/bin/grep -Fq 'uninstallInventoryWatchedPaths.contains(path)' "$APP_STATE_CONTRACT_SOURCE" || \
        fail "inventory filesystem watchers are not idempotent"
    /usr/bin/grep -Fq 'UninstallInventoryCache.restoreInBackground()' "$APP_STATE_CONTRACT_SOURCE" || \
        fail "uninstall inventory is not restored across app launches"
    /usr/bin/grep -Fq 'withTaskGroup' "$APP_STATE_CONTRACT_SOURCE" || \
        fail "new and changed apps are not enriched in bounded background batches"
    /usr/bin/grep -Fq 'DeletionPlan.identity(at: app.path + "/Contents/Info.plist") == app.infoIdentity' \
        "$native_core" || fail "native uninstall does not bind the app Info.plist identity"
    /usr/bin/grep -Fq 'candidate.path != appURL.path' "$ROOT_DIR/SimpleMole/Services/UninstallPlanningService.swift" || \
        fail "native uninstall does not protect same-Bundle-ID sibling installs"
    /usr/bin/grep -Fq 'files.append(contentsOf: relatedUninstallCandidates(' "$ROOT_DIR/SimpleMole/Services/UninstallPlanningService.swift" || \
        fail "native uninstall does not build an exact related-file plan"

    local key copy_count
    for key in uninstall.action uninstall.space.cache uninstall.space.data uninstall.loading; do
        copy_count=$(/usr/bin/grep -h "\"$key\":" \
            "$ROOT_DIR"/SimpleMole/L10n/Tables*.swift | /usr/bin/wc -l | tr -d ' ')
        [[ "$copy_count" == "12" ]] || \
            fail "$key is missing from a locale ($copy_count/12)"
    done

    if [[ "${SM_TEST_SKIP_SWIFT:-0}" != "1" ]]; then
        local arch binary module_cache
        arch="$(uname -m)"
        binary="$TEST_ROOT/uninstall-space-tests"
        module_cache="$TEST_ROOT/uninstall-space-module-cache"
        mkdir -p "$module_cache"
        swiftc -target "$arch-apple-macos13.0" \
            -module-cache-path "$module_cache" \
            "$ROOT_DIR/SimpleMole/Models.swift" \
            "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift" \
            "$ROOT_DIR/SimpleMole/Services/CleanupRiskPolicy.swift" \
            "$ROOT_DIR/SimpleMole/Services/DeveloperCacheLocator.swift" \
            "$ROOT_DIR/SimpleMole/Services/UninstallInventoryCache.swift" \
            "$ROOT_DIR/SimpleMole/Services/UninstallListProjection.swift" \
            "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift" \
            "$ROOT_DIR/script/UninstallSpaceTests.swift" \
            -o "$binary" || fail "compile uninstall space tests"
        "$binary" || fail "uninstall space tests"
    fi

    pass "uninstall action, non-overlapping space breakdown and locale contract"
}

test_native_cask_uninstall_contract() {
    local native_core="$ROOT_DIR/SimpleMole/Services/NativeCore.swift"
    /usr/bin/grep -Fq 'private func nativeBrewCaskToken(for app: UninstallApp)' \
        "$ROOT_DIR/SimpleMole/Services/UninstallPlanningService.swift" || fail "native uninstall does not resolve Homebrew casks"
    /usr/bin/grep -Fq 'runCommand(brew, ["uninstall", "--cask", "--force", plan.caskToken])' \
        "$native_core" || fail "native cask uninstall does not use the reviewed token"
    /usr/bin/grep -Fq 'result.removed + 1' "$native_core" || \
        fail "native cask uninstall does not count an app removed by Homebrew"
    /usr/bin/grep -Fq '^[A-Za-z0-9@._+/-]+$' "$native_core" || \
        fail "native cask uninstall does not validate the token"
    if /usr/bin/sed -n '/func applyUninstall(/,/\/\/ MARK: Optimize/p' \
        "$native_core" | /usr/bin/grep -q 'autoremove'; then
        fail "native cask uninstall runs unreviewed brew autoremove"
    fi
    /usr/bin/sed -n '/func previewUninstall(_ app:/,/func uninstallJob(for app:/p' \
        "$APP_STATE_CONTRACT_SOURCE" | /usr/bin/grep -q 'confirmation = Confirmation' || \
        fail "uninstall action must confirm removal and forced process shutdown"
    pass "native Homebrew cask discovery, token validation and uninstall"
}

test_uninstall_queue() {
    local state_source="$APP_STATE_CONTRACT_SOURCE"
    local view_source="$ROOT_DIR/SimpleMole/Views/UninstallTabView.swift"
    if /usr/bin/grep -Eq 'isDisabled: state\.(isUninstalling|isPreviewingUninstall)|disabled\(state\.isUninstalling' \
        "$view_source"; then
        fail "one uninstall still disables every application row"
    fi
    /usr/bin/grep -Fq 'job.state.isPending || job.state.isActive' "$view_source" || \
        fail "uninstall row does not render the current app queue state"
    /usr/bin/grep -Fq 'state.cancelQueuedUninstall(id: job.id)' "$view_source" || \
        fail "pending uninstall cancellation is not exposed in the UI"
    /usr/bin/grep -Fq 'uninstallQueue.enqueue(app: app, plan: plan, dataPaths: dataPaths)' "$state_source" || \
        fail "uninstall confirmation does not enqueue its captured request"
    /usr/bin/grep -Fq 'let target = job.app' "$state_source" || \
        fail "uninstall worker does not use the queued application identity"
    /usr/bin/grep -Fq 'uninstallExecutor.execute(job)' "$state_source" && \
        /usr/bin/grep -Fq 'dependencies.apply(app, plan, includingData, appAlreadyRemoved)' "$ROOT_DIR/SimpleMole/Services/UninstallWorkflow.swift" || \
        fail "uninstall worker does not pass the captured request to its scoped executor"
    if /usr/bin/grep -Eq 'var uninstall(Target|Files|NeedsAdmin|IsBrewCask|CaskToken|IncludesProtectedAppData)' \
        "$state_source"; then
        fail "mutable row selection can still overwrite a queued uninstall request"
    fi
    /usr/bin/grep -Fq 'uninstallQueue.startNext(blocked: blocked)' "$state_source" || \
        fail "uninstall worker bypasses the queue's exclusive start"
    /usr/bin/grep -Fq 'isUninstallMutationBlocked || confirmation != nil || isDispatchingConfirmation' \
        "$state_source" || fail "uninstall worker is not gated against other writes and confirmations"
    /usr/bin/grep -Fq 'state.runConfirmation(accepted)' \
        "$ROOT_DIR/SimpleMole/Views/MainWindowView.swift" || \
        fail "confirmation dispatch bypasses the asynchronous operation gate"
    /usr/bin/grep -Fq 'guard !isStoppingUninstallQueue, !blocked,' "$state_source" || \
        fail "queue wakeups can start another uninstall while the app is terminating"
    /usr/bin/awk '
        /func applicationWillTerminate/ { inside = 1 }
        inside && /stopUninstallQueueForTermination/ { stopped = 1 }
        inside && /MoleEngine.shared.cancelAll/ {
            if (!stopped) exit 1
            found = 1
            exit
        }
        END { if (!found) exit 1 }
    ' "$ROOT_DIR/SimpleMole/AppDelegate.swift" || \
        fail "app termination must close the queue before cancelling active subprocesses"
    /usr/bin/grep -Fq 'DeletionPlan.identity(at: app.path) == app.appIdentity' \
        "$ROOT_DIR/SimpleMole/Services/NativeCore.swift" || \
        fail "queued native uninstall no longer revalidates the app identity"
    /usr/bin/grep -Fq 'messages: result.messages + ["The application bundle was not removed."]' \
        "$ROOT_DIR/SimpleMole/Services/NativeCore.swift" || \
        fail "native uninstall can report success while the app bundle still exists"

    if [[ "${SM_TEST_SKIP_SWIFT:-0}" != "1" ]]; then
        local arch binary module_cache
        arch="$(uname -m)"
        binary="$TEST_ROOT/uninstall-queue-tests"
        module_cache="$TEST_ROOT/uninstall-queue-module-cache"
        mkdir -p "$module_cache"
        swiftc -target "$arch-apple-macos13.0" \
            -module-cache-path "$module_cache" \
            "$ROOT_DIR/SimpleMole/Models.swift" \
            "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift" \
            "$ROOT_DIR/SimpleMole/Services/CleanupRiskPolicy.swift" \
            "$ROOT_DIR/SimpleMole/Services/DeveloperCacheLocator.swift" \
            "$ROOT_DIR/SimpleMole/Services/UninstallQueue.swift" \
            "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift" \
            "$ROOT_DIR/script/UninstallQueueTests.swift" \
            -o "$binary" || fail "compile uninstall queue tests"
        "$binary" || fail "uninstall queue tests"
    fi

    pass "uninstall FIFO, immutable requests, cancellation and asynchronous single worker"
}

test_task_activity() {
    bash "$ROOT_DIR/script/test_task_activity.sh" || fail "independent page task activity"
    pass "independent page activity and overlapping deletion guards"
}

test_cleanup_process_probe_batching() {
    # shellcheck disable=SC1090
    source "$RUNTIME_DIR/lib/core/common.sh"
    # shellcheck disable=SC1090
    source "$RUNTIME_DIR/bin/app_runtime_guard.sh"

    local pgrep_calls=0 pgrep_pattern="" state=0
    pgrep() {
        pgrep_calls=$((pgrep_calls + 1))
        pgrep_pattern="${2:-}"
        return 1
    }

    MOLE_TEST_MODE=0 simplemole_any_process_state \
        node beam.smp "Google Chrome" 'tool+worker' || state=$?
    unset -f pgrep

    [[ "$state" -eq 1 ]] || fail "batched process probe did not report idle"
    [[ "$pgrep_calls" -eq 1 ]] || \
        fail "process guard launched pgrep $pgrep_calls times instead of once"
    [[ "$pgrep_pattern" == 'node|beam\.smp|Google Chrome|tool\+worker' ]] || \
        fail "process guard did not escape its combined pgrep pattern: $pgrep_pattern"

    local stub_dir="$TEST_ROOT/cleanup-runtime-stubs"
    local candidate="$TEST_ROOT/cleanup-runtime-target"
    local idle_candidate="$TEST_ROOT/cleanup-runtime-idle"
    local lsof_args="$TEST_ROOT/cleanup-runtime-lsof.args"
    local previous_path="$PATH"
    mkdir -p "$stub_dir" "$candidate" "$idle_candidate"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'printf "%s\n" "$*" >> "$SM_TEST_LSOF_ARGS"' \
        'if [[ "${SM_TEST_LSOF_ERROR:-0}" == "1" ]]; then printf "denied\n" >&2; exit 1; fi' \
        'printf "p1\nn%s/unrelated\np2\nn%s/open-file\n" "$SM_TEST_UNRELATED" "$SM_TEST_OPEN_ROOT"' \
        > "$stub_dir/lsof"
    chmod +x "$stub_dir/lsof"
    export PATH="$stub_dir:/usr/bin:/bin:/usr/sbin:/sbin"
    export SM_TEST_LSOF_ARGS="$lsof_args"
    export SM_TEST_UNRELATED="$TEST_ROOT/unrelated"
    export SM_TEST_OPEN_ROOT="$candidate"
    export SM_TEST_LSOF_ERROR=0
    : > "$lsof_args"

    state=0
    MOLE_TEST_MODE=0 simplemole_path_open_state "$candidate" || state=$?
    [[ "$state" -eq 0 ]] || fail "global lsof snapshot missed an open cleanup path"
    [[ "$(< "$lsof_args")" == '-nP -Fpn' ]] || \
        fail "cleanup path guard still uses recursive lsof: $(< "$lsof_args")"

    state=0
    MOLE_TEST_MODE=0 simplemole_path_open_state "$idle_candidate" || state=$?
    [[ "$state" -eq 1 ]] || fail "global lsof snapshot did not report an idle cleanup path"
    [[ "$(wc -l < "$lsof_args" | tr -d ' ')" -eq 1 ]] || \
        fail "cleanup path guard launched more than one lsof snapshot per batch"

    export SM_TEST_LSOF_ERROR=1
    SIMPLEMOLE_OPEN_SNAPSHOT_STATE="unprepared"
    SIMPLEMOLE_OPEN_SNAPSHOT_FILE=""
    : > "$lsof_args"
    state=0
    MOLE_TEST_MODE=0 simplemole_path_open_state "$candidate" || state=$?
    [[ "$state" -eq 2 ]] || fail "cleanup path guard did not fail closed on lsof error"

    PATH="$previous_path"
    unset SM_TEST_LSOF_ARGS SM_TEST_UNRELATED SM_TEST_OPEN_ROOT SM_TEST_LSOF_ERROR
    pass "cleanup guards batch process and open-file probes without recursive lsof"
}

test_runtime_process_identity_binding() {
    local stub_dir="$TEST_ROOT/runtime-stubs"
    local signal_log="$TEST_ROOT/runtime-signals.log"
    local start="Wed_Aug_27_12:34:56_2026"
    local current_uid output rc
    current_uid="$(id -u)"
    mkdir -p "$stub_dir"

    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'if [[ "$1" == "-axo" ]]; then' \
        '    case "$2" in' \
        '        pid=,ppid=,uid=,lstart=,state=,etime=,pcpu=,pmem=,comm=,args=)' \
        '            printf "4321 4100 %s Wed Aug 27 12:34:56 2026 S 00:10 1.2 0.3 /tmp/tool /tmp/tool --serve\\n" "${MOLE_TEST_UID}"' \
        '            ;;' \
        '        pid=,ppid=)' \
        '            [[ "${MOLE_TEST_TREE_PROBE_FAIL:-0}" != "1" ]] || exit 2' \
        '            printf "4100 1\\n4321 4100\\n4322 4321\\n"' \
        '            ;;' \
        '    esac' \
        'elif [[ "$1" == "-p" ]]; then' \
        '    pid="$2"' \
        '    second=56; ppid=4100; uid="${MOLE_TEST_STALE_UID:-${MOLE_TEST_UID}}"' \
        '    state="${MOLE_TEST_STALE_STATE:-S}"; comm="${MOLE_TEST_STALE_COMM:-/tmp/tool}"' \
        '    signal_count=0' \
        '    [[ -f "${MOLE_TEST_SIGNAL_LOG}" ]] && signal_count=$(wc -l < "${MOLE_TEST_SIGNAL_LOG}" | tr -d " ")' \
        '    if [[ "$pid" == "4100" ]]; then' \
        '        second=54; ppid=1; state=S; comm=/Applications/Parent.app/Contents/MacOS/Parent' \
        '    elif [[ "$pid" == "4322" ]]; then' \
        '        second=55; ppid=4321; state=S; comm=/tmp/child' \
        '    fi' \
        '    [[ "${MOLE_TEST_REUSED_PID:-}" == "$pid" ]] && second=57' \
        '    if [[ "$pid" == "4321" && "${MOLE_TEST_ZOMBIE_REAP:-0}" == "1" && "$signal_count" -ge 1 ]]; then exit 1; fi' \
        '    if [[ "$pid" == "4321" && "${MOLE_TEST_EXIT_AFTER_KILL:-0}" == "1" && "$signal_count" -ge 2 ]]; then exit 1; fi' \
        '    case "${4:-}" in' \
        '        lstart=) printf "Wed Aug 27 12:34:%s 2026\\n" "$second" ;;' \
        '        ppid=,uid=,lstart=,state=,comm=)' \
        '            printf "%s %s Wed Aug 27 12:34:%s 2026 %s %s\\n" "$ppid" "$uid" "$second" "$state" "$comm" ;;' \
        '    esac' \
        'fi' > "$stub_dir/ps"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        '[[ "${2:-}" == "Nori" && -n "${MOLE_TEST_FORGESWEEP_PID:-}" ]] && printf "%s\\n" "$MOLE_TEST_FORGESWEEP_PID"' \
        'exit 0' > "$stub_dir/pgrep"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'printf "%s\\n" "$*" >> "$MOLE_TEST_SIGNAL_LOG"' > "$stub_dir/kill"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'printf "p4321\\nctool\\nn127.0.0.1:8080\\n"' > "$stub_dir/lsof"
    chmod +x "$stub_dir/ps" "$stub_dir/pgrep" "$stub_dir/kill" "$stub_dir/lsof"

    run_runtime_fixture() {
        env MOLE_TEST_MODE=1 \
            MOLE_TEST_PS_BIN="$stub_dir/ps" \
            MOLE_TEST_PGREP_BIN="$stub_dir/pgrep" \
            MOLE_TEST_KILL_BIN="$stub_dir/kill" \
            MOLE_TEST_LSOF_BIN="$stub_dir/lsof" \
            MOLE_TEST_SIGNAL_LOG="$signal_log" \
            MOLE_TEST_UID="$current_uid" \
            MOLE_TEST_REUSED_PID="${MOLE_TEST_REUSED_PID:-}" \
            MOLE_TEST_FORGESWEEP_PID="${MOLE_TEST_FORGESWEEP_PID:-}" \
            MOLE_TEST_STALE_UID="${MOLE_TEST_STALE_UID:-}" \
            MOLE_TEST_STALE_STATE="${MOLE_TEST_STALE_STATE:-}" \
            MOLE_TEST_STALE_COMM="${MOLE_TEST_STALE_COMM:-}" \
            MOLE_TEST_ZOMBIE_REAP="${MOLE_TEST_ZOMBIE_REAP:-0}" \
            MOLE_TEST_EXIT_AFTER_KILL="${MOLE_TEST_EXIT_AFTER_KILL:-0}" \
            bash "$RUNTIME_DIR/bin/app_runtime.sh" "$@"
    }

    output=$(run_runtime_fixture processes) || fail "runtime process scan failed"
    [[ "$(printf '%s\n' "$output" | awk -F '\t' '$1 == 4321 {print $2 ":" $3 ":" $4 ":" $5 ":" $6 ":" $9}')" == \
        "4100:$current_uid:$start:S:00:10:/tmp/tool" ]] || \
        fail "runtime scan omitted the safe process schema: $output"
    output=$(run_runtime_fixture ports) || fail "runtime port scan failed"
    [[ "$(printf '%s\n' "$output" | awk -F '\t' '$1 == 8080 {print $2 ":" $3}')" == "4321:$start" ]] || \
        fail "runtime port scan omitted the stable process identity: $output"

    printf '' > "$signal_log"
    run_runtime_fixture kill-pid "4321|$start" >/dev/null || \
        fail "runtime kill-pid rejected a matching identity"
    [[ "$(sed -n '1p' "$signal_log")" == "-TERM 4321" ]] || \
        fail "runtime kill-pid did not signal the confirmed process"

    printf '' > "$signal_log"
    set +e
    output=$(MOLE_TEST_REUSED_PID=4321 run_runtime_fixture kill-pid "4321|$start" 2>&1)
    rc=$?
    set -e
    assert_status 4 "$rc" "runtime kill-pid accepted a reused PID"
    [[ ! -s "$signal_log" ]] || fail "runtime kill-pid signalled a reused PID"

    printf '' > "$signal_log"
    run_runtime_fixture kill-group "4321|$start" >/dev/null || \
        fail "runtime kill-group rejected a matching root identity"
    [[ "$(tr '\n' ' ' < "$signal_log")" == "-TERM 4322 -TERM 4321 " ]] || \
        fail "runtime kill-group did not signal the confirmed tree leaf-first"

    printf '' > "$signal_log"
    set +e
    output=$(MOLE_TEST_FORGESWEEP_PID=4322 run_runtime_fixture kill-group "4321|$start" 2>&1)
    rc=$?
    set -e
    assert_status 3 "$rc" "runtime kill-group accepted a tree containing Nori"
    [[ ! -s "$signal_log" ]] || fail "runtime kill-group signalled before self-protection completed"

    printf '' > "$signal_log"
    MOLE_TEST_STALE_STATE=Z MOLE_TEST_ZOMBIE_REAP=1 \
        run_runtime_fixture cleanup-stale "4321|$start|4100|$current_uid" >/dev/null || \
        fail "runtime cleanup-stale did not allow a safe zombie reap request"
    [[ "$(tr '\n' ' ' < "$signal_log")" == "-CHLD 4100 " ]] || \
        fail "runtime cleanup-stale signalled a zombie instead of notifying its parent"

    printf '' > "$signal_log"
    MOLE_TEST_STALE_STATE=Z MOLE_TEST_STALE_COMM='<defunct>' MOLE_TEST_ZOMBIE_REAP=1 \
        run_runtime_fixture cleanup-stale "4321|$start|4100|$current_uid" >/dev/null || \
        fail "runtime cleanup-stale rejected macOS defunct zombie output"
    [[ "$(tr '\n' ' ' < "$signal_log")" == "-CHLD 4100 " ]] || \
        fail "runtime cleanup-stale used an unsafe signal for defunct zombie output"

    printf '' > "$signal_log"
    set +e
    output=$(MOLE_TEST_STALE_STATE=Z run_runtime_fixture cleanup-stale \
        "4321|$start|4100|$current_uid" 2>&1)
    rc=$?
    set -e
    assert_status 6 "$rc" "runtime cleanup-stale did not report an unreaped zombie"
    [[ "$(tr '\n' ' ' < "$signal_log")" == "-CHLD 4100 " ]] || \
        fail "runtime cleanup-stale used a terminating signal for an unreaped zombie"

    printf '' > "$signal_log"
    MOLE_TEST_STALE_STATE=E MOLE_TEST_EXIT_AFTER_KILL=1 \
        run_runtime_fixture cleanup-stale "4321|$start|4100|$current_uid" >/dev/null || \
        fail "runtime cleanup-stale rejected a verified exiting process"
    [[ "$(tr '\n' ' ' < "$signal_log")" == "-TERM 4321 -KILL 4321 " ]] || \
        fail "runtime cleanup-stale did not escalate a persistent exiting process"

    assert_stale_rejected_without_signal() {
        local expected_status="$1" message="$2"
        shift 2
        printf '' > "$signal_log"
        set +e
        output=$(env "$@" bash "$RUNTIME_DIR/bin/app_runtime.sh" cleanup-stale \
            "4321|$start|4100|${MOLE_TEST_TOKEN_UID:-$current_uid}" 2>&1)
        rc=$?
        set -e
        assert_status "$expected_status" "$rc" "$message"
        [[ ! -s "$signal_log" ]] || fail "$message emitted a signal"
    }

    assert_stale_rejected_without_signal 5 "runtime cleanup-stale accepted a normal process" \
        MOLE_TEST_MODE=1 MOLE_TEST_PS_BIN="$stub_dir/ps" MOLE_TEST_PGREP_BIN="$stub_dir/pgrep" \
        MOLE_TEST_KILL_BIN="$stub_dir/kill" MOLE_TEST_SIGNAL_LOG="$signal_log" MOLE_TEST_UID="$current_uid" \
        MOLE_TEST_STALE_STATE=S

    MOLE_TEST_TOKEN_UID=$((current_uid + 1)) \
        assert_stale_rejected_without_signal 3 "runtime cleanup-stale accepted another user's process" \
        MOLE_TEST_MODE=1 MOLE_TEST_PS_BIN="$stub_dir/ps" MOLE_TEST_PGREP_BIN="$stub_dir/pgrep" \
        MOLE_TEST_KILL_BIN="$stub_dir/kill" MOLE_TEST_SIGNAL_LOG="$signal_log" MOLE_TEST_UID="$current_uid" \
        MOLE_TEST_STALE_UID=$((current_uid + 1)) MOLE_TEST_STALE_STATE=E
    unset MOLE_TEST_TOKEN_UID

    assert_stale_rejected_without_signal 3 "runtime cleanup-stale accepted a system executable" \
        MOLE_TEST_MODE=1 MOLE_TEST_PS_BIN="$stub_dir/ps" MOLE_TEST_PGREP_BIN="$stub_dir/pgrep" \
        MOLE_TEST_KILL_BIN="$stub_dir/kill" MOLE_TEST_SIGNAL_LOG="$signal_log" MOLE_TEST_UID="$current_uid" \
        MOLE_TEST_STALE_STATE=E MOLE_TEST_STALE_COMM=/System/Library/CoreServices/tool

    assert_stale_rejected_without_signal 3 "runtime cleanup-stale accepted a reused PID" \
        MOLE_TEST_MODE=1 MOLE_TEST_PS_BIN="$stub_dir/ps" MOLE_TEST_PGREP_BIN="$stub_dir/pgrep" \
        MOLE_TEST_KILL_BIN="$stub_dir/kill" MOLE_TEST_SIGNAL_LOG="$signal_log" MOLE_TEST_UID="$current_uid" \
        MOLE_TEST_STALE_STATE=E MOLE_TEST_REUSED_PID=4321

    assert_stale_rejected_without_signal 3 "runtime cleanup-stale accepted the Nori tree" \
        MOLE_TEST_MODE=1 MOLE_TEST_PS_BIN="$stub_dir/ps" MOLE_TEST_PGREP_BIN="$stub_dir/pgrep" \
        MOLE_TEST_KILL_BIN="$stub_dir/kill" MOLE_TEST_SIGNAL_LOG="$signal_log" MOLE_TEST_UID="$current_uid" \
        MOLE_TEST_STALE_STATE=E MOLE_TEST_FORGESWEEP_PID=4321

    assert_stale_rejected_without_signal 3 "runtime cleanup-stale ignored an unavailable self-tree probe" \
        MOLE_TEST_MODE=1 MOLE_TEST_PS_BIN="$stub_dir/ps" MOLE_TEST_PGREP_BIN="$stub_dir/pgrep" \
        MOLE_TEST_KILL_BIN="$stub_dir/kill" MOLE_TEST_SIGNAL_LOG="$signal_log" MOLE_TEST_UID="$current_uid" \
        MOLE_TEST_STALE_STATE=E MOLE_TEST_TREE_PROBE_FAIL=1

    pass "runtime PID binding, stale-state cleanup, and process-tree protection"
}

test_netmon_bridge() {
    local helper="$RUNTIME_DIR/bin/app_netmon.sh"
    local stub_dir="$TEST_ROOT/netmon-stub"
    local output rc
    mkdir -p "$stub_dir"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'printf "time\\tinterface\\tstate\\tbytes_in\\tbytes_out\\n"' \
        'printf "10:00:00.000001 launchd.1\\t\\t\\t0\\t0\\t0\\t0\\t0\\n"' \
        'printf "10:00:00.000002 Google Chrome Helper.123\\t\\t\\t100\\t200\\t0\\t0\\t0\\n"' \
        'printf "10:00:00.000003 kernel_task.0\\t\\t\\t9\\t9\\t0\\t0\\t0\\n"' \
        'printf "10:00:00.000004 weird.pidX\\t\\t\\t1\\t2\\n"' \
        'printf "10:00:00.000005 com.apple.WebKit.456\\t\\t\\t300\\t400\\n"' \
        'printf "10:00:00.000006 worker.2.789\\t\\t\\t500\\t600\\n"' \
        > "$stub_dir/nettop"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        '[[ " $* " == *" -FpcnP "* ]] || exit 2' \
        'printf "p1131\\ncD-Chat\\nf10\\nPTCP\\nn127.0.0.1:1->221.229.52.251:80\\n"' \
        'printf "p1138\\ncTencentMeeting\\nf20\\nPUDP\\nn[fe80::1]:1->[2606:4700::1]:8080\\n"' \
        'printf "p999\\ncListener\\nf30\\nPTCP\\nn*:9090\\n"' \
        > "$stub_dir/lsof"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'if [[ "$1" == "-n" ]]; then shift; fi' \
        'if [[ "${1:-}" == "get" ]]; then' \
        '    address="${@: -1}"' \
        '    if [[ "$address" == "8.8.8.8" ]]; then printf "   interface: en0\\n"' \
        '    elif [[ "$address" == "2606:4700::1" ]]; then exit 0' \
        '    else printf "   interface: utun9\\n"; fi' \
        'fi' \
        > "$stub_dir/route"
    chmod +x "$stub_dir"/*

    output=$(env MOLE_TEST_MODE=1 MOLE_TEST_NETTOP_BIN="$stub_dir/nettop" \
        bash "$helper" bytes) || fail "netmon bytes mode failed"
    [[ "$output" == *"proc"$'\t'"123"$'\t'"100"$'\t'"200"$'\t'"Google Chrome Helper"* ]] || \
        fail "netmon bytes dropped the spaced process name: $output"
    [[ "$output" == *"proc"$'\t'"1"$'\t'"0"$'\t'"0"$'\t'"launchd"* ]] || \
        fail "netmon bytes dropped the pid-1 daemon row: $output"
    [[ "$output" != *"kernel_task"* && "$output" != *"weird"* ]] || \
        fail "netmon bytes accepted invalid pid rows: $output"
    [[ "$output" == *"proc"$'\t'"456"$'\t'"300"$'\t'"400"$'\t'"com.apple.WebKit"* ]] || \
        fail "netmon bytes dropped the dotted process name: $output"
    [[ "$output" == *"proc"$'\t'"789"$'\t'"500"$'\t'"600"$'\t'"worker.2"* ]] || \
        fail "netmon bytes used a process-name component as PID: $output"

    output=$(env MOLE_TEST_MODE=1 MOLE_TEST_LSOF_BIN="$stub_dir/lsof" \
        bash "$helper" flows) || fail "netmon flows mode failed"
    [[ "$output" == *"flow"$'\t'"1131"$'\t'"D-Chat"$'\t'"TCP"$'\t'"127.0.0.1:1"$'\t'"221.229.52.251:80"* ]] || \
        fail "netmon flows lost the connected TCP row: $output"
    [[ "$output" == *"UDP"$'\t'"[fe80::1]:1"$'\t'"[2606:4700::1]:8080"* ]] || \
        fail "netmon flows lost the UDP protocol or IPv6 endpoint: $output"
    [[ "$output" != *":9090"* ]] || fail "netmon flows kept a listener row: $output"

    output=$(printf '8.8.8.8\n2606:4700::1\nnot-an-ip\n10.0.0.1\n' \
        | env MOLE_TEST_MODE=1 MOLE_TEST_ROUTE_BIN="$stub_dir/route" \
            bash "$helper" routes) || fail "netmon routes mode failed"
    [[ "$output" == *"route"$'\t'"8.8.8.8"$'\t'"en0"* ]] || \
        fail "netmon routes missed the en0 lookup: $output"
    [[ "$output" == *"route"$'\t'"2606:4700::1"$'\t'"unknown"* ]] || \
        fail "netmon routes did not fail closed on unrouted v6: $output"
    [[ "$output" == *"route"$'\t'"10.0.0.1"$'\t'"utun9"* ]] || \
        fail "netmon routes missed the utun lookup: $output"
    [[ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" == "3" ]] || \
        fail "netmon routes accepted a non-address line: $output"

    set +e
    output=$(env MOLE_TEST_MODE=1 bash "$helper" bogus-mode 2>/dev/null)
    rc=$?
    set -e
    assert_status 2 "$rc" "netmon unknown mode did not fail closed"

    pass "netmon bridge byte, flow and route contracts"
}

test_dev_env_current_version_lock() {
    local home="$TEST_ROOT/env-home"
    local current="$home/.nvm/versions/node/v20.1.0"
    local old="$home/.nvm/versions/node/v18.2.0"
    local latest="$home/.nvm/versions/node/v22.3.0"
    local output
    mkdir -p "$current" "$old" "$latest" \
        "$home/.nvm/alias/lts" "$home/.nvm/alias/release"
    mkdir -p "$old/lib/node_modules/typescript"
    printf 'global package' > "$old/lib/node_modules/typescript/package.json"
    printf 'lts/krypton\n' > "$home/.nvm/alias/lts/*"
    printf 'v20.1.0\n' > "$home/.nvm/alias/lts/krypton"
    printf 'release/team\n' > "$home/.nvm/alias/work"
    printf 'lts/krypton\n' > "$home/.nvm/alias/release/team"

    assert_nvm_alias_locked() {
        local alias="$1" expected="$2" expected_path
        expected_path="$home/.nvm/versions/node/$expected"
        printf '%s\n' "$alias" > "$home/.nvm/alias/default"
        output=$(env HOME="$home" PATH=/usr/bin:/bin:/usr/sbin:/sbin MOLE_TEST_NVM_ONLY=1 \
            bash "$RUNTIME_DIR/bin/app_env_scan.sh") || fail "nvm alias scan failed for $alias"
        [[ "$(printf '%s\n' "$output" | awk -F '\t' -v path="$expected_path" \
            '$4 == path { count++; kind=$2 } END { print count ":" kind }')" == "1:current" ]] || \
            fail "nvm alias $alias did not uniquely lock $expected: $output"
        [[ "$(printf '%s\n' "$output" | awk -F '\t' '$2 == "current" {count++} END {print count+0}')" == "1" ]] || \
            fail "nvm alias $alias produced more than one current version: $output"
    }

    assert_nvm_alias_locked "v20.1.0" "v20.1.0"
    assert_nvm_alias_locked "20" "v20.1.0"
    assert_nvm_alias_locked "node" "v22.3.0"
    assert_nvm_alias_locked "stable" "v22.3.0"
    assert_nvm_alias_locked "lts/*" "v20.1.0"
    assert_nvm_alias_locked "lts/krypton" "v20.1.0"
    assert_nvm_alias_locked "work" "v20.1.0"
    [[ "$(printf '%s\n' "$output" | awk -F '\t' -v path="$old" '$4 == path { print $2; exit }')" == "runtime" ]] || \
        fail "non-current nvm version was not selectable"
    [[ "$(printf '%s\n' "$output" | awk -F '\t' -v path="$old" \
        '$4 == path { print ((($5 + 0) > 0 && $6 == path "/lib/node_modules") ? "linked" : "missing"); exit }')" == "linked" ]] || \
        fail "nvm global node_modules were not linked to their version: $output"
    pass "development environment current-version lock"
}

test_nvm_delete_time_guard() {
    local home="$TEST_ROOT/nvm-guard-home"
    local trash="$TEST_ROOT/nvm-guard-trash"
    local plan="$TEST_ROOT/nvm-guard-plan"
    local current="$home/.nvm/versions/node/v20.1.0"
    local old="$home/.nvm/versions/node/v18.2.0"
    local identity output rc
    mkdir -p "$current/bin" "$old/bin" "$home/.nvm/alias" "$trash"
    printf '#!/bin/sh\nexit 0\n' > "$old/bin/node"
    printf '#!/bin/sh\nexit 0\n' > "$current/bin/node"
    chmod +x "$old/bin/node"
    chmod +x "$current/bin/node"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$old")
    printf '%s\0%s\0' "$old" "$identity" > "$plan"

    run_nvm_apply_fixture() {
        env HOME="$home" PATH="${NVM_TEST_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" \
            MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
            MOLE_TEST_TRASH_DIR="$trash" MOLE_DELETE_LOG="$TEST_ROOT/nvm-guard-deletions.log" \
            MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
            bash "$RUNTIME_DIR/bin/app_apply.sh" < "$plan"
    }

    # The preview selected an old version, but default changed before apply.
    printf 'v18.2.0\n' > "$home/.nvm/alias/default"
    set +e
    output=$(run_nvm_apply_fixture 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -d "$old" && "$output" == *"failed=1"* ]] || \
        fail "delete-time guard accepted the fresh nvm default: $output"

    # The default is elsewhere, but the selected version now backs active node.
    printf 'v20.1.0\n' > "$home/.nvm/alias/default"
    set +e
    output=$(NVM_TEST_PATH="$old/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        run_nvm_apply_fixture 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -d "$old" && "$output" == *"failed=1"* ]] || \
        fail "delete-time guard accepted the fresh active nvm version: $output"

    # An identity-bound version that is neither fresh default nor active remains deletable.
    output=$(NVM_TEST_PATH="$current/bin:/usr/bin:/bin:/usr/sbin:/sbin" run_nvm_apply_fixture) || fail "delete-time guard rejected an inactive nvm version"
    [[ ! -e "$old" && "$output" == *"removed=1"* && "$output" == *"failed=0"* ]] || \
        fail "delete-time guard returned unexpected counters for an inactive version: $output"
    pass "nvm delete-time default and active version guard"
}

test_owner_managed_runtimes_readonly() {
    local home="$TEST_ROOT/owner-runtime-home"
    local trash="$TEST_ROOT/owner-runtime-trash"
    local plan="$TEST_ROOT/owner-runtime-plan"
    local output path identity kind rc
    local -a paths=(
        "$home/Library/Application Support/fnm/node-versions/v20.1.0/installation"
        "$home/.volta/tools/image/node/20.1.0"
        "$home/.asdf/installs/node/20.1.0"
        "$home/.asdf/installs/nodejs/20.1.0"
        "$home/.pyenv/versions/3.12.1"
        "$home/.rbenv/versions/3.3.1"
        "$home/.rustup/toolchains/stable-aarch64-apple-darwin"
    )

    mkdir -p "$trash"
    for path in "${paths[@]}"; do mkdir -p "$path"; done

    output=$(env HOME="$home" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        FORGESWEEP_FULL_DISK_AUTHORIZED=1 \
        bash "$RUNTIME_DIR/bin/app_env_scan.sh") || \
        fail "owner-managed runtime scan failed"
    for path in "${paths[@]}"; do
        kind=$(printf '%s\n' "$output" | awk -F '\t' -v path="$path" \
            '$4 == path { count++; kind=$2 } END { print count ":" kind }')
        [[ "$kind" == "1:manager" ]] || \
            fail "owner-managed runtime was not uniquely read-only: $path ($kind)"
    done

    : > "$plan"
    for path in "${paths[@]}"; do
        identity=$(/usr/bin/stat -f '%d:%i:%m' "$path")
        printf '%s\0%s\0' "$path" "$identity" >> "$plan"
    done
    set +e
    output=$(env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_TRASH_DIR="$trash" MOLE_DELETE_LOG="$TEST_ROOT/owner-runtime-deletions.log" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_apply.sh" < "$plan" 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && "$output" == *"removed=0"* && "$output" == *"failed=${#paths[@]}"* ]] || \
        fail "apply sink accepted an owner-managed runtime path: $output"
    for path in "${paths[@]}"; do
        [[ -d "$path" ]] || fail "apply sink removed an owner-managed runtime: $path"
    done
    pass "owner-managed runtimes are read-only at scan and apply"
}

test_auto_cleanup_planner() {
    if [[ "${SM_TEST_SKIP_SWIFT:-0}" == "1" ]]; then
        printf 'ok - Auto-cleanup planner tests skipped (SM_TEST_SKIP_SWIFT=1)\n'
        return
    fi

    local arch="$(uname -m)"
    local binary="$TEST_ROOT/auto-cleanup-planner-tests"
    local module_cache="$TEST_ROOT/auto-cleanup-planner-module-cache"
    AUTO_CLEANUP_FIXTURE=$(mktemp -d "$ROOT_DIR/.auto-cleanup-planner-tests.XXXXXX") || \
        fail "create auto-cleanup planner fixture"
    mkdir -p "$module_cache"

    swiftc -target "$arch-apple-macos13.0" \
        -module-cache-path "$module_cache" \
        "$ROOT_DIR/SimpleMole/Models.swift" \
        "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift" \
        "$ROOT_DIR/SimpleMole/Services/CleanupRiskPolicy.swift" \
        "$ROOT_DIR/SimpleMole/Services/DeveloperCacheLocator.swift" \
        "$ROOT_DIR/SimpleMole/Services/AutoCleanup.swift" \
        "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift" \
        "$ROOT_DIR/script/AutoCleanupPlannerTests.swift" \
        -o "$binary" || fail "compile auto-cleanup planner tests"
    "$binary" "$AUTO_CLEANUP_FIXTURE" || fail "auto-cleanup planner tests"

    rm -rf -- "$AUTO_CLEANUP_FIXTURE"
    AUTO_CLEANUP_FIXTURE=""
    pass "auto-cleanup planner policies, symlink guard and persistence"
}

test_cleanup_risk_policy() {
    if [[ "${SM_TEST_SKIP_SWIFT:-0}" == "1" ]]; then
        printf 'ok - Cleanup risk policy tests skipped (SM_TEST_SKIP_SWIFT=1)\n'
        return
    fi

    local arch="$(uname -m)"
    local binary="$TEST_ROOT/cleanup-risk-tests"
    local module_cache="$TEST_ROOT/cleanup-risk-module-cache"
    local fixture="$TEST_ROOT/cleanup-risk-fixture"
    mkdir -p "$module_cache" "$fixture"

    swiftc -target "$arch-apple-macos13.0" \
        -module-cache-path "$module_cache" \
        "$ROOT_DIR/SimpleMole/Models.swift" \
        "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift" \
        "$ROOT_DIR/SimpleMole/Services/CleanupRiskPolicy.swift" \
        "$ROOT_DIR/SimpleMole/Services/DeveloperCacheLocator.swift" \
        "$ROOT_DIR/SimpleMole/Services/Parsers.swift" \
        "$ROOT_DIR/SimpleMole/Services/CleanupCache.swift" \
        "$ROOT_DIR/SimpleMole/Services/CleanupAgePolicy.swift" \
        "$ROOT_DIR/SimpleMole/Services/CleanupScanWorker.swift" \
        "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift" \
        "$ROOT_DIR/script/CleanupRiskPolicyTests.swift" \
        -o "$binary" || fail "compile cleanup risk policy tests"
    "$binary" "$fixture" || fail "cleanup risk policy tests"
    pass "cleanup risk defaults, routes, runtime guards and cache persistence"
}

test_inventory_components() {
    SM_TEST_SKIP_SWIFT="${SM_TEST_SKIP_SWIFT:-0}" \
        bash "$ROOT_DIR/script/test_inventory.sh" || fail "simulator and Docker inventory tests"
    pass "simulator and Docker inventory safety contracts"
}

test_cleanup_execution_accounting() {
    local apply_source installer_source
    apply_source=$(sed -n '/private func performApply(/,/private func reportCleanupResult/p' \
        "$APP_STATE_CONTRACT_SOURCE")
    if printf '%s\n' "$apply_source" | grep -Fq 'cleanupScanComplete = false'; then
        fail "partial cleanup invalidates the scan and disables retry"
    fi
    # 安装包清理并入统一“清理”分发：勾选后仍走废纸篓（DR-4），不再有独立确认按钮。
    installer_source=$(sed -n '/private func performApply(/,/private func reportCleanupResult/p' \
        "$APP_STATE_CONTRACT_SOURCE")
    printf '%s\n' "$installer_source" | grep -Fq '.installerTrash, categories: [installers], mode: mode,' || \
        fail "unified apply does not dispatch checked installers to the installer route"
    printf '%s\n' "$installer_source" | grep -Fq 'permanently: false' || \
        fail "reviewed installer cleanup must default to Trash (DR-4)"
    if [[ "${SM_TEST_SKIP_SWIFT:-0}" == "1" ]]; then
        printf 'ok - Cleanup execution accounting tests skipped (SM_TEST_SKIP_SWIFT=1)\n'
        return
    fi
    local arch binary module_cache
    arch="$(uname -m)"
    binary="$TEST_ROOT/cleanup-execution-tests"
    module_cache="$TEST_ROOT/cleanup-execution-module-cache"
    mkdir -p "$module_cache"
    swiftc -target "$arch-apple-macos13.0" \
        -module-cache-path "$module_cache" \
        "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift" \
        "$ROOT_DIR/SimpleMole/Services/CleanupExecutionResult.swift" \
        "$ROOT_DIR/script/CleanupExecutionTests.swift" \
        -o "$binary" || fail "compile cleanup execution accounting tests"
    "$binary" || fail "cleanup execution accounting tests"
    pass "cleanup execution removed, skipped, and failed accounting"
}

test_clipboard_history() {
    local arch binary
    arch="$(uname -m)"
    binary="$TEST_ROOT/clipboard-history-tests"
    mkdir -p "$TEST_ROOT/clipboard-module-cache"
    swiftc -target "$arch-apple-macos13.0" \
        -module-cache-path "$TEST_ROOT/clipboard-module-cache" \
        -framework AppKit -framework Combine \
        "$ROOT_DIR/SimpleMole/Services/ClipboardHistoryManager.swift" \
        "$ROOT_DIR/script/ClipboardHistoryTests.swift" \
        -o "$binary" || fail "clipboard history tests compile"
    "$binary" || fail "clipboard history retention and pinning"
    pass "clipboard history retention and pinning"
}

test_swift() {
    if [[ "${SM_TEST_SKIP_SWIFT:-0}" == "1" ]]; then
        printf 'ok - Swift typecheck skipped (SM_TEST_SKIP_SWIFT=1)\n'
        return
    fi

    local arch sparkle_dir
    local swift_sources=(
        "$ROOT_DIR"/SimpleMole/*.swift
        "$ROOT_DIR"/SimpleMole/L10n/*.swift
        "$ROOT_DIR"/SimpleMole/Services/*.swift
        "$ROOT_DIR"/SimpleMole/Views/*.swift
    )
    arch="$(uname -m)"
    sparkle_dir="$(/usr/bin/python3 "$ROOT_DIR/script/fetch_sparkle.py")" || fail "Sparkle dependency verification"
    mkdir -p "$TEST_ROOT/swift-module-cache"
    # macOS 27 SDK 的 SwiftUI 宏插件只随完整版 Xcode 分发；CLT 环境探测失败时
    # 回退到仍为非宏实现的 26.x SDK 再做 typecheck（与 build.sh 同一策略）。
    local typecheck_sdkroot="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
    /usr/bin/printf 'import SwiftUI\nstruct SwiftUIMacroProbe: View {\n    @State private var flag = false\n    var body: some View { Text(String(flag)) }\n}\n' \
        > "$TEST_ROOT/swiftui-macro-probe.swift"
    if ! SDKROOT="$typecheck_sdkroot" swiftc -typecheck -framework SwiftUI \
            -module-cache-path "$TEST_ROOT/swift-module-cache" \
            "$TEST_ROOT/swiftui-macro-probe.swift" >/dev/null 2>&1; then
        for fallback_sdk in macosx26.5 macosx26.0; do
            fallback_root="$(xcrun --sdk "$fallback_sdk" --show-sdk-path 2>/dev/null)" || continue
            [[ -d "$fallback_root" ]] || continue
            if SDKROOT="$fallback_root" swiftc -typecheck -framework SwiftUI \
                    -module-cache-path "$TEST_ROOT/swift-module-cache" \
                    "$TEST_ROOT/swiftui-macro-probe.swift" >/dev/null 2>&1; then
                typecheck_sdkroot="$fallback_root"
                break
            fi
        done
    fi
    SDKROOT="$typecheck_sdkroot" swiftc -typecheck -target "$arch-apple-macos13.0" \
        -module-cache-path "$TEST_ROOT/swift-module-cache" \
        -F "$sparkle_dir" -framework Sparkle \
        -framework Cocoa -framework SwiftUI -framework Security -framework CryptoKit -framework IOKit -framework ServiceManagement \
        "${swift_sources[@]}" || fail "Swift typecheck"
    pass "Swift typecheck"

    if [[ "${SM_TEST_BUILD:-0}" == "1" ]]; then
        GOPROXY=off SM_BUILD_ARCHS="${SM_TEST_BUILD_ARCHS:-$arch}" \
            SM_CODESIGN_IDENTITY="${SM_TEST_CODESIGN_IDENTITY:--}" SM_ALLOW_ADHOC=1 \
            "$ROOT_DIR/script/build.sh" || fail "app build"
        for built_arch in ${SM_TEST_BUILD_ARCHS:-$arch}; do
            codesign --verify --deep --strict "$ROOT_DIR/dist/$built_arch/Nori.app" || \
                fail "app code signature ($built_arch)"
        done
        pass "app build and code signature"
    fi
}

printf 'Nori local regression tests\n'
test_shell_syntax
if [[ "${SM_TEST_SKIP_SWIFT:-0}" != "1" ]]; then
    bash "$ROOT_DIR/script/test_duplicates.sh" || fail "exact duplicate scanning tests"
    bash "$ROOT_DIR/script/test_duplicate_responsiveness.sh" || fail "duplicate background responsiveness tests"
    bash "$ROOT_DIR/script/test_duplicate_deletion.sh" || fail "duplicate deletion safety tests"
    bash "$ROOT_DIR/script/test_similar_images.sh" || fail "similar image grouping tests"
    bash "$ROOT_DIR/script/test_duplicate_workspaces.sh" || fail "duplicate result reuse and persistence tests"
    bash "$ROOT_DIR/script/test_cleanup_scan.sh" || fail "native cleanup scan tests"
    bash "$ROOT_DIR/script/test_cache_cleanup.sh" --all || fail "cache cleanup unit and filesystem E2E tests"
    bash "$ROOT_DIR/script/test_cleanup_page_state.sh" || fail "cleanup inline results and pending retry tests"
    bash "$ROOT_DIR/script/test_auto_cleanup_workflow.sh" || fail "automatic cleanup scheduler lifecycle tests"
    bash "$ROOT_DIR/script/test_administrator_cleanup.sh" || fail "administrator cleanup safety tests"
    bash "$ROOT_DIR/script/test_administrator_cleanup_performance.sh" || fail "bounded cleanup batches, path indices and UI responsiveness"
    bash "$ROOT_DIR/script/test_analysis_deletion.sh" || fail "analysis selection identity-bound Trash tests"
    bash "$ROOT_DIR/script/test_analysis_inventory.sh" || fail "independent incremental analysis cache tests"
    bash "$ROOT_DIR/script/test_analysis_selection.sh" || fail "per-category cleanup and compression selection tests"
    bash "$ROOT_DIR/script/test_analysis_automation.sh" || fail "automatic incremental analysis scheduling tests"
    bash "$ROOT_DIR/script/test_system_disk_metrics.sh" || fail "macOS available disk capacity tests"
    bash "$ROOT_DIR/script/test_agents.sh" || fail "agent cleanup catalog, skills and MCP tests"
    bash "$ROOT_DIR/script/test_agent_scan_performance.sh" || fail "bounded Agent scan, metadata reuse and cancellation"
    bash "$ROOT_DIR/script/test_agent_storage_footprint.sh" || fail "shared Agent/software capacity and garbage classification"
    bash "$ROOT_DIR/script/test_agent_software_inventory.sh" || fail "selected Agent application and CLI inventory"
    bash "$ROOT_DIR/script/test_agent_data_process_scope.sh" || fail "trusted shared-data consumers and process isolation"
    bash "$ROOT_DIR/script/test_agent_program_removal.sh" || fail "selected Agent installation removal and separate data consent"
    bash "$ROOT_DIR/script/test_agent_cli.sh" || fail "agent CLI uninstall execution tests"
    bash "$ROOT_DIR/script/test_agent_workflow.sh" || fail "agent cleanup lifecycle tests"
    bash "$ROOT_DIR/script/test_agent_icons.sh" || fail "agent icon tests"
    bash "$ROOT_DIR/script/test_task_feedback.sh" || fail "task feedback queue tests"
    bash "$ROOT_DIR/script/test_task_feedback_localization.sh" || fail "multilingual task feedback tests"
    # Ordinary Agent garbage cleanup executes its captured selection directly;
    # installation removal and associated user-data cleanup have separate consent.
    /usr/bin/grep -Eq 'AgentCleanupExecutor\.execute\([^,]+, running: snapshot, home: home, permanent: true[,)]' \
        "$ROOT_DIR/SimpleMole/AppState+Agents.swift" || fail "agent cleanup no longer deletes permanently"
    /usr/bin/grep -Fq '    func applyAgentCleanup() {' "$ROOT_DIR/SimpleMole/AppState+Agents.swift" || \
        fail "ordinary Agent cleanup action is missing"
    if sed -n '/^    func applyAgentCleanup() {$/,/^    }$/p' "$ROOT_DIR/SimpleMole/AppState+Agents.swift" \
        | /usr/bin/grep -Eq 'confirmation[[:space:]]*='; then
        fail "ordinary Agent garbage cleanup asks for confirmation again"
    fi
    bash "$ROOT_DIR/script/test_optimize.sh" || fail "optimize admin bridge safety tests"
    bash "$ROOT_DIR/script/test_cleanup_refresh.sh" || fail "post-cleanup inventory refresh tests"
    bash "$ROOT_DIR/script/test_disk_analysis.sh" || fail "directory analysis tests"
    bash "$ROOT_DIR/script/test_directory_files.sh" || fail "directory file operation safety tests"
    bash "$ROOT_DIR/script/test_directory_search.sh" || fail "directory persistent index and search tests"
    bash "$ROOT_DIR/script/test_directory_browser.sh" || fail "directory navigation and clipboard workflow tests"
    bash "$ROOT_DIR/script/test_media.sh" || fail "file slimming tests"
    # 瘦身只删除自己的临时输出；原件只能经注入的 Trash 离开原位。
    media_slimmer="$ROOT_DIR/SimpleMole/Services/MediaSlimmer.swift"
    [[ "$(/usr/bin/grep -c 'removeItem(' "$media_slimmer")" -eq \
        "$(( $(/usr/bin/grep -c 'removeItem(at: temp)' "$media_slimmer") + 1 ))" ]] || \
        fail "media slimming removes something other than its own temporary output"
    /usr/bin/grep -Fq 'name.hasPrefix(".") && name.contains(".nori-slim-\(token)")' "$media_slimmer" || \
        fail "media slimming temp cleanup is not bound to its own token"
    if /usr/bin/grep -Fq 'case images' "$APP_STATE_CONTRACT_SOURCE"; then
        fail "the standalone image tab came back; image slimming lives in disk analysis"
    fi
    bash "$ROOT_DIR/script/test_login_item.sh" || fail "login item opt-in and system status tests"
    bash "$ROOT_DIR/script/test_uninstall_residue.sh" || fail "uninstall residue discovery and result tests"
    bash "$ROOT_DIR/script/test_uninstall_processes.sh" || fail "confirmed uninstall process shutdown tests"
    bash "$ROOT_DIR/script/test_cli_tools.sh" || fail "multi-ecosystem CLI inventory tests"
    bash "$ROOT_DIR/script/test_software_updates.sh" || fail "application and CLI version checks"
    bash "$ROOT_DIR/script/test_software_update_execution.sh" || fail "software update commands and running-process closure"
    bash "$ROOT_DIR/script/test_software_update_request.sh" || fail "independent signed-updater routing and software reentry"
    bash "$ROOT_DIR/script/test_cli_uninstall_workflow.sh" || fail "confirmed CLI uninstall and scoped process shutdown"
    bash "$ROOT_DIR/script/test_software_workflows.sh" || fail "software workflow dependency and orchestration contracts"
    bash "$ROOT_DIR/script/test_administrator_uninstall.sh" || fail "administrator uninstall and Trash safety tests"
fi
test_native_core_ownership_contract
test_plists
test_brand_contract
test_tab_motion_contract
test_control_motion_contract
test_header_layout_contract
test_process_icon_contract
test_island_contract
test_productivity_feature_contract
stage_bridge_runtime
test_timeout_fallback
test_scan_access_boundary
test_signing_policy_contract
test_local_signing_identity
/usr/bin/python3 "$ROOT_DIR/script/test_sparkle.py" || fail "Sparkle dependency and host signing policy"
bash "$ROOT_DIR/script/test_release_identity.sh" || fail "fixed release identity provisioning"
bash "$ROOT_DIR/script/test_release_packaging.sh" || fail "fixed release packaging policy"
test_signing_identity_classification
test_screenshot_presets
test_theme_contract
test_destructive_sinks
test_process_sampler
test_gc_runner
test_node_cache_inventory
test_identity_bound_apply
test_auto_cleanup_apply
test_installer_apply
test_packaged_apply_layout
test_uninstall_space_breakdown
test_native_cask_uninstall_contract
test_uninstall_queue
test_task_activity
test_cleanup_process_probe_batching
test_runtime_process_identity_binding
test_runtime_store_aggregation
test_netmon_bridge
if [[ "${SM_TEST_SKIP_SWIFT:-0}" != "1" ]]; then
    bash "$ROOT_DIR/script/test_traffic.sh" || fail "traffic accounting and app attribution"
    pass "traffic accounting, app attribution and descending rankings"
fi
test_dev_env_current_version_lock
test_nvm_delete_time_guard
test_owner_managed_runtimes_readonly
test_auto_cleanup_planner
test_cleanup_risk_policy
test_cleanup_execution_accounting
test_inventory_components
test_clipboard_history
test_swift
printf 'All %d checks passed.\n' "$PASSED"
