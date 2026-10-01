# Nori 品牌与动态形象

Nori 是安静照看 Mac 的小伙伴。形象沿用确认过的极简稿：轻微倾斜的圆润主体、两颗胶囊眼睛；无嘴、工具、装饰和烘焙高光。正文、进度与权限提示仍由真实界面承担，形象不单独表达成功或失败。

## 生产资产

- `SimpleMole/Support/Nori/design.json`：唯一几何与颜色母版；`script/generate_nori.py` 同步输出 SVG 和 `Views/NoriGeometry.swift`。
- `Nori/Nori.svg`：透明静态形象，256 × 256 矢量坐标。
- `Nori/AppIcon.icon`：Apple Icon Composer 工程，1024 × 1024、未预裁切前景、全幅不透明纯色背景。已用 Apple `ictool` 实际导出验证。
- `AppIcon-1024.png`、`AppIcon.icns`：当前手工 Swift 构建采用的 macOS 13+ 兼容图标，sRGB，1024px 母版，光学内缩；ICNS 覆盖 16 / 32 / 64 / 128 / 256 / 512 / 1024px 和 Retina 表示。
- `HeaderBrandIcon.png`、`LogoTransparent.png`：透明静态形象。原生动态组件直接绘制同源路径，不再盖住旧图片的眼睛。
- `MenuBarIconTemplate.png`、`MenuBarIconTemplate@2x.png`：18pt、1×/2×，仅黑色与透明眼孔，AppKit 设置 `isTemplate = true`。菜单栏不循环动画。

当前构建继续使用 `CFBundleIconFile = AppIcon` 的 ICNS，不声称已集成系统动态 Liquid Glass 图标。现代 `.icon` 源文件已经准备好；当前 Xcode 的 `actool` 因缺少首次启动组件而不可用，因此本次没有把未验证的 `Assets.car` 加入构建。

## 配色

- 主体：冰蓝 `#BFEAF2`
- Dock 背景与眼睛：深海蓝 `#10283F`
- 环绕与彩纸三色：水蓝 `#69C7DD`、柔金 `#F2C66D`、淡紫 `#B8A7DF`
- 结果图标：成功薄荷绿 `#5FC98A`、失败珊瑚红 `#E56672`

保留项目刚完成的 Earth Blue / 单层液态玻璃主题。原生裸形象在浅色玻璃上增加细深色轮廓，避免浅蓝与背景混在一起；在深色界面省略轮廓。SVG 素材保持批准的纯色外形，浅色使用场景可选择深海蓝承托背景。

## SVG 状态

SVG 自包含 CSS、无脚本和外部资源。深色宿主中的 `<object>` 建议设置 `color-scheme: normal`，避免浏览器因嵌套文档色彩模式不一致而补白色底。可通过 `<img src="…svg">` 或 `<object data="…svg" type="image/svg+xml">` 使用。全部包含 `prefers-reduced-motion: reduce` 静态降级；用作装饰时给 `img` 设置空 `alt`。

「工作中」保留标志性的三色环绕。其余扫描和执行状态只用 Nori 自身的挤压回弹、弹跳、摇摆、呼吸与浮动表达正在处理，不再描绘键盘、柱状图、应用图块或收纳篮。五种抽象动效共用同一个居中位置、主体大小和基线；辅助圆点或波纹居中放在主体下方，短弧留在两侧，始终留出间隔。成功和失败共用同一个圆形结果图标，弹在 Nori 右下角并盖住一部分身体：成功是绿色「✓」并放彩纸，失败是珊瑚红「!」。闲置动效没有业务含义，用于各 tab 占位和灵动岛陪伴。

| 文件 | 行为 | 使用场景 |
| --- | --- | --- |
| `nori-static.svg` | 身体不动，4.2 秒眨一次眼 | 只作降级替补：没有指定动画的占位、减少动态效果、App 失活 |
| `nori-working.svg` | 三色缎带前后环绕 + 果冻回弹 | 硬盘清理扫描与执行、Agent 清理执行 |
| `nori-typing.svg` | 1.65 秒双拍弹跳，落地挤压、跃起伸展，下方三点跟随节拍 | 开发环境检索 |
| `nori-agent.svg` | 1.8 秒左右轻摆并伸缩，下方三点依次明暗交替 | Agent 扫描 |
| `nori-disk.svg` | 2 秒浮起回落与果冻形变，下方两圈波纹错拍扩散 | 磁盘分析 |
| `nori-apps.svg` | 2.2 秒舒展呼吸，两侧短弧同步张合 | 软件 tab 首次载入 |
| `nori-tidying.svg` | 1.4 秒挤压回弹，下方三点轻轻起伏 | 清理中与卸载中共用；顶部栏仅形象形变，不显示任务胶囊；清理页执行时整页展示 |
| `nori-success.svg` | 1.9 秒：右下角弹出绿色「✓」圆标，同时彩纸炸开，跳一下、眯眼看向图标，仅一次 | 任务成功 |
| `nori-attention.svg` | 1.9 秒：右下角弹出珊瑚红「!」圆标，身体微沉、低头看向图标，仅一次 | 任务失败或部分失败 |
| `nori-coffee.svg`、`nori-doze.svg`、`nori-humming.svg`、`nori-bubble.svg` | 喝咖啡（举起无把手的小杯抿一口、两缕热气）、打盹、哼歌、吹泡泡 | 各 tab 开始任务前的占位：每次打开窗口随机选一个，所有 tab 保持一致；灵动岛空闲时每次展开轮换，刘海屏放在刘海左侧肩位，无刘海屏放在指标行最左 |

原来的待机、无聊、照镜子、眨眼并入静态；原来的分析与敲键盘合并；检视带业务含义，已移除。减少动态效果时只留下静态形象，道具全部隐藏。扩展场景源文件位于 `script/nori_scenes.py`，用 `script/generate_nori.py` 重建；动效总览见 `docs/brand/nori-animations.html`。

单次 SVG 通过重新挂载来重播。普通图片导出会得到静态帧，CSS 动画仅由支持 SVG CSS 的渲染器播放。

## 原生调用

```swift
NoriMascotView(mood: .working, size: 48)
NoriMascotView(mood: .success, size: 64).id(completionEventID)
```

标题栏继续使用轻量 SwiftUI Canvas。各页空态统一用窗口打开时随机选中的闲置动效，扫描中播放各自的抽象活动节奏；WebKit 仅加载内联图片，禁用 JavaScript、网络和持久存储，减少动态效果或 App 失活时停止形变并隐藏辅助动效，离开页面时释放。`NoriMotion` 为纯时间采样，表情/果冻运动与 SVG 对应；彩纸与结果图标和 SVG 同样的位置与节奏；标题栏的 20pt 形象在四周留出 0.7 倍尺寸的绘制余量，道具可以画到图标外面。切换 `mood` 会重置时间；相同单次状态的新事件用新的 `.id` 重播。

标题栏接入全部 `isBusy` 工作态。任务结果只在标题栏表示：成功时右下角弹出绿色「✓」圆标、Nori 眯眼跳一下并放彩纸；失败或部分失败时弹出珊瑚红「!」圆标。取消和什么都没做保持安静。页面里不再放庆祝或提醒形象，失败时只留一个警示图标和实际结果文字。对工作中的形象不启用跟随鼠标；静止时保留眼睛跟随。

原生在视图消失、窗口不可见/最小化/被遮挡、App 失活、减少动态效果开启时暂停时间线。成功/失败会在播放结束后停止刷新。无随机翻转、无限循环的结果动画或菜单栏动画。

## Apple 设计依据与兼容边界

依据 2026-09-27 查阅的 Apple 官方指南：

- [App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)：简单、可辨识、视觉一致；1024px 未遮罩分层源文件、清晰轮廓、内容居中留出空间；背景全幅不透明；让系统添加光效。
- [The menu bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar)：菜单栏符号使用黑色与透明，由系统适配浅/深色和选择态；24pt 菜单栏内采用 18pt 模板图。
- 系统减少动态效果使用 SwiftUI `accessibilityReduceMotion`；SVG 使用对应媒体查询。

兼容 ICNS 必须与 Icon Composer 的未遮罩层区别使用，避免重复圆角。没有使用 Apple 硬件图样、品牌文字或系统图标作为 App 标识。

## 重建与验证

```bash
bash script/make_nori.sh
bash script/test_nori.sh
```

当前机器若默认 Xcode 受许可证/组件配置影响，可只对命令选用已安装 CLT 和 26.5 SDK，不修改系统设置：

```bash
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
bash script/make_nori.sh
```

`docs/brand/nori-preview.html` 提供所有状态、浅/深色背景、暂停、减少动态效果和单次动画重播；从仓库根目录启动本地 HTTP 服务预览，保留相对路径。

可见名称与产品身份均为 Nori：Bundle ID `com.nori.app`，可执行文件与构建产物为 `dist/<arch>/Nori.app`。旧 ForgeSweep / Simple Mole 的偏好与数据目录（Application Support、Caches、Logs）由 `BrandMigration` 在首次启动时自动迁移；发布签名沿用已固定的历史证书（标签 "ForgeSweep Release Signing"，指纹不变）。

## 本次验证记录（2026-09-27）

- 全项目 Swift 类型检查通过（macOS 13 target、26.5 SDK）；现有 AppState 捕获所有权警告仍存在。
- `script/test_nori.sh` 通过：六种动态状态的形变范围与画布边界、减少动态效果、成功/提醒单次结束、旧成功标记隔离、图标像素尺寸、菜单栏黑色/透明眼孔、Bundle 身份不变。
- 浏览器实测通过：九种 SVG 动画加载、暂停/恢复、庆祝重播、三个道具动作独立重播、旋转彩带前后层四个相位同步、减少动态效果、360px 窄屏无溢出、零脚本与资源错误。
- SVG XML 解析与 ICNS 11 个表示的尺寸检查通过；Icon Composer 源文件经 Apple `ictool` 成功导出。
- 全套 `script/test.sh` 在原有灵动岛首击契约检查失败：检查还在 `FloatingIslandView.swift` 查找 `acceptsFirstMouse`，当前实现已移至 `IslandWindow.swift`。本次未改动该功能或掩盖测试失败。
- `script/build.sh` 被缺少可用 Apple Development / 本地签名证书阻挡；未安装或覆盖 `/Applications` 中的旧 App，未更换签名或权限身份。
