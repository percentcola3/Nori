# Agent 历史清理验证交接

2026-10-13。本次交付是代码和研究资料，最新历史适配代码尚未编译或运行；本机不进行软件验证或安装。以交接消息中的 Git 提交 SHA 为验证基线，不使用浮动的 `master` 结果代替。

## 验证范围和当前状态

- 普通文件清理：会话、归档、历史/状态库、配置、凭据、记忆、工作树和恢复备份受保护。缓存、明确临时文件和旧日志沿用现有规则。退出或卸载 Agent 不解除历史保护。
- 独立历史入口：首批代码覆盖 OpenCode、Copilot CLI、Gemini CLI。`SimpleMole/Services/AgentHistoryService.swift` 的 `interfacesEnabled` 为 `false`，服务和界面均禁止读取/删除。提交或编译成功不代表功能已启用。
- Codex：已确认本机协议存在相关方法，尚未实现可启用的删除适配；仍保持文件保护。其他产品的官方能力见 [接口研究](official-session-apis.md)，不能视为已经完成接入。
- 备份：`~/Library/Application Support/Nori/agent-history-backups/<UUID>/`，供人工恢复演练；目前没有自动恢复功能，也没有完成可恢复性验证。

## 1. 使用独立测试账户准备机器

使用独立 macOS 用户或可回滚虚拟机，准备 Xcode/Command Line Tools、Python 3 和 Git。首次构建可能需要联网下载已固定的 Sparkle 依赖。先记录 macOS、CPU 架构、Swift、SDK 和三个 Agent 的实际版本、安装来源、协议版本。

基础编译和夹具阶段不安装或启动真实 Agent。协议联调只创建一次性测试项目、测试会话及必要的测试凭据，不导入个人历史。仅设置 shell 的 `HOME` 不足以证明隔离：界面使用 `NSHomeDirectory()`，某些产品还有系统设置、Keychain、XDG 或自定义数据根。

在干净仓库中检出交接 SHA，保留日志：

```bash
git fetch origin
git switch --detach <交接提交SHA>
git status --short
VALIDATION_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nori-agent-history-validation.XXXXXX")"
git rev-parse HEAD > "$VALIDATION_DIR/commit.txt"
sw_vers > "$VALIDATION_DIR/macos.txt"
xcrun swift --version > "$VALIDATION_DIR/swift.txt"
xcrun --sdk macosx --show-sdk-path > "$VALIDATION_DIR/sdk.txt"
```

## 2. 保持开关关闭，先编译和运行已有回归

下面命令均在仓库根目录执行。每项单独保存 stdout/stderr 和退出码；失败先修复并记录新 SHA，不把旧代码曾通过的测试算作本次通过。

```bash
SM_ALLOW_ADHOC=1 SM_CODESIGN_IDENTITY=- SM_OUTPUT_DIR="$VALIDATION_DIR/build" \
  bash script/build.sh > "$VALIDATION_DIR/build.log" 2>&1
bash script/test_agents.sh > "$VALIDATION_DIR/agents.log" 2>&1
bash script/test_agent_workflow.sh > "$VALIDATION_DIR/workflow.log" 2>&1
bash script/test_agent_resource_management.sh > "$VALIDATION_DIR/resources.log" 2>&1
bash script/test_cache_cleanup.sh > "$VALIDATION_DIR/cache.log" 2>&1
bash script/test_uninstall_residue.sh > "$VALIDATION_DIR/uninstall.log" 2>&1
bash script/test_task_feedback_localization.sh > "$VALIDATION_DIR/localization.log" 2>&1
bash script/audit_destructive_sinks.sh > "$VALIDATION_DIR/deletion-audit.log" 2>&1
```

此阶段不运行 `install_update.sh`，不替换 `/Applications/Nori.app`。临时 ad-hoc 构建只验证编译，不能证明正式签名、权限延续或安装成功。

需要补齐现有显式编译清单：Agent presentation 夹具当前还没有接入新的 `AgentHistory*` 服务/View/Store 及其 AppState 测试依赖，须补充 `CryptoKit`/`SQLite3` 对应链接。补齐后用 `NORI_AGENT_PRESENTATION_COMPILE_ONLY=1 bash script/test_agent_presentation.sh`，先不启动夹具界面。新历史模块的自有临时目录删除也须经过删除出口审计；只能针对确认归属的清理语句放行，不扩大为允许删除历史文件或整个服务。

重点断言：旧扫描记录、伪造 Safe 分类、`verifiedTargets`、父目录选择和卸载残留均不能绕过历史保护；过期会话、数据库主文件和 WAL/SHM、凭据、记忆、工作树及 Nori 恢复备份保持原样；普通缓存仍能按既有进程/白名单规则清理。

## 3. 新增隔离夹具，修复启用前的缺口

当前没有新历史适配器的专用测试套件，不能通过重复旧测试宣称完成验证。使用受控 child process、loopback HTTP 和一次性目录测试生产代码。需要测试开关时，仅修改测试源码副本，交付源码继续保留 `false`。

启用前必须补齐以下事项：

1. **Nori 白名单**：当前 `AgentHistoryService.delete` 没有显式检查白名单。增加会话、项目和已确认数据根的保护检查，并测试父/子目录覆盖和扫描后新增白名单；备份或官方 API 都不能绕过用户保护。
2. **关联保护**：核对各实际版本是否提供运行、置顶、自动化、父子会话、工作树和远端字段。字段缺失不等于未关联；无法取得可靠证据的版本/记录继续禁用。备份不完整或不能恢复的记录继续禁用。
3. **进程与通信**：分段/合并 Content-Length 帧、错误 ID、异常 JSON、输出超限、超时、进程崩溃、SIGPIPE、关闭与残留子进程；拒绝登录/权限/行动请求；OpenCode 认证失败和重定向拒绝。复核其他客户端进程和扫描后新启动客户端。
4. **备份**：选中正文及关联产物、SQLite 已提交 WAL、一致性、源文件变更、符号链接、权限错误、读取不完整、空间不足、512 MiB/2 万条限制、目录 0700/文件 0600。备份前后身份和摘要不一致时不得删除。
5. **删除结果**：空/重复/跨项目 ID、CLI 被替换、列表变化、用户取消、版本不兼容、首项/中途失败、删除成功但验证仍列出、响应丢失。确认失败停止后续项；不确定结果保留收据，禁止自动重试或退回文件删除。
6. **资源占用**：验证 8 MiB 响应、2000 条列表、100 条批次上限；重复扫描、切项目、切页和失败后内存/进程释放。正文留在磁盘，备份引用缓存有界。

## 4. 逐产品进行一次性会话联调

先创建两组项目和若干一次性会话，包含选中、未选中、应保护的记录。保存官方列表和文件摘要，先验证只读流程，再验证删除。联调时只打开测试副本的开关，不发布启用构建。

| 产品 | 必须核对的事项 |
| --- | --- |
| OpenCode | 自有 loopback 服务、随机认证、完整 session/status/children/export/messages/diff 契约；只删除选中 ID，其他会话与凭据保持可用；重启官方客户端后索引不残留打不开的条目 |
| Copilot CLI | `--headless --stdio --no-auto-update --no-auto-login` 被实际版本支持；当前适配只接受 protocol 3；cwd 过滤、远端记录保护、session-state 和索引备份；调用不触发登录、升级、创建/恢复会话或 Agent turn |
| Gemini CLI | 临时系统设置覆盖确实被 CLI 接受，`general.sessionRetention.enabled=false` 在列表启动前生效；额外放一个已过期但未选中的会话，list/delete 后它必须仍在；原设置不变；核对 registry、ownership marker、sandbox 根、stdout 格式及 summary/auth 启动副作用；补齐自定义 plans/tool-output 等关联产物后才判断备份完整 |

官方删除后重新查询并重启客户端：选中 ID 消失，未选中 ID 仍能打开，凭据、配置、Skills、记忆、工作树保持可用。人工恢复演练必须在另一个一次性环境中进行，验证正文和所需关联产物可读取；不要用在线整库覆盖作为恢复方案。

## 5. 界面和安装验收

基础和协议检查通过后，再手动检查三个语言的历史入口、项目切换、禁用原因、选择与确认、进度、失败记录、备份定位和完成后刷新。检查与普通清理/卸载互斥，取消不会执行删除，失败不会丢失未处理选择。先验收关闭开关的状态，再验收测试副本的启用状态。

正式安装另行使用 `bash script/install_update.sh`。如果已安装固定发布签名，需要原发布私钥；本机此前曾因私钥缺失停止安装。目标机器应按实际结果记录，不能通过更换签名或 ad-hoc 替换正式版绕过检查。没有签名材料时，只交付构建和夹具结果，安装验收保持未完成。

全部启用前事项通过并留下证据后，才以单独提交决定是否开放经过验证的产品/版本；当前为全局开关，不能因某一个产品通过就把三个产品一起放开。

## 回传结果

回传基线/修复 SHA、机器及 Agent 版本、每项退出码、脱敏日志、失败复现、删除前后 ID 对照、备份权限/恢复证据，以及开关是否仍为 `false`。标明未执行、无法执行和失败项；日志不得包含会话正文、口令、Authorization header 或个人项目路径。不要上传整个历史备份。
