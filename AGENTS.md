# Nori 界面约定

## SwiftUI 优化 Skill

进行 SwiftUI 界面开发、审查或优化时，先阅读并使用项目内的 `.agents/skills/swiftui-expert-skill/SKILL.md`，再按任务需要加载其 `references/` 中的相关文档。

来源：<https://github.com/AvdLee/SwiftUI-Agent-Skill>。以本项目的 macOS 部署版本和实际 SDK 为准；若通用建议与下方液态玻璃约定冲突，优先遵循本项目约定。

## 主线程与耗时任务边界

- 界面主线程只处理交互、轻量状态和已计算结果的发布。不要在 `View.body`、显示用计算属性或绑定 setter 中枚举文件系统、读取文件属性、排序大列表，或反复遍历整份扫描库存。
- `async`、`Task {}` 和 `.task` 不保证离开 `MainActor`。耗时只读扫描应走独立 worker 进程；后台编码、解码、聚合、展示投影和排序须使用明确的后台执行边界，再返回带版本的快照。
- worker 必须支持取消、父进程退出、超时和协议错误；不可因 worker 缺失或失败而静默回退到主线程。扫描 worker 不提供清理、卸载或其他破坏性协议。
- 展示缓存按真实库存与规则版本失效。选择、展开、进度和系统指标变化不得重新遍历十万级路径；同数量、同总字节的路径替换也必须正确失效。旧异步任务不得覆盖新结果。
- 展示快照不是执行授权。实际清理前仍须重新检查身份、权限、白名单、占用和内容保护。
- 修改这条链路时，验证十万级规模、主线程心跳、版本失效和进程取消/失败场景，不只验证结果正确或编译通过。使用合成数据或专属临时夹具，不为性能测试清理真实用户数据。

## 液态玻璃交互

玻璃只留给导航和浮层，内容层改用 surface 面板，从而建立主次和区域。

- 玻璃分层：L0 是窗口底的 `GlassSurface`，L1 是导航与浮层——`PillPicker` 选中、侧栏选中透镜（`SidebarSelectionLens`）、`liquidSurface` 弹层、灵动岛、启用态主操作按钮（`ActionGlassChrome`）。一屏玻璃不超过约三处。
- 内容层不用玻璃：L2 工作区面板只用于带侧栏页的右侧（`.contentPanel()`，surface1 圆角 14），单列页内容直接落在窗口玻璃上；L3 行/卡片用 `ListRowSurface`——分组头 surface2，普通行 surface1，选中态 `selectionFill`，已打开路径 surface2。滚动列表里的原生玻璃会逃出裁剪泄漏到相邻视图，不要引入。
- 玻璃只有一层。不要在玻璃上叠不透明色块，否则模糊和折射会被盖住，看起来像玻璃没生效。
- 玻璃必须直接包住内容：对内容调用 `glassEffect`，不要把玻璃做成内容后面的 sibling。文字若垫在独立玻璃层后面，会被合成层反向遮挡。
- 选中态就是玻璃透镜，不是 `opacity` 色条，但只限导航与浮层。用 `GlassEffectContainer`（或 `LiquidGlassGroup`）把可切换的玻璃放在一组里，选中项使用 `glassEffect` + `glassEffectID` + `glassEffectTransition(.matchedGeometry)`。减少动态效果时过渡用 `.identity`。内容行的选中改用 `selectionFill`，不做玻璃透镜。
- 可点击的玻璃加上 `.interactive()`，减少动态效果时关掉。禁用控件不用玻璃，回退 surface1 实底（`ActionGlassChrome` 已处理）。
- macOS 26 以下，或系统开启「减少透明度」时，回退到 `GlassSurface` / `Color.glassOpaque`，不要留空。
- 底色用 `surface1/2/3`，描边用 `hairline`，状态色用 `success/warning/danger`。不要新写 `Color.white.opacity` 或 `Color.black.opacity` 当面板底。

参考：`Views/Theme.swift`、`Views/LiquidPresentation.swift`、`Views/Components.swift` 的 `PillPicker`。

## 需求完成后的安装

每完成一项需求，运行 `script/install_update.sh`。它会编译新版本，退出正在运行的 Nori，卸掉 `/Applications` 里的旧版，验签后安装并启动。编译或验签失败时不会替换已安装的版本。
