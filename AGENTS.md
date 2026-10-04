# Nori 界面约定

## SwiftUI 优化 Skill

进行 SwiftUI 界面开发、审查或优化时，先阅读并使用项目内的 `.agents/skills/swiftui-expert-skill/SKILL.md`，再按任务需要加载其 `references/` 中的相关文档。

来源：<https://github.com/AvdLee/SwiftUI-Agent-Skill>。以本项目的 macOS 部署版本和实际 SDK 为准；若通用建议与下方液态玻璃约定冲突，优先遵循本项目约定。

## 液态玻璃交互

新的面板、菜单、弹出层和选中态都使用液态玻璃，不要再做实色卡片配一块灰色高亮。

- 玻璃只有一层。不要在玻璃上叠不透明色块，否则模糊和折射会被盖住，看起来像玻璃没生效。
- 玻璃必须直接包住内容：对内容调用 `glassEffect`，不要把玻璃做成内容后面的 sibling。文字若垫在独立玻璃层后面，会被合成层反向遮挡。
- 选中态就是玻璃透镜，不是 `opacity` 色条。用 `GlassEffectContainer`（或 `LiquidGlassGroup`）把可切换的玻璃放在一组里，选中项使用 `glassEffect` + `glassEffectID` + `glassEffectTransition(.matchedGeometry)`。减少动态效果时过渡用 `.identity`。
- 可点击的玻璃加上 `.interactive()`，减少动态效果时关掉。
- macOS 26 以下，或系统开启「减少透明度」时，回退到 `GlassSurface` / `Color.glassOpaque`，不要留空。
- 底色用 `surface1/2/3`，描边用 `hairline`，状态色用 `success/warning/danger`。不要新写 `Color.white.opacity` 或 `Color.black.opacity` 当面板底。

参考：`Views/Theme.swift`、`Views/LiquidPresentation.swift`、`Views/Components.swift` 的 `PillPicker`。

## 需求完成后的安装

每完成一项需求，运行 `script/install_update.sh`。它会编译新版本，退出正在运行的 Nori，卸掉 `/Applications` 里的旧版，验签后安装并启动。编译或验签失败时不会替换已安装的版本。
