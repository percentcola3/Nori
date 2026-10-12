# Agent 清理研究与实施索引

核对日期：2026-10-01。当前 [AgentCatalog](../../SimpleMole/Services/AgentCatalog.swift) 有 **30 个定义：29 个产品/服务及 Shared 技能组**。本文区分当前代码中的规则、研究建议及未支持范围；目录里存在某份研究不表示相关功能已经实现。各子文档的“当前差异”记录取证时的实现，后续已实施项以本矩阵和代码为准。

## 研究入口

| 文档 | 范围与主要证据 |
| --- | --- |
| [codex.md](codex.md) | Codex CLI/App；固定 CLI 源码、配置参考；会话与状态库、目标/记忆/队列、备份、日志和自定义根 |
| [open-source-cli.md](open-source-cli.md) | OpenCode、Gemini CLI、两代 Kimi、pi、Crush；固定源码，含凭据/数据库 schema 与项目 registry |
| [other-cli-and-extensions.md](other-cli-and-extensions.md) | Claude Code、Copilot、Cursor CLI、Grok Build、Factory、Amp、Cline、Continue，以及尚未支持的 Roo；固定源码/文档、安装器和版本化现场证据 |
| [desktop-agents.md](desktop-agents.md) | Cursor、Windsurf/Devin、Zed、Warp、Qoder、Kiro、Trae、Antigravity、Claude Desktop、Chrome DevTools MCP；固定开源实现、官方文档与闭源软件证据边界 |
| [additional-open-source.md](additional-open-source.md) | Aider、Goose 固定源码补充；已接入全局缓存、XDG 根、会话与配置边界，项目级历史仍不做全盘扫描 |

证据按“固定实现、官方资料、版本化现场、候选未知”阅读。源码只能证明固定版本；在线官方页可变化，论坛/issue 不独立证明可无损重建。子文档的字母等级口径不同，不据等级字母推导覆盖率。[`documented`](../../SimpleMole/Services/AgentCatalog.swift) 也是程序提示标记，不代表每个叶子均有完整公开实现。

## 当前 Catalog 覆盖矩阵

S = 程序当前默认可选的缓存/日志/旧版本；R = 有损审查；H = 配置、凭据、持久状态或未知内容的高风险手动清理。档位描述当前安装状态下的分类，不额外保证所有版本均已取证。代码中的历史名称 `showOnly` 现在映射为 warning，**允许手动选择**。表中“技能/MCP”只表示已有的目录/配置源，不保证发现全部项目、插件和自定义路径；“CLI”表示安装实例识别后可卸载，不保证所有发行布局可识别。

| Agent（catalog id） | 已实施的主要数据规则 | 资源关联 / CLI | 证据与仍需注意的边界 |
| --- | --- | --- | --- |
| Claude Code `claude-code` | S 旧版本、统计/更新缓存；R 项目转录、文件快照、计划/任务/附件/备份；H 项目 memory、运行记录、环境、配置/授权 | 技能、`.claude.json` MCP；CLI | [CLI/扩展研究](other-cli-and-extensions.md#1-claude-code)。转录已与 memory 拆开；系统 temp、插件安装记录、Keychain、其他项目注册来源未完整覆盖 |
| Claude Desktop `claude-desktop` | S Electron 叶子、Caches/ShipIt、MCP 日志；R `vm_bundles` | `claude_desktop_config.json` MCP | [桌面研究](desktop-agents.md#claude-desktop--cowork)。VM 含活动磁盘/会话；未分别识别 immutable 下载、所有 extension 包与凭据；本地删除不清云端会话 |
| Codex `codex` | S `tmp`、系统/用户临时根前缀产物、文件日志、模型目录缓存、原子写残留、桌面缓存与日志；R 按文件会话/归档、computer-use 会话、附件、图片、db/config 备份；H state/history/goals/memories/queue 库、Shell 快照、授权 | 桌面与 CLI 共享技能、TOML MCP 和 .codex 数据，统一展示；独立 CLI 本体单独检测；可切换实验性 thread-store 压缩 | [Codex](codex.md)。支持可见 `CODEX_HOME`、SQLite 根和 `log_dir`；会话按 mtime 保留，压缩开关只改 config.toml、不运行 Codex；插件、worktrees、automations 仍未全量处理 |
| Cursor `cursor` | S Electron/更新/编译/statsig 缓存、淘汰扩展、内置旧 CLI 版本；R snapshots、Nori 配置备份；H projects、workspaceStorage、state.vscdb | 原生与兼容共享技能、MCP | [桌面](desktop-agents.md#cursor)。闭源数据库/快照仅部分路径证据，不宣称所有历史布局；项目文件和认证存储未全量覆盖 |
| Cursor CLI `cursor-cli` | S 旧版本；R 经 Git 状态核验的 worktrees；H chats 限深 `store*.db` 族、cli-config | 与桌面共享技能/MCP；CLI | [CLI 研究](other-cli-and-extensions.md#3-cursor-cli)。worktree 仅在已合并/孤儿且过期时推荐；store.db 来自论坛观察，认证文件/Keychain 未证明 |
| Copilot CLI `copilot` | S 旧版本、日志、macOS cache；R session-state、命令历史；H session-store.db、配置、MCP secrets/OAuth、权限/provider、plugin-data | 技能、MCP；CLI | [CLI 研究](other-cli-and-extensions.md#2-github-copilot-cli)。已有宿主扩展 presence；插件本体/登记、额外 Skill、Keychain、全部 cache 覆盖参数未处理 |
| Gemini CLI `gemini` | R tmp 会话、history、projects 索引、Seatbelt runtime；H OAuth/MCP/A2A 文件与设置 | 技能、settings MCP；CLI | [开源 CLI](open-source-cli.md#gemini-cli)。`tmp` 含历史；未按官方 retention 连带整理各会话 artifacts、扩展及所有 Keychain/沙盒账号路径 |
| Antigravity `antigravity` | S Electron 叶子；R browser recordings；H conversations、brain、MCP OAuth | 当前/旧全局技能、两版 MCP 源 | [桌面研究](desktop-agents.md#google-antigravity)。录像为产物；共享 `.gemini` 不能整根归属；CLI/插件和所有内部 schema 未完整覆盖 |
| Aider `aider` | S 全局模型目录缓存；H OAuth key、配置、分析/安装状态 | 无全局 Skill/MCP 源；presence 检测 CLI | [补充研究](additional-open-source.md#aider)。不遍历未授权项目中的聊天历史和 tag cache；pip/pipx/uv 安装本体未接入卸载 |
| Goose `goose` | S XDG/桌面日志、模型目录与 Electron 缓存；R 旧 JSONL 会话、MCP app cache；H 会话 DB、用户 app、配置/凭据与旧根 | 专属及兼容共享技能；presence 检测 CLI/桌面 | [补充研究](additional-open-source.md#goose)。支持 `GOOSE_PATH_ROOT` 与 XDG；YAML extensions、Keychain secret map 不做单项编辑 |
| Cline `cline` | R 新会话附件/日志、旧宿主 tasks/checkpoints/cache；H 新 state/secrets/DB/settings 与旧 MCP settings | 专属及共享技能、四个 JSON MCP 源；扩展宿主 presence | [扩展研究](other-cli-and-extensions.md#7-cline-扩展与新-sdk)。支持 `CLINE_DATA_DIR`/`CLINE_DIR`；其他细粒度 DB/文件 override 与 SecretStorage 未全覆盖 |
| Continue `continue` | R 单会话、派生 SQLite/vector 索引、dev_data/logs/runtime；H OAuth context、配置与 `.env` | 技能；扩展宿主/`cn` presence | [扩展研究](other-cli-and-extensions.md#9-continue-扩展)。支持 `CONTINUE_GLOBAL_DIR`；保留 sessions.json，MCP 多文件多格式不做编辑 |
| OpenCode `opencode` | S XDG cache/log；R runtime、snapshot、tool-output、plans、旧 storage/state、Git 状态核验的 repos worktree；H opencode*.db 族、provider/MCP 授权 | 配置技能、JSON/JSONC MCP；CLI | [开源 CLI](open-source-cli.md#opencode)。DB **含 credential**；支持 XDG 与 worktree 安全门。`OPENCODE_DB`、系统 temp、单数 skill、额外路径与插件登记仍有缺口 |
| Grok CLI `grok` | S 旧版本、marketplace-cache/日志；R sessions；H worktrees 库/目录、两版 memory、auth/MCP credentials | 技能、TOML MCP；CLI | [官方 Grok Build](other-cli-and-extensions.md#4-官方-grok-build)。marketplace-cache/日志未逐版本证明；不混同第三方 grok-cli。Grove、自定义 memory/auth、项目 rewind、兼容 scope 和会话搜索库独立分组未完整处理 |
| pi `pi` | R sessions；S pi-debug.log、tmp/extensions；H auth/MCP auth、settings/models | 技能、mcp.json；CLI | [开源 CLI](open-source-cli.md#pi)。支持新旧 npm 包名识别；npm/git Pi package 本体和 settings packages/skills 声明级联、session-dir 覆盖未完整支持 |
| Kimi `kimi` | 两代 `.kimi` / `.kimi-code`：S 日志/新版 cache；R 会话、输入历史、旧 plans、paste-cache、新 blobs；H store/index、两代凭据和配置 | 两代技能/MCP；CLI | [开源 CLI](open-source-cli.md#kimi旧-cli-与新-kimi-code)。根覆盖语义已区分；旧 plans 保持真实 home。旧版迁移完成状态、插件与索引 tombstone 协调未自动实现 |
| Factory Droid `factory` | R sessions、日志/cache/temp、specs、snapshots/history、Git 状态核验的 worktrees；H settings/local settings | 技能、MCP；CLI | [CLI 研究](other-cli-and-extensions.md#5-factory-droid)。cache/temp 保持审查；自定义 specs/worktree、插件登记、commands/droids、OAuth 存储未知或未支持 |
| Devin `devin` | S Electron/浏览器 profile 缓存叶子、淘汰扩展；R 可重下浏览器 runtime、代码索引、文件历史；H WebStorage、共享 Cascade/memories | Windsurf/Devin 技能、Devin MCP | [桌面研究](desktop-agents.md#windsurf-与-devin-desktop)。共享 Windsurf 根去重并保留双方 owner；WebStorage schema、系统技能与 CLI 覆盖仍不完整 |
| Windsurf `windsurf` | S Electron/浏览器 profile 缓存叶子；R 可重下浏览器 runtime、代码索引、文件历史；H Cascade/memories | Windsurf 技能、旧 MCP 源 | [桌面研究](desktop-agents.md#windsurf-与-devin-desktop)。Cascade 是历史/设置，memories 含 global_rules；与 Devin 共用物理数据并按消费者保护 |
| Playwright `playwright` | S 当前用户临时根中的 artifacts/profile/download 前缀产物；R 已下载浏览器 runtime | 无技能/MCP/presence；仅以已知数据存在显示 | 临时产物只认直接子项前缀并要求 24 小时 mtime；浏览器版本可重下但成本较高，保持 review |
| Chrome DevTools MCP `chrome-devtools-mcp` | S 默认 chrome-profile 指定缓存叶子；R Service Worker CacheStorage | 通用共享 MCP 本体/注册区另行管理 | [桌面研究](desktop-agents.md#chrome-devtools-mcp)。CacheStorage 可能保存离线站点数据，已取消默认选择；纳入 Chrome 运行守卫。未完整覆盖 channel、viaCli、自定义 profile；整 profile 不承诺 Safe |
| Qoder `qoder` | H AppSupport/Qoder、`.qoder` 混合根 | `.qoder/skills`；无专属 MCP 源 | [桌面研究](desktop-agents.md#qoder)。macOS 内部 DB/cache schema 与 MCP 物理路径未证明；IDE/CLI 共用技能不能当独占残留 |
| Kiro `kiro` | H AppSupport/Kiro、`.kiro` 混合根 | 技能、settings/mcp.json | [桌面研究](desktop-agents.md#kiro)。已知 kiro.kiroagent 会话/checkpoint 证据，尚未从整根独立分组；IDE/CLI 共享根和快照物理路径需继续核对 |
| Trae `trae` | H AppSupport/Trae、`.trae` 混合根 | 技能、候选 User/mcp.json 源 | [桌面研究](desktop-agents.md#trae)。MCP 路径与内部会话 DB 未明确证明；项目 skill-config.json、TRAE SOLO 独立产品未支持 |
| Zed `zed` | S 真实 Cache/Logs/hang_traces；H threads.db、限深 scope db.sqlite、state、settings/prompts/themes/snippets | settings 的 context_servers MCP | [桌面研究](desktop-agents.md#zed)。已换成原生路径；扩展/语言服务/外部 Agent 安装资源与自定义 data root 未完整支持 |
| Warp `warp` | H Stable/Preview App Group 与旧回退根的 GUI/TUI warp.sqlite；S 两版日志 | `.warp/skills`、`.warp/.mcp.json` | [桌面研究](desktop-agents.md#warp)。不把 AppSupport 整根当 cache；themes/workflows 等未全量分组，TUI/OSS/开发 profile 与 Keychain 未完整支持 |
| Amp `amp` | H `.config/amp`、`.cache/amp` 混合根 | 技能、settings.json MCP；CLI（含原生 `.amp/bin`、brew ampcode） | [CLI 研究](other-cli-and-extensions.md#6-amp)。JSONC source、插件登记、版本化本地线程/日志位置和 secret 存储未完整覆盖 |
| Crush `crush` | H 两类配置/授权；R projects registry/cache；S providers 目录缓存；受控 registry 项目的 R crush.db 族及 S 精确日志 | 技能、两类 JSON MCP；CLI | [开源 CLI](open-source-cli.md#crush)、[项目扫描](../../SimpleMole/Services/AgentProjectStorage.swift)。仅 Home 内、非 symlink、专用 data_dir；不删项目根。crushrc 不执行/不逐项解析，自定义 Skill 和 registry 同步仍需补足 |
| Shared `shared` | 无缓存 target；全局 `.agents/skills`、`.config/agents/skills` 资源 | 共享技能链接/本体管理 | [开源 CLI](open-source-cli.md#跨工具的清理与残留策略)。消费者来自当前已知源，不是对所有项目/插件/机器的全盘使用证明 |

运行时另有 **Shared MCP** 管理区，由注册中的可识别本地安装生成，不是额外的 catalog 产品。远程 URL、无法证明归属的命令或按需 npx/uvx 环境，不能一概视作可递归删除的独占服务器包。

## 仅研究，未接入产品支持

| 工具 | 已取证内容 | 尚未实施 |
| --- | --- | --- |
| Roo Code | customStoragePath、tasks/checkpoint Git、MCP、SecretStorage、原生/共享/mode skills；[扩展研究](other-cli-and-extensions.md#8-roo-code-扩展) | 扩展定义/检测、任务/快照独立操作、有效自定义根及多宿主支持 |

Roo Code 的文件偶然出现在共享技能目录，并不代表其专属扫描或卸载已受支持。

## 清理原则与实施边界

1. **风险是删除影响。** S 默认可选；R/H、Skill、MCP、卸载由用户明确选择。体积大、Agent 生成、目录名含 cache/tmp、软件已卸载，都不独立证明无损。[OpenCode 数据库含凭据](https://github.com/anomalyco/opencode/blob/0112a92c416f5ad833d96e7a8308441f0a875d94/packages/core/src/credential/sql.ts)、[Goose 用户 app 持久化](https://github.com/aaif-goose/goose/blob/bab8ff641039c9cd3331121cd84a5c6045f365ca/crates/goose/src/goose_apps/cache.rs#L145) 是具体反例。
2. **数据存在与安装存在分开。** 当前检查 app、CLI/已知宿主扩展，不启动外部 Agent 探测；已卸载资料进入清理 Tab 的残留项，执行时重验安装状态。共享客户端/CLI/Preview/插件不能仅因一端不存在就孤儿化。当前检测仍受搜索范围和已知宿主清单限制。[旧 Kimi 入口会运行迁移器](https://github.com/MoonshotAI/kimi-cli/blob/9ab1286b8fe4e6bcd116949a27ce5e0ac3389c82/src/kimi_cli/__main__.py#L28) 说明不能靠执行命令查询版本来探测。
3. **技能链接、本体、调用登记分开。** unlink 保留目标；删除共享本体联动可核对的链接/登记，展示已知消费者。MCP 单项解绑与本体卸载分别管理；[Gemini extension 安装/卸载](https://github.com/google-gemini/gemini-cli/blob/c6bccb7ecbf6d8368d995455dd725ed34466faad/packages/cli/src/config/extension-manager.ts#L548) 和 [Claude MCPB](https://github.com/anthropics/mcpb) 说明 MCP 不统一等于全局 npm 包。当前级联只覆盖可解析源，不宣称所有插件 manifest、YAML/TS 和外部登记已清净。
4. **数据库、产物、工作树分别说明后果。** SQLite 主文件和 sidecars 合组，运行/打开文件/文件身份在执行边界重验；用户计划、录像、VM、memory 和未提交代码保持有损提示。[Zed threads.db](https://github.com/zed-industries/zed/blob/74c134a3c12418cc095122fff938ef1c2504ae06/crates/agent/src/db.rs#L443)、[Warp GUI/TUI 分库](https://github.com/warpdotdev/warp/blob/40b791c351377c4b30c48179a568326144113726/crates/warp_core/src/paths.rs#L297) 是具体例子；文件清理不等于原生数据库内业务删除或所有索引/附件同步。
5. **仅扫描明确归属的根。** 当前支持一部分产品 env/XDG 覆盖和 Codex SQLite/log 配置；Crush 只读官方 registry 的专用项目 data_dir，不遍历任意源码树。GUI 可见环境不等于用户所有 shell 运行环境，外部盘、CLI flags、项目覆盖、系统配置和每个版本未全覆盖。[Crush registry](https://github.com/charmbracelet/crush/blob/76cc5c574e15072b15aaed0f4f843a5711fae0d9/internal/projects/projects.go#L14) 为受控入口来源。
6. **清理计划去重、备份并重校验。** 当前物理路径按父子关系去重计量；MCP 配置修改备份并校验内容，CLI 先识别原生/包管理器所有权再卸载。未知 executable 最多解除已确认入口，不能递归删除共享解释器或未证明安装根。[执行器](../../SimpleMole/Services/AgentCleanupExecutor.swift)、[配置编辑器](../../SimpleMole/Services/AgentMCPConfigEditor.swift)、[CLI 服务](../../SimpleMole/Services/AgentCLIService.swift) 是实施入口。

保留策略只对 review 类的对话历史与检查点/产物生效，只用 mtime 判断单项是否过期；Agent 启动时批量读取历史会刷新 atime，因此不把它当用户活动。删除历史移入废纸篓，但 Agent 本地索引可能暂时保留失效条目。Git worktree 还要在扫描与执行时分别复核状态：仅无改动且已被其他 ref 包含、或主仓库已不存在的过期树可推荐；Nori 不运行 `git worktree prune`、不写仓库登记。系统临时目录只认已审计根下的直接子项前缀，并同时要求对应保留期（用户 T 根 24 小时、`/private/tmp` 7 天）的 mtime、当前 uid 与打开文件复核；临时根不参与 Agent 安装/残留判定。

普通文件清理不撤销服务端 token，不清 Keychain，也不删除云端会话。当前没有覆盖所有 Agent 产物、第三方插件持久数据、原生 session 删除 API、索引更新或 Git worktree 注册修复；这些属于后续能力，不能用“扫描完成”表达成全盘无残留。

本次复核额外区分 Skill 自有目录与隐式读取目录：Cursor 的兼容读取不会把 `.agents/skills` 归为 Cursor 卸载残留。目录、Skill 和 MCP 操作纳入实际匹配的 IDE 扩展宿主守卫；Devin/Windsurf 的同一物理数据只产生一份分类，保留双方运行守卫。直接覆盖的 `CRUSH_CACHE_DIR` 未证明专用根时不扫描整根，避免用户普通目录成为可删残留。

普通清理同时排除与已知 Agent 数据路径重叠的候选，包括自定义 SQLite/日志根所在的缓存父目录；重新扫描后才产生本轮策略下的清理计划，旧风险分类缓存会失效。

MCP 本体识别排除已知 Agent CLI 的命令和 npm 包；Agent 提供的 MCP 服务只解除注册，CLI 卸载仍走专用入口。Skill/MCP 的 TOML 扫描与修改按字符串上下文识别真实注册，不编辑多行提示词中的配置示例；注册文件无法可靠解析时保留相关 Skill 本体，待配置恢复或被明确清理后再操作。
