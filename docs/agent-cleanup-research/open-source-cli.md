# 开源 CLI Agent 的清理路径与生命周期

研究日期：2026-10-01。范围为 OpenCode、Gemini CLI、Kimi CLI / Kimi Code、pi、Crush。结论来自官方仓库的固定提交；只下载和读取源码，没有运行这些 Agent、安装脚本或项目代码，也没有读取、修改真实用户数据。Aider、Goose 的边界见末节。

这里的风险是删除影响，不是操作能力限制：缓存、历史、配置、授权都可以让用户主动删除；只有可证明能重新生成且不丢用户内容的数据才建议默认勾选。安装本体、共享资源本体、Agent 的配置关联必须分开建模。下文的 `home` 表示 macOS 用户目录，`data` / `cache` 等表示该工具解析后的根目录。

## 固定版本

| 工具 | 官方仓库 | 本次固定 SHA | 提交时间（UTC） |
| --- | --- | --- | --- |
| OpenCode | anomalyco/opencode，dev | [`0112a92c416f5ad833d96e7a8308441f0a875d94`](https://github.com/anomalyco/opencode/commit/0112a92c416f5ad833d96e7a8308441f0a875d94) | 2026-10-01 04:27:04 |
| Gemini CLI | google-gemini/gemini-cli，main | [`c6bccb7ecbf6d8368d995455dd725ed34466faad`](https://github.com/google-gemini/gemini-cli/commit/c6bccb7ecbf6d8368d995455dd725ed34466faad) | 2026-09-30 20:15:09 |
| Kimi CLI，旧 Python 版 | MoonshotAI/kimi-cli，main | [`9ab1286b8fe4e6bcd116949a27ce5e0ac3389c82`](https://github.com/MoonshotAI/kimi-cli/commit/9ab1286b8fe4e6bcd116949a27ce5e0ac3389c82) | 2026-09-22 09:29:17 |
| Kimi Code，新 TypeScript 版 | MoonshotAI/kimi-code，main | [`21406fb4c805cc8c715e6d1f16ad3fb5f25f4fe3`](https://github.com/MoonshotAI/kimi-code/commit/21406fb4c805cc8c715e6d1f16ad3fb5f25f4fe3) | 2026-09-30 07:23:40 |
| pi | earendil-works/pi，main；原 badlogic/pi-mono 已重定向 | [`a4715ec9bffbfcb8a32a1a4100dcfd06c12c93e4`](https://github.com/earendil-works/pi/commit/a4715ec9bffbfcb8a32a1a4100dcfd06c12c93e4) | 2026-10-01 08:43:44 |
| Crush | charmbracelet/crush | [`76cc5c574e15072b15aaed0f4f843a5711fae0d9`](https://github.com/charmbracelet/crush/commit/76cc5c574e15072b15aaed0f4f843a5711fae0d9) | 2026-10-01 00:25:14 |

同一个工具的旧版和新版可能并存。扫描不能假设当前命令入口代表所有历史数据目录仍在使用，尤其是 Kimi 的两代产品。

## OpenCode

### 路径解析

源码用 `xdg-basedir` 构造 `data`、`cache`、`config`、`state`，默认 macOS 路径是 `~/.local/share/opencode`、`~/.cache/opencode`、`~/.config/opencode`、`~/.local/state/opencode`，必须支持 `XDG_DATA_HOME` / `XDG_CACHE_HOME` / `XDG_CONFIG_HOME` / `XDG_STATE_HOME`。`tmp` 是 **`os.tmpdir()/opencode`**，不是 `data/tmp` 或 `data/temp`。`OPENCODE_TEST_HOME` 只替换该服务的 home 字段，不能当作所有 XDG 根的统一覆盖。[路径源码][oc-global]

`OPENCODE_CONFIG_DIR` 增加配置根；`OPENCODE_CONFIG` 可指向单个配置文件。还会读取 home 的 `.opencode` 与已知项目的 `.opencode`。项目发现应使用已知项目范围，不沿整个 home 找配置。[配置目录][oc-paths]

`OPENCODE_DB` 可以是绝对文件、相对 data 的文件或 `:memory:`。默认数据库为 `data/opencode.db`；非 latest/beta/prod 的 channel 可用 `opencode-<channel>.db`。数据库启用 WAL，清理需同组处理主库、`-wal`、`-shm`、`-journal`，并在退出运行进程后重新检查文件身份与占用。[数据库源码][oc-db]

### 数据与删除影响

| 路径 / 对象 | 分类与生命周期 | 删除影响 / 建议风险 |
| --- | --- | --- |
| `cache/`，含下载包、工具、模型目录、远端 skill 缓存 | 官方缓存根。下载依赖可重建；远端 skill 由版本文件判断更新 | 低风险；下次重新下载，断网时暂时缺资源。不能因此把用户自建 skill 目录也当缓存 |
| `data/log/` | 诊断日志；当前 logger 默认写 `opencode.log` | 低风险；失去诊断记录，需停止正在写日志的 Agent。[日志][oc-log] |
| `data/tool-output/` | 超过工具输出限额的完整结果；源码保留 7 天，延迟 1 分钟启动、每小时清理旧 `tool_*` | 中风险；历史会话中的全文路径会失效，当前任务可能还要读它。可优先选择超过官方保留期的文件。[输出生命周期][oc-truncate] |
| `data/snapshot/<project>/<worktree-hash>/` | Git 对象形式的文件变更快照，供恢复 / 撤回使用 | 中风险；清掉后丢恢复能力，不能命名为普通下载缓存。[快照][oc-snapshot] |
| `data/opencode*.db` 及 SQLite 伴随文件 | 会话、消息、项目等结构化数据；本次源码新增 / 已包含 `credential` 表 | **高风险**；丢历史且可能丢 API key / OAuth 凭据，不能仅标“会话数据库”。[凭据表][oc-credential-sql] [凭据 CRUD][oc-credential] |
| `data/storage/` | 旧存储目录，兼容读取 / 迁移；不会因为有新数据库就自动证明旧目录无用 | 中风险；用户主动清旧历史。应识别版本与迁移状态后再提供“已迁移残留”解释。[旧存储][oc-storage] |
| `data/plans/` | 全局计划文件；Git 项目可能改用项目 `.opencode/plans` | 中风险；用户计划丢失，属于生成内容而不是缓存。[计划路径][oc-plans] |
| `data/repos/` | 管理的参考仓库 checkout 缓存 | 中风险；可以重新 clone，但目录内可能被用户改过，删除前需要提示。不要等同用户原项目。[参考仓库][oc-repos] |
| `state/` | 最近模型、插件元信息、界面状态等，例如 `model.json`、`plugin-meta.json` | 中风险；丢偏好和插件状态，整体重置可手动选择；比按名字视为 safe 更稳妥 |
| `data/auth.json`、`data/mcp-auth.json` | Provider / MCP 授权 | 高风险；下次重新登录，删除授权文件不会删除 MCP 程序或远端服务。[provider 授权][oc-auth] [MCP 授权][oc-mcp-auth] |
| `config/opencode.json`、`.jsonc` 及配置根 | 配置、MCP 注册、权限、资源声明，可能含凭据 | 高风险；重置配置，并可能使插件 / MCP 不再可用。按注册条目编辑优于整文件删除 |
| `os.tmpdir()/opencode` | 官方运行时临时目录 | 可再生内容低风险；仅精确路径、停止 Agent 后操作；系统 temp 根本身不能递归删除 |

### Skill / MCP 关联

Skill 会扫描 `{skill,skills}/**/SKILL.md`，不仅是复数 `skills`；还扫描 `~/.agents/skills`、`~/.claude/skills`、项目目录和配置 `skills.paths`，支持符号链接。`skills.urls` 会生成缓存。[Skill 发现][oc-skills]

删除本体时需移除已知 symlink 与匹配的 `skills.paths`；只删 `skills.paths` / symlink 是解除该 Agent 的关联。直接共享目录自动发现的 skill，没有单独“注册文件”，应在共享资源页标明消费者。下载 skill 缓存保留 URL 配置后会重新下载，因此“清缓存”与“卸载 skill”语义不同。

MCP 是 `opencode.json(c)` 的 `mcp` 映射。条目可以是远端 URL，或执行本地 command；这不是“所有 MCP 全局安装”的证据。删除远端条目仅解除连接，不能删除远端服务。删除本地已确认包本体才需要把各 Agent 中相同本体的注册都移除。[MCP schema][oc-mcp-schema]

### 对 AgentCatalog 的纠正

- 现有 `.db` 前缀 / SQLite 族扫描方向正确，但应把数据库从 review 提到高风险并写明包含凭据；`OPENCODE_DB` 自定义文件名不能只靠 `opencode*` 匹配。
- 当前 `data/tmp`、`data/temp` 没有本次官方源码依据；应删掉这两项“官方 safe”规则，真正临时路径在系统 temp。
- 遗漏 `plans`、`repos`、`mcp-auth.json`；Skill 遗漏 `skill` 单数目录、自动发现共享目录、`skills.paths` 与 URL 缓存关联。
- 不应通过删整个 `.opencode` 完成 CLI 卸载：其中既可有 `bin/opencode`，也可有用户配置 / skill。

## Gemini CLI

### 路径解析

`GEMINI_CLI_HOME` 替代 **父 home**，然后工具再拼 `.gemini`；设置为 `/a` 的结果是 `/a/.gemini`，不是 `/a`。它不使用 XDG 根作为普通数据根。[home 语义][gm-home]

普通运行时与全局配置共用 `<home>/.gemini`。当 `SANDBOX=sandbox-exec`，macOS Seatbelt 运行时切到 **`<home>/.cache/.gemini`**，而配置、provider OAuth 文件仍在 `<home>/.gemini`。因此不能只扫描 `.gemini/tmp`。[运行时根][gm-storage]

`GEMINI_CLI_TRUSTED_FOLDERS_PATH`、`GEMINI_CLI_SYSTEM_SETTINGS_PATH` 可覆盖单文件；macOS 系统配置默认 `/Library/Application Support/GeminiCli/settings.json`。这类系统 / 外部路径应明确列为扫描边界，不伪装成 home 内数据。

### 数据与删除影响

| 路径 / 对象 | 分类 | 删除影响 / 建议风险 |
| --- | --- | --- |
| `<runtime>/tmp/<project-id>/chats/*.json(l)` | 持久会话 | 中风险；不能因上层叫 tmp 就归为安全垃圾。会话 JSON 与 JSONL 可并存 |
| `<runtime>/tmp/<project-id>/<session>/`，`checkpoints`、`memory`、`plans`、`tracker`、`tasks`、`shell_history`、`logs` | 会话关联产物、检查点、记忆、计划、输入历史、诊断 | 会话 / 记忆 / 计划中风险；纯诊断日志低风险；清会话应连同对应 artifact / subagent 清，不能把整个 project 当单一缓存。[目录构造][gm-directories] |
| `<runtime>/history/<project-id>/` | 历史 / checkpoint 存储 | 中风险；现有规则未覆盖。[history][gm-history] |
| `<runtime>/projects.json` | project-id 注册表，包含项目关联 | 中风险；删索引可能改变数据定位，需连同相关目录管理；旧 hash 会迁移成短 ID |
| `<runtime>/tmp/bin/` | 管理的辅助工具 | 可再生；低风险但下次下载，当前进程不可删 |
| `<home>/.gemini/oauth_creds.json`、`<runtime>/google_accounts.json` | 旧 / 普通授权与账号状态 | 高风险；重新登录 / 丢账号选择，不等于完全登出所有安全存储 |
| `<runtime>/mcp-oauth-tokens.json`、`a2a-oauth-tokens.json` | MCP / A2A 授权 | 高风险；重新授权，不能与服务本体合并删除 |
| `<home>/.gemini/gemini-credentials.json` 或 macOS Keychain | 安全授权存储；`GEMINI_FORCE_FILE_STORAGE=true` 强制加密文件后端 | 高风险；仅删 `oauth_creds.json` 不能声称删除所有凭据。[后端选择][gm-keychain] [加密文件][gm-file-keychain] |
| `<home>/.gemini/settings.json`、commands、policies、agents、keybindings、可信目录与权限完整性状态 | 用户配置 / 扩展内容 / 信任状态 | 高风险；重置行为、权限或用户自建指令，不默认选 |
| `<home>/.gemini/extensions/<name>/` | 扩展资源本体 / link 元数据，扩展可附带 MCP / skill | 中或高风险；按官方 extension 安装元数据判断本体，link 安装不能删外部源目录。[扩展路径][gm-extensions] [官方卸载][gm-extension-remove] |

官方在 CLI 启动时按 `general.sessionRetention` 做清理。未启用时直接退出；有启用时支持 maxAge / maxCount / minRetention，并跳过当前 session，连带清理 session 的 artifact 与 subagent。默认最短保护期常量为 `1d`。这证明应有按会话年龄与关联对象的规则，不能只有“整项目 tmp 可删”。[会话清理源码][gm-cleanup]

### Skill / MCP 与目录纠正

用户与项目 `.gemini/skills` 及 `.agents/skills` 都是正式 skill 源；自动发现共享目录必须登记消费者。MCP 普通注册位于用户 / 项目 `settings.json` 的 `mcpServers`，也可由 extension 提供。因此卸载 extension 后要让它附带的 MCP / skill 消失；编辑 settings 注册不会卸载 npm/本地程序。

现有 `.gemini/tmp` review 方向正确，但范围过粗；遗漏沙盒 runtime、history、授权新后端、账号状态在沙盒内的路径、扩展、共享 skill。Gemini 与 Antigravity 共用 `.gemini` 命名空间；卸载 Gemini 后不能整体把 `.gemini` 当独占残留，必须只取 Gemini 明确叶子。

## Kimi：旧 CLI 与新 Kimi Code

### 版本边界

旧 Python Kimi CLI 在 2026-09-22 归档，1.52.0 是最终版本。本次 HEAD 的无参数 `kimi` 入口直接运行迁移安装器；原 CLI dispatch 仅作参考保留。**不得为确认安装存在性执行 `kimi`**。[入口证据][km-entry]

新版 Kimi Code 默认数据根 `~/.kimi-code`，`KIMI_CODE_HOME` **直接替代数据根**；旧版 `KIMI_SHARE_DIR` 也直接替代 `~/.kimi`，与 Gemini 的父 home override 不同。两代工具同时有 `kimi` 命令，所以仅凭命令名无法证明旧 `.kimi` 仍被使用。[旧根][km-share] [新根][kc-paths]

### 旧 Python CLI 数据

| 路径（相对于 share 根，除注明者） | 分类与删除影响 |
| --- | --- |
| `sessions/<workdir-hash>/<session-id>/`，包括 `context.jsonl`、`wire.jsonl`、state、subagents | 会话历史，中风险；原程序删除一个 session 会删其整个目录。不要只清 context 文件而留下索引、state 或子代理。[会话][km-session] |
| `kimi.json` | 工作目录元数据、last_session 等索引；中风险，与 session 删除同步处理。[元数据][km-metadata] |
| `user-history/` | 用户输入历史，中风险 |
| **`~/.kimi/plans`** | 计划内容，中风险；旧版这一路径硬编码 `Path.home()`，不随 `KIMI_SHARE_DIR` 迁移。[计划][km-plans] |
| `logs/kimi.log` 与轮转文件 | 诊断日志，低风险；每天 06:00 轮转、保留 10 天。[日志][km-log] |
| `prompt-cache/`、旧 `/tmp/kimi` | 粘贴文本 / 图片 placeholder；建议中风险，因为恢复输入历史会引用这些文件，不是模型远端 prompt cache。[粘贴缓存][km-paste] |
| `telemetry/failed_*.jsonl` | 失败遥测队列，可再生低风险；删除只是丢待重试遥测。[遥测][km-telemetry] |
| `bin/` | 管理的 rg 等工具，可重新下载，低风险；不是 Kimi 安装包本体 |
| `credentials/*.json`、`mcp-oauth/`，旧 Keyring 路径 | provider / MCP 授权，高风险；源码仍兼容旧 Keyring、现在优先 file storage。[provider 授权][km-auth] [MCP 授权][km-mcp-auth] |
| `config.toml` / 旧 `config.json`、`mcp.json`、plugins | 配置、API key、注册 / 插件资源，高风险或中风险按本体区分 |
| `latest_version.txt`、`kimi_code_tips.json`、`skipped_version.txt` | 更新 / 迁移提示状态，可以重建；是否清 skipped 状态影响用户选择，宜手动选 |

Skill 的根还有 `~/.config/agents/skills`、`~/.agents/skills`、`~/.claude/skills`、`~/.codex/skills`、项目版本与 extra_skill_dirs / --skills-dir。部分目录采用优先级 fallback，而非把所有候选同时装载；扫描消费者时需按版本语义区分候选与实际生效源。[Skill 来源][km-skills]

### 新 Kimi Code 数据

| 数据根内路径 | 分类与删除影响 |
| --- | --- |
| `cache/` | 可再生 CLI 缓存，低风险；原生资源清理也有专门实现，不能把整个安装 `bin` 当缓存 |
| `logs/` | 诊断日志，低风险；全局和 session 日志可能分别存放 |
| `sessions/`、`blobs/`、`store/` | 持久会话、附件、索引 / 数据存储，中风险；blobs 可能被会话引用，不应独立默认清空。[bootstrap scope][kc-bootstrap] |
| `user-history/`、`session_index.jsonl` | 输入历史与会话索引，中风险；官方删除写索引 tombstone，应避免只删文件留下旧索引。[索引生命周期][kc-session-delete] |
| session 的 `agents/<agent-id>/plans/` | 用户生成计划，中风险，随关联 session 管理 |
| `credentials/`、`server.token` | provider 授权与本地 Web 服务 bearer token，高风险；停止服务后清理，重新登录 / 客户端重新配对。[credentials][kc-credentials] [server token][kc-server-token] |
| `config.toml`、`tui.toml`、`mcp.json`、`skills/`、plugins | 配置 / 注册 / 资源本体；手动管理，不能自动算垃圾 |
| `updates/latest.json` / `rollout.log` 等 | 更新缓存 / 日志低风险；`install.lock` 和正在安装的状态必须复核活动任务。[更新路径][kc-paths] |
| `migration-report.json` / `migration-errors.log` / `.migrated-to-kimi-code` 等 | 迁移报告与标记；不能单凭目录存在推断迁移成功，可人工看结果后清旧数据。[迁移路径][kc-migration-paths] |

新版 MCP 注册有 `<KIMI_CODE_HOME>/mcp.json`、项目根 `.mcp.json` 与当前工作目录 `.kimi-code/mcp.json`，key 为 `mcpServers`，还可由 plugin 提供。删除本体必须同时考虑插件 manifest 的注册来源。[新版 MCP][kc-mcp]

对现有 Catalog：补 credentials、mcp-oauth、prompt-cache、telemetry、配置；把日志改低风险；新增 `.kimi-code` 产品数据。旧 `.kimi` 不应因新版 `kimi` 已安装就一直留在 Agent Tab。保留“旧版数据 / 已迁移数据”状态，按已确认迁移与安装来源判定残留；不能自动清空未迁移会话。

## pi

### 路径与生命周期

官方仓库已从 `badlogic/pi-mono` 迁到 `earendil-works/pi`，CLI 包为 `@earendil-works/pi-coding-agent`。旧 npm package / binary 可与新版并存，卸载时按实际 package ownership 而非只硬编码旧包名。[官方安装][pi-install]

`PI_CODING_AGENT_DIR` 直接替代默认 `~/.pi/agent`。session 根另支持 `--session-dir`、`PI_CODING_AGENT_SESSION_DIR` 和 `settings.sessionDir`，CLI 优先最高。没有 evidence 表明通用 XDG 会替代默认根。[根目录][pi-config] [会话目录][pi-sessions]

| 对象 | 分类与删除影响 |
| --- | --- |
| `agent/sessions/<encoded-cwd>/*.jsonl` | 持久会话，中风险；每个文件是 append-only tree，compaction 增加 summary 而不会删原记录，所以“上下文压缩后旧文件无用”不成立。[session 文件][pi-session-code] |
| `agent/pi-debug.log` | 诊断日志，低风险；interactive 模式直接用 `getDebugLogPath()` 写到 agent 根，不是 cwd。[写入点][pi-log-write] |
| `agent/tmp/extensions` | extension 的临时 checkout，低风险但需停止正在加载 / 更新的 Agent。[临时包路径][pi-package-tmp] |
| `agent/bin` | 下载的 fd / rg 工具，可再生低风险；不等于 pi 安装本体 |
| `agent/npm`、`agent/git` | npm / Git Pi package 本体，中风险；这些 package 可同时提供 extensions、skills、prompts、themes。删除本体需从 settings 的 `packages` 移除对应来源，否则会重新安装。[包路径][pi-package-paths] [包删除][pi-package-delete] |
| `agent/auth.json`、`agent/mcp-auth.json` | provider / MCP 授权，高风险；MCP 授权按 server URL 保存，含 client registration 和 token。[provider 文件][pi-auth] [MCP 文件][pi-mcp-auth] |
| `agent/settings.json`、`models.json`、themes、tools、prompts、extensions | 用户配置 / 资源，高风险或中风险按内容；自定义 model 配置也可能含 API key |
| `agent/skills`、`~/.agents/skills`、项目 `.pi/skills` / `.agents/skills`、settings `skills` 列表 / package 声明 | skill 来源；本体与路径声明分开，自动发现共享目录要标消费者。[Skill 来源][pi-skills] |

最新版 pi 已内置 MCP：用户 `agent/mcp.json`、项目 `.pi/mcp.json`，JSON `mcpServers` 映射。扩展也能动态注册 MCP；有旧 pi-mcp-adapter 的版本 / 配置会替换内置 MCP 行为。不能统一声称 pi 无 MCP；也不能把扩展动态声明当作同一静态配置文件。[MCP 文档][pi-mcp] [配置源码][pi-mcp-config]

当前 Catalog 只扫 sessions、skills 且 `mcpSources=[]`：遗漏授权、配置、包本体、临时 checkout、debug log、新 MCP 与自定义 session 根。需要明确“清包”和“解除 package 声明”的差别；local package 的官方 remove 只移声明，不删外部项目本体。

## Crush

### 全局与项目数据不能混淆

macOS / Unix 默认全局配置为 `~/.config/crush/crush.json`，也支持 `crushrc`。`XDG_CONFIG_HOME` 影响配置根；`CRUSH_GLOBAL_CONFIG` **是目录**，再拼 `crush.json`。

全局状态为 `~/.local/share/crush/crush.json`。`XDG_DATA_HOME` 的值再拼 `crush/crush.json`，`CRUSH_GLOBAL_DATA` **是目录**，直接拼 `crush.json`。缓存为 `~/.cache/crush`；`XDG_CACHE_HOME` 再拼 `crush`，`CRUSH_CACHE_DIR` 直接替代缓存根。[路径源码][cr-roots] [macOS / Unix 官方说明][cr-readme]

主要会话数据 **默认在项目 `.crush`**，不是全局根。`--data-dir` / config `options.data_directory` 可改目录，源码解析成绝对路径；向上查找被 Git worktree root 限制，避免拿到无关父目录 `.crush`。[data_dir 默认][cr-default] [data_dir 语义][cr-option]

| 对象 | 分类与删除影响 |
| --- | --- |
| `<data_dir>/crush.db` 及 SQLite 伴随文件 | 会话、消息、文件变更记录，中风险；需要关闭 Agent / server 与打开文件检查，不能独立删 WAL。[数据库][cr-db] |
| `<data_dir>/logs/crush.log` 与轮转 | 诊断日志，低风险；lumberjack 10 MiB 轮转、30 天保留。[日志][cr-log] |
| `<data_dir>/crush.json` | workspace 状态 / 配置覆盖，可能有授权，高风险 |
| 全局 `crush.json` / `crushrc` | 用户配置、MCP 注册 / token、provider API key / OAuth，高风险；`crushrc` 是可信可执行代码，本次研究没有执行它。[OAuth 写入][cr-oauth] |
| 全局 `providers.json` 等 provider catalog | 可刷新数据低风险；只能精确叶子，不把整个全局状态根都当 cache。[provider cache][cr-provider] |
| `<cache>/server-*/` | server-client 缓存日志、启动锁等，需停止 server 后清日志 / 已证明失效锁，不能把活锁直接清掉 |
| 全局 / 项目 skills | 配置品牌目录、`agents/skills`、`~/.agents/skills`、`~/.claude/skills`；项目还读取 `.cursor/skills`。`CRUSH_SKILLS_DIR` 直接替代全局候选目录。[Skill 来源][cr-skills] |

项目 registry 位于 **`dirname(GlobalConfigData())/projects.json`**，默认 `~/.local/share/crush/projects.json`，结构为：

```json
{"projects":[{"path":"/Users/name/project","data_dir":"/Users/name/project/.crush","last_accessed":"…"}]}
```

这是登记过的真实 `data_dir`，可以作为深入扫描的受控入口。[registry 定义与写入][cr-projects]

扫描建议：只读已注册 `data_dir`；要求 home 内、每级非 symlink、合理专用目录，排除 home / Library / .config / 项目根等宽泛根；只产出精确 `crush.db` 族和日志叶子。不能对任意 `data_dir` 做整目录删除，不能沿 `path` 扫全盘找项目，也不能猜全局一定有 DB。registry 不存在时提示“未发现可验证项目数据”，保留全局精确叶子能力。

MCP 静态 JSON key 为 `mcp`，还有新 `crushrc` 配置方式。删除 JSON 注册后源码会清孤立 OAuth token 项；仅处理 `.config/crush/crush.json` 会漏全局状态覆盖 / project config / crushrc。[孤立 token][cr-orphan-token]

现有 Crush 将 `.config/crush` 与 `.local/share/crush` 作为 undocumented 整根处理：应改为上述精确类型，补 cache 与 registry 指向的项目数据；不要把这些目录当成唯一会话来源。

## 跨工具的清理与残留策略

1. 安装存在性只依据真实 app bundle、可执行普通文件 / 已知 package 所有权，数据目录存在不代表安装存在；不得执行 CLI 以探测，Kimi 入口就是反例。
2. 缓存清理、删除历史、重置配置、删除凭据、解除 skill/MCP 关联、卸载本体是不同动作，UI 需要给出明确后果。高风险仍可操作，但不默认勾选。
3. MCP 注册可能启动本地绝对文件、PATH 命令、npx/uvx 临时包，或连接远端 URL。没有通用“全局 MCP 安装目录”。共享本体删除时移除能确定指向该本体的注册；不能只按服务名字匹配并删同名远端资源。
4. 删除 skill 的 symlink 是解除关联，删除 symlink 目标是删除共享本体。删除本体要清已知 link / 配置声明，并展示所有已知消费者；卸载某个 Agent 后不能把仍被别的 Agent 使用的共享 skill 本体当残留。
5. SQLite 要合组，活动进程、文件身份、主库与 sidecar 在执行边界再复核。DB 属于历史还是授权要靠 schema；不能仅根据扩展名标低风险。
6. 卸载 CLI 后的数据进入清理 Tab 的残留分类；默认不选历史 / 配置 / 授权。产品迁移需保留旧版数据说明，不能因新版同名入口存在就把旧产品仍当安装着。
7. 所有 env override 必须按该工具实际语义解析。当前 Nori 若只支持 home 内物理路径，应明确报告范围外路径而不是声称已经全盘清完。系统 temp 路径是另一受控范围，不与任意 env 路径混用。

## Aider / Goose 边界

本次没有固定并逐文件审核 Aider、Goose 的官方源码，不能把它们现有 Catalog 根标记为“已验证安全”。仅可保留已知根的高风险手动删除 / 残留能力，报告“结构与恢复影响未核实”。后续应分别审核官方 aider-ai/aider、block/goose 的版本、平台路径、env override、项目内状态、历史 / 授权 / extension 生命周期，再升格 documented；不应照搬上面其他 CLI 的 XDG 或 SQLite 分类。

## 证据链接

[oc-global]: https://github.com/anomalyco/opencode/blob/0112a92c416f5ad833d96e7a8308441f0a875d94/packages/core/src/global.ts#L10-L28
[oc-paths]: https://github.com/anomalyco/opencode/blob/0112a92c416f5ad833d96e7a8308441f0a875d94/packages/opencode/src/config/paths.ts#L23-L44
[oc-db]: https://github.com/anomalyco/opencode/blob/0112a92c416f5ad833d96e7a8308441f0a875d94/packages/core/src/database/database.ts#L24-L54
[oc-log]: https://github.com/anomalyco/opencode/blob/0112a92c416f5ad833d96e7a8308441f0a875d94/packages/core/src/observability/logging.ts#L49
[oc-truncate]: https://github.com/anomalyco/opencode/blob/0112a92c416f5ad833d96e7a8308441f0a875d94/packages/opencode/src/tool/truncate.ts#L12-L17
[oc-snapshot]: https://github.com/anomalyco/opencode/blob/0112a92c416f5ad833d96e7a8308441f0a875d94/packages/opencode/src/snapshot/index.ts#L71
[oc-credential-sql]: https://github.com/anomalyco/opencode/blob/0112a92c416f5ad833d96e7a8308441f0a875d94/packages/core/src/credential/sql.ts#L5-L14
[oc-credential]: https://github.com/anomalyco/opencode/blob/0112a92c416f5ad833d96e7a8308441f0a875d94/packages/core/src/credential.ts#L65-L138
[oc-storage]: https://github.com/anomalyco/opencode/blob/0112a92c416f5ad833d96e7a8308441f0a875d94/packages/opencode/src/storage/storage.ts#L224
[oc-plans]: https://github.com/anomalyco/opencode/blob/0112a92c416f5ad833d96e7a8308441f0a875d94/packages/opencode/src/session/session.ts#L329-L335
[oc-repos]: https://github.com/anomalyco/opencode/blob/0112a92c416f5ad833d96e7a8308441f0a875d94/packages/core/src/repository-cache.ts#L144-L216
[oc-auth]: https://github.com/anomalyco/opencode/blob/0112a92c416f5ad833d96e7a8308441f0a875d94/packages/opencode/src/auth/index.ts#L10
[oc-mcp-auth]: https://github.com/anomalyco/opencode/blob/0112a92c416f5ad833d96e7a8308441f0a875d94/packages/opencode/src/mcp/auth.ts#L37
[oc-skills]: https://github.com/anomalyco/opencode/blob/0112a92c416f5ad833d96e7a8308441f0a875d94/packages/opencode/src/skill/index.ts#L149-L224
[oc-mcp-schema]: https://github.com/anomalyco/opencode/blob/0112a92c416f5ad833d96e7a8308441f0a875d94/packages/core/src/config/mcp.ts
[gm-home]: https://github.com/google-gemini/gemini-cli/blob/c6bccb7ecbf6d8368d995455dd725ed34466faad/packages/core/src/utils/paths.ts#L18-L27
[gm-storage]: https://github.com/google-gemini/gemini-cli/blob/c6bccb7ecbf6d8368d995455dd725ed34466faad/packages/core/src/config/storage.ts#L54-L108
[gm-directories]: https://github.com/google-gemini/gemini-cli/blob/c6bccb7ecbf6d8368d995455dd725ed34466faad/packages/core/src/config/storage.ts#L332-L481
[gm-history]: https://github.com/google-gemini/gemini-cli/blob/c6bccb7ecbf6d8368d995455dd725ed34466faad/packages/core/src/config/storage.ts#L289-L329
[gm-keychain]: https://github.com/google-gemini/gemini-cli/blob/c6bccb7ecbf6d8368d995455dd725ed34466faad/packages/core/src/services/keychainService.ts#L112-L135
[gm-file-keychain]: https://github.com/google-gemini/gemini-cli/blob/c6bccb7ecbf6d8368d995455dd725ed34466faad/packages/core/src/services/fileKeychain.ts#L19-L21
[gm-extensions]: https://github.com/google-gemini/gemini-cli/blob/c6bccb7ecbf6d8368d995455dd725ed34466faad/packages/cli/src/config/extensions/storage.ts#L23-L43
[gm-extension-remove]: https://github.com/google-gemini/gemini-cli/blob/c6bccb7ecbf6d8368d995455dd725ed34466faad/packages/cli/src/config/extension-manager.ts#L548-L572
[gm-cleanup]: https://github.com/google-gemini/gemini-cli/blob/c6bccb7ecbf6d8368d995455dd725ed34466faad/packages/cli/src/utils/sessionCleanup.ts#L86-L224
[km-entry]: https://github.com/MoonshotAI/kimi-cli/blob/9ab1286b8fe4e6bcd116949a27ce5e0ac3389c82/src/kimi_cli/__main__.py#L28-L52
[km-share]: https://github.com/MoonshotAI/kimi-cli/blob/9ab1286b8fe4e6bcd116949a27ce5e0ac3389c82/src/kimi_cli/share.py#L7-L14
[km-session]: https://github.com/MoonshotAI/kimi-cli/blob/9ab1286b8fe4e6bcd116949a27ce5e0ac3389c82/src/kimi_cli/session.py#L99-L175
[km-metadata]: https://github.com/MoonshotAI/kimi-cli/blob/9ab1286b8fe4e6bcd116949a27ce5e0ac3389c82/src/kimi_cli/metadata.py#L18-L38
[km-plans]: https://github.com/MoonshotAI/kimi-cli/blob/9ab1286b8fe4e6bcd116949a27ce5e0ac3389c82/src/kimi_cli/tools/plan/heroes.py#L8
[km-log]: https://github.com/MoonshotAI/kimi-cli/blob/9ab1286b8fe4e6bcd116949a27ce5e0ac3389c82/src/kimi_cli/app.py#L61-L71
[km-paste]: https://github.com/MoonshotAI/kimi-cli/blob/9ab1286b8fe4e6bcd116949a27ce5e0ac3389c82/src/kimi_cli/ui/shell/placeholders.py#L23-L24
[km-telemetry]: https://github.com/MoonshotAI/kimi-cli/blob/9ab1286b8fe4e6bcd116949a27ce5e0ac3389c82/src/kimi_cli/telemetry/transport.py#L253-L272
[km-auth]: https://github.com/MoonshotAI/kimi-cli/blob/9ab1286b8fe4e6bcd116949a27ce5e0ac3389c82/src/kimi_cli/auth/oauth.py#L264-L277
[km-mcp-auth]: https://github.com/MoonshotAI/kimi-cli/blob/9ab1286b8fe4e6bcd116949a27ce5e0ac3389c82/src/kimi_cli/mcp_oauth.py#L15
[km-skills]: https://github.com/MoonshotAI/kimi-cli/blob/9ab1286b8fe4e6bcd116949a27ce5e0ac3389c82/src/kimi_cli/skill/__init__.py#L55-L98
[kc-paths]: https://github.com/MoonshotAI/kimi-code/blob/21406fb4c805cc8c715e6d1f16ad3fb5f25f4fe3/apps/kimi-code/src/utils/paths.ts#L33-L92
[kc-bootstrap]: https://github.com/MoonshotAI/kimi-code/blob/21406fb4c805cc8c715e6d1f16ad3fb5f25f4fe3/packages/agent-core-v2/src/app/bootstrap/bootstrapService.ts#L45-L59
[kc-session-delete]: https://github.com/MoonshotAI/kimi-code/blob/21406fb4c805cc8c715e6d1f16ad3fb5f25f4fe3/packages/agent-core-v2/src/workspace/sessionLifecycle/sessionLifecycleService.ts#L478
[kc-credentials]: https://github.com/MoonshotAI/kimi-code/blob/21406fb4c805cc8c715e6d1f16ad3fb5f25f4fe3/packages/oauth/src/toolkit.ts#L126
[kc-server-token]: https://github.com/MoonshotAI/kimi-code/blob/21406fb4c805cc8c715e6d1f16ad3fb5f25f4fe3/apps/kimi-code/src/cli/sub/web/shared.ts#L131-L141
[kc-migration-paths]: https://github.com/MoonshotAI/kimi-code/blob/21406fb4c805cc8c715e6d1f16ad3fb5f25f4fe3/packages/migration-legacy/src/paths.ts#L3-L34
[kc-mcp]: https://github.com/MoonshotAI/kimi-code/blob/21406fb4c805cc8c715e6d1f16ad3fb5f25f4fe3/packages/agent-core-v2/src/app/mcpConfig/configLoader.ts#L28-L30
[pi-install]: https://github.com/earendil-works/pi/blob/a4715ec9bffbfcb8a32a1a4100dcfd06c12c93e4/packages/coding-agent/README.md#L24-L27
[pi-config]: https://github.com/earendil-works/pi/blob/a4715ec9bffbfcb8a32a1a4100dcfd06c12c93e4/packages/coding-agent/src/config.ts#L535-L613
[pi-sessions]: https://github.com/earendil-works/pi/blob/a4715ec9bffbfcb8a32a1a4100dcfd06c12c93e4/packages/coding-agent/docs/sessions.md#L40-L50
[pi-session-code]: https://github.com/earendil-works/pi/blob/a4715ec9bffbfcb8a32a1a4100dcfd06c12c93e4/packages/coding-agent/src/core/session-manager.ts#L585-L608
[pi-package-tmp]: https://github.com/earendil-works/pi/blob/a4715ec9bffbfcb8a32a1a4100dcfd06c12c93e4/packages/coding-agent/src/core/package-manager.ts#L232
[pi-package-paths]: https://github.com/earendil-works/pi/blob/a4715ec9bffbfcb8a32a1a4100dcfd06c12c93e4/packages/coding-agent/src/core/package-manager.ts#L2093-L2174
[pi-package-delete]: https://github.com/earendil-works/pi/blob/a4715ec9bffbfcb8a32a1a4100dcfd06c12c93e4/packages/coding-agent/src/core/package-manager.ts#L1065-L1086
[pi-auth]: https://github.com/earendil-works/pi/blob/a4715ec9bffbfcb8a32a1a4100dcfd06c12c93e4/packages/coding-agent/src/core/auth-storage.ts#L49-L65
[pi-log-write]: https://github.com/earendil-works/pi/blob/a4715ec9bffbfcb8a32a1a4100dcfd06c12c93e4/packages/coding-agent/src/modes/interactive/interactive-mode.ts#L6746-L6765
[pi-mcp-auth]: https://github.com/earendil-works/pi/blob/a4715ec9bffbfcb8a32a1a4100dcfd06c12c93e4/packages/coding-agent/src/extensions/mcp/oauth.ts#L116-L124
[pi-skills]: https://github.com/earendil-works/pi/blob/a4715ec9bffbfcb8a32a1a4100dcfd06c12c93e4/packages/coding-agent/docs/skills.md#L59-L63
[pi-mcp]: https://github.com/earendil-works/pi/blob/a4715ec9bffbfcb8a32a1a4100dcfd06c12c93e4/packages/coding-agent/docs/mcp.md#L32-L38
[pi-mcp-config]: https://github.com/earendil-works/pi/blob/a4715ec9bffbfcb8a32a1a4100dcfd06c12c93e4/packages/coding-agent/src/extensions/mcp/config.ts#L116-L118
[cr-roots]: https://github.com/charmbracelet/crush/blob/76cc5c574e15072b15aaed0f4f843a5711fae0d9/internal/config/load.go#L1209-L1276
[cr-readme]: https://github.com/charmbracelet/crush/blob/76cc5c574e15072b15aaed0f4f843a5711fae0d9/README.md#L285-L319
[cr-default]: https://github.com/charmbracelet/crush/blob/76cc5c574e15072b15aaed0f4f843a5711fae0d9/internal/config/load.go#L585-L594
[cr-option]: https://github.com/charmbracelet/crush/blob/76cc5c574e15072b15aaed0f4f843a5711fae0d9/internal/config/config.go#L461-L465
[cr-db]: https://github.com/charmbracelet/crush/blob/76cc5c574e15072b15aaed0f4f843a5711fae0d9/internal/db/connect.go#L83-L129
[cr-log]: https://github.com/charmbracelet/crush/blob/76cc5c574e15072b15aaed0f4f843a5711fae0d9/internal/log/log.go#L23-L30
[cr-oauth]: https://github.com/charmbracelet/crush/blob/76cc5c574e15072b15aaed0f4f843a5711fae0d9/internal/config/store.go#L855-L862
[cr-provider]: https://github.com/charmbracelet/crush/blob/76cc5c574e15072b15aaed0f4f843a5711fae0d9/internal/config/provider.go#L37
[cr-skills]: https://github.com/charmbracelet/crush/blob/76cc5c574e15072b15aaed0f4f843a5711fae0d9/internal/config/load.go#L1363-L1399
[cr-projects]: https://github.com/charmbracelet/crush/blob/76cc5c574e15072b15aaed0f4f843a5711fae0d9/internal/projects/projects.go#L14-L102
[cr-orphan-token]: https://github.com/charmbracelet/crush/blob/76cc5c574e15072b15aaed0f4f843a5711fae0d9/internal/config/load.go#L604-L612
