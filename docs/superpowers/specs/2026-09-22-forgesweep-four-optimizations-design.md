# ForgeSweep 四项优化设计

日期：2026-09-22
范围：授权管理、截图模板、玻璃配色、进程管理。四块相互独立，按 授权 → 截图 → 配色 → 进程 的顺序实施，每块完成后产出一个可安装 DMG 到桌面。
已确认的决定：本地自签名身份；权限中心四项自愈能力全部实现；配色采用 Fjord 冷青蓝并跟随系统外观；截图做一键预设与导出选项；进程管理做原生数据源 + 列表体验 + 操作升级。

## 1. 授权管理

### 1.1 根因

`/Applications/ForgeSweep.app` 为 ad-hoc 签名，designated requirement 是 `cdhash H"…"`。TCC 把授权记录绑定到该 requirement，每次重新打包 cdhash 变化，已有记录随之失效：系统设置里开关仍显示打开，但 `CGPreflightScreenCaptureAccess()` 返回 false，截图里其他窗口为空；完全磁盘访问同理。次要原因：`CGRequestScreenCaptureAccess()` 对同一签名只弹一次系统框，之后静默返回 false；授权后必须在新进程中才生效。

### 1.2 构建侧：本地自签名身份

- 新增 `script/dev_identity.sh`：
  - `--ensure`（默认）：登录钥匙串中已有标签为 `ForgeSweep Local Signing`（可用 `SM_LOCAL_SIGN_LABEL` 覆盖）且可用于 codesign 的身份时直接退出 0；否则用 `openssl` 生成 RSA 2048 密钥与 10 年期自签名证书（`extendedKeyUsage = codeSigning`，`keyUsage = digitalSignature`），打包为 PKCS#12 导入登录钥匙串（`security import … -T /usr/bin/codesign`），再 `security add-trusted-cert -r trustRoot -p codeSign` 加入用户信任域。该步骤会弹一次钥匙串授权，脚本前后打印说明。
  - `--print`：输出可用于 `SM_CODESIGN_IDENTITY` 的身份标签；`--remove`：删除该身份。
  - 临时文件放在 `mktemp -d`，退出时清理；私钥不落盘到仓库。
- `script/build.sh`：`set_signing_identity_from_record` 新增 `local` 类型（标签等于 `SM_LOCAL_SIGN_LABEL`）。`resolve_signing_identity` 优先级：显式 `SM_CODESIGN_IDENTITY` → Apple Development → Developer ID Application → 本地自签名 → ad-hoc（仅 `SM_ALLOW_ADHOC=1`）。构建日志打印所用身份类型。
- `script/package_dmg_to_desktop.sh`：没有 Apple 身份时先执行 `dev_identity.sh --ensure`；成功则用本地身份签名，失败才退回 ad-hoc 并保留现有警告。
- 结果：designated requirement 变为 `identifier "com.forgesweep.app" and certificate leaf = H"…"`，跨构建稳定；Gatekeeper 行为不变（首次仍需右键“打开”）。

### 1.3 App 内：权限中心自愈

新增 `Services/SigningIdentityInspector.swift`：
- 通过 `SecCodeCopySelf` + `SecCodeCopyDesignatedRequirement` + `SecRequirementCopyString` 取得 DR 字符串；分类 `adhoc`（以 `cdhash` 开头）、`local`（含 `certificate leaf = H"`）、`apple`（含 `anchor apple`）、`unknown`。`isStable = kind != .adhoc`。

`PermissionCenter` 扩展：
- `liveScreenRecordingStatus()`：派生子进程 `ForgeSweep --preflight-screen-capture`（同一可执行文件，`main.swift` 在入口处识别该参数：打印 `1`/`0` 后 `exit`，不初始化 `NSApplication`），读取输出得到未被进程内缓存影响的实时值。超时 3 s 视为未知，保留上次值。
- `requestScreenRecordingAccess()`：记录调用耗时；返回 false 且耗时 < 300 ms 判定为“已有决定、未弹框”，置 `screenRecordingDecisionStale = true`，并自动 `openSystemSettings(.screenRecording)`。
- `resetScreenRecordingDecision()` / `resetFullDiskDecision()`：执行 `/usr/bin/tccutil reset <Service> com.forgesweep.app`；成功后前者立即重新请求授权，后者打开系统设置并高亮拖拽提示。失败时显示“在系统设置中用 − 移除 ForgeSweep 后重新拖入”的说明。
- 自动复检：监听 `NSApplication.didBecomeActiveNotification`；权限中心可见期间每 3 s 复检一次。屏幕录制由 false 变 true 时置 `screenRecordingNeedsRelaunch = true`。

`PermissionCenterView`：
- 顶部新增签名诊断条：ad-hoc 显示橙色警告“此构建为临时签名，每次更新后 macOS 会忘记授权”，附修法（运行 `script/dev_identity.sh` 后重新打包）；稳定身份显示灰色一行“授权会在更新后保留”。
- 屏幕录制行：`screenRecordingDecisionStale` 时显示“系统设置里显示已开启，但对当前构建无效”与“重置并重新授权”按钮；`screenRecordingNeedsRelaunch` 时用醒目的确认条“屏幕录制已授权，重启后生效”[立即重启][稍后]，替代现有小字提示。
- 完全磁盘访问行新增“重置授权”次级按钮。
- `relaunchApplication()` 的辅助脚本日志改到 `~/Library/Logs/ForgeSweep/relaunch.log`（目录 0700），路径经 `shellQuoted` 拼入。

L10n：新增键均补齐 en / zh-Hans / zh-Hant，其他语言回退英文。

### 1.4 测试与验收

- `script/test.sh` 新增：`dev_identity.sh --print` 在无身份时退出非 0 且不弹窗（`SM_DEV_IDENTITY_DRY_RUN=1`）；`build.sh` 在存在 `local` 记录的模拟 `find-identity` 输出下选择本地身份；ad-hoc 仍需 `SM_ALLOW_ADHOC=1`。
- Swift 测试：`SigningIdentityInspector.classify(requirementString:)` 对三类字符串的判定。
- 手工验收：本地身份连续打包两次并安装，第二次不需要重新授权；在 ad-hoc 构建上权限中心显示警告，点“重置并重新授权”后系统弹出授权框，授权后出现重启确认。

## 2. 截图模板

### 2.1 模型

`ScreenshotPreset`（`Models` 或独立文件 `ScreenshotPresets.swift`）：
- `background`: `.transparent` | `.solid(Color)` | `.linear([Color])` | `.mesh([Color])`（`MeshGradient` 3×3，macOS 15+；低版本回退为线性渐变）。
- `frame`: `.none` | `.macWindow(appearance: light|dark, showsTitle: Bool)` | `.roundedCard(border: Bool)`。
- `aspect`: `.free` | `.square` | `.wide16x9` | `.portrait3x4` | `.story9x16`。
- `paddingRatio`（默认 0.06）、`cornerRadius`（默认 14）、`shadow`（随背景明暗自动选择强弱）。

内置 10 个预设：Plain、Aurora（默认）、Sunset、Ocean、Mint、Candy、Graphite、Paper、Midnight、Frame。名称走 L10n（`shot.preset.<id>`）。

### 2.2 渲染

- `BeautifyFrame` 重写为 `PresetFrame`：先按 `aspect` 计算外框尺寸（内容 + 边距后向外扩展补齐比例，内容居中不裁切），再绘制背景、相框、内容、阴影。预览与导出共用同一视图，仅尺寸不同。
- 窗口相框：标题栏高 30，红黄绿点直径 11，可选标题文字（默认空，编辑器里可输入）。
- 兼容旧 `BeautifyTemplate` 的 6 个渐变（映射到新预设），删除旧枚举。

### 2.3 编辑器

- 模板条改为横向预设条：每个预设渲染 56×36 的实时缩略图（占位内容为当前截图的低分辩率版本），当前预设高亮；右侧一个弹出菜单放相框（含标题输入）与比例。
- 导出：分辩率 1x / 2x（`ImageRenderer.scale`），格式 PNG / JPEG（质量 0.9）；复制到剪贴板同时写 PNG 与 TIFF；保存默认到下载目录，新增“另存为…”（`NSSavePanel`）。
- 偏好：预设、比例、分辩率、格式写入 `UserDefaults`（`screenshot.preset` 等），下次打开编辑器恢复。

### 2.4 测试与验收

- Swift 测试：`PresetFrame.layout(contentSize:preset:)` 对五种比例的外框尺寸与内容居中偏移；2x 导出像素尺寸 = 布局尺寸 × 2。
- 手工验收：切换预设 ≤ 100 ms；透明背景复制到 Keynote / Figma 保留透明。

## 3. 玻璃配色（Fjord，跟随系统）

### 3.1 Token

`Views/Theme.swift`（从 `Components.swift` 拆出）：
- 强调：`accent`（深色 `#5AB0F2` / 浅色 `#1E88D6`，通过 `Color(nsColor:)` 动态色实现）、`accentText`（深色 `#8CCBFF` / 浅色 `#1E88D6`）、`onAccent`（`#0B1B2B` / 白）。
- 玻璃：`glassTint`（深色 `#0E1218` α0.32 / 浅色 `#F4F6F9` α0.45）。
- 表面：`surface1/2/3`（深色 白 α0.05/0.08/0.12；浅色 白 α0.45/0.62/0.80）、`hairline`（深色 白 α0.10 / 浅色 黑 α0.08）。
- 语义：`success #3DCC91`、`warning #F2B23F`、`danger #F0616B`（浅色下各降 8% 亮度）。
- 保留 `moleAccent` 等旧名作为 `@available(*, deprecated)` 别名，逐文件替换后删除。

### 3.2 玻璃层

- `DarkGlassSurface` 重命名 `GlassSurface`：只保留 `NSGlassEffectView`（tint = `glassTint`，`style = .regular`）或 13–25 的 `NSVisualEffectView(.hudWindow/.popover)` 回退；删除实色层与渐变层；边框 1 px `hairline`。减少透明度开启时改为实色 `glassTint` α1。
- 移除 `.preferredColorScheme(.dark)` 与 `NSAppearance(named: .darkAqua)` 的强制；窗口跟随系统外观。
- `PillPicker` 玻璃 tint 改为 `accent` α0.22，去掉阴影。

### 3.3 收敛

- 67 处 `Color.white/black.opacity(…)` 改为 `surface*` / `hairline`。
- 101 处 `moleAccent*` 改为新 token；`moleOnAccent` 保持语义。
- 语义色 86 处保持 `.green/.orange/.red` 中用于状态的部分改为 token，纯装饰保留。
- 更新 `script/test.sh` 中关于 `glassEffectID` 的断言到新文件位置。

### 3.4 验收

主窗口能透出壁纸；浅色与深色切换下文字对比度 ≥ 4.5:1（用 `Theme` 单测计算 WCAG 对比）；全仓库无 `moleAccent` 残留；减少透明度模式下界面不透明。

## 4. 进程管理

### 4.1 数据源 `Services/ProcessSampler.swift`

- `proc_listallpids` 枚举；`proc_pidinfo(PROC_PIDTBSDINFO)` 取 pid、ppid、uid、`pbi_start_tvsec/usec`、`pbi_status`（`SZOMB` 为僵尸）、`pbi_flags & PROC_FLAG_INEXIT` 为退出中；`proc_pidinfo(PROC_PIDTASKINFO)` 取 `pti_resident_size` 与 `pti_total_user + pti_total_system`；`proc_pidpath` 取完整路径。
- CPU% = 两次采样 CPU 时间差 / 墙钟时间差 × 100（可超过 100%，与活动监视器一致）；首帧无差值显示 `--`。
- 身份 `ProcessIdentity(pid, startTime, ppid, uid)`；发信号前重采样比对，不一致即拒绝。
- 拒绝规则沿用：非当前 uid、路径在 `/System /usr /bin /sbin /private` 且非用户请求的应用、ForgeSweep 自身及子进程树。
- 聚合：`ProcessGroup { key, name, bundleURL?, icon, rows, cpu, memBytes, history: [Double](最多 30) }`；`key` = 路径中第一个 `.app` 分量；无 `.app` 的按可执行名分组。
- 采样节奏：进程页或快捷面板可见时 2 s；不可见时停止。自动清理（僵尸/退出中）逻辑接到新数据源，判据不变。

### 4.2 界面 `ProcessesTabView`

- 顶部：搜索框（名称 / PID / 路径）、排序菜单（CPU / 内存 / 名称 / 进程数）、筛选片（我的应用 / 后台进程 / 异常）、高级模式开关保留（显示原始进程行）。
- 组行：图标、名称、进程数、CPU、内存、30 点趋势线、操作按钮；展开显示 helper 行（名称、PID、CPU、内存、单行操作）。
- 高占用提示条：某组 CPU 连续 30 s > 80% 或内存 > 4 GB 时在列表上方出现，可点击定位到该组。

### 4.3 操作

- App 组：退出（`NSRunningApplication.terminate()`）→ 5 s 内未退出提示“强制退出”→ `forceTerminate()`；“结束整组”对 helper 发 SIGTERM，3 s 后仍存活的发 SIGKILL。
- 非 App 进程：SIGTERM → 3 s → 提示 SIGKILL。
- 僵尸 / 退出中：沿用现有清理逻辑（向父进程发 SIGCHLD / 对退出中进程发 SIGKILL），改为原生实现。
- 快捷面板“强制退出”改走原生 `forceTerminate`（修 A2），结果写 `quickPanelStatus`。
- 端口页：`refreshPorts` 检查 `result.succeeded`，失败保留旧列表并显示 `ports.status.readFailed`（修 A8）；刷新间隔 5 s；“结束”走 SIGTERM → SIGKILL 升级。
- 高级模式计数使用 `total`（修 A12）。

### 4.4 测试与验收

- Swift 测试 `script/ProcessSamplerTests.swift`：CPU 差值计算、`.app` 聚合（`/Applications/Google Chrome.app/Contents/Frameworks/…/Google Chrome Helper` 归入 Chrome）、身份不匹配拒绝、排序与筛选。
- `script/test.sh`：保留 `app_runtime.sh` 的既有断言（脚本仍服务 ports 与测试）。
- 手工验收：Chrome 及 helper 一组且名称完整；快捷面板强制退出生效；端口页 lsof 超时不再显示“无监听端口”。

## 5. 不做的事

- 不改流量管控。
- 不发系统通知（高占用只做页内提示条）。
- 不引入 ScreenCaptureKit 替换 `screencapture -i`。
- 不做 Apple 公证或 Developer ID 分发。
