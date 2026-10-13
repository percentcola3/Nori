# Codex CLI / App 清理研究

核对日期：2026-10-13。研究范围为本机数据生命周期；不删除真实用户数据。

## 历史清理修正（2026-10-13）

旧规则不成立：文件年龄和退出进程只能证明文件暂时未使用，不能证明会话、索引和桌面状态可以分别删除。隔离测试通过 Nori 的真实执行入口，复现了删除 rollout 后 `state_5.sqlite` 仍存在的情况。它支持“列表仍在但历史打不开”的原因；没有用真实会话重现，也没有恢复此前丢失的数据。

本机随应用附带的 CLI 为 `codex-cli 0.162.0-alpha.17.2`。使用 `codex app-server generate-json-schema --out <临时目录>`，确认非 experimental schema 中存在 `thread/list`、`thread/archive`、`thread/delete`。删除参数为 `{ "threadId": "..." }`。这证明本机协议有该方法，不证明它是所有版本的稳定接口，也不证明删除会自动处理全部桌面端自动化/工作树状态。没有调用真实删除接口。

官方文档入口：[Codex app-server](https://developers.openai.com/codex/app-server)。本次访问返回 HTTP 403，以上接口信息以本机生成的 schema 为证据。

当前 Nori 的处理：

- 普通清理保留明确的缓存、临时文件和日志规则及既有进程/打开文件校验。
- 会话、归档、相关历史/状态数据库、附件及恢复备份只展示，不能选中。保留配置、凭据、记忆和工作树；Skills/MCP 继续由独立的资源管理功能处理。
- 扫描清单、执行计划和最终文件删除入口均保护上述路径；伪造为 Safe、旧扫描结果、卸载残留、整根目录删除都不能解除保护。其他 Agent 适用同一保护规则。
- 对话历史不再按文件年龄推荐清理；旧保留期设置不再作用于历史文件。

后续接入会话删除接口需要满足这些条件，缺任一项则停用历史清理：

1. 按宿主应用使用的二进制和实际 Codex home 检查版本/协议。不能启动独立 app-server 后，把其空的 loaded 列表当成桌面端没有运行中任务；必须连接宿主使用的服务，或要求所有相关客户端退出并再次复核。
2. `thread/list` 分页查询 `archived: false` 和 `archived: true`，展示 ID、名称、`projectId`/`cwd`、创建和更新时间。仅查默认列表不足以验证删除，因为归档会话不在默认结果中。
3. 排除运行中、置顶、自动化绑定和工作树关联的会话，并在删除前复核。本机普通 Thread schema 包含 `status` 和 `section`，另有 attachment 查询；启用 experimental 后才有 `extra` 和 `environments`，`project/list` 也属于 experimental。schema 未给出完整桌面置顶/自动化绑定的通用契约，不能把缺失字段当成未绑定。
4. 备份选中会话及恢复所需关联状态，并验证备份可读。文件路径字段明确标记为 unstable；复制 rollout 不是完整的恢复方案，不能在线复制 SQLite 主文件就声称已备份状态。恢复契约未确认前不启用删除。
5. 用户按会话选择后逐项调用 `thread/delete`，重新查询活跃/归档列表并核对会话不存在；超时、接口错误或验证失败保留失败项，禁止退回文件删除或清整个数据库。

`thread/archive` 和删除是两个操作：归档仍保留历史，不能当成释放磁盘空间。对其他 Agent 也先确认其正式会话删除/恢复能力，不能将 Codex 的接口名称套用到其他产品。

## 证据

- 官方配置参考：[config-reference](https://learn.chatgpt.com/docs/config-file/config-reference)。原 `developers.openai.com/codex/config-reference` 在本次请求中重定向到该页。确认 `history.persistence`、`history.max_bytes`、`sqlite_home`、`log_dir`。
- 开源源码固定版本：[openai/codex@6b4daafdb445340e5af66f067ad4057e6ed9fd81](https://github.com/openai/codex/commit/6b4daafdb445340e5af66f067ad4057e6ed9fd81)。下列代码链接均固定该版本。
- [core/src/config/mod.rs](https://github.com/openai/codex/blob/6b4daafdb445340e5af66f067ad4057e6ed9fd81/codex-rs/core/src/config/mod.rs)：`CODEX_HOME` 默认 `~/.codex`；`sqlite_home` 可独立配置，配置优先于 `CODEX_SQLITE_HOME`，否则使用 Codex home；日志默认 `$CODEX_HOME/log`，也支持独立 `log_dir`。
- [tui/src/lib.rs](https://github.com/openai/codex/blob/6b4daafdb445340e5af66f067ad4057e6ed9fd81/codex-rs/tui/src/lib.rs#L278)：文件日志名为 `codex-tui.log`。自定义 `log_dir` 可以共用普通文件夹，Nori 只认该精确日志叶子，不将整个自定义目录归类为缓存。
- [state/src/sqlite.rs](https://github.com/openai/codex/blob/6b4daafdb445340e5af66f067ad4057e6ed9fd81/codex-rs/state/src/sqlite.rs)：`logs_2.sqlite`、`state_5.sqlite`、`thread_history_1.sqlite`、`goals_1.sqlite`、`memories_1.sqlite`、`memories_v2_1.sqlite`、`queue_1.sqlite`。
- [state/src/runtime/recovery.rs](https://github.com/openai/codex/blob/6b4daafdb445340e5af66f067ad4057e6ed9fd81/codex-rs/state/src/runtime/recovery.rs)：数据库损坏恢复会在 SQLite 根下创建 `db-backups`；这些备份是恢复资料。
- [rollout/src/lib.rs](https://github.com/openai/codex/blob/6b4daafdb445340e5af66f067ad4057e6ed9fd81/codex-rs/rollout/src/lib.rs)：`sessions`、`archived_sessions` 是持久化 rollout；包含 CLI、编辑器、App 等来源。
- [message-history/src/lib.rs](https://github.com/openai/codex/blob/6b4daafdb445340e5af66f067ad4057e6ed9fd81/codex-rs/message-history/src/lib.rs)：`history.jsonl` 是逐行输入历史，支持上限收缩。
- [core/src/shell_snapshot.rs](https://github.com/openai/codex/blob/6b4daafdb445340e5af66f067ad4057e6ed9fd81/codex-rs/core/src/shell_snapshot.rs)：`shell_snapshots` 保存环境快照，源码有三天保留策略；删除会失去快照，运行时可能仍需读取，且与环境/凭据相关。
- [arg0/src/lib.rs](https://github.com/openai/codex/blob/6b4daafdb445340e5af66f067ad4057e6ed9fd81/codex-rs/arg0/src/lib.rs)：`tmp/arg0` 是进程启动辅助路径和锁；运行中不能清理。
- [models-manager/src/manager.rs](https://github.com/openai/codex/blob/6b4daafdb445340e5af66f067ad4057e6ed9fd81/codex-rs/models-manager/src/manager.rs)、[cache.rs](https://github.com/openai/codex/blob/6b4daafdb445340e5af66f067ad4057e6ed9fd81/codex-rs/models-manager/src/cache.rs)：`models_cache.json` 是短期模型目录缓存；缓存失败可回退/重新请求。

## 分类和删除影响

| 路径（相对 Codex home，除另述） | 归类 | 删除影响 | 推荐策略 |
| --- | --- | --- | --- |
| `models_cache.json` | 可再生元数据缓存 | 下次重新请求模型目录，离线时可能使用内置目录 | Safe，退出 Codex 后清理 |
| `tmp` / `tmp/arg0` | 启动辅助临时数据 | 重新创建；活动进程持有锁或执行文件 | Safe，但进程/打开文件校验必须通过 |
| `log` / `logs_*.sqlite` 及 SQLite 伴随文件 | 调试日志 | 丢失排障资料，非会话正文 | 文件日志 Safe；日志库仍需手动确认 |
| `sessions` / `archived_sessions` | 会话正文 | 无法继续/找回相应会话，影响历史索引一致性 | 禁止按文件删除；原应用按会话管理 |
| `state_*.sqlite` / `thread_history_*.sqlite` | 会话元数据和历史数据库 | 丢失本地线程、历史、附件登记、索引或 UI 状态 | 只展示，禁止按文件删除 |
| `goals_*.sqlite` / `memories_*.sqlite` / `queue_*.sqlite` | 目标、记忆、队列 | 重置目标/记忆，丢失待执行输入 | 只展示，禁止按文件删除 |
| `db-backups`（SQLite 根） | 数据库恢复备份 | 丢失恢复损坏数据库的机会 | 保留恢复资料，禁止按文件删除 |
| `shell_snapshots` | Shell 环境快照 | 丢失环境快照，可能含环境相关敏感信息 | 只展示，禁止按文件删除 |
| `history.jsonl` | 输入历史 | 丢失命令/提示历史 | 只展示，禁止按文件删除 |
| `auth.json` / `.credentials.json` | 登录和 MCP OAuth 凭据 | 需重新登录/授权；Keychain 中的凭据不能靠删文件等价清除 | 保留，在原应用管理 |
| `generated_images` / `attachments` | 会话关联产物 | 丢失图片或附件 | 保留，在原应用管理 |
| `config.toml`、Skill、插件、worktrees、automations | 用户配置/安装资源/工作成果 | 可能含代码、未提交修改及持久自动化 | 单独管理；不能整体归类为缓存 |

## 对 Nori 的修正与边界

本轮补充缺失的目标/记忆/队列数据库、恢复备份、模型目录缓存、Shell 快照和 MCP OAuth 文件凭据；延续 SQLite 主文件与 `-wal/-shm/-journal` 一起扫描。配置根需与 Skill/MCP 注册读取采用同一解析器。

Codex App 自身没有对应的公开完整客户端源码。Electron 缓存叶子、`Library/Caches/com.openai.codex` 和日志规则属于运行时结构与本机路径证据，不代表整个 App Support 目录可安全再生。CLI 与桌面版共享 Codex home，会话数据不能各自重复计量或在另一客户端运行时删除。

自定义目录只在明确可识别的路径中发现。Nori 可读取自己进程可见的环境变量；从 Finder 启动时不一定继承用户 shell 的变量。项目级/命令行临时覆盖、工作树及外部磁盘不应通过扫描任意目录来猜测。删除本地文件不表示删除云端会话或撤销服务端凭据。
