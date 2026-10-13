# 首批历史接口适配代码

2026-10-13。按用户要求，本轮只写代码，编译、测试、实际 CLI/API 调用校验及安装均留待后续。没有删除真实历史。

## 当前范围

Agent 页新增独立“历史”入口，首批覆盖 OpenCode、Copilot CLI、Gemini CLI。用户选择项目，读取原应用会话，按会话 ID 选择并确认删除。历史不进入 `CleanupCategory`、自动清理、缓存清理或卸载数据范围。

`AgentHistoryService.interfacesEnabled` 默认 **false**。读取和删除入口均关闭；该开关不能在完成下面校验前打开。Codex 及其他 Agent 继续使用已有只读保护，没有因本轮代码放开文件删除。调用者只通过统一服务进入官方删除流程，不绕过备份与再次复查。

## 实现入口

- `Services/AgentHistoryModels.swift`：项目/CLI 身份、会话 ID、更新指纹与保护原因。
- `Services/AgentHistoryService.swift`：复查选择 → 私有备份 → 再次复查 → 官方删除 → 重新列出验证。失败停止本批，保留失败记录和备份；超时后的不确定结果禁止直接重试。
- `Services/AgentHistoryOpenCode.swift`：退出其他客户端后，启动 Nori 自有 loopback 服务；随机认证口令只在进程环境及请求头中使用，不跟随重定向。通过 Session API 导出和删除，不复制包含凭据的整库。
- `Services/AgentHistoryCopilot.swift`、`AgentHistoryRPC.swift`：使用官方 SDK 同一 stdio JSON-RPC，限定已研究的 **protocol 3**；不创建或恢复会话、不启动 Agent turn。备份选中的 session-state，相关 SQLite 索引用 `sqlite3_backup` 捕获 WAL 中已提交状态。
- `Services/AgentHistoryGemini.swift`：官方 CLI 列表及 UUID 删除；正文只读用于备份和指纹。只认官方 registry/ownership marker；未知布局或重复 ID 停用。原生列表启动前会运行自动过期清理，因此每次调用使用 Nori 自有临时系统设置覆盖 `general.sessionRetention.enabled=false`，保留其他系统设置及 defaults 路径，不修改用户文件。未知/JSONC 管理设置不做猜测替换。
- `Services/AgentHistoryBackup.swift`：私有磁盘备份、文件摘要和源身份；逐文件核对一致性，备份索引使用 SQLite 的备份 API。单个备份上限 512 MiB、2 万个条目；接口 JSON 上限 8 MiB、列表上限 2000 条、单批最多 100 条。
- `Views/AgentHistoryStore.swift`、`AgentHistoryView.swift`：独立的会话选择/进度/失败记录；复用现有 AppState 的执行门禁，完成后按已有路径刷新空间清单。只缓存少量 metadata，历史正文保留在磁盘。

备份位于 `~/Library/Application Support/Nori/agent-history-backups/<UUID>/`。目录 0700、文件 0600；清理文件入口同样保护该目录。备份保留为人工恢复材料，不提供自动覆盖数据库的恢复功能，也不保证复制全部跨产品或云端副本。

## 后续校验后才能开放

可交给其他机器执行的步骤见 [验证交接](validation-handoff.md)。启用前还须补齐 Nori 白名单对官方会话删除的检查；当前文件删除保护不能替代此检查。新历史接口的专用夹具、presentation 显式源码清单和删除出口审计也待完成。

1. 编译与隔离夹具：stdio framing、超时/退出/输出截断、拒绝权限或登录请求、服务认证/重定向、CLI argv 和环境覆盖。先使用受控 child/HTTP 夹具，不操作真实会话。
2. 逐产品核对安装版本、官方 metadata 中的置顶/自动化/父子/工作树/远端关联。现有代码识别已知保护字段及未知 `extra`，不能把产品未暴露字段直接解释成未关联。无法证明安全时继续保留，不放开该版本。
3. 备份和恢复演练：WAL、符号链接、文件改动、目录读取不完整、超额/空间不足、源校验及失败收据；确认所选正文和相关产物可恢复。Gemini 自定义 plans/tool-output 等额外位置未纳入时不能宣称完整备份。
4. 确认 Gemini 临时设置覆盖被当前 CLI 实际接受，自动过期清理确实关闭；核对 list 的 summary/auth 等启动副作用，以及各实际会话布局、项目 registry 与 stdout 格式。
5. 真实调用前复核其他客户端和 CLI 身份，验证官方删除成功后 ID 确实消失；错误/超时/仍被列出均保留收据和备份，不调用 FileManager 删除历史或整库。

一次版本或接口的校验通过，不代表其他版本、另一宿主、云端镜像或扩展同样受覆盖。
