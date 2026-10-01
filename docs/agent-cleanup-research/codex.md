# Codex CLI / App 清理研究

核对日期：2026-10-01。研究范围为本机数据生命周期；不运行远程代码，不删除真实用户数据。

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
| `sessions` / `archived_sessions` | 会话正文 | 无法继续/找回相应会话，可能影响本地历史索引一致性 | 高风险，默认不选 |
| `state_*.sqlite` / `thread_history_*.sqlite` | 会话元数据和历史数据库 | 丢失本地线程、历史、附件登记、索引或 UI 状态 | 高风险，默认不选，不称作垃圾缓存 |
| `goals_*.sqlite` / `memories_*.sqlite` / `queue_*.sqlite` | 目标、记忆、队列 | 重置目标/记忆，丢失待执行输入 | 高风险，默认不选 |
| `db-backups`（SQLite 根） | 数据库恢复备份 | 丢失恢复损坏数据库的机会 | 需要确认，默认不选 |
| `shell_snapshots` | Shell 环境快照 | 丢失环境快照，可能含环境相关敏感信息 | 高风险，默认不选 |
| `history.jsonl` | 输入历史 | 丢失命令/提示历史 | 高风险，默认不选 |
| `auth.json` / `.credentials.json` | 登录和 MCP OAuth 凭据 | 需重新登录/授权；Keychain 中的凭据不能靠删文件等价清除 | 高风险，默认不选 |
| `generated_images` | 用户生成产物 | 丢失图片 | 需要确认，不作为可再生缓存 |
| `config.toml`、Skill、插件、worktrees、automations | 用户配置/安装资源/工作成果 | 可能含代码、未提交修改及持久自动化 | 单独管理；不能整体归类为缓存 |

## 对 Nori 的修正与边界

本轮补充缺失的目标/记忆/队列数据库、恢复备份、模型目录缓存、Shell 快照和 MCP OAuth 文件凭据；延续 SQLite 主文件与 `-wal/-shm/-journal` 一起扫描。配置根需与 Skill/MCP 注册读取采用同一解析器。

Codex App 自身没有对应的公开完整客户端源码。Electron 缓存叶子、`Library/Caches/com.openai.codex` 和日志规则属于运行时结构与本机路径证据，不代表整个 App Support 目录可安全再生。CLI 与桌面版共享 Codex home，会话数据不能各自重复计量或在另一客户端运行时删除。

自定义目录只在明确可识别的路径中发现。Nori 可读取自己进程可见的环境变量；从 Finder 启动时不一定继承用户 shell 的变量。项目级/命令行临时覆盖、工作树及外部磁盘不应通过扫描任意目录来猜测。删除本地文件不表示删除云端会话或撤销服务端凭据。
