# Nori development and engineering reference

[English product overview](../README.md) · [中文产品介绍](../README.zh-CN.md)

This document preserves the project’s detailed Chinese engineering notes, build instructions, and safety policies. For the current release identity and upgrade checks, use the [release signing guide](release-signing.md).

安静守护 Mac 的原生工具：菜单栏常驻（点击直达主窗口）+ 灵动岛 + 主窗口（硬盘清理 / 磁盘分析 / 应用卸载 / 开发环境 / 进程清理 / 端口清理 / 图片瘦身 / 截图 / 剪贴板）。支持 12 种语言，默认跟随系统语言，可随时手动切换。

## 多语言

支持：简体中文、繁體中文、English、日本語、한국어、Deutsch、Français、Español、Português、Italiano、Русский、Türkçe。

- **自动识别**：默认 `auto`，按系统偏好语言（含区域变体归一，如 pt-BR → pt、zh-TW → 繁中）匹配；回到前台会重新解析。
- **手动切换**：主窗口“设置”标签中的语言选项，选择即持久化（`SMLanguage`）并即时刷新全部界面、状态栏文案与应用菜单。
- 语言表内置代码（`SimpleMole/L10n/`，覆盖 12 种语言），缺失键回退英文；格式化占位符保持一致。

## 定位

Nori 受到 [Mole](https://github.com/tw93/Mole) 启发。核心清理、磁盘分析、应用卸载和系统优化由 Swift `NativeCore` 直接实现；Mole 的审计辅助库为现有 bridge 提供基础能力：

- **核心路径原生化**。`NativeCore` 使用 `FileManager`、`Bundle`、`NSWorkspace` 和 `Process` 完成候选扫描、大小分析、应用身份校验、废纸篓/永久删除和优化命令。每条待删除路径携带扫描时的 `device:inode:mtime`，执行前再次读取并比对；软链接、保护目录、白名单和运行中的应用默认跳过。Agent 专清通过 `AgentInventory`、`AgentCleanupExecutor` 和原生服务执行，图片处理走 `MediaSlimmer`；`vendor/mole/` 的 `lib/core/` 为开发者、运行时及其他现有桥接脚本提供审计过的基础函数。上游版本记录在 `vendor/mole/UPSTREAM_COMMIT`，许可证见 `vendor/mole/LICENSE`。
- **UI 层为 Swift + SwiftUI 原生实现**。周期指标（CPU / 内存 / 网络 / 磁盘）走系统 API；进程排行按需读取一次 `/bin/ps`。耗时扫描和清理通过日志抽屉展示阶段状态与聚合结果，结构化清单在完成后一次性更新，避免逐行 UI 调度拖慢文件扫描。

## 功能面

| 页面 | 能力 | 引擎路径 |
| --- | --- | --- |
| 硬盘清理 | 快速扫描常用缓存，深度扫描补充更多应用目录与历史残留；只展示 Safe 垃圾，归入缓存、卸载残留、废纸篓、开发者缓存、AI 缓存五个可折叠大类（默认只展开最大分组），支持分类/子项勾选；同一分组内小于 100MB 的长尾小项自动合并为「其他」。开发者缓存与构建产物默认按 **7 天未活跃**门槛推荐（活跃条目保留可见、默认不勾选），支持 npm/Yarn/pip/Gradle 等自定义缓存位置。Safe 垃圾默认全部勾选，一键清理**永久删除**所选；执行前会用最新进程快照与年龄证据重新评估，运行中或重新活跃的路径自动跳过并计入「已跳过」 | `NativeCore.scanCleanup/applyCleanup` + `CleanupScanWorker` + `CleanupAgePolicy`；AI/Xcode 缓存共用原生统计 |
| 磁盘分析 | 统一扫描范围：用户空间（默认当前用户主目录）、根目录、自定义目录；支持取消、逐层浏览和缓存复用，避免符号链接循环与硬链接重复计量 | `NativeCore.scanAnalyze` + `DiskAnalysisWorker` |
| 重复文件 / 相似图片 | 从磁盘分析页打开，单独选择多个普通文件目录；精确重复采用大小、采样、完整 SHA-256 分级检测，不限于大文件列表；相似静态图片按感知特征分组，展示尺寸、参考清晰度并支持原图预览。默认不勾选，每组至少保留一份，移入废纸篓前复核选中项和保留项 | `DuplicateScanner` + `SimilarImageScanner` + `DuplicateDeletionPlan` + `NativeCore.applyCleanup` |
| 应用卸载 | 列出 `/Applications`、用户 Applications 和 Setapp 应用；按 Bundle ID 精确生成缓存、日志和需复核数据明细，应用本体与关联路径在串行队列中逐项复验身份后移入废纸篓 | `NativeCore.scanInstalledApps` + `NativeCore.uninstallPlan/applyUninstall` |
| 系统优化 | 刷新 DNS、Quick Look、LaunchServices，清理 30 天以前的保存状态，并只读检查 Spotlight 状态；每项独立显示 applied/unchanged/unavailable/failed | `NativeCore.runOptimize` |
| 状态监控 | 菜单栏和主窗口实时显示 CPU、内存、磁盘容量与读写、网络速率；可读取电池电量/健康/循环次数，灵动岛的内存榜也走原生进程快照 | `SystemMetrics.sample` + IOKit / Mach / sysctl / statfs / getifaddrs |
| 开发环境 | 识别 nvm 版本（默认/使用中锁定，可勾选清理旧版本）；fnm/Volta/asdf/pyenv/rbenv/rustup/Homebrew/JDK 版本及 Bun/Deno 等工具只读展示，版本移除交给各自管理器 | `app_env_scan.sh` + `app_apply.sh` |
| AI Agent 专清 | 分组识别 Agent 缓存、历史、配置与安装实例；默认只选择可丢弃项，历史/凭据/未知内容需手动选择；Skills、MCP 登记和安装本体分开管理；执行所选文件删除为永久删除 | `AgentCatalog` + `AgentInventory` + `AgentCleanupExecutor` + `AgentCLIService` + `AgentMCPConfigEditor` |
| 进程/端口 | NSWorkspace 应用级管理、高级 PID 模式、lsof 监听端口 | 原生 + `app_runtime.sh` |
| 流量监控 | 通用应用流量排行（总量 / 下载 / 上传）、实时速率、当前连接、物理接口与隧道独立计数；无需代理客户端配置 | `TrafficMonitorStore` + `app_netmon.sh` |
| 图片瘦身 | 图片清单、压缩（副本/替换）；精确重复和相似图片走独立原生扫描 | `MediaSlimmer` + `DuplicateScanner` + `SimilarImageScanner` |
| 白名单 | `~/.config/mole/whitelist` 的 GUI 维护，clean / purge / 全部桥接清理共用 | `load_mole_whitelist` / `is_path_whitelisted` |

卸载残留采用“证据优先”策略：应用仍在废纸篓时，用它的 Bundle ID 精确反查对应的用户缓存和日志；应用已经被手动删除且废纸篓也已清空时，不凭目录名猜测归属，而把可疑的大目录留给“磁盘分析”或后续深度审查。这样首屏可以保持快速，也不会把仍被其他应用使用的同名目录当成垃圾。

重复扫描跳过应用包、图库、用户 Library、隐藏及受管理目录、符号链接和未下载的云文件。可比较导出到普通目录的 IM 附件，不扫描或改写微信内部数据。相似分组只供人工判断，不证明内容相同；移入废纸篓不立即释放空间，文件大小合计也不代表 APFS 克隆或快照存在时的实际释放量。

快速扫描先按预设路径发现缓存，完成风险分类、白名单过滤和路径去重后，再以最多 8 个工作线程统计实际磁盘占用。文件遍历预算为整体 45 秒、单目录 8 秒；遇到慢目录时保留已完成的结果，并提示尚未统计完的目录数。预算在遍历间检查，底层文件系统阻塞时可能超出预算，不承诺所有机器都在固定时间内完成。

深度扫描会补充应用容器和更多 Application Support 缓存，取消单目录时间限制，用户可随时取消。超时、无法读取或被取消的统计不会按完整容量展示，也不会写入完整结果缓存。页面可复用最近 5 分钟的完整快照，明确点击“快速扫描”或“深度扫描”会重新扫描。日志抽屉记录目录发现、容量统计耗时和未完成数量，便于实机比较。

扫描回归与吞吐测试：`bash script/test_cleanup_scan.sh`。它只创建独立测试目录，不启动 GUI、不扫描真实用户缓存；覆盖重叠目录、保护路径、深度补充、取消、部分结果、硬链接和大输出量进程读取。

清理与磁盘分析的完整策略（统一规则模型、7 天活跃门、快速/深度分析、处置语义、已知边界）见 [docs/cleanup-strategy.md](cleanup-strategy.md)；与最初重写方案的有意偏差及安全论证见 [docs/decision-records.md](decision-records.md)。删除出口静态审计：`bash script/audit_destructive_sinks.sh`（已并入 `script/test.sh`）。

### 自动目录清理

从“设置”标签中的“自动清理”进入规则管理。每个目录可选择“容量上限”（超限后按最旧优先清理至阈值）或“保留最近 X 天”；添加后的规则默认关闭，可先预览、手动确认清理，再显式开启。应用常驻期间每小时检查调度，实际扫描至少间隔六小时；执行失败会在下一次小时调度重试。

### 顶部刘海与设置

顶部刘海悬停展开彩色进度环：绿色表示健康、橙色表示偏高、红色表示高占用。CPU 和内存支持悬停查看应用排行、单个正常退出，以及闪电按钮智能清理；智能清理只尝试正常退出符合策略的高占用隐藏应用，内存清理同时释放 Nori 自身缓存。右侧箭头直接打开主窗口。

设置始终作为独立标签显示，集中管理语言、自动化、白名单、权限和功能开关。设置弹窗与刘海在 macOS 26 及以上使用原生 Liquid Glass 过渡；较早系统与辅助功能设置保留相应回退。扫描、清理中与清理结果使用 Nori SVG 状态动画，减少动态效果时显示静态图形。

## README screenshot assets

The English and Chinese product introductions use `docs/screenshots/en/` and `docs/screenshots/zh-CN/`. Screenshots render actual app components with isolated sample data; they are illustrative and do not expose a personal cleanup scan or clipboard. Capture commands and fixture details are documented in the [screenshot guide](screenshots/CAPTURE.md).

## 构建与 GitHub Release

需要 macOS 和提供 `swiftc` 的 Xcode 工具链，建议使用完整、稳定的 Xcode 26。特色桥接所需的 Mole 源码已内置，无需另行安装或检出。

### 无 Apple 开发者账号的公开发布

GitHub Release 使用项目固定的自签名证书，不要求购买 Apple Developer 计划。公开证书和身份记录位于 `signing/release.cer`、`signing/release.plist`；只有维护者保存私钥。每个版本复用同一份证书和 Bundle ID，发布入口会严格校验身份，不会降级为 ad-hoc：

```bash
bash script/release_identity.sh ensure
bash script/package_release.sh
```

输出为 `dist/Nori-arm64.dmg`（Apple 芯片）和 `dist/Nori-x86_64.dmg`（Intel），每个 DMG 包含对应架构的 `Nori.app` 与 `/Applications` 快捷方式。可通过 `SM_BUILD_ARCHS=arm64` 或 `SM_BUILD_ARCHS=x86_64` 只生成一个架构。

`release_identity.sh init` 只用于维护者首次建立发布身份；仓库已有公开证书但本机缺少私钥时，它会拒绝生成替代身份。新维护者或新 Mac 必须通过 `import` 导入原来的加密 PKCS#12 备份。私钥、密码、钥匙串不得提交到 Git。初始化、恢复、备份和安装验证见 [发布签名指南](release-signing.md)。

安装并登录 GitHub CLI 后，可安全配置仓库的两个 Actions secrets：

```bash
bash script/configure_release_secrets.sh
```

脚本从 `origin` 推断仓库，也接受 `owner/repository` 参数；秘密通过标准输入上传，临时导出随后删除。如果任一同名 secret 已存在，脚本会拒绝覆盖。Actions 的 **Signed macOS release** 支持默认分支手动构建；推送 `v*` 标签会运行回归检查，生成两个 DMG、校验和及 **draft Release**，由维护者检查后公开。

固定签名有助于跨版本保持同一应用身份，但不能保证所有 macOS 版本保留全部隐私权限。从 ad-hoc 或其他证书签署的版本迁移时，可能需要重新授权。自签名也不等同于 Apple 公证：用户首次打开下载的 App 时可能需要前往“系统设置 → 隐私与安全性”允许打开，再按功能需求授予完全磁盘访问和屏幕录制权限。用户无需安装发布证书。

### 本机开发和测试

不持有发布私钥的贡献者，可以创建自己的本地开发身份：

```bash
bash script/dev_identity.sh --ensure
bash script/build_and_run.sh
```

`build.sh` 优先选择钥匙串中的 `Apple Development` 身份，其次选择本机自签名身份；也可通过 `SM_CODESIGN_IDENTITY` 指定。构建使用 `-O` 与 Swift 跨文件优化，签名前移除本地符号；默认只构建当前架构，输出到 `dist/arm64/Nori.app` 或 `dist/x86_64/Nori.app`。设置 `SM_BUILD_ARCHS="arm64 x86_64"` 可生成两个独立 App。本地开发证书与项目的公开发布证书是不同身份。

如果本机 CLT 27 报缺少 `SwiftUIMacros`，且已经安装 macOS 26.5 SDK，可显式选择该 SDK：

```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk bash script/build_and_run.sh
```

通用 DMG 入口 `bash script/package_dmg.sh` 沿用本机构建的签名选择。桌面脚本默认只构建当前架构，依次尝试 Apple Development、本地自签名身份；若本地身份创建失败且未禁止降级，才会退回 ad-hoc。完成上述本地身份配置后，可以明确禁止该降级：

```bash
SM_ALLOW_ADHOC=0 bash script/package_dmg_to_desktop.sh cleanup-parity
```

结果位于 `~/Desktop/Nori-<arch>-cleanup-parity.dmg`，并在 Finder 中定位；不传 label 时使用时间戳。公开发行应使用 `package_release.sh`，确保使用仓库固定的发布身份。

仅用于临时测试的 ad-hoc 构建需显式开启：

```bash
SM_CODESIGN_IDENTITY=- SM_ALLOW_ADHOC=1 bash script/build_and_run.sh
```

这种签名可能在重编译或更新后要求重新授权，不能用它验证跨版本权限保留。若旧授权已失效，先退出 App，在系统设置中移除旧条目，重新添加实际安装的新版 App 并开启权限。

### 可选的 Apple 公证发布

持有 Developer ID 的维护者仍可使用独立的签名公证流程：

```bash
SM_CODESIGN_IDENTITY="Developer ID Application: ..." \
SM_NOTARY_PROFILE="forgesweep" \
bash script/release.sh
```

`SM_NOTARY_PROFILE` 是通过 `xcrun notarytool store-credentials` 保存的钥匙串配置名。此流程默认校验并使用 `vendor/mole/UPSTREAM_COMMIT`，分别公证两个架构，生成 `dist/Nori-arm64.zip` 和 `dist/Nori-x86_64.zip`，其中 App 已 stapled。升级 Mole 时应整体更新 `vendor/mole/`、重新审计并运行完整测试；也可通过 `MOLE_SRC=/path/to/Mole` 临时验证上游检出。

## Nori 图标与动态形象

新版品牌采用冰蓝 Nori 形象。已包含同源 SVG、Apple Icon Composer 工程、兼容 ICNS、菜单栏 1×/2× 模板，以及静态眨眼、彩带环绕工作、开发者/Agent/磁盘/应用活动、整理、成功与提醒状态；闲置时提供喝咖啡、打盹、哼歌和吹泡泡动画。产品身份已全面切换为 Nori：Bundle ID 为 `com.nori.app`，可执行文件与构建产物均为 `Nori.app`；旧 ForgeSweep / Simple Mole 的偏好设置与数据目录（Application Support、Caches、Logs）在首次启动时自动迁移。因 Bundle ID 变化，升级后可能需要重新授予一次完全磁盘访问、屏幕录制等系统权限。发布签名证书沿用已固定的历史身份（标签 "ForgeSweep Release Signing"，指纹不变），GitHub Actions secret 名称保持 `FORGESWEEP_SIGNING_P12_*` 不变，已配置的仓库无需改动。

[设计和调用说明](brand/nori-design.md) · [动画预览](brand/nori-preview.html)

全部资源重建：`bash script/make_nori.sh`；动画与资产验证：`bash script/test_nori.sh`。


矢量渲染主图、菜单栏模板、设计记录与 ICNS 分别位于 `SimpleMole/Support/AppIcon-1024.png`、`MenuBarIconTemplate.png`、`AppIcon.prompt.txt` 和 `AppIcon.icns`。更新主图后运行：

```bash
bash script/make_icon.sh
```

主窗口应用栏使用无底色 Nori 矢量动画，Dock / Finder 使用彩色 App 图标；菜单栏状态项使用独立的单色 Template 图标，由 macOS 自动适配深浅色。

`dist/<架构>/Nori.app` 内嵌 Swift 主程序、`bridge/` 脚本和 `lib/core/` 中的审计辅助函数。构建与桥接回归共用
`script/stage_bridge_resources.sh`，避免未被调用的 Mole 模块进入成品；
不再打包 Mole CLI、旧卸载入口或 Go 辅助程序。开源 GitHub Release 使用
`package_release.sh` 校验固定自签名身份并生成 DMG；可选的 `release.sh`
流程则校验 Developer ID、TeamIdentifier、公证和 stapling。

## 目录

```
SimpleMole/   Swift 源码（AppKit 骨架 + SwiftUI 视图 + 服务层）
bridge/       app_*.sh 桥接脚本（删除边界复用引擎函数）
vendor/mole/  固定版本的 Mole 桥接支持源码与 GPLv3 许可证
script/       构建、运行、发布、测试与图标脚本
signing/      固定发布身份的公开证书与指纹记录（无私钥）
docs/         发布签名与维护说明
SimpleMole/Support/  Info.plist 与应用图标
dist/         构建产物（gitignored）
```

## 验证

```bash
bash script/test.sh
```

测试覆盖脚本语法、Plist、受保护路径权限门禁、关键删除身份绑定、GC 退出码、图片计划互斥，并可执行 Swift 构建与签名检查。测试数据只在临时目录内创建。

## 安全约定

- 磁盘清理、全盘分析、卸载残留和图片全目录扫描统一经过权限门禁。未检测到“完全磁盘访问”时只打开 App 内权限中心，不启动扫描；授权后自动恢复用户刚才的操作。后台任务在未授权时安静跳过。
- Swift 只在实测授权成功后向扫描子进程传递 `FORGESWEEP_FULL_DISK_AUTHORIZED=1`。桥接脚本默认拒绝或跳过 Desktop、Documents、Downloads、Pictures、其他 App 的 Application Support / Containers 等受保护根，避免未来调用点遗漏门禁后触发原生文件夹弹窗。
- 完全磁盘访问和屏幕录制是 macOS 的两项独立权限：前者一次授权覆盖 Nori 的磁盘扫描，后者仅在使用截图功能时单独请求。开发者签名用于稳定识别 App，不会自动授予这两项权限。

- 所有原生删除计划同时携带扫描或选择时捕获的 `device:inode:mtime` 身份，并在最终落盘前复验；桥接删除仍使用 NUL 协议传递，文件名中的空格或换行不会改变边界。
- 卸载同时绑定应用绝对路径、Bundle ID、应用目录身份和 `Info.plist` 身份；预览与执行都重新扫描并要求精确匹配，拒绝同名应用或中途替换。
- 卸载队列为每个已确认任务独立保存应用身份与预览快照，实际卸载保持串行并与其他磁盘清理互斥。等待项可取消，执行中的任务不可通过单项取消中断；退出会停止队列，重启不会自动继续删除。
- 白名单在扫描与执行两侧同时生效（`is_path_whitelisted`），预览与清理结果一致。
- 硬盘清理先确认容量估算，只接受 Safe 垃圾并明确提示“永久删除、不可恢复”；卸载、磁盘分析与自动目录规则默认使用废纸篓保护。Agent 专清直接执行所选动作，没有第二次确认弹窗，其中选中文件通过 `permanent: true` 永久删除；历史、凭据、未知数据及资源移除保持手动选择和风险提示。
- 自动目录规则默认关闭，只处理用户选择目录的第一层子项；容量策略保护最近一小时仍有写入的内容，父规则也不会移走另一个已配置规则的目录。执行侧重新验证规则根目录、直接父子关系、扫描时文件身份和白名单，再移入废纸篓。
- 原生卸载只自动处理已确认身份的应用本体与用户目录数据；LaunchAgent、LaunchDaemon、PrivilegedHelper 和诊断报告等系统位置只展示为人工复核项，不自动提权删除。
- 系统清理选择清单使用 NUL 编码、SHA-256、私有权限和执行侧白名单复验，拒绝被替换、软链接或权限过宽的清单。
- 测试与联调使用 `MOLE_TEST_NO_AUTH=1` 避免真实授权弹窗。
