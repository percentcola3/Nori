# Nori 清理与磁盘分析策略

本文档描述垃圾清理与磁盘分析的统一规则模型、默认保留策略、执行语义与已知边界。实现与测试位于 `SimpleMole/Services/` 与 `script/`。

## 1. 统一规则与候选模型

发现（`NativeCore.cleanupRoots`）、分类（`CleanupRiskPolicy`）、展示（清理页分组）、执行（`performApply` → `CleanupApplyRoute`）与自动化（`AutoCleanup`）共用同一套定义：

- **发现层**为每个候选声明：路径、标签、来源（`CleanupSource`）、运行态守卫（`CleanupActivityGuard`）与默认保留期（`retention`，秒）。
- **策略层**（`CleanupRiskPolicy`）对路径裁决风险等级、处置动作、执行路由与保护名单；发现层枚举出的每个条目都先过策略，`risk == .safe` 才进入计量与展示。
- **候选**（`CleanupCategory`）携带：路径与文件身份（`device:inode:mtime`，执行前复验）、占用大小与统计完整性、活动证据（同一次 FTS 遍历采集的 mtime/atime 最大值）、保留期、可执行动作与默认推荐状态。

风险分层：

| 层级 | 语义 | 页面表现 |
| --- | --- | --- |
| 推荐清理（safe） | 满足该类内容的全部回收条件（可再生 + 归属明确 + 未活跃 + 未被占用） | 默认勾选 |
| 需要确认（warning） | 有回收价值但存在恢复成本 / 用户数据 / 归属不确定 | 默认不勾选 |
| 保留/受保护（protected） | 正在使用、最近活跃、共享归属、证据不足或含持久数据 | 不可勾选或标注原因 |

## 2. 「7 天未活跃」的语义（`CleanupAgePolicy`）

- 默认保留期 = 连续 7 × 24 小时，边界含：恰好满 7 天视为未活跃（测试固定）。
- 活动证据 = 缓存单元内所有文件 mtime / atime 的最大值，在同一次大小计量遍历中采集（FTS 单次遍历同时取 blocks / inode / 时间戳，无二次 stat）。
  - ctime 不作为证据：chmod、备份、迁移等元数据操作都会刷新它。
  - atime 仅在比 mtime 新时生效（noatime 挂载下不可信）。
- 判定单元是“可独立清理的缓存单元”：Gradle `build-cache-*` 单目录、DerivedData 单项目、npm/pip 等整缓存。活跃条目保留在页面上但默认不勾选（原因 `cleanup.risk.recentlyActive`），不会冻结同组其他条目。
- 证据缺失、未来时间（时钟偏差容忍 120s）、遍历不完整 → 一律不升级为推荐。
- **执行前重检**（`performApply`）：对 `retention > 0` 的类目按选中路径重新计量，扫描后重新活跃或证据失效的条目计入「已跳过」。

## 3. 各类内容的覆盖与默认保留

| 内容 | 默认保留期 | 说明 |
| --- | --- | --- |
| 应用/浏览器/IM 可再生缓存、日志、崩溃报告 | 无年龄门 | 由运行态守卫 + 执行前身份/占用复核把关 |
| 开发者缓存与构建产物（npm/pnpm/Yarn/Bun/pip/uv/Cargo/Go/Gradle build-cache/SwiftPM/DerivedData/各前端构建缓存…） | 7 天 | DerivedData 与 Gradle 按子目录单元；自定义位置见下 |
| 依赖仓库（Maven local、Gradle modules、NuGet packages、pub-cache、cargo registry/src） | 只读复核 | 永不进入一键清理；`toolCommand` 路由交给工具自身的清理命令 |
| IM：Telegram 媒体缓存 / 飞书文档预览 / 各 IM 容器与 App Support 缓存叶子 | 无年龄门 | messenger 守卫按具体应用收窄：微信在跑不冻结 Telegram |
| 聊天数据库、账号状态、凭据、会话 | 保护 | `isProtectedContent` 名单（Keychains、sessions、模型权重等） |
| 卸载残留（废纸篓中的 App + 深度扫描下未安装应用的容器） | 无年龄门 | 仅缓存/日志叶子可回收，按 Bundle ID 精确归属 |
| 废纸篓、诊断报告、设备固件、Messages 预览缓存 | 无年龄门 | macOS 可再生 |

**自定义缓存位置**（`DeveloperCacheLocations`，只读解析、进程内复用）：`~/.npmrc cache=`、`.yarnrc.yml cacheFolder`、`pip.conf cache-dir`、`POETRY_CACHE_DIR`，以及 `GRADLE_USER_HOME / CARGO_HOME / GOMODCACHE / GOCACHE / NPM_CONFIG_CACHE / YARN_CACHE_FOLDER / PIP_CACHE_DIR` 环境变量。发现层与策略层共用同一解析，杜绝“扫得到却被保护规则拦下”（Gradle 冲突回归有测试）。`XDG_CACHE_HOME` 整体重定向暂不支持（已知边界）。

**保护名单**：`~/.config/mole/whitelist`（literal / `~` / `$HOME` / glob）在发现、执行两层生效；受保护子目录会保护其父目录不被整体提供。

## 4. 磁盘分析范围

- 只保留一个扫描范围菜单：用户空间、根目录、自定义目录；首次从当前用户主目录开始。
- 三种范围统一使用 `DiskAnalysisWorker`，不再混入保存位置或项目雷达。
- FTS_PHYSICAL + FTS_XDEV 避免符号链接循环与跨卷重复；硬链接按设备和 inode 去重；取消保留部分结果，下钻复用会话缓存。

## 5. 执行语义一致性

- `CleanupDisposal` 枚举与执行器行为一致：清理页路由执行**永久删除**（`permanentDelete`，旧快照的 `trash` 值解码兼容）；AI / Xcode / 工具等特殊家族经各自入口**移入废纸篓**或执行工具命令。执行汇总按家族区分文案（`已永久删除 %d · 已跳过 %d · 已失败 %d`）。
- 执行前逐项复核：路径身份（`device:inode:mtime`）、符号链接、保护名单、运行态（进程快照 + 打开文件快照，缺失即跳过）、7 天活跃门重检。单个候选失效只跳过自身，不影响其他独立候选。
- 已跳过/失败的原因写入日志；预计可回收空间与实际处理数分开呈现（`已处理/已永久删除 · 已跳过 · 已失败`），移入废纸篓不宣称释放了同等磁盘空间。

## 6. 已知边界（诚实清单）

- 5 分钟结果缓存恢复时会重新全选 Safe 条目（含活跃的开发缓存）；执行前重检兜底跳过，不会误删。
- 项目雷达与休眠已移除；开发缓存清理保留独立的项目活动、路径身份和风险校验。
- IM 聊天附件的独立时间/类型/大小筛选尚未提供；附件与数据库保持只读复核。
- 未安装应用容器的 Application Support 数据树仍属“需要确认”，只在磁盘分析中人工处理；本次仅放行其缓存/日志叶子。
- SDK / 运行时 / Docker 镜像不按文件年龄处理，依赖各自管理接口（`toolCommand` 路由）。
- 深度分析未提供独立挂载卷选择器（可用「选择文件夹」指定任意卷路径）。

## 7. 测试索引

- `script/CleanupScanTests.swift`：目录目录、分组、白名单、取消、部分结果、硬链接；**7 天门扫描级**（旧项目推荐/新项目保留、执行前复核、GRADLE_USER_HOME / npmrc 自定义位置发现与策略一致性）。
- `script/CleanupRiskPolicyTests.swift`：风险默认值、路由、运行态守卫（messenger 按应用收窄）、**年龄边界**（恰好 7 天/差一秒/缺失/未来）、**处置解码兼容**、长尾合并。
- `script/test_disk_analysis.sh`：深度遍历、目录层级、稀疏文件、取消与缓存导航。
