# Aider / Goose 补充源码研究

核对日期：2026-10-01。本次仅下载、读取公开固定版本源码；不运行外部代码、不修改真实用户数据。A 表示固定实现证据，B 表示版本化观察，C 表示未证明的候选。下文所有路径均有源码证据，未核对的范围另述；“可再生”仍要求所属进程退出后清理。

本次不新增产品支持。核对时 Nori 的 `AgentCatalog` / `AgentCLIService` 没有 Aider 或 Goose 专属定义；本研究不能视为已完成检测、缓存扫描、MCP/Skill 关联编辑或卸载支持。

## Aider

固定提交：[Aider-AI/aider@5dc9490bb35f9729ef2c95d00a19ccd30c26339c](https://github.com/Aider-AI/aider/commit/5dc9490bb35f9729ef2c95d00a19ccd30c26339c)。Aider 数据多数在项目根/CWD，不存在可代表全部数据的唯一 macOS App Support 根。

| 精确路径/规则 | 生命周期与删除影响 | 固定源码 |
| --- | --- | --- |
| `<repo-root>/.aider.tags.cache.v3` 或 `.aider.tags.cache.v4`；无 root 时 CWD | diskcache 的代码符号索引。是否使用 tree-sitter language pack 决定 v3/v4；按源文件 mtime 缓存，损坏时实现会删除目录并重建/回退内存。退出后低风险清理，只扫描明确授权的项目根 | [repomap.py#L35](https://github.com/Aider-AI/aider/blob/5dc9490bb35f9729ef2c95d00a19ccd30c26339c/aider/repomap.py#L35)、[重建实现 #L177](https://github.com/Aider-AI/aider/blob/5dc9490bb35f9729ef2c95d00a19ccd30c26339c/aider/repomap.py#L177) |
| `~/.aider/caches/model_prices_and_context_window.json` | 模型价格/上下文元数据，TTL 24h，可重新请求；删除可能影响离线元数据，不丢聊天 | [models.py#L164](https://github.com/Aider-AI/aider/blob/5dc9490bb35f9729ef2c95d00a19ccd30c26339c/aider/models.py#L164) |
| `~/.aider/caches/openrouter_models.json` | OpenRouter 模型目录缓存，缺失/过期重新请求 | [openrouter.py#L30](https://github.com/Aider-AI/aider/blob/5dc9490bb35f9729ef2c95d00a19ccd30c26339c/aider/openrouter.py#L30) |
| 项目/Git 根 `.aider.chat.history.md`、`.aider.input.history` | 分别为聊天记录和输入历史；删除失去历史，`--restore-chat-history` 无法恢复已删文件。按会话审查清理 | [args.py#L270](https://github.com/Aider-AI/aider/blob/5dc9490bb35f9729ef2c95d00a19ccd30c26339c/aider/args.py#L270) |
| `--llm-history-file` 指定文件 | 可选完整 LLM 对话日志，默认没有固定文件路径；可能含代码/敏感内容 | 同上 #L295。不猜测 `.aider.llm.history` 永远存在，它只是参数帮助中的示例 |
| `~/.aider.conf.yml`、Git 根/CWD `.aider.conf.yml`、`--config` 指定文件 | 用户模型/行为配置，可含 API key；不是缓存 | [main.py#L464](https://github.com/Aider-AI/aider/blob/5dc9490bb35f9729ef2c95d00a19ccd30c26339c/aider/main.py#L464)、[args.py#L789](https://github.com/Aider-AI/aider/blob/5dc9490bb35f9729ef2c95d00a19ccd30c26339c/aider/args.py#L789) |
| `~/.aider/oauth-keys.env` | OpenRouter OAuth 获得的 API key 持久存储，启动加载。高风险凭据清理；删除不等于远端撤销 | [onboarding.py#L357](https://github.com/Aider-AI/aider/blob/5dc9490bb35f9729ef2c95d00a19ccd30c26339c/aider/onboarding.py#L357)、[main.py#L361](https://github.com/Aider-AI/aider/blob/5dc9490bb35f9729ef2c95d00a19ccd30c26339c/aider/main.py#L361) |
| `.env` / `--env-file` 指定文件、provider 环境变量 | 凭据可能来自项目/用户共有 `.env` 或 shell 环境。仅移除 Aider 不能授权删除共享 `.env`、shell 配置或其他应用的 API key | 同上；[args.py#L801](https://github.com/Aider-AI/aider/blob/5dc9490bb35f9729ef2c95d00a19ccd30c26339c/aider/args.py#L801) |
| `~/.aider/analytics.json`、`installs.json` | telemetry 用户 ID/禁用偏好、版本/解释器使用记录；删除可重置隐私偏好或再次显示版本提示，不是会话缓存 | [analytics.py#L137](https://github.com/Aider-AI/aider/blob/5dc9490bb35f9729ef2c95d00a19ccd30c26339c/aider/analytics.py#L137)、[main.py#L1183](https://github.com/Aider-AI/aider/blob/5dc9490bb35f9729ef2c95d00a19ccd30c26339c/aider/main.py#L1183) |

[args.py#L35](https://github.com/Aider-AI/aider/blob/5dc9490bb35f9729ef2c95d00a19ccd30c26339c/aider/args.py#L35) 使用 `auto_env_var_prefix="AIDER_"`，历史、配置、env 文件等参数能被命令行/配置/环境改变。因此不能用默认项目文件扫描宣称覆盖全部历史。`--cache-prompts` 是 provider 提示缓存行为，不证明本地存在另一份可清理目录。

用户自定义 `.aider.model.settings.yml`、`.aider.model.metadata.json`、`.aiderignore`、read-only 提示文件也属于配置/项目资源。整个 `~/.aider` 含 OAuth key 和隐私偏好，不能以其中两个缓存 JSON 可再生为由整根 Safe。本次没有证明统一的 Aider 原生 Skill/MCP 全局注册 schema 或 macOS Keychain 存储；后续不得照搬其他 Agent 的结构。卸载还需识别 pip/pipx/uv/venv 等实际安装归属，不能删除共享 Python 解释器或整个环境。

## Goose

旧 [block/goose](https://github.com/block/goose) 在此次读取时重定向至 **[aaif-goose/goose](https://github.com/aaif-goose/goose)**，固定提交 [bab8ff641039c9cd3331121cd84a5c6045f365ca](https://github.com/aaif-goose/goose/commit/bab8ff641039c9cd3331121cd84a5c6045f365ca) 的 `Cargo.toml` repository 字段同样使用新 owner。

默认 macOS 核心路径使用 **XDG**。虽然 [Paths 的注释](https://github.com/aaif-goose/goose/blob/bab8ff641039c9cd3331121cd84a5c6045f365ca/crates/goose/src/config/paths.rs#L19) 提到保留 Block 名称，它调用的 `etcetera::choose_app_strategy` 在 macOS 选择 XDG，而不是 Apple native strategy。已下载 Cargo.lock 锁定的 etcetera **0.11.0** 源码，并核对包 SHA256 `de48cc4d1c1d97a20fd819def54b890cadde72ed3ad0c614822a0a433361be96`；[版本化依赖源码](https://docs.rs/etcetera/0.11.0/src/etcetera/app_strategy.rs.html) 可复核该选择。

默认根为 `~/.config/goose`（config）、`~/.local/share/goose`（data）、`~/.local/state/goose`（state），分别支持 XDG 对应变量。绝对 `GOOSE_PATH_ROOT` 优先改为 `<root>/config`、`<root>/data`、`<root>/state`；相对值被忽略。`GOOSE_ADDITIONAL_CONFIG_FILES` 还能增加配置层，顺序为系统配置、额外文件、用户配置（[base.rs#L173](https://github.com/aaif-goose/goose/blob/bab8ff641039c9cd3331121cd84a5c6045f365ca/crates/goose/src/config/base.rs#L173)）；只删用户文件的一项不保证继承的同名注册不会再出现。旧 `~/Library/Application Support/Block/goose` 仍可能留在旧安装中；固定 [ClawMetry 文档](https://github.com/aaif-goose/goose/blob/bab8ff641039c9cd3331121cd84a5c6045f365ca/documentation/docs/tutorials/clawmetry.md#L40) 明确将其作为 macOS 旧路径回退，但不能假定新版会自动迁移/删除旧数据。

| 路径（默认值） | 生命周期与删除影响 | 固定源码 |
| --- | --- | --- |
| `~/.local/share/goose/sessions/sessions.db` | WAL SQLite，含 session、消息正文、extension state、recipe、provider/model 和使用记录。高风险/会话审查；连同 `-wal/-shm/-journal`，CLI 与桌面共同拥有 | [session_manager.rs#L960](https://github.com/aaif-goose/goose/blob/bab8ff641039c9cd3331121cd84a5c6045f365ca/crates/goose/src/session/session_manager.rs#L960)、[schema #L1028](https://github.com/aaif-goose/goose/blob/bab8ff641039c9cd3331121cd84a5c6045f365ca/crates/goose/src/session/session_manager.rs#L1028) |
| 同 `sessions` 下旧 `.jsonl` | 旧格式会话，初始化数据库时有导入逻辑；已有 db 不代表这些正文无价值 | [legacy.rs](https://github.com/aaif-goose/goose/blob/bab8ff641039c9cd3331121cd84a5c6045f365ca/crates/goose/src/session/legacy.rs)、同上 `import_legacy`；有损审查，不删整根 Safe |
| `~/.local/state/goose/logs/<component>/<date>/` | CLI/server/debug/LLM 等日志；实现清理组件下 mtime 超过 14 天的目录，启动时创建日志路径 | [logging.rs#L116](https://github.com/aaif-goose/goose/blob/bab8ff641039c9cd3331121cd84a5c6045f365ca/crates/goose/src/logging.rs#L116)。丢失诊断资料；停止进程后低风险，不操作其他 state 文件 |
| `~/.local/share/goose/model_catalog/models_dev_api.json`、`models_dev_api.etag` | 下载的模型元数据，内置目录可回退，远端可重取 | [model_catalog.rs](https://github.com/aaif-goose/goose/blob/bab8ff641039c9cd3331121cd84a5c6045f365ca/crates/goose/src/model_catalog.rs)、[registry.rs#L133](https://github.com/aaif-goose/goose/blob/bab8ff641039c9cd3331121cd84a5c6045f365ca/crates/goose-provider-types/src/canonical/registry.rs#L133)。低风险；不要把整个 data 根当缓存 |
| `~/.config/goose/config.yaml`，系统 `/etc/goose/config.yaml` | 用户配置/继承的系统配置；`extensions` 字段持久化本地/远程 MCP 注册和启用状态 | [base.rs#L155](https://github.com/aaif-goose/goose/blob/bab8ff641039c9cd3331121cd84a5c6045f365ca/crates/goose/src/config/base.rs#L155)、[extensions.rs#L84](https://github.com/aaif-goose/goose/blob/bab8ff641039c9cd3331121cd84a5c6045f365ca/crates/goose/src/config/extensions.rs#L84)。单项移除与本体卸载分开；YAML 系统/用户合并不能当普通 mcpServers JSON |
| macOS Keychain：service `goose`、account `secrets` | `system-keyring` 构建下默认存储一整个 secret map；其中 `oauth_creds_<extension>` 是 MCP OAuth。只删 config.yaml 不会清该 map | [base.rs#L30](https://github.com/aaif-goose/goose/blob/bab8ff641039c9cd3331121cd84a5c6045f365ca/crates/goose/src/config/base.rs#L30)、[keyring entry #L1204](https://github.com/aaif-goose/goose/blob/bab8ff641039c9cd3331121cd84a5c6045f365ca/crates/goose/src/config/base.rs#L1204)、[oauth/persist.rs#L29](https://github.com/aaif-goose/goose/blob/bab8ff641039c9cd3331121cd84a5c6045f365ca/crates/goose/src/oauth/persist.rs#L29)。删除整个 entry 会移除多项凭据，应高风险独立操作 |
| `~/.config/goose/secrets.yaml` | 禁用 keyring、无该 feature 或可用性失败后的文件凭据存储；API/OAuth secrets，非缓存 | [base.rs#L393](https://github.com/aaif-goose/goose/blob/bab8ff641039c9cd3331121cd84a5c6045f365ca/crates/goose/src/config/base.rs#L393)。文件与 Keychain 可能共存，不保证删一方就撤销全部凭据 |
| config 中 `gemini_oauth/tokens.json`、`kimicode/token.json` 等 provider token | 某些 provider 单独的 OAuth 持久文件。目录或函数名含 cache 也仍是凭据 | [registrations.rs](https://github.com/aaif-goose/goose/blob/bab8ff641039c9cd3331121cd84a5c6045f365ca/crates/goose/src/providers/inventory/registrations.rs)。高风险重新授权；未声称已遍历所有 provider |
| `~/.agents/skills`、`~/.config/goose/skills`，兼容 `~/.claude/skills`、`~/.config/agents/skills` | 全局 Skill，多 Agent 共享；项目使用 `.agents/skills`，插件也可提供技能 | [skills/mod.rs#L46](https://github.com/aaif-goose/goose/blob/bab8ff641039c9cd3331121cd84a5c6045f365ca/crates/goose/src/skills/mod.rs#L46)、[发现列表 #L401](https://github.com/aaif-goose/goose/blob/bab8ff641039c9cd3331121cd84a5c6045f365ca/crates/goose/src/skills/mod.rs#L401)。解除链接/登记与删除本体分别管理 |
| `~/.agents/plugins`、`.agents/agents`；有 path root 时 `<root>/.agents/...` | 安装插件和子 Agent 资源，另有项目插件 | [paths.rs#L8](https://github.com/aaif-goose/goose/blob/bab8ff641039c9cd3331121cd84a5c6045f365ca/crates/goose/src/config/paths.rs#L8)、[plugins/discovery.rs](https://github.com/aaif-goose/goose/blob/bab8ff641039c9cd3331121cd84a5c6045f365ca/crates/goose/src/plugins/discovery.rs)。配置根卸载不能吞掉共享父 `.agents` |
| `~/.config/goose/mcp-apps-cache` | 完整 GooseApp JSON，可含自定义 HTML app；内置 clock 可重建，任意用户/外部 app 不保证重建 | [cache.rs#L35](https://github.com/aaif-goose/goose/blob/bab8ff641039c9cd3331121cd84a5c6045f365ca/crates/goose/src/goose_apps/cache.rs#L35)、[持久化 #L145](https://github.com/aaif-goose/goose/blob/bab8ff641039c9cd3331121cd84a5c6045f365ca/crates/goose/src/goose_apps/cache.rs#L145)。产物审查；不能仅依据 cache 名称 Safe |
| `~/.local/share/goose/apps` | 用户创建/迭代的 HTML/CSS/JS app 文件 | [apps.rs#L135](https://github.com/aaif-goose/goose/blob/bab8ff641039c9cd3331121cd84a5c6045f365ca/crates/goose/src/agents/platform_extensions/apps.rs#L135)。用户成果，有损审查 |
| desktop `app.getPath('userData')/logs/main.log`、`logs/startup` | Electron 桌面主进程/启动日志；与核心 XDG logs 不同 | [logger.ts#L5](https://github.com/aaif-goose/goose/blob/bab8ff641039c9cd3331121cd84a5c6045f365ca/ui/desktop/src/utils/logger.ts#L5)、[main.ts#L182](https://github.com/aaif-goose/goose/blob/bab8ff641039c9cd3331121cd84a5c6045f365ca/ui/desktop/src/main.ts#L182)。日志可低风险清理；实际 userData 根需核对 packaged/development app name |
| 同 desktop userData 的 `settings.json`、`recent-dirs.json`、`recipe_hashes` | 用户设置、最近目录、recipe 信任/记录状态；非全体可再生缓存 | [main.ts](https://github.com/aaif-goose/goose/blob/bab8ff641039c9cd3331121cd84a5c6045f365ca/ui/desktop/src/main.ts)、[recentDirs.ts](https://github.com/aaif-goose/goose/blob/bab8ff641039c9cd3331121cd84a5c6045f365ca/ui/desktop/src/utils/recentDirs.ts)、[recipeHash.ts](https://github.com/aaif-goose/goose/blob/bab8ff641039c9cd3331121cd84a5c6045f365ca/ui/desktop/src/utils/recipeHash.ts)。配置/状态审查 |

桌面 `package.json` 的 `productName` 为 `Goose`（版本 1.53.0），正常打包 userData 通常为 `~/Library/Application Support/Goose`；源码以 Electron `app.getPath` 为准，不能据此保证所有 dev/改名构建的具体根。核心 Paths 没有通用 `cache_dir()`，所以不能凭 XDG 约定推导 `~/.cache/goose` 整根可再生。语音模型、local inference 下载、scheduled recipes/jobs、permissions、TLS、项目资料和所有 provider 凭据的全量生命周期尚未完成逐项核对，不纳入 Safe 保证。

## 后续支持边界

两产品均需专属 presence、安装来源和卸载逻辑，以及自定义根、CLI/桌面共享 owner、SQLite/file identity 重校验、配置备份和关联级联。Aider 项目历史/tag cache 不能靠扫用户 Home 全部仓库来覆盖；Goose 的 YAML extension 注册、Keychain secret map、共享 skills/plugins、旧目录和新 XDG 根需要分别实现。本次只建立可核对路径及风险依据，未修改现有扫描器，也未扩大清理授权范围。
