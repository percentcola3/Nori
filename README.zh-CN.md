# Nori

**让 Mac 用起来更方便，也更干净。**

Nori 是一款为 **macOS 13 Ventura 及以上**打造的轻量原生增强工具。它把更深度的垃圾清理、磁盘与文件管理、截图、剪贴板历史等常用能力，集合在一个安静的 Mac 伙伴里，用原生 Swift + SwiftUI 和灵动岛风格的交互，让日常维护变得简单愉悦。

![Nori 中文主界面](docs/screenshots/zh-CN/overview.png)

## 这款产品是什么？

Nori 源于一个真实的小困扰：一直找不到一款真正轻量、顺手的 Mac 剪贴板工具。受 [tw93/Mole](https://github.com/tw93/Mole) 这款开源作品启发后，我发现“小工具”同样能创造巨大价值——它们解决的是每天真实存在、却又总被忽略的小麻烦。于是我把 Mole CLI 的清理能力融入 Nori（非常感谢 tw93），又补上了开发者最常用的工具，希望它成为 Mac 上安静又可靠的伙伴。

不用打开复杂面板，就能随手清理垃圾、查看磁盘占用、找回复制过的内容、截一张顺手标注的图，并随时掌握系统状态。

> **早期开发阶段，目前尚不够稳定。** 扫描、清理、权限处理和界面交互仍可能存在问题。删除前请核对所选路径，保留重要数据备份；反馈问题时请附上 macOS 版本和复现步骤。

## 核心能力一览

| 模块 | 一句话卖点 | 典型场景 |
| --- | --- | --- |
| **深度垃圾清理** | 识别可安全重建的缓存、日志、残留，按风险分层勾选 | Xcode / npm / pip 缓存、AI Agent 数据、卸载残留、废纸篓 |
| **开发者工作台** | 统一管理运行时、Shell、hosts、CLI 和端口 | 旧 Node 版本、冲突 PATH、被占端口 |
| **AI Agent 清理** | 区分缓存、会话、凭据、记忆，避免误删 | Claude Code / Cursor / Codex / Devin 等 |
| **磁盘与目录分析** | 目录大小、磁盘分析、重复文件、相似图片 | 找出占用大户、清理重复副本 |
| **目录与文件管理** | Finder 增强入口：搜索、隐藏文件、路径复制、常用操作 | 快速定位文件、批量操作、全局文件名搜索 |
| **剪贴板历史** | 自动记录文本、链接、文件、图片 | 找回刚刚复制的命令、截图或链接 |
| **截图与标注** | 区域/比例截图 + 标注 + 背景排版 | 一键出图、打码、Mac 风格展示 |
| **灵动岛系统监控** | 随时查看 CPU、内存、磁盘、网络、电池 | 抬眼就能看到 Mac 状态 |
| **自动化清理** | 按时间或容量上限自动整理指定目录 | 下载目录、临时文件夹定时保持整洁 |

---

## 深度垃圾清理

Nori 不仅扫普通应用缓存，还会识别系统数据、开发构建产物和 AI Agent 数据。相比普通清理工具，Nori 对开发环境和 AI Agent 缓存的识别，常常能多清理出数十 GB 的可回收空间（具体取决于你磁盘上的实际内容）。扫描结果按风险分层：

- **推荐清理**：可重建、未活跃、未被占用的缓存，默认勾选。
- **需要确认**：可能包含历史记录或恢复成本的内容，默认不勾选。
- **受保护**：正在使用、最近活跃、含凭据或持久数据的项目，不可勾选或会提示原因。

支持范围包括：

- 系统：日志、诊断报告、废纸篓、设备固件、 Messages 预览缓存。
- 应用与浏览器：通用缓存、IM 容器缓存、卸载残留。
- 开发环境：Xcode DerivedData、npm / pnpm / Yarn / Bun / pip / uv / Cargo / Go / Gradle 等构建与下载缓存。
- AI Agent：Claude Code、Cursor、Codex、Devin、Windsurf、Gemini CLI 等缓存与旧版本，会话和记忆单独审查。

开发者缓存默认在 **连续 7 天未活跃** 后推荐清理；执行前会重新复核路径身份和活跃状态。

![中文磁盘清理界面](docs/screenshots/zh-CN/cleanup.png)

## 开发者工作台

包管理器和构建系统留下的东西往往比普通缓存更多。Nori 为常见环境提供专门识别：

| 环境 | 可以清理或管理的内容 |
| --- | --- |
| **Xcode / SwiftPM / Carthage** | DerivedData、下载/构建缓存、模拟器缓存、不可用模拟器；Archives 受保护。 |
| **Node.js** | npm / pnpm / Yarn / Bun 缓存、store prune；旧 nvm 版本可删除，当前版本受保护。 |
| **前端工具链** | node-gyp、TypeScript、Electron、Turborepo、Vite、Webpack、ESLint、Prettier 等缓存。 |
| **Python** | pip / uv / Poetry / Conda 缓存与官方清理命令；Poetry 虚拟环境不进入普通清理。 |
| **Java / Android** | Gradle 构建缓存、daemon 日志、worker 临时数据。 |
| **Rust / Go** | Cargo registry 下载缓存、Go 构建与模块缓存。 |
| **Homebrew / Ruby** | Homebrew 下载缓存、`brew cleanup`、RubyGems 清理。 |
| **Docker** | 空间占用明细，明确后通过 Docker 官方命令清理。 |

工作台还整合运行时、Shell、hosts、CLI 与 PATH 管理，以及监听端口一键释放。

![中文开发者工作台](docs/screenshots/zh-CN/developers.png)

## AI Agent 清理

AI 工具留下的不只是缓存。Nori 按工具把本地数据分组，让你看清哪些可以重建、哪些包含历史、哪些需要谨慎处理：

- **容量拆分**：安装本体与关联数据分开显示，数据再分为垃圾和保留占用。Agent 页与软件页共用计量，共享路径只计算一次，部分结果明确标记；勾选数据另行显示本次删除容量。
- **可重建缓存**：旧 CLI 版本、桌面/更新/编译缓存，默认勾选。
- **持久数据**：会话、历史、记忆、worktree、VM 数据和凭据需手动勾选，并带有风险说明；其他审查项按页面显示的建议处理。
- **共享资源**：Skills、MCP 登记区分“解除关联”和“删除共享文件”。

可在 Agent 页直接卸载所选 CLI 或桌面安装。卸载成功后另行确认已识别 Agent 数据清理；数据仍被使用时，先确认是否关闭相关程序。已卸载 Agent 的残留继续显示，默认不勾选。

支持 Claude Code、Cursor、Codex、GitHub Copilot CLI、Gemini CLI、OpenCode、Grok CLI、Devin、Windsurf、Zed、Warp 等。

![中文 AI Agent 清理界面](docs/screenshots/zh-CN/agents.png)

## 磁盘与目录分析

- **目录大小**：文件与文件夹显示实际分配的磁盘占用，后台逐步计算并缓存，支持刷新。
- **磁盘分析**：选择用户目录、根目录或任意文件夹，按大小排序下钻查看大文件。
- **重复文件**：按内容哈希找出重复组，逐项审查后移入废纸篓，每组至少保留一份。
- **相似图片**：识别视觉相似的图片，方便对比后清理。

## 目录与文件管理

“目录”页是 Finder 的增强入口：

- 始终显示可点击、可复制的面包屑路径。
- 默认显示隐藏文件，分别记住每个目录的显示开关。
- 支持新建、复制、剪切、粘贴、重命名、移入废纸篓、拖放和 Finder 打开。
- 搜索可过滤当前目录，也可查询 Spotlight 全局索引；本地索引补充 `.开头` 文件和其他指定目录。

## 剪贴板历史

自动记录 **文本、链接、文件、图片**，支持：

- 按类型筛选（文本 / 网址 / 图片 / 文件 / 全部）。
- 置顶常用条目、再次复制、调整历史容量。
- 一键清除未置顶条目。文件只保存路径，不额外复制原文件。

![中文剪贴板历史界面](docs/screenshots/zh-CN/clipboard.png)

## 截图与标注

- **⌘⇧S** 交互式选择区域或窗口；**⌘⇧R** 按指定比例截图。
- 标注：形状、箭头、画笔、文字、马赛克。
- 排版：iPhone/iPad 外框、社交平台比例、渐变背景、留白、圆角、Mac 窗口样式。
- 导出 1× / 2× 的 PNG 或 JPEG，记住上次设置。

![中文截图编辑器](docs/screenshots/zh-CN/screenshot.png)

## 灵动岛系统监控

顶部灵动岛面板随时展示：

- CPU、内存、磁盘容量与读写、网络速率、电池信息。
- 资源占用应用、进程列表、监听端口、应用流量。
- 可尝试正常退出符合策略的后台应用，释放内存时也会清理 Nori 自身缓存。

![中文 Nori 灵动岛](docs/screenshots/zh-CN/island.png)

## 自动化清理

为任意目录设置规则：

- **保留最近 X 天** 或 **保持容量上限**。
- 启用前预览结果，也可手动执行。
- 每小时检查一次调度，实际扫描至少间隔 6 小时，保护敏感路径和近期写入内容。

![中文自动目录清理界面](docs/screenshots/zh-CN/automation.png)

## 安装与更新

需要 **macOS 13 Ventura 或更高版本**。原生液态玻璃需要 macOS 26 或更高版本。

1. 打开 [GitHub Releases](https://github.com/percentcola3/Nori/releases/latest)。
2. Apple 芯片下载 `Nori-arm64.dmg`，Intel 下载 `Nori-x86_64.dmg`。
3. 将 `Nori.app` 拖入 `/Applications`；更新前先退出旧 Nori，再覆盖安装。
4. 打开 Nori，通过权限中心授予清理与扫描所需的**完全磁盘访问**。截图使用独立的**屏幕录制**权限。

从 1.0.1 起，Nori 使用 Sparkle 检查更新。公开版本复用同一份固定签名证书和 `com.nori.app` Bundle ID；这是固定自签名身份，**不等于 Apple 公证**。身份校验和更新验证见 [发布签名指南](docs/release-signing.md)。

## 多语言

English、简体中文、繁體中文、日本語、한국어、Deutsch、Français、Español、Português、Italiano、Русский、Türkçe。默认跟随系统语言，也可在设置中即时切换。

## 构建与参与

需要 Mac 和提供 `swiftc` 的 Xcode 工具链：

```bash
bash script/dev_identity.sh --ensure
bash script/build_and_run.sh
```

运行 `bash script/test.sh` 执行回归检查。架构、构建选项、安全策略及维护说明见 [开发文档](docs/development.md)。

欢迎通过 [Issues](https://github.com/percentcola3/Nori/issues) 和 Pull Request 提交问题与改进。

## 许可证与致谢

Nori 以 [GNU General Public License v3.0](LICENSE) 开源。内置 Mole 源码保留其 [GPL v3 许可证](vendor/mole/LICENSE)，上游署名与打包组件详见 [第三方声明](THIRD_PARTY_NOTICES.md)。

感谢 [tw93/Mole](https://github.com/tw93/Mole) 带来的灵感和基础清理工作。
