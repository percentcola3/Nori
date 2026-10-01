# 其他 CLI 与编辑器扩展的 Agent 清理审计

核对日期：2026-10-01。范围：Claude Code、GitHub Copilot CLI、Cursor CLI、官方 Grok Build、Factory Droid、Amp，以及 Cline、Roo Code、Continue 扩展。本文只提供来源、删除影响和补丁建议；未运行外部项目代码、安装器或任何真实数据清理。对照对象是本次工作区的 `AgentCatalog.swift`、`AgentCLIService.swift` 与资源配置编辑器。

## 证据口径

| 等级 | 含义 | 如何使用 |
|---|---|---|
| A | 官方源码，链接固定到完整 commit；实现直接构造路径或读写数据 | 可作为规则来源，但仍需检查正在运行的版本与路径覆盖 |
| B | 官方文档或官方安装器；网页内容可变，记录访问日期，部分附 SHA256 | 可作为默认路径与操作语义的来源；不要声称固定到源码版本 |
| C | 官方仓库 issue 或官方论坛中的用户案例 | 补充现场路径和历史版本，不能单独证明“可以无损重建” |
| D | 第三方案例或工具支持记录 | 仅作待验证候选，保持手动选择和版本提示 |

源码取证固定点：

| 项目 | 仓库与固定 commit | 范围限制 |
|---|---|---|
| Claude Code | `anthropics/claude-code@6160717d8994f236ab381cf534fc1cde5347c12f` | 仓库的示例、mods、发布记录不等于完整核心存储实现；主要目录证据来自官方文档 |
| Copilot CLI | `github/copilot-cli@659e4652ac910f8046dc64480bd6beda8f0ad2a6` | 安装器与 changelog 可核验；存储细节由 GitHub 官方文档补足 |
| Copilot 文档 | `github/docs@10844e10c034b5e5d9b62793c3af9feb4b91de07` | [配置目录全文][CP1] 固定；与未来 CLI 版本仍可能有差异 |
| Grok Build | `xai-org/grok-build@2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8` | 官方 Rust CLI/runtime；不要混同社区 `superagent-ai/grok-cli` |
| Factory Droid | `Factory-AI/factory@485a0c3b5d3d11c52d50cd2a8889e1a71e86905a` | 本次使用固定文档文件，未将仓库体积或目录名视为核心实现证据 |
| Amp Homebrew | `ampcode/homebrew-tap@93b9416a8ae1ea41046b1a6e62a81b4090d7aa4a` | 官方 formula：`ampcode`，binary：`amp`，版本 `0.0.1790844275-g6aabf1` |
| Cline | `cline/cline@8eee168b80127b0c94bad849323754b5864865e7` | 当前 HEAD 已包含 SDK 存储迁移；旧版扩展布局要同时支持 |
| Roo Code | `RooCodeInc/Roo-Code@b867ec9145750d0ae1ff7f02d35406e9bf2a0b16` | 扩展 manifest 版本 `3.53.0`；同时存在新的 Roo CLI，不能混用两者存储根 |
| Continue | `continuedev/continue@5522c6f44ca0ac3528b37244818fbfa39b5af470` | IDE 扩展和 CLI 共用部分路径；远端 `cn serve` 同步另有语义 |
| Cursor CLI | 无公开核心源码固定点 | 官方安装器此次版本 `2026.09.28-64d2043`；文档按访问日期引用，SQLite 布局只有论坛案例 |

风险建议对应 Nori 的 `safe / review / showOnly`：安全缓存可快速清理；历史、日志、检查点手动选择；配置、凭据、持久记忆、worktree 高风险并提示明确损失。当前实现已允许高风险项目手动操作，本文不建议恢复“只显示不可清理”。官方文档的“not recommended”应转成风险提示，而不是产品里的永久保护。

## 1. Claude Code

官方 [目录说明][CC1]、[环境变量][CC2]、[认证][CC3]、[安装/卸载][CC4]、[记忆][CC5] 构成主要证据，均为 B；不要用一个示例中的路径来替代完整规则。

| 路径/来源 | 内容与删除影响 | 建议档位、当前差异 |
|---|---|---|
| `~/.local/share/claude/versions/`，入口 `~/.local/bin/claude` | 官方原生安装器存放多个 binary 版本；入口是 symlink。移除当前 binary 是卸载，旧版本通常可再下载 | 现有旧版本规则合理，必须保留入口实际引用版本和最新版本。自定义 launcher 从 v2.1.207 起可被保留，不能把它误认成标准 symlink |
| `~/.claude/projects/<project>/<session>.jsonl`，及 orphaned / superseded transcript | 完整对话、工具调用/输出；旧 transcript 可能是唯一可恢复副本 | review；现有 `.children(projects)` 粒度过粗 |
| `projects/<project>/<session>/subagents/`、`tool-results/` | 子会话转录、大输出和 MCP 返回图片 | review；按会话归组，删除 transcript 时允许连带清理这些伴随内容 |
| `projects/<project>/memory/` | 持久自动记忆。官方 retention sweep 明确排除记忆，项目 worktree/子目录可能共享它 | 高风险；现有“项目转录”整个根删除会同时删记忆，应拆分或明确标成“会话与项目记忆” |
| `file-history/<session>/` | 修改前文件快照，供 checkpoint/rewind 恢复 | review，提示“失去文件回退能力”，不能简单写“缓存” |
| `plans/`、`tasks/`、`feedback/drafts/`、`usage-data/` | 计划、任务、待审反馈、用量报告和分析缓存 | review；现有漏项。`todos/` 是旧布局，应与当前 `tasks/` 分开识别 |
| `uploads/<session>/`、旧 `image-cache/<session>/`、`paste-cache/` | 附件、图片、大段粘贴内容 | review；现有只覆盖 paste-cache |
| `debug/`、`session-env/`、`shell-snapshots/` | 调试日志、会话环境、shell 别名/函数快照。shell-snapshots 正常退出会清除，崩溃后可能留下 | review 或经停用/过期检查后清理；debug 日志可含敏感文本 |
| `sessions/` | 每个运行会话的小型活跃记录，供并发/崩溃检测；并非 transcript | 仅退出后清理，不应因名称叫 sessions 就作为普通会话历史 |
| `backups/`、`feedback-bundles/`、插件 install-record 的 set-aside/unreadable 副本 | `.claude.json` 备份、诊断档案、无法读取的安装记录 | review；备份可能含 MCP/账号信息，不能当无价值临时文件 |
| `stats-cache.json`、`cache/changelog.md` | 用量统计聚合和更新日志缓存 | 可考虑 safe；前者删除会重算统计，后者可刷新。现有只扫描 legacy statsig |
| `todos/`、`statsig/`、`logs/` | 官方当前文档称为不再写入的历史布局 | 仍可扫描；规则证据不宜继续只写“当前官方缓存” |
| `history.jsonl` | 输入历史和搜索/补全 | 高风险或 review，失去历史；当前已扫描 |
| `.credentials.json`，macOS Keychain | macOS 正常凭据在 Keychain；Keychain 写入失败才回退 JSON。只删 JSON 不等于完全登出 | 高风险；凭据文件当前已扫描，应提示仅处理文件凭据。不要删除整个 Keychain 数据库 |
| `settings.json`、`~/.claude.json`、`agent-memory/`、`jobs/`、`daemon/` | 设置、应用状态/MCP、子 agent 记忆、后台任务状态 | 高风险。`.claude.json` 当前仅作为 MCP source；其他持久数据仍遗漏 |
| `plugins/`、`skills/`、`commands/` | 插件本体、marketplace、用户 Skill/旧 commands、安装记录及插件持久状态 | 资源管理；插件 cache 不应无条件整根删：删除插件需要更新 installed_plugins.json 与启用设置。同步 skill/plugin 本地删除后可能重下载；`.trash` 是可恢复回收内容 |
| `/private/tmp/claude-<uid>/<project>/<session-id>/scratchpad/`，新版 session `images/` | 自测/工具中间文件与草稿。系统临时路径不同于 ~/.claude | 额外扫描候选；只限当前 uid 的已知子树、停用会话，需说明草稿可能丢失。当前缺少 temp 根适配 |

`CLAUDE_CONFIG_DIR` 默认 `~/.claude`，覆盖设置、会话、插件；凭据 JSON 和 macOS Keychain entry 也按该根隔离。`CLAUDE_CODE_PROJECT_DIR_NAME` 可改 projects 中项目目录名；`CLAUDE_CODE_TMPDIR` 控制临时树；`CLAUDE_CODE_DEBUG_LOGS_DIR` 名字像目录，官方说明它实际是**日志文件路径**；`CLAUDE_CODE_PLUGIN_CACHE_DIR` 实际是 plugins **父目录**。需要独立 resolver，不能对这些值统一加 `/cache` 或 `/debug`。

MCP 有 user/local `~/.claude.json` 与 project `.mcp.json`，插件还可携带 MCP；[官方 MCP 文档][CC6]。现有编辑器已支持 `.claude.json` 的 projects 嵌套表，后续不要重复实现。移除注册与删除 server 本体应分开；远端 URL 无可删除本地 server。`~/.claude` 还被桌面端、VS Code、JetBrains 共用，[官方卸载说明][CC4]明确指出这些客户端仍安装时会重建目录。只检测 standalone `claude` 不足以决定它是否是残留。

公开现场证据：[anthropics/claude-code#96058](https://github.com/anthropics/claude-code/issues/96058)（C，macOS Desktop）报告删除 UI 会话后仍留下 transcript、file-history、uploads、session-env；它支持加深残留扫描，但不能证明现场所有文件均可无损删除。

## 2. GitHub Copilot CLI

[官方配置目录全文][CP1] 是固定文档源码 A，[安装器][CP2] 是固定脚本 A。文档提供明确“删除影响”表，是本组最适合直接转成 UI 提示的来源。

| 路径（配置根默认为 `~/.copilot`） | 删除影响 | 当前差异与建议 |
|---|---|---|
| `logs/`、`logs/extensions/` | 调试日志重建，无功能影响 | safe，当前 logs 覆盖；与用户代码 `extensions/` 分开 |
| macOS `~/Library/Caches/copilot` | marketplace、自动更新包、临时数据可再取 | safe，当前已覆盖；`COPILOT_CACHE_HOME` 可独立覆盖 |
| `session-state/<id>/events.jsonl`、计划/检查点/跟踪文件 | 失去会话恢复。删除本地副本不会删除账户已同步的远端会话 | review，当前已覆盖根子项，但需清楚展示伴随资产和云端不受影响 |
| `session-store.db` + SQLite sidecars | 跨会话数据/搜索/检查点索引；官方允许 `/chronicle reindex` 重建，并指出重建会同步会话数据 | review，关键漏项；不能把数据库“自动重建”理解为删除无损。reindex 不应被清理器自动执行 |
| `command-history-state/` | 丢 Ctrl+R 命令历史 | review，漏项 |
| `config.json` | 应用状态、认证、插件 metadata；删除后须重新认证 | 高风险，漏项。旧 user settings 会迁到 settings.json，config.json 仍有用途 |
| `settings.json`（支持 JSONC） | 偏好恢复默认 | 高风险，漏项；不要把它作为严格 JSON 全文件重写 |
| `permissions-config.json`、旧 `permissions-config` | 清除项目保存的工具/目录审批，下次重新询问 | 高风险，漏项；文件是否存在决定 legacy fallback |
| `providers.json` | 丢 BYOK provider/model registry | 高风险，漏项；`COPILOT_PROVIDERS_CONFIG` 可覆盖 |
| `mcp-config.json` | 移除 user MCP 注册 | 当前已有；project `.mcp.json` / `.github/mcp.json` 另有作用域 |
| `mcp-oauth-config/`、`mcp-secrets/` | Keychain 不可用时的 OAuth/PKCE、注册和 secret 占位映射；删后需重新认证或配置 | 高风险，漏项；清除文件 fallback 不代表清除 Keychain 中该 server 的凭据 |
| `installed-plugins/{marketplace}/{plugin}`、`installed-plugins/_direct/` | 插件本体 | 资源卸载，漏项；官方建议 `copilot plugin uninstall` 保持 config.json metadata 一致 |
| `plugin-data/` | 插件持久数据，官方标为可按需重建 | 至少 review，按 plugin 展示；“持久数据”具体内容由插件决定，不建议默认整根选中 |
| `agents/`、`skills/`、`hooks/`、`extensions/`、`instructions/`、`copilot-instructions.md`、`lsp-config.json` | 用户自定义内容/代码/服务定义 | 高风险或资源操作；当前仅 skills 有资源入口 |
| `ide/` | IDE 锁文件/集成状态 | 停止所有相关 CLI/IDE 后清理；文件夹名不证明整个目录永远可删 |

`--config-dir` 优先于 `COPILOT_HOME`，后者替代**完整配置根**；官方称前者是 legacy option。cache 根不跟随 COPILOT_HOME，macOS 路径如上，Linux `$XDG_CACHE_HOME/copilot` 或 `~/.cache/copilot`。旧 XDG 配置在没有 COPILOT_HOME 时可能迁入默认根。`skillDirectories` 是 settings 中额外 Skill 目录；最新版 changelog 指出显式 config-dir/COPILOT_HOME 不再加载默认 `~/.agents/skills`，因此不能无条件给所有实例附同一组 shared Skill。

安装器支持 `PREFIX`，普通用户默认 `$HOME/.local/bin/copilot`，root 默认 `/usr/local/bin/copilot`；当前 `.copilot/pkg/universal` 不能代表所有安装本体。[Copilot CLI #4529](https://github.com/github/copilot-cli/issues/4529)（C，1.0.80 Remote-SSH）报告 session-store.db 的 turns 仍保存完整消息，[#4543](https://github.com/github/copilot-cli/issues/4543)报告无 standalone CLI 的 VS Code 内嵌模式仍写 ~/.copilot。存在性要考虑 VS Code 内嵌宿主，不能因为 PATH 没有 copilot 就把整根当已卸载。

## 3. Cursor CLI

| 路径/覆盖 | 证据 | 删除影响、对照建议 |
|---|---|---|
| `~/.local/share/cursor-agent/versions/<version>/`，`~/.local/bin/cursor-agent` / `agent` | B，[此次安装器][CU1] | 当前 oldVersions 规则匹配安装器。`agent` 与 Grok 等产品冲突，必须解析入口归属后再卸载 |
| `~/.cursor/cli-config.json` | B，[配置][CU2] | CLI 偏好/权限相关配置；高风险可清理。当前 Cursor CLI 只列旧版本，遗漏它 |
| `CURSOR_CONFIG_DIR`；Linux/BSD `XDG_CONFIG_HOME/cursor/cli-config.json` | B，[配置][CU2] | 自定义配置目录要按 CLI 平台规则解析；不能把 Linux XDG 规则直接套到 macOS |
| 项目 `.cursor/cli.json` | B，[配置][CU2] | 项目配置；仅在用户指定/已知项目范围纳入资源盘点，不应全盘扫描所有仓库 |
| `~/.cursor/chats/**/store.db` | C，[官方论坛案例][CU6] | CLI 会话数据库含消息。建议 review + SQLite family，按 chat 展示。准确路径层级和版本需 fixture/进一步源码证据，当前完全遗漏 |
| `~/.cursor/worktrees/<reponame>/<name>` | B，[使用说明][CU3] | CLI 与 editor 共用 Git worktree；可能有未提交源码。高风险、手动确认、说明 git 元数据影响；漏项 |
| `~/.cursor/mcp.json`、项目 `.cursor/mcp.json` | B，[MCP][CU4]、[CLI 使用][CU3] | CLI 自动使用 editor MCP。当前只给 Cursor 桌面 group，CLI 的 mcpSources 为空，错误影响归属/残留判断 |
| `~/.cursor/skills`、`~/.agents/skills`，兼容 Claude/Codex Skill 目录 | B，[Skills][CU5] | CLI/桌面共享目录，删除本体影响多个客户端；当前 CLI skillDirectories 为空。发现“共享使用”不等于磁盘上有 symlink |
| 本地认证存储 | B，[认证][CU7]仅说安全保存在本地 | **未证实具体文件/Keychain service**；不要新增猜测的 auth.json 删除规则 |

官方论坛 [#151821][CU6] 中用户通过 `~/.cursor/chats` 查找 `store.db`、读取 blobs 来列出会话；这不是安全删库承诺。另有 [#149955](https://forum.cursor.com/t/create-a-unified-chat-history-view-across-all-projects/149955) 区分 legacy composer state.vscdb、JSONL transcript 与较新 CLI/ACP store.db，共存应按格式识别，不能由目录里存在一种数据就推断其他都是垃圾。

Cursor desktop 的 `User/globalStorage/state.vscdb` 和 `workspaceStorage` 存多种功能状态；现有高风险提示应保留。共享 `.cursor` 根应以 desktop **或** CLI 任一真实安装为 live，同时按资源叶子分摊占用，避免 orphan 分类重复清理。

## 4. 官方 Grok Build

官方 [README][GR0] 说明仓库包含 Rust CLI/TUI 和 runtime。以下直接来自固定源码 A；现有名称“Grok CLI”应注明官方 Grok Build，以区别社区 CLI。

| 路径 | 来源 | 内容/操作建议与当前差异 |
|---|---|---|
| `$GROK_HOME` 或 `~/.grok` | [home resolver][GR1] | 所有 home-anchored 数据不能只硬编码 ~/.grok；非空 GROK_HOME 优先且按原值解析 |
| `<grok-home>/bin/grok`，历史 downloads | [应用路径][GR2]、[npm bootstrap][GR3] | 本体/入口。现有下载旧版本规则不能代表所有发行布局；只由解析后的真实指向归属 |
| `<grok-home>/sessions/<encoded-cwd>/...` | [路径][GR2]、[存储常量][GR4] | chat_history.jsonl、summary/plan/goal state、工具状态、压缩检查点/请求等。review；现有按 CWD 子树能覆盖，但提示应说明会丢计划、子任务和回退资料 |
| `<grok-home>/sessions/session_search.sqlite` | [search DB][GR5] | 会话搜索索引，使用 JournalMode 有可能选择有效 DB 路径。review/可重建候选；应从会话目录子项中分出 SQLite family，避免只删 base 或把它当“一个项目会话” |
| `<grok-home>/worktrees.db` | [worktree registry][GR6] | Git worktree 注册数据库，sidecars 及网络盘 effective path 需处理。高风险；当前只列 worktrees 文件夹，漏掉注册状态，不应独立默认删除导致树与登记失配 |
| Grove 数据根：`GROVE_DATA_DIR`、配置 data_dir、`XDG_DATA_HOME/grove`、`~/.local/share/grove`、`<grok-home>/grove` 候选 | [生产候选根][GR7] | workspace/snapshot 数据，并非普通缓存。当前漏根。不能把每个候选都归 Grok：Grove 可被独立使用，先验证 metadata 和引用关系 |
| `<cwd>/.grok/rewind-checkpoints/<session-id>/checkpoint-<n>.json` | [checkpoint store][GR8] | durable feature 开启时的恢复镜像；review。项目内而非全局 home；自测工作区清理有价值，默认不全盘搜仓库 |
| `<grok-home>/auth.json` 或 `GROK_AUTH_PATH` | [登录存储][GR9] | 账号 token。高风险，当前漏项；损坏备份同样含 token，不能当安全日志 |
| `<grok-home>/mcp_credentials.json` | [MCP credentials][GR10] | MCP OAuth，与 xAI auth.json 分开，按 server name+URL 组合键保存。高风险；移除一个 server 不应删整份其他 server 凭据 |
| `<grok-home>/memory/`，新版 `memory-v2/global/`、`memory-v2/workspaces/<hash>/` | [memory storage][GR11] | Markdown 持久记忆、旧会话摘要，旧 workspace 的 index.sqlite。高风险；源码允许自定义 memory root，当前完全遗漏 |
| `config.toml` 的 mcp_servers | [TOML loader][GR12] | 当前已有原生注册；作用域/有效用户配置路径仍需 resolver |
| `~/.claude.json` 和 `.cursor/mcp.json` 兼容 MCP | [JSON loader][GR13] | 按 compat/import 状态加载，不是 Grok 安装的独立本体。当前未建消费关系；不能在 Grok 卸载时直接删 Claude/Cursor 的配置 |
| `.grok/skills`、`.agents/skills`、可选兼容 `.claude` / `.cursor` Skill | [Skill discovery][GR14] | 消费关系受兼容配置影响；不再扫描 vendor `skills-cursor`，并过滤已知 built-in 名。不要照搬 Cursor 全目录推导 Grok 能见到哪些 Skill |

当前 marketplace-cache/logs 可保留为候选；此次未逐个核对其所有版本写入与重建逻辑，不将整根“名称含 cache”升级成无条件 safe。`worktrees.db` 与源码工作树应整体形成可审查计划，先识别未提交修改和其他进程持有，再清理注册与本体。

## 5. Factory Droid

[设置][FD1]、[MCP][FD2]、[Skills][FD3]、[插件][FD4] 都固定到官方文档 commit（A：固定文档，路径行为仍由文档而非运行代码保证）。

| 路径 | 删除影响/建议 | 当前差异 |
|---|---|---|
| `~/.factory/sessions/<encoded-cwd>/` | 对话/恢复与任务数据；review，停止 daemon、desktop 与 CLI 后清理 | 当前已列 sessions 子项。官方 issue [#1][FD5]（C，macOS 0.183.0）报告空会话积累；允许按无用户消息/无 token 且非活跃会话单列，不仅按文件大小猜 |
| `~/.factory/logs`、cache、temp | 日志/候选临时数据 | 当前已有，日志适合 review；此次没有确认每个 cache/temp 叶子的生产实现，不扩大到所有未知子项 |
| `~/.factory/settings.json`、`settings.local.json` | 个人偏好、自动运行、模型/BYOK 等设置 | 高风险、漏项；项目/祖先文件另有 precedence，不应删 user 文件后声称所有设置已移除 |
| `~/.factory/specs`，settings 的 `specSaveDir` | 用户保存的规格文档 | review，漏项；不能叫缓存 |
| `~/.factory/worktrees`，settings 的 `worktreeDirectory` | Git worktree 和未提交源码 | 高风险，漏项；自定义目录要先验证归属 |
| `~/.factory/skills`、`commands/`、`droids/` | Skill、旧 slash command、自定义 droid | 资源管理；当前仅 skills。旧 commands 已与 skills 功能合并，但仍被加载 |
| `~/.factory/mcp.json`；祖先/项目 `.factory/mcp.json` | MCP 注册，user 高于 folder 高于 project。项目启用/禁用会在 user 配置存副本 | 当前 user source 已有；移除 user 项可能重新暴露下层 server，要提示作用域。project server 可通过编辑文件删除，不应因官方 UI 不给按钮而永久保护 |
| 插件本体及配置安装登记 | 插件可能带 Skills、hooks、MCP | 固定 docs 说明 `.factory-plugin/plugin.json` 为 manifest，其他组件在 plugin 根。**未核实全局 installed-plugin/cache 的具体存储根**，不要编造路径；卸载应依插件登记和实际 manifest 识别 |
| OAuth | 官方文档说 Droid 用 keyring 保管 OAuth token | 未核实 macOS keyring service 名或 file fallback，暂不列猜测凭据文件 |

官方安装器 [app.factory.ai/cli][FD6] 此次版本 `0.231.0`，安装 regular binary 到 `$HOME/.local/bin/droid`，只读取脚本，未执行。未在固定 docs 找到通用 `FACTORY_HOME`/XDG 数据根保证，应将“支持自定义 specs/worktree”与“整个 Factory root 可 env 覆盖”分开。桌面与 CLI 同享 `.factory`，[#22](https://github.com/Factory-AI/factory/issues/22)（C，macOS desktop 0.200.0、standalone 0.199.0）验证两者均读写 sessions；PATH 无 droid 不能单独证明全局根已无活跃宿主。

## 6. Amp

现有 `undocumented` 将 `.config/amp`、`.cache/amp` 两个根整体列为高风险。官方已经说明设置、Skills、plugins 与安装器，值得拆叶子；线程目录只能保留历史版本证据。没有找到完整官方核心源码仓库，不用第三方同名项目替代。

| 路径/来源 | 证据 | 内容、删除影响与补丁建议 |
|---|---|---|
| `~/.config/amp/settings.json` **或 `settings.jsonc`**，项目 `.amp/settings.json[c]` | B，[settings][AM1] | 当前只扫描 json，漏 jsonc；user/project setting 合并不能用整根删除来充当一个 MCP 解绑 |
| `amp.mcpServers`（literal dotted key）与 `--mcp-config` | B，[MCP][AM2] | flags > workspace > user > Skills。现有配置编辑器已兼容 literal dotted key；新源需要 jsonc lossless 编辑或明确 raw-file 手动删除 |
| `~/.config/amp/skills`、`~/.config/agents/skills`、`~/.agents/skills`，Claude Skill/plugin cache，`amp.skills.path` | B，[Skills][AM3]、[settings][AM1] | 官方共享发现路径，额外路径可 colon 分隔、相对 workspace，前两个共享 Agent 根有关闭开关。不允许把共享路径当 Amp 独占 orphan data |
| `~/.config/amp/plugins`，project `.amp/plugins` | B，[plugins & Skills][AM4] | 系统插件本体；高风险/资源卸载，现有只扫整个 config 根，无插件引用层。托管 personal/workspace Skill repository 删除本地副本不等于删除云端发布 |
| `AMP_HOME/bin/amp`，默认 `~/.amp/bin/amp`；入口可能在 ~/.local/bin、~/bin、~/.bin | B，[安装器][AM5] | 官方当前安装本体；现有 nativeRoots 没有 Amp，可能只删 symlink 留 binary，或直用 ~/.amp/bin 时不识别。新增已证实 root resolver，不扩大到 AMP_HOME 整根任意删除 |
| 官方 Homebrew tap `ampcode/homebrew-tap` 的 formula `ampcode`，binary `amp` | A，[formula][AM6] | 当前允许 brew token `amp`，遗漏官方 token `ampcode`。以 realpath Cellar 的实际 formula identity 卸载，不凭命令名猜 |
| `~/.local/share/amp/threads/`、`history.jsonl`、`device-id.json` | D，[第三方 issue][AM7]、[AM8] | 历史本地线程、输入历史、安装身份。当前漏 data 根；建议版本标注、高风险/手动核对。AMP_DATA_DIR 与 XDG override 此次没有官方源码证明，不应据第三方转成默认高置信规则 |
| `~/.cache/amp/logs/threads/*.log` | D，[AM7] | 用户报告新版本按需写线程日志，authoritative thread 在服务端。可按版本扫描日志叶子，仍提示可能含完整内容。不能把旧 threads 空/mtime 久直接判定所有旧文件是垃圾 |
| 认证与 MCP OAuth | B，[MCP][AM2] | 官方说 secret storage 安全保存 token，清除后重新认证；**具体 macOS keychain service 和 fallback 文件未证实**，勿编造 auth.json/secrets.json 规则 |

第三方 [alleycat#21][AM7] 记录 2026-03-31 前后线程从 local/share 转为 cache/logs/threads 的差异；[tokens#64][AM8] 在 macOS Amp `0.0.1787616161` 报告旧线程目录不再产生新文件、history.jsonl 仍更新。两者迁移时间表述不同，均不是官方存储兼容合同。只有存在本地文件才展示手动清理；不要自动调用 Amp server API 删除远端线程。

官方网页未承诺 XDG_CONFIG_HOME 全面影响 Amp 配置，本次可验证的是列出的 `~/.config/amp` 路径，不能从 `.config` 这个目录名自动推断遵循所有 XDG 变量。

## 7. Cline 扩展与新 SDK

扩展 ID 由固定 [manifest][CL0] 得到 `saoudrizwan.claude-dev`。macOS 标准 VS Code 的 extension globalStorage 基准为 `~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/`，但真正权威的是 `ExtensionContext.globalStorageUri`；Cursor、Insiders、portable、user-data-dir、profile、Remote-SSH 可换根。不要把源码注释中“~/.vscode SQLite”当成 macOS 真实全局 state.vscdb 位置。

| 存储 | 来源 | 删除影响/建议 |
|---|---|---|
| legacy extension root `tasks/<id>/`、`state/taskHistory.json`、`checkpoints/` | [disk helpers][CL1]、[迁移说明][CL2] | JSON transcript/UI/task metadata 和 Git checkpoints。review，可按任务分层。迁移说明仍保留旧数据以便 downgrade；看到新根不等于旧根已可无提示全删 |
| extension `cache/`、`settings/cline_mcp_settings.json` | [CL1] | cache 需要核验具体内容；MCP 为 mcpServers map，应资源解绑，不整根 settings 删除 |
| `~/.cline/data/globalState.json`、`secrets.json`、`workspaces/<hash>/workspaceState.json` | [文件存储][CL3] | 当前跨 VSCode/CLI/JetBrains 共享 state，secrets 为 0600；高风险。旧 VS Code memento/secrets 迁移后未清空 |
| `~/.cline/data/db/sessions.db`、`connectors.db`、`cron.db`、`tasks.db` | [path resolver][CL4]、[SQLite session store][CL5] | sessions 为会话元数据/状态，connectors 含配置与凭据，cron/tasks 含自动化/任务生命周期。分别 review/高风险，SQLite sidecars 必须作为同一数据组 |
| `~/.cline/data/sessions/<id>/` | [CL4]、[session artifacts][CL6] | 消息、压缩资料等附件，数据库删除不自动删除 artifacts；会话删除计划要协调两种数据 |
| `data/settings/providers.json`、`global-settings.json`、`cline_mcp_settings.json` | [CL4]、[SDK Controller][CL7] | provider/全局偏好/当前共享 MCP 注册。新 MCP 不在旧 extension settings 下，必须同时识别版本/迁移 source |
| `data/logs/connectors/...`；provider request capture | [CL4]、[provider 文档][CL8] | connector stdout/stderr、可能含 prompt 的请求捕获。review；CLINE_CAPTURE_DIR 或 CLINE_DATA_DIR/provider-request-captures 有证据，capture 并非所有实例默认创建 |
| `~/.cline/skills`、`~/.agents/skills` 与项目 `.clinerules/skills`、`.cline/skills`、`.claude/skills`、`.agents/skills` | [Skill discovery][CL9] | 全局/项目共享资源；unlink 和删除本体分开。扫描函数不应由 Nori 调用，以免外部运行/创建目录 |
| `~/Documents/Cline/{Rules,Workflows,Hooks,MCP}` 与插件/`.cline` 新资源 | [CL1]、[CL4] | 用户编写内容、MCP server 本体候选，而不是全部 cache。MCP 目录只是官方提供的创作建议路径，不代表目录里每个文件都已注册 |

`CLINE_DATA_DIR` > `CLINE_DIR/data` > `~/.cline/data`；SDK 另有 `CLINE_SESSION_DATA_DIR`、`CLINE_DB_DATA_DIR`、`CLINE_TEAM_DATA_DIR`、`CLINE_CONNECTOR_DATA_DIR`；单文件覆盖包括 `CLINE_MCP_SETTINGS_PATH`、`CLINE_PROVIDER_SETTINGS_PATH`、`CLINE_GLOBAL_SETTINGS_PATH`、`CLINE_CONNECTORS_DB_PATH`、`CLINE_CRON_DB_PATH`、`CLINE_TASKS_DB_PATH`。这些是固定源码 A，不宜统一拼成一个 root。

[旧 MCP 迁移实现][CL10] 还读取 extension settings 和 Documents/Cline/MCP/cline_mcp_settings.json，合并到共享文件并保留迁移状态。配置本体删除后不能在另一个仍存在的 legacy source 留同名注册，亦不能把 legacy OAuth 整根清除影响其他 server。现有 Catalog 没有 Cline，应新增**宿主扩展安装证据**和这些数据 targets，而不是仅因 VS Code 已安装就视为 Cline 已安装。

## 8. Roo Code 扩展

固定 [manifest][RO0] 是 `RooVeterinaryInc.roo-cline`，规范路径常见为 lowercase `rooveterinaryinc.roo-cline`；从宿主 extension metadata 取 ID，不靠显示名匹配。Storage base 可由 `roo-cline.customStoragePath` 覆盖，[实现][RO1] 会验证自定义目录可用，否则回退 globalStorage。Settings 和 cache 同样受这个覆盖影响。

| 路径（下述 base 为有效 extension storage/customStoragePath） | 来源 | 删除影响/建议 |
|---|---|---|
| `<base>/tasks/<id>/api_conversation_history.json`、`ui_messages.json` | [storage][RO1]、[文件名][RO2] | 对话与 UI 记录；review，可按任务选择 |
| `<base>/tasks/<id>/checkpoints/.git` 与旧 `<globalStorage>/checkpoints/<workspaceHash>` | [RepoPerTask][RO3]、[ShadowCheckpoint][RO4] | 独立 shadow Git snapshots，删除后失去 task rollback；review，分别展示快照和会话，不删项目自己的 .git |
| `<base>/settings/mcp_settings.json` | [MCP hub][RO5] | mcpServers 注册；资源解绑，项目 `.roo/mcp.json` 另有作用域 |
| `<base>/cache` | [RO1] | 仅证实路径，不证明任意 cache 内容都无损；先 review，逐叶子定级 |
| VS Code memento / SecretStorage provider profiles | [ProviderSettingsManager][RO6] | 高风险设置和凭据，不能因删除 extension files 就宣称已登出，也不能删除宿主整份 state.vscdb |
| `~/.roo/skills`、历史 `skills-<mode>`、`~/.agents/skills` / `skills-<mode>`，项目相同布局 | [roots][RO7]、[Skill manager][RO8] | 原生和共享 Skill，有 symlink/canonical scan；只删链接时保留 shared target。mode 历史目录仍参与扫描，不能遗漏 |

公开 [#12072](https://github.com/RooCodeInc/Roo-Code/issues/12072)（C，macOS）报告 tasks 的 checkpoint Git 达 33GB；[#10801](https://github.com/RooCodeInc/Roo-Code/issues/10801)请求只删 checkpoints 保留会话，说明这应是两个独立用户动作。当前无 Roo definition，整个扩展缺扫描。新的 `apps/cli/src/lib/storage/config-dir.ts` 是另一个 Roo CLI 的 source，不应用其路径替代 VS Code 扩展 globalStorage。

## 9. Continue 扩展

扩展 ID `Continue.continue` 来自固定 [manifest][CO0]；[core/util/paths.ts][CO1] 直接提供 mac/Linux `~/.continue` 以及 `CONTINUE_GLOBAL_DIR` 覆盖。相对 override 按 Continue 启动工作目录解析，不是 Nori 的当前 cwd。

| 路径 | 来源/删除影响 | 建议与关键陷阱 |
|---|---|---|
| `sessions/<id>.json`、`sessions/sessions.json` | [paths][CO1] 会话与列表；[history][CO2] | review，删单会话要更新列表；当前缺组 |
| `index/index.sqlite`、`index/lancedb`、`index/autocompleteCache.sqlite`、`index/docs.sqlite` | [CO1] 派生代码/文档/补全索引 | 可再生成但会重建成本；数据库 family 与 vector store 单独选；未检查所有来源能否再取前不默认整根 safe |
| **`index/globalContext.json`** | [paths][CO1] + [GlobalContext][CO3] + [OAuth][CO4] | **包含 mcpOauthStorage 的 OAuth clientInformation/tokens/codeVerifier，不能把 index/ 整根默认当缓存删！** 高风险单列或按 server 定向清理 |
| `dev_data/devdata.sqlite`、版本目录 JSONL | [CO1] 开发/遥测事件 | review，含交互内容，不仅普通日志 |
| `logs/core.log`、`logs/prompt.log` | [CO1] 调试及 prompt 内容 | review，可清理但提示隐私/诊断记录会丢 |
| `config.yaml`、旧 `config.json`、`config.ts`、`.env`、`sharedConfig.json` | [CO1] 模型配置/可含 API keys、规则与环境变量 | 高风险，不能整根当缓存；YAML/JSONC/TS 要各自解析，不用现有严格 JSON/TOML MCP editor 强写 |
| `.utils/.chromium-browser-snapshots`、`.utils/esbuild`、`out/config.js` | [CO1] 下载工具/编译产物 | 可重建候选，待核验入口后叶子清理。`.utils/repo_map.txt` 需单独说明 |
| `.configs/`、`.diffs/`、`prompts/`、rules | [CO1] remote 配置副本、diff、用户 prompt | 按内容拆，review/高风险，不因点目录就判垃圾 |
| `~/.continue/skills`、项目 `.continue/skills` 和 `.claude/skills` | [Markdown loader][CO5] | Skill 消费来源，资源操作 |
| `~/.continue/mcpServers/`、项目 `.continue/mcpServers/` 的 JSON/YAML；config 内 mcpServers | [JSON loader][CO6] | 多种格式/一文件多 server / Claude-compatible project map，当前 catalog 不支持；config 删除与 server 本体分开 |

[Continue #13233](https://github.com/continuedev/continue/issues/13233)（C）报告 index 的删除与检索生命周期缺陷，可作为索引重建入口的理由，不构成所有 index 文件都是 safe 的依据。远端 `cn serve --id` 会同步 session.json/diff.txt，[固定说明][CO7]；本地清理不删除 S3/账户副本，不应自动触发同步网络请求。

## 10. 可执行补丁建议

本次已经完成的 symlink 解绑、Skill/MCP 本体 cascade、安装存在性、CLI 手动卸载与 SQLite sidecar 保证不应重复重写。以下是取证后新增的缺口。

| 优先级 | 修改位置/能力 | 可审查的目标 |
|---|---|---|
| P0 | Claude project target 语义 | 把项目 transcript/子会话/tool-results 与 `memory/` 拆开；最小修改也须明确整个项目删除包含持久记忆，禁止“只清转录”误导 |
| P0 | 共享宿主存在性与 orphan 归属 | `.claude`、`.cursor`、`.copilot`、`.factory` 各有桌面/IDE/CLI 共用；只在相关安装证据全部消失后列残留。扩展 ID 要在宿主安装清单里核实，不能把“Code.app 存在”当扩展存在 |
| P0 | Continue 新组的索引边界 | 若增加 Continue，绝不默认选择 `index/` 整根；globalContext.json OAuth 与派生 DB 分离 |
| P1 | Copilot、Grok、Cursor CLI DB 目标 | Copilot session-store.db；Grok worktrees.db + sessions/session_search.sqlite；Cursor chats/**/store.db（C 级手动）。每组配 sidecars、进程/打开文件/identity guard，不只列 base |
| P1 | root resolver，保留“为什么发现” | 产品/实例有效配置根、cache 根、data 根、temp 根分别解析；记录来源 env/配置/默认与证据。GUI 无法获知所有 shell alias 的 env，允许用户添加根，不自动执行 shell rc 或启动 agent 探测 |
| P1 | Cursor CLI 共享资源归属 | CLI 与 desktop 都消费 mcp.json / skills / worktrees；physical bytes 去重，消费关系保留，删除本体后清理明确注册，而非删另一个客户端整个根 |
| P1 | Amp 安装支持 | 新增 `AMP_HOME/bin/amp`（默认 `.amp/bin/amp`）归属和 brew `ampcode`；保留原 npm `@sourcegraph/amp` 兼容，卸载只针对识别的安装实例 |
| P1 | Amp JSONC 与其他自定义内容 | 增 settings.jsonc source；无法可靠逐项编辑时展示 raw-file 高风险删除，避免“只能看”。MCP literal dotted key 已处理，勿再引入不兼容分支 |
| P1 | 增 Cline/Roo/Continue 定义 | 先加证据充分的 user roots、旧扩展 tasks/checkpoints 与 DB；客户端/版本/layout metadata 显示，避免迁移重复计数 |
| P2 | Claude 深层与 temp 扫描 | tasks/plans/uploads/旧 images/backups/usage/feedback/trash/scratchpad，按 session 与数据类型显示；未知 temp 子树只手动添加范围 |
| P2 | Copilot/Factory 用户内容与插件 | 单独列设置、permissions、provider、specs、自定义 agents/hooks/commands；插件本体卸载编辑真实安装登记，有混合 MCP/Skill 的 manifest 时形成一次事务 |
| P2 | Git worktree/snapshot 管理 | 引用图需含注册数据库、Git worktree metadata、未提交修改和共享 Grove 用户；高风险允许手动卸载，但保证可审查回收范围并留备份 |

扫描可扩展，不应以“把所有根 children 一次遍历”代替规则。每项建议都应产出 path/layout、来源、风险、损失说明、操作者动作（清缓存/删历史/解绑/卸载本体）与关联配置；隐藏/云端副本不计入本地释放大小。对于只有文档或 issue 证明存在而没有重建证据的路径，允许清理并使用 review/高风险提示，保持用户选择权。

建议的后续 fixture：自定义配置根与默认根共存；CLI 卸载后桌面/IDE 仍消费共享资源；Claude projects 混有 memory；Copilot 重建索引仍保留 session-state；Cursor chat DB sidecars 与 `.cursor/worktrees` 同在；Amp JSONC 与官方 brew token；Cline 新旧根并存/MCP 迁移重复项；Roo customStoragePath；Continue index/globalContext 含 OAuth 与 lancedb 同目录。只用沙盒，不读真实认证内容。

## 来源索引与网页快照说明

以下源码链接固定完整 commit。官方网页均访问于 2026-10-01；它们可继续更新。取证内容 SHA256（网页正文，不是安装 binary）：Claude directory `68cc92fa7d6f0ad0feb59470efb20eb694b3f6b664823898ab1fa1acba288d67`；Claude env-vars `4071acaa854d4de336f004efae18bb66e080e94765bc38e8b31b97f9921c7de8`；Claude memory `11efbfc1af44b658151f1cfe8f2180df57391185065aea5cd1d29b3864dc606a`；Amp settings `3b16ba8f97b38cd283dc58f00e85f1a75d72c1470763df5f1ea4044398109067`；Amp skills `af9d21fbdde7dc6ffb855654e13e6393ef43219f3e5e78275d354b3ae40af3f1`；Amp installer `70f9a234fdc1aee9bf88af73c38a80435556e5dd364d204bd0ff8b6a27f23f5f`；Factory installer `230081a9acbd6e9baa7fbae28afafe085b5e0e00ed2099010a64486405c30bf8`；Cursor config `d6921fd7a44cf73c0e09063d42aeebd01695fdc1848505df515b573dbf8d579d`。未把网页可变 URL 的 SHA256 当成可永久下载的 ref。

[CC1]: https://code.claude.com/docs/en/claude-directory
[CC2]: https://code.claude.com/docs/en/env-vars
[CC3]: https://code.claude.com/docs/en/authentication
[CC4]: https://code.claude.com/docs/en/setup
[CC5]: https://code.claude.com/docs/en/memory
[CC6]: https://code.claude.com/docs/en/mcp
[CP1]: https://github.com/github/docs/blob/10844e10c034b5e5d9b62793c3af9feb4b91de07/content/copilot/reference/copilot-cli-reference/cli-config-dir-reference.md
[CP2]: https://github.com/github/copilot-cli/blob/659e4652ac910f8046dc64480bd6beda8f0ad2a6/install.sh
[CU1]: https://cursor.com/install
[CU2]: https://cursor.com/docs/cli/reference/configuration.md
[CU3]: https://cursor.com/docs/cli/using.md
[CU4]: https://cursor.com/docs/mcp.md
[CU5]: https://cursor.com/docs/skills.md
[CU6]: https://forum.cursor.com/t/cli-headless-doesnt-work-with-ls-no-way-to-get-a-list-of-chat-ids/151821
[CU7]: https://cursor.com/docs/cli/reference/authentication.md
[GR0]: https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/README.md
[GR1]: https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-dirs/src/lib.rs
[GR2]: https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-config/src/paths.rs
[GR3]: https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-pager/npm/grok/bin/grok-bootstrap.js
[GR4]: https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-shell/src/session/storage/mod.rs
[GR5]: https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-session-search/src/db.rs
[GR6]: https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-fast-worktree/src/db/mod.rs
[GR7]: https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-fast-worktree/src/data_dirs.rs
[GR8]: https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-workspace/src/session/checkpoint_store.rs
[GR9]: https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-login/src/storage.rs
[GR10]: https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-mcp/src/credentials.rs
[GR11]: https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-memory/src/storage.rs
[GR12]: https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-config/src/mcp_servers/config_toml.rs
[GR13]: https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-config/src/mcp_servers/json_config.rs
[GR14]: https://github.com/xai-org/grok-build/blob/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen/xai-grok-tools/src/implementations/skills/discovery.rs
[FD1]: https://github.com/Factory-AI/factory/blob/485a0c3b5d3d11c52d50cd2a8889e1a71e86905a/docs/cli/configuration/settings.mdx
[FD2]: https://github.com/Factory-AI/factory/blob/485a0c3b5d3d11c52d50cd2a8889e1a71e86905a/docs/cli/configuration/mcp.mdx
[FD3]: https://github.com/Factory-AI/factory/blob/485a0c3b5d3d11c52d50cd2a8889e1a71e86905a/docs/cli/configuration/skills.mdx
[FD4]: https://github.com/Factory-AI/factory/blob/485a0c3b5d3d11c52d50cd2a8889e1a71e86905a/docs/cli/configuration/plugins.mdx
[FD5]: https://github.com/Factory-AI/factory/issues/1
[FD6]: https://app.factory.ai/cli
[AM1]: https://ampcode.com/docs/markdown/cli/settings
[AM2]: https://ampcode.com/docs/markdown/customize/mcp
[AM3]: https://ampcode.com/docs/markdown/customize/skills
[AM4]: https://ampcode.com/docs/markdown/customize/global-plugins-and-skills
[AM5]: https://ampcode.com/install.sh
[AM6]: https://github.com/ampcode/homebrew-tap/blob/93b9416a8ae1ea41046b1a6e62a81b4090d7aa4a/Formula/ampcode.rb
[AM7]: https://github.com/0xSero/alleycat/issues/21
[AM8]: https://github.com/missuo/tokens/issues/64
[CL0]: https://github.com/cline/cline/blob/8eee168b80127b0c94bad849323754b5864865e7/apps/vscode/package.json
[CL1]: https://github.com/cline/cline/blob/8eee168b80127b0c94bad849323754b5864865e7/apps/vscode/src/core/storage/disk.ts
[CL2]: https://github.com/cline/cline/blob/8eee168b80127b0c94bad849323754b5864865e7/apps/vscode/src/hosts/vscode/vscode-to-file-migration.ts
[CL3]: https://github.com/cline/cline/blob/8eee168b80127b0c94bad849323754b5864865e7/apps/vscode/src/shared/storage/storage-context.ts
[CL4]: https://github.com/cline/cline/blob/8eee168b80127b0c94bad849323754b5864865e7/sdk/packages/shared/src/storage/paths.ts
[CL5]: https://github.com/cline/cline/blob/8eee168b80127b0c94bad849323754b5864865e7/sdk/packages/core/src/services/storage/sqlite-session-store.ts
[CL6]: https://github.com/cline/cline/blob/8eee168b80127b0c94bad849323754b5864865e7/sdk/packages/core/src/services/session-artifacts.ts
[CL7]: https://github.com/cline/cline/blob/8eee168b80127b0c94bad849323754b5864865e7/apps/vscode/src/sdk/SdkController.ts
[CL8]: https://github.com/cline/cline/blob/8eee168b80127b0c94bad849323754b5864865e7/sdk/packages/llms/src/providers/README.md
[CL9]: https://github.com/cline/cline/blob/8eee168b80127b0c94bad849323754b5864865e7/apps/vscode/src/core/storage/skill-directories.ts
[CL10]: https://github.com/cline/cline/blob/8eee168b80127b0c94bad849323754b5864865e7/apps/vscode/src/hosts/vscode/mcp-settings-legacy-migration.ts
[RO0]: https://github.com/RooCodeInc/Roo-Code/blob/b867ec9145750d0ae1ff7f02d35406e9bf2a0b16/src/package.json
[RO1]: https://github.com/RooCodeInc/Roo-Code/blob/b867ec9145750d0ae1ff7f02d35406e9bf2a0b16/src/utils/storage.ts
[RO2]: https://github.com/RooCodeInc/Roo-Code/blob/b867ec9145750d0ae1ff7f02d35406e9bf2a0b16/src/shared/globalFileNames.ts
[RO3]: https://github.com/RooCodeInc/Roo-Code/blob/b867ec9145750d0ae1ff7f02d35406e9bf2a0b16/src/services/checkpoints/RepoPerTaskCheckpointService.ts
[RO4]: https://github.com/RooCodeInc/Roo-Code/blob/b867ec9145750d0ae1ff7f02d35406e9bf2a0b16/src/services/checkpoints/ShadowCheckpointService.ts
[RO5]: https://github.com/RooCodeInc/Roo-Code/blob/b867ec9145750d0ae1ff7f02d35406e9bf2a0b16/src/services/mcp/McpHub.ts
[RO6]: https://github.com/RooCodeInc/Roo-Code/blob/b867ec9145750d0ae1ff7f02d35406e9bf2a0b16/src/core/config/ProviderSettingsManager.ts
[RO7]: https://github.com/RooCodeInc/Roo-Code/blob/b867ec9145750d0ae1ff7f02d35406e9bf2a0b16/src/services/roo-config/index.ts
[RO8]: https://github.com/RooCodeInc/Roo-Code/blob/b867ec9145750d0ae1ff7f02d35406e9bf2a0b16/src/services/skills/SkillsManager.ts
[CO0]: https://github.com/continuedev/continue/blob/5522c6f44ca0ac3528b37244818fbfa39b5af470/extensions/vscode/package.json
[CO1]: https://github.com/continuedev/continue/blob/5522c6f44ca0ac3528b37244818fbfa39b5af470/core/util/paths.ts
[CO2]: https://github.com/continuedev/continue/blob/5522c6f44ca0ac3528b37244818fbfa39b5af470/core/util/historyUtils.ts
[CO3]: https://github.com/continuedev/continue/blob/5522c6f44ca0ac3528b37244818fbfa39b5af470/core/util/GlobalContext.ts
[CO4]: https://github.com/continuedev/continue/blob/5522c6f44ca0ac3528b37244818fbfa39b5af470/core/context/mcp/MCPOauth.ts
[CO5]: https://github.com/continuedev/continue/blob/5522c6f44ca0ac3528b37244818fbfa39b5af470/core/config/markdown/loadMarkdownSkills.ts
[CO6]: https://github.com/continuedev/continue/blob/5522c6f44ca0ac3528b37244818fbfa39b5af470/core/context/mcp/json/loadJsonMcpConfigs.ts
[CO7]: https://github.com/continuedev/continue/blob/5522c6f44ca0ac3528b37244818fbfa39b5af470/extensions/cli/docs/storage-sync.md
