# 桌面 Agent 与 Chrome DevTools MCP 清理研究

核对日期：2026-10-01。范围为 macOS 本地数据的归属、生命周期和删除影响。研究只读取公开文档、固定版本源码及公开问题报告；未运行下载的代码、诊断脚本或卸载命令，也未修改真实 Agent 数据。

## 证据与风险约定

- **A：可核对实现或官方明确路径。** 开源实现使用固定提交；官方在线文档记录核对日期，不能假定所有旧版均采用新路径。
- **B：有版本/平台的公开观察。** 官方社区和官方仓库 issue 的用户报告可证明该版本观察到的路径，但不是厂商承诺，也不独立证明可安全删除。
- **C：待证实候选。** Nori 原目录规则或同类软件经验只能用于低置信度发现，不能据此声称会自动重建。

风险决定默认选择和提示，不决定用户是否拥有清理能力。可再生缓存与日志可以低风险处理；会话、快照、录制、数据库、凭据和配置都可以清理，但必须说明损失。下文“审查”表示默认不选、有损删除；“高风险”表示重置配置、身份或完整工作环境。软件已卸载后，这些持久资料仍然可能有价值，不能自动降为无损垃圾。

清理数据库时以主文件与同名 `-wal`、`-shm`、`-journal` 为一个目标，停止所属客户端和服务器后操作。不要同时计量父目录和已列出的子目标。配置、Skill、MCP 注册、服务器包是独立资源；仅解除一个 Agent 的关联不能顺带删除其他 Agent 使用的本体。

## Cursor

Cursor 的完整客户端未公开源码。本次能证明 Skills/MCP 配置和工作树生命周期；状态库内容由官方社区报告补充。

| 路径 | 类型、删除影响 | 证据与处理 |
| --- | --- | --- |
| `~/.cursor/skills/`、`~/.agents/skills/` | 全局 Skill；删除丢失能力定义及附属文件 | A，[Skills](https://cursor.com/docs/skills)。本体、链接及调用端分别管理；`.agents` 为共享资源 |
| 项目 `.cursor/skills/` | 项目 Skill，可含版本控制中的用户文件 | A，同上；不可通过全局清理扫描随意删除项目目录 |
| `~/.cursor/mcp.json`、项目 `.cursor/mcp.json` | `mcpServers` 注册，可含命令、远程地址和凭据 | A，[MCP](https://cursor.com/docs/mcp)。移除单项注册不等于卸载包或撤销服务端授权 |
| `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` | 聊天、Agent checkpoint 和相关状态；删除失去本地历史和恢复能力 | B，[macOS 存储报告的第 7 帖](https://forum.cursor.com/t/cursor-storage-has-grown-to-125gb-on-my-mac-how-can-i-safely-reduce-it-without-losing-history-context/172127/7)。此次取得论坛搜索摘录；完整帖访问被服务器拒绝，未验证发帖者员工身份。审查，不是缓存 |
| `~/Library/Application Support/Cursor/User/workspaceStorage/` | 工作区布局/聊天关联等状态，具体内部结构随版本变化 | B，[重装不移除工作区 state.vscdb](https://forum.cursor.com/t/empty-non-exitable-black-cursor-pane-ghost-pane/172113/8)、[聊天仍在 state.vscdb](https://forum.cursor.com/t/multi-root-workspace-save-as-rename-creates-duplicate-workspace-agent-chats-stay-on-workspace-json-and-folders-break/171560/9)。整体审查，不把所有子目录视为缓存 |
| `~/.cursor/worktrees/` | 自动创建的 Git 工作树，可含未提交代码 | A，[安装/存储问题](https://cursor.com/help/troubleshooting/install-issues)。官方说明自动清理时间和容量限制并不证明 Nori 可无损删除；需检查 Git 状态，手动审查 |
| `~/Library/Application Support/Cursor/snapshots` | Nori 现有 checkpoint 路径候选 | C。官方 [Agent troubleshooting](https://cursor.com/help/troubleshooting/agent-issues) 只确认 checkpoints 本地保存、与 Git 分离，未在本次资料中给出该物理路径。可有损清理，不能标成已证实的可再生缓存 |
| `~/.cursor/projects` | Nori 现有转录路径候选 | C。未在本次官方资料证明全目录结构、所有者和保留策略；按会话/产物审查 |

App Support 中的 `Cache`、`Code Cache`、`GPUCache` 等 Electron 叶子应与上述用户状态分开。Nori 现有叶子路径属于运行时/本机结构依据，本研究没有从 Cursor 私有实现证明所有叶子。`globalStorage` 整体、`User` 整体和 `.cursor` 整体不得因为某些缓存可再生就标成 Safe。内置 Agent CLI 版本目录还必须保留链接指向的活动版本。

## Windsurf 与 Devin Desktop

在核对日期，旧 Windsurf 文档链接已出现 Devin Desktop 品牌。应保留旧路径兼容性，并将两客户端及 Devin CLI 的共享根纳入归属；不能仅因 Windsurf.app 不存在就宣布所有 `.codeium/windsurf` 为孤儿。

| 路径 | 类型、删除影响 | 证据与处理 |
| --- | --- | --- |
| `~/.codeium/windsurf/cascade` | Cascade 会话历史和本地设置 | A，[Common Devin Desktop Issues](https://docs.devin.ai/desktop/troubleshooting/windsurf-common-issues)。官方删除建议明确警告会丢失 history/settings；它是故障重置方式，不是无损缓存清理 |
| `~/.codeium/windsurf/memories/` | 本地自动记忆；同目录含人工规则 `global_rules.md` | A，[Memories & Rules](https://docs.devin.ai/desktop/cascade/memories)。新 Devin Local Agent 不持久化这些旧 Cascade memories，但官方提供迁移到 skills；按记忆/配置审查 |
| `~/.codeium/windsurf/skills/`、`~/.config/devin/skills/` | 全局 Skill，后者与 Devin CLI 共享 | A，[Skills](https://docs.devin.ai/desktop/cascade/skills)。独立管理，不能放进级联会话清理 |
| 项目 `.devin/skills/`、旧 `.windsurf/skills/`、`.agents/skills/` | 项目或跨 Agent 技能 | A，同上；不得当作 IDE 缓存 |
| `/Library/Application Support/Devin/skills/`，回退 `/Library/Application Support/Windsurf/skills/` | IT 部署的系统 Skill；Devin 目录存在时不合并旧目录 | A，同上。与用户可写全局技能区分；清理需要相应文件权限并明确系统范围 |
| `~/.config/devin/mcp_config.json` 或 `$XDG_CONFIG_HOME/devin/mcp_config.json` | 当前 `mcpServers` 注册 | A，[MCP](https://docs.devin.ai/desktop/cascade/mcp)。配置读取应遵守 XDG 覆盖，不能只读默认路径 |
| `~/.codeium/windsurf/mcp_config.json`、`~/.codeium/mcp_config.json` | Nori 的旧版本注册路径 | C/兼容候选；当前文档已迁至 Devin 配置根，不能给所有版本同一个置信度 |
| `~/Library/Application Support/Windsurf`、`~/Library/Application Support/Devin` | 桌面运行时混合根 | C：本研究未证明全部内部模式。已确认缓存叶子可单列，剩余数据高风险手动清理；不同时计量整根和叶子 |

`~/Library/Application Support/Devin/WebStorage` 在本次官方资料中没有明确结构/生命周期证据。该名称不足以证明它保存何种会话、可被重建或可无损删除。

## Zed

实现固定为 [zed-industries/zed@74c134a3c12418cc095122fff938ef1c2504ae06](https://github.com/zed-industries/zed/commit/74c134a3c12418cc095122fff938ef1c2504ae06)。这是原生应用，不能套用 Electron 目录假设。

| 路径 | 类型、删除影响 | 证据与处理 |
| --- | --- | --- |
| `~/Library/Caches/Zed` | `temp_dir()`；临时原子写入/键位编辑工作树、模型目录缓存和 crash-handler 辅助文件 | A，[paths.rs](https://github.com/zed-industries/zed/blob/74c134a3c12418cc095122fff938ef1c2504ae06/crates/paths/src/paths.rs#L193)、[fs.rs](https://github.com/zed-industries/zed/blob/74c134a3c12418cc095122fff938ef1c2504ae06/crates/fs/src/fs.rs#L980)、[模型缓存消费者](https://github.com/zed-industries/zed/blob/74c134a3c12418cc095122fff938ef1c2504ae06/crates/language_models/src/provider/opencode.rs#L332)。退出后低风险清理；Nori 原 `Library/Caches/dev.zed.Zed` 未由源码证明 |
| `~/Library/Logs/Zed` | `Zed.log`、`Zed.log.old` 等日志 | A，[paths.rs](https://github.com/zed-industries/zed/blob/74c134a3c12418cc095122fff938ef1c2504ae06/crates/paths/src/paths.rs#L228)。丢失诊断资料；退出后低风险 |
| `~/Library/Application Support/Zed/hang_traces` | 卡顿诊断资料 | A，同文件 `hang_traces_dir()`；可单列日志/诊断清理 |
| `~/Library/Application Support/Zed/threads/threads.db` | 持久 Agent threads：摘要、消息序列及子 Agent 信息 | A，[agent/db.rs](https://github.com/zed-industries/zed/blob/74c134a3c12418cc095122fff938ef1c2504ae06/crates/agent/src/db.rs#L443)。删除失去 Agent 历史；审查；不要将同级整个 App Support 计入同一批 |
| `~/Library/Application Support/Zed/db/0-<scope>/db.sqlite` | 按 release/global scope 的应用状态数据库 | A，[db.rs](https://github.com/zed-industries/zed/blob/74c134a3c12418cc095122fff938ef1c2504ae06/crates/db/src/db.rs#L138)。按发现的 scope 列举实际文件，审查；不硬编码唯一 stable 路径 |
| `~/Library/Application Support/Zed/extensions`、`languages`、`debug_adapters`、`external_agents` | 安装的扩展、语言服务、调试适配器和外部 Agent 服务 | A，[paths.rs](https://github.com/zed-industries/zed/blob/74c134a3c12418cc095122fff938ef1c2504ae06/crates/paths/src/paths.rs#L345)。可卸载/重新下载，但会停用功能及影响离线使用；安装资源管理，不整体默认 Safe |
| `~/.config/zed/settings.json` | 用户设置及 `context_servers` MCP 注册 | A，[配置文档](https://github.com/zed-industries/zed/blob/74c134a3c12418cc095122fff938ef1c2504ae06/docs/src/configuring-zed.md#L33)、[MCP 文档](https://github.com/zed-industries/zed/blob/74c134a3c12418cc095122fff938ef1c2504ae06/docs/src/ai/mcp.md#L54)。移除服务器项需保留其余用户设置 |
| `~/.config/zed/prompts`、`prompt_overrides`、`themes`、`snippets` | Assistant 资料和用户定制内容 | A，[paths.rs](https://github.com/zed-industries/zed/blob/74c134a3c12418cc095122fff938ef1c2504ae06/crates/paths/src/paths.rs#L369)。用户配置/内容，高风险重置 |
| `~/.local/state/Zed` | 源码定义的 macOS state 根 | A 路径，[paths.rs](https://github.com/zed-industries/zed/blob/74c134a3c12418cc095122fff938ef1c2504ae06/crates/paths/src/paths.rs#L169)；本研究未逐一证明内部文件生命期，剩余整体为未知状态、高风险 |

源码还支持自定义数据根。扫描器应使用明确配置的根；不能为了覆盖自定义路径而遍历任意用户项目。

## Warp

截至核对日期，Warp 客户端已开源。实现固定为 [warpdotdev/warp@40b791c351377c4b30c48179a568326144113726](https://github.com/warpdotdev/warp/commit/40b791c351377c4b30c48179a568326144113726)，并与官方 [Logging out and uninstalling](https://docs.warp.dev/support-and-community/troubleshooting-and-support/logging-out-and-uninstalling/) 交叉核对。

| 路径 | 类型、删除影响 | 证据与处理 |
| --- | --- | --- |
| `~/Library/Group Containers/2BBY89MBSN.dev.warp/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite` | 当前 GUI 主数据库；含 Agent 会话/任务、本地窗口恢复及其他持久状态 | A，官方卸载页证明具体 Group Container，[paths.rs](https://github.com/warpdotdev/warp/blob/40b791c351377c4b30c48179a568326144113726/crates/warp_core/src/paths.rs#L272)、[sqlite.rs](https://github.com/warpdotdev/warp/blob/40b791c351377c4b30c48179a568326144113726/app/src/persistence/sqlite.rs#L473)、[agent.rs](https://github.com/warpdotdev/warp/blob/40b791c351377c4b30c48179a568326144113726/app/src/persistence/agent.rs#L14)。审查；这是 Nori 旧规则漏扫的大项 |
| `~/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite` | 无可写 App Group 时使用的旧/回退数据库 | A，同上 `unwrap_or_else(state_dir)`。与 Group Container 分别发现实际存在的文件，避免只支持一个位置 |
| 对应 `dev.warp.Warp-Preview` 根下的 `warp.sqlite` | Preview 的独立数据库 | A，官方卸载文档。不得把 Stable 和 Preview 的数据库混为一个资源 |
| 上述 state 根的 `tui/warp.sqlite` | TUI 的独立持久状态 | A，[paths.rs](https://github.com/warpdotdev/warp/blob/40b791c351377c4b30c48179a568326144113726/crates/warp_core/src/paths.rs#L297)、[sqlite.rs](https://github.com/warpdotdev/warp/blob/40b791c351377c4b30c48179a568326144113726/app/src/persistence/sqlite.rs#L479)。源码特意分库，不能用 GUI 数据库替代 TUI 的扫描/运行保护 |
| `~/Library/Logs/warp.log`、`warp_preview.log` | 产品日志 | A，官方卸载页。单文件低风险日志清理 |
| `~/.warp/` | 用户 themes、workflows、launch configurations 等混合配置/资源根 | A，[paths.rs](https://github.com/warpdotdev/warp/blob/40b791c351377c4b30c48179a568326144113726/crates/warp_core/src/paths.rs#L119) 与卸载页。整根高风险；Stable/Preview 共享，卸载一端不得自动孤儿化 |
| `~/.warp/skills`、`~/.warp/.mcp.json` | 全局技能与 MCP 配置路径 | A，[paths.rs](https://github.com/warpdotdev/warp/blob/40b791c351377c4b30c48179a568326144113726/crates/warp_core/src/paths.rs#L61)。按资源项管理，父 `.warp` 清理必须涵盖或排除这些项，不能重复计量 |

**重要实现陷阱：** Warp 的 macOS `cache_dir()` 在该版本返回 `project_dirs.data_dir()`，与旧 state 的 App Support 根重合（[源码](https://github.com/warpdotdev/warp/blob/40b791c351377c4b30c48179a568326144113726/crates/warp_core/src/paths.rs#L315)）。函数名不能把整根证明为 Safe。Keychain 登录项目 `dev.warp.Warp-Stable` 由卸载文档单独处理；删状态数据库不等于撤销凭据。源码还给 oss/dev/local/integration 及 development profile 独立目录名，不应猜测所有路径都属于 Stable。

## Qoder

| 路径 | 类型、删除影响 | 证据与处理 |
| --- | --- | --- |
| `~/.qoder/skills/<name>/SKILL.md` 及附属文件 | 全局 Skill，IDE 与 CLI 同用 | A，[Skills](https://docs.qoder.com/extensions/skills)。本体/链接清理需考虑 CLI 仍安装的情况 |
| 项目 `.qoder/skills/` | 项目技能 | A，同上。用户项目资源，不是缓存 |
| `~/Library/Application Support/Qoder`、`~/.qoder` | Nori 的混合根候选 | C。本次官方资料未确认 macOS 每个 cache/history/DB 叶子的生命期；允许高风险手动清理，不能凭 VS Code/Electron 类似结构给整根 Safe |

官方 [MCP 说明](https://docs.qoder.com/user-guide/chat/model-context-protocol) 证明支持本地/远程服务器及 JSON 注册，但此次没有找到明确 macOS 注册文件路径。因此不应编造 Qoder 的 MCP 文件名。旧 [诊断指南](https://docs.qoder.com/troubleshooting/troubleshooting-guide) 的 `.qoder` 安装位置与删除建议明确面向 **Windows**；不能外推成 macOS 无损清理指令。诊断程序未运行。

## Kiro

| 路径 | 类型、删除影响 | 证据与处理 |
| --- | --- | --- |
| `~/.kiro/skills/`、项目 `.kiro/skills/` | 全局/项目 Skill | A，[Skills](https://kiro.dev/docs/skills)。不能把整个 `.kiro` 的内容当缓存 |
| `~/.kiro/settings/mcp.json`、项目 `.kiro/settings/mcp.json` | `mcpServers` 配置 | A，[MCP configuration](https://kiro.dev/docs/mcp/configuration)。单项解除注册，保留其他设置 |
| `~/Library/Application Support/Kiro/User/globalStorage/kiro.kiroagent/` | Agent 会话、执行记录及 checkpoint 关联资料 | B，[macOS 26.4.1/Kiro 0.11.131 的容量报告 #7709](https://github.com/kirodotdev/Kiro/issues/7709)、[会话/执行文件分析 #8007](https://github.com/kirodotdev/Kiro/issues/8007)。可以单独提供有损审查清理；删后能启动不代表历史可恢复 |
| `~/Library/Application Support/Kiro`、`~/.kiro` 其他部分 | 混合配置、运行时和状态根 | C：本次尚未证明所有 macOS 子项，整体高风险；与已列出的 Skill、MCP、session 叶子去重 |

官方 [Checkpoints](https://kiro.dev/docs/checkpoints) 说明文件快照与上下文恢复/rewind 的差别；这是用户恢复能力。CLI 实验性 shadow bare Git 仓库的行为不能证明 IDE checkpoint 目录可无损删。本次没有精确证明 IDE 快照独立物理目录，也不根据名字推测。`/private/tmp/zeb_*` socket 的公开问题报告不足以证明每个 socket 都属于 Kiro、已过期或可删，应排除泛匹配清理。

## Trae

| 路径 | 类型、删除影响 | 证据与处理 |
| --- | --- | --- |
| `~/.trae/skills`、项目 `.trae/skills/` | macOS 全局/项目 Skill | A，[官方 Skills](https://docs.trae.ai/ide/skills)。内容在页面序列化 rich text 中，已读取并核对；不以 HTML 静态正文为空判为无证据 |
| 项目 `.trae/skill-config.json` | 禁用的项目 Skill 记录；不包含全局禁用列表 | A，同页。删除/改名 Skill 后需处理对应登记；这不是全局能力本体 |
| `~/Library/Application Support/Trae/logs` | 版本化日志目录，报告有 `renderer.log` | B，[macOS/Trae 3.5.21 报告 #2092](https://github.com/Trae-AI/TRAE/issues/2092)。可单列日志，生命周期结论仅适用该报告版本 |
| `~/Library/Application Support/Trae`、`~/.trae` 其他内容 | Nori 的混合根候选 | C。具体聊天数据库、快照和再生缓存模式没有本次可核对证据，默认高风险 |
| `~/Library/Application Support/Trae/User/mcp.json` | Nori 现有 MCP 注册候选 | C。[官方 MCP 页](https://docs.trae.ai/ide/model-context-protocol) 证明产品能力，未在本次资料明确该 macOS 文件路径；扫描应读取存在且格式匹配的文件，不将猜测宣称官方路径 |

TRAE SOLO 与 Trae IDE 是独立产品。公开 issue 的 SOLO 数据根/重置建议不能直接归入 Trae IDE。此次未证明 Trae 全局禁用 Skill 的持久存储位置，不能根据项目 `skill-config.json` 假造同名全局文件。

## Google Antigravity

| 路径 | 类型、删除影响 | 证据与处理 |
| --- | --- | --- |
| `~/.gemini/config/skills/`、旧 `~/.gemini/antigravity/skills/` | 当前与兼容的 IDE 全局 Skill | A，[Skills](https://antigravity.google/docs/skills)。独立资源区，支持链接/本体管理 |
| 项目 `.agents/skills/` | 工作区 Skill，可在多个 Agent 复用 | A，同上。共享，不属于单一 IDE 缓存 |
| `~/.gemini/config/mcp_config.json`、项目 `.agents/mcp_config.json` | 当前 IDE MCP 配置 | A，[MCP](https://antigravity.google/docs/mcp)。旧版 `~/.gemini/antigravity/mcp_config.json` 需作为版本兼容路径，不能无条件认为当前唯一来源 |
| `~/.gemini/antigravity/mcp_oauth_tokens.json` | MCP OAuth 凭据 | A，同页。删后需重新授权，不代表远端 token 被撤销；高风险凭据清理 |
| `~/.gemini/antigravity/browser_recordings` | Nori 的物理路径规则；内容是用户可回放的录制产物 | C 路径，A 用途：[Artifacts](https://antigravity.google/docs/artifacts)、[Browser recordings](https://antigravity.google/docs/ide/browser-recordings/)。官方明确“saved as recording artifacts for your review”。可以审查删除，**不能因代理生成就归 Safe** |
| `~/.gemini/antigravity/conversations`、`brain` | Nori 的会话/知识资料路径 | C：本次未证明准确内部 schema/保留周期；按持久会话、记忆/产物有损审查 |
| `~/Library/Application Support/Antigravity` | 混合桌面根 | C：可单列有本机依据的缓存叶子；整根高风险且与叶子去重 |

Antigravity CLI 另有 `~/.gemini/antigravity-cli/skills` 与插件资源；IDE 存在/卸载不能代表 CLI 状态。`.gemini` 也被 Gemini CLI 使用，严禁把整个父根归给 Antigravity。项目内文件、计划、图片、代码差异和录像都是任务产物；“Agent 自动生成”不等于“无用户价值”。

## Claude Desktop / Cowork

| 路径 | 类型、删除影响 | 证据与处理 |
| --- | --- | --- |
| `~/Library/Application Support/Claude/claude_desktop_config.json` | 手动 `mcpServers` 注册 | A，[官方 MCP 连接本地服务器指南](https://modelcontextprotocol.io/docs/develop/connect-local-servers)。改单项，保留其他 MCP 和配置 |
| `~/Library/Logs/Claude/mcp*.log`（日志根 `~/Library/Logs/Claude`） | 本地 MCP 启动/运行日志 | A，同指南。丢失诊断资料，可低风险单列；不等于删除 MCP 服务器 |
| `~/Library/Application Support/Claude/vm_bundles/claudevm.bundle/rootfs.img` | Cowork 活动 Linux VM 磁盘，包含运行期间安装/下载/构建内容 | B，[macOS 26.1/Claude 1.11187.1 #65577](https://github.com/anthropics/claude-code/issues/65577)、[Claude 1.37937.2 #89869](https://github.com/anthropics/claude-code/issues/89869)；A 官方 [架构页](https://support.claude.com/en/articles/14479288-claude-cowork-architecture-overview) 证明 macOS 使用 Apple Virtualization.framework 的独立 Linux VM。高风险工作环境重置 |
| 同 bundle 的 `sessiondata.img` | VM 中的持久会话状态 | B，#65577。删除影响会话；不能用“镜像可重新下载”证明无损 |
| 同 bundle 的 `rootfs.img.zst`、`.partial` | 报告版本残留的压缩下载与不完整文件 | B，#89869。有缩小占用潜力，但未证明任意版本启动/修复均不再使用它们；仅在确认不活动和重新安装需求后单列审查，不把整个 bundle 默认 Safe |
| `~/Library/Application Support/Claude/vm_bundles` | 以上镜像和状态的父根 | 高风险整体重置；原 Safe 规则应修正。不能同时列父根与各镜像计量 |
| `~/Library/Application Support/Claude` 其他部分；`~/Library/Caches/com.anthropic.claudefordesktop[.ShipIt]` | 桌面混合数据、缓存和更新暂存 | C/本机运行时依据；已证实缓存叶子可分开，用户状态和整个 App Support 保持高风险 |

当前官方 [Desktop Extensions](https://support.claude.com/en/articles/10949351-getting-started-with-local-mcp-servers-on-claude-desktop) 使用 `.mcpb` 包、自动更新和 bundled runtime（上游 [mcpb](https://github.com/anthropics/mcpb)）。因此 **MCP 不一定是全局 npm 安装**：还可能是客户端 extension、uv/npx 按需环境、容器或远程 URL。注册、插件包、运行时和服务器本体要区分，不能把一个启动命令里的可执行文件直接当作独占本体。

官方架构页还区分云会话与旧本地部署。清理本地文件不会删除云会话；VM 暂不可用时 shell/code 报 workspace unavailable，文件/web 工具仍可运行。连接的用户项目文件夹不属于 Claude 运行垃圾，不能跟随 App Support/VM 清理删除。Keychain 凭据也不能由普通目录删除等价撤销。

## Chrome DevTools MCP

实现固定为 [ChromeDevTools/chrome-devtools-mcp@5b2c6f97a7f78e3fe3dbf2faacfb366bcb4ed6d2](https://github.com/ChromeDevTools/chrome-devtools-mcp/commit/5b2c6f97a7f78e3fe3dbf2faacfb366bcb4ed6d2)。它不是普通桌面 Agent；通常通过其他客户端 `npx` 启动，不要求独立 app 或全局 CLI。已存在可验证 MCP 注册时，不能因没有 app/命令就判卸载残留。

| 路径/模式 | 类型、删除影响 | 证据与处理 |
| --- | --- | --- |
| `~/.cache/chrome-devtools-mcp/chrome-profile` | 默认持续 Chrome profile | A，[BrowserManager.ts](https://github.com/ChromeDevTools/chrome-devtools-mcp/blob/5b2c6f97a7f78e3fe3dbf2faacfb366bcb4ed6d2/src/BrowserManager.ts#L224)。会保留浏览器状态；整个 profile 高风险重置，不能凭 `.cache` 名字 Safe |
| 同根 `chrome-profile-<channel>` | 非 stable channel 独立 profile | A，同上。只能枚举实际可识别 channel 目录，不用宽泛任意 `chrome-*` 归属 |
| `~/.cache/chrome-devtools-mcp-cli/chrome-profile[-<channel>]` | `viaCli` 模式的独立 profile 根 | A，同上第 234 行；不能漏扫或与普通 MCP profile 混在一起 |
| `--isolated` | 临时 profile，浏览器关闭后自动清理 | A，[configuration.md](https://github.com/ChromeDevTools/chrome-devtools-mcp/blob/5b2c6f97a7f78e3fe3dbf2faacfb366bcb4ed6d2/docs/configuration.md#L88)。非 isolated 默认 false；不得把默认 profile 当同种临时文件 |
| `--user-data-dir` / `--userDataDir` | 用户指定 profile | A，同文档。可指向普通浏览器/用户数据，不能自动扩大允许删除范围；显示真实影响和归属 |
| remote existing browser 连接 | 复用现有浏览器，而非独占 MCP 数据 | A，配置文档。清理 MCP 缓存不能删用户日用 Chrome profile；运行保护还要包含浏览器进程 |
| screenshot 的 `filePath`、trace 等输出 | 用户明确保存的任务产物；可在客户端 roots 范围内 | A，[screenshot.ts](https://github.com/ChromeDevTools/chrome-devtools-mcp/blob/5b2c6f97a7f78e3fe3dbf2faacfb366bcb4ed6d2/src/tools/screenshot.ts#L269)。不能按后缀把项目/导出目录图片和 trace 当垃圾 |

源码截图工具在未指定目的地且图片较大时调用 `saveTemporaryFile`；本研究未核对该函数最终目录，不猜测特定 `/tmp` 前缀。`--log-file` 同样由用户指定，不存在可推导的唯一全局日志根。

默认 profile 中的 HTTP/GPU/编译缓存可依已核对 Chromium schema 单列；`History`、`Cookies`、`Local Storage`、`IndexedDB` 属于持久状态。现有规则中的 `Service Worker/CacheStorage` 可能存站点离线数据，删除可影响离线应用，不应同一般编译缓存承诺无影响。整体 `.cache/chrome-devtools-mcp` 至少需要审查，并同时管理依赖的 MCP 注册/安装资源。

## 对实现的优先建议

1. 修正两个明确误分类：Antigravity browser recordings 是可回放产物；Claude vm_bundles 含活动磁盘/会话状态。二者都支持删除，默认不选并描述损失。
2. 精细补齐有 A/B 证据的漏扫：Warp App Group/回退/Preview/TUI 的 `warp.sqlite`；Zed 的 `threads/threads.db`、scope 数据库、真实 cache/log 根；Kiro 的 `kiro.kiroagent` 状态；Claude MCP 日志。每一项使用现有会话/状态/日志标签，避免模糊“应用数据”覆盖一切。
3. 对无内部 schema 证据的闭源混合根提供高风险手动清理，记录 C 置信度和具体未知项。不能因为缺乏研究就只读，也不能补出虚假的再生保证。
4. Presence 与数据存在分离；但共享配置/CLI/Preview/注册型 MCP 都要计入 owner。软件卸载后资料移入“清理”残留项，再校验安装状态，禁止跨端误判和重装后的旧计划删除。
5. 解除 Skill 链接仅 unlink；删除本体先列出所有关联，并清除可核对的登记/链接。MCP 解除注册与包卸载分别提供，远程服务器没有本地本体。删除父配置根时，要将所属 Skill/MCP 登记作为同一清理计划处理并去重。
6. 对 SQLite 和可执行资源先关闭所有相关客户端/服务器，重校验路径/文件身份/注册内容并备份后操作。目录名、可重新下载、已卸载或体积大都不能单独证明无损。

本次未证明的内部路径仍保持候选标记；后续应该按产品版本补充本机只读布局证据或公开实现，而不是照搬另一个 Electron/VS Code 产品的目录模式。
