# 菜单栏收纳：界面、原生交互与兼容性

收纳配置位于 Nori 主设置面板的「菜单栏收纳」分区，不创建独立窗口。启用、应用选择、刷新、收起／恢复和权限状态采用 Nori 的开关、surface 行和按钮样式。

灵动岛「快捷指标」新增「收纳」勾选项，与 CPU、内存等使用同一套持久化配置。未勾选时不显示收纳控件。勾选后展示最多三个图标缩略图和剩余数量；悬停或点击展开图标网格。顶部在同一岛表面向下展开；左右侧栏向屏幕内侧展开，与资源详情共用命中区域和减少动态效果回退。没有常驻的收纳盒按钮。

## 预览与操作

- 未授权辅助功能时，使用已选应用的应用图标预览，并提示授权；不能将这些预览误称为已经读取到的真实菜单栏图标。
- 辅助功能授权后，通过公开 AXExtrasMenuBar 读取已选应用的状态项。一个应用有多个图标时，网格显示多个状态项；macOS 27 的隐藏仍按整个应用进行。
- macOS 14 及以上、已有屏幕录制授权时，用 ScreenCaptureKit 截取展开状态的状态项区域作为真实缩略图。只缓存复制后的局部像素，不保存屏幕截图、不保留整屏缓冲。无法截取时回退应用图标。
- 图标左键／右键会恢复原菜单栏，重新解析对应应用的原状态项，再执行原生 AXPress 或在不支持 AXPress 时转发经过位置验证的点击。不会用打开应用主窗口代替菜单操作。
- 无权限、原图标消失或身份／数量变化导致无法定位时，保持展开并进入 Nori 设置显示说明。原菜单打开于 macOS 原生位置。操作原菜单后可以从收纳列表再次收起；没有猜测菜单结束时间来强制重新隐藏。
- 菜单栏恢复按钮继续保留，关闭功能和退出 Nori 时恢复全部图标。显示器变化、睡眠／会话退出、新应用启动／退出时也恢复展示，不自动重新收起。

## 系统范围

| 系统 | 隐藏方式 | 预览／交互限制 |
| --- | --- | --- |
| macOS 13–26 | 自有 NSStatusItem 分隔条变宽，推出左侧图标 | 布局技巧，不是苹果稳定收纳契约。仅 LTR。按住 ⌘ 将图标拖到 │ 左侧，恢复按钮留在右侧。读取分区图标需要辅助功能；macOS 13 的缩略图使用应用图标回退。刘海／多屏仍需实机验收。 |
| macOS 27 | MenuBarClientCore 私有可见性限制，明确标注实验 | 同一应用的图标一起隐藏。系统控制和未选中应用保留。辅助功能用于读取和原生交互，屏幕录制用于真实缩略图；仅隐藏本身无需这两项权限。系统升级可能失效，不承诺 App Store 兼容。 |
| 其他版本 | 停用隐藏 | 未知版本不静默复用私有后端。 |

没有将第三方 NSStatusItem 重新挂载到 Nori 窗口。网格展示缓存缩略图，交互转交原应用的真实状态项。状态项缺少可靠标识时使用本次清单的序号和数量校验，变化后拒绝猜测点击目标。

## 验证

环境：macOS 27.0.1，arm64，SDK 27.0。

- `script/test_menu_bar_collection.sh`：版本门控、仅隐藏选中集合、保留自身／系统／未选中／新应用以及多屏宽度边界。
- `script/test_menu_bar_controller.sh --native`：一次性应用夹具；真实私有接口激活、待完成请求取消、迟到回调、应用启动恢复、停用恢复、主设置回调路由（不生成窗口）。测试偏好独立，夹具退出后清理。
- `script/test_island_window.sh`：原生命中、首次点击、右键转发、禁用时不转发以及侧栏拖动回归。
- `script/test_island_side_presentation.sh`：真实 View 的顶部／左右侧栏缩略图和网格，六个图标的左右键目标、详情命中区域、透明间隙、多指标、两种语言及减少透明度回退。
- 真实应用的 AX 菜单和真实图标截图需要 Nori 本机对应授权；布局夹具使用合成图标，不把布局通过当成全部第三方交互已验收。
- 全仓本地化审计已有 17 条未翻译文本问题；新增中文收纳文案提供简／繁体，其他语言暂用英文回退。

## 研究来源

- [Apple NSStatusItem](https://developer.apple.com/documentation/appkit/nsstatusitem)
- [Hidden Bar architecture](https://github.com/dwarvesf/hidden/blob/develop/docs/ARCHITECTURE.md)
- [Hidden Bar native visibility engine](https://github.com/dwarvesf/hidden/blob/develop/hidden/Features/StatusBar/Engine/NativeVisibilityEngine.swift)
- [Hidden Bar private API shim](https://github.com/dwarvesf/hidden/blob/develop/hidden/Features/StatusBar/Engine/Native/HBNativeVisibilityShim.m)

Nori 的后端按研究到的接口独立实现。构建使用固定签名身份；本地测试版本保持 1.0.10 / build 11。

安装后的实测：Nori 主设置中存在「收纳」快捷指标勾选项；应用选择行使用现有样式，灵动岛显示三张缩略图与 +3，展开后列出六个当前已选应用。已从岛内执行收起／恢复并确认状态切换，齿轮按钮返回同一个 Nori 主设置窗口。用户现有应用选择保留，收纳展示项已勾选。当前 Nori 尚无辅助功能授权，实际原生图标和原菜单交互仍等待授权；没有自动授予权限。

本次日志保存在 `dist/menu-bar-hover-validation/`。

最终权限说明文案同步后已再次编译、验签、安装并启动成功，版本保持 1.0.10 / build 11。最终安装日志：`dist/menu-bar-hover-validation/install.log`。

发布前复核（2026-10-14）：已用 SDK 26.5 编译并通过 `script/install_update.sh` 安装 1.0.11 / build 12，保持固定签名身份。55 个布局场景覆盖顶部／两侧、刘海屏、收纳网格、网络空闲／进行中／失败、设置页、英文／简体／繁体和减少透明度回退。完整回归的已通过前段与修复后的后段合计 46 项通过；CI 对最终提交重新执行完整回归。新增原图标点击前的 PID／应用身份校验。日志位于 `dist/v1.0.11-validation/`，辅助功能授权与跨系统实机验证的限制仍同上。
