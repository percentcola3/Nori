# 无 Apple 开发者账号的 GitHub 发布

项目使用一份固定的自签名证书签署公开版本。`signing/release.cer` 是可以公开的 DER 证书，`signing/release.plist` 记录证书指纹、Bundle ID 和签名名称；私钥及其密码始终留在仓库之外。每个版本都必须使用同一份私钥和证书，不能在 GitHub Actions 每次构建时重新生成。

固定签名让版本更新保持相同的代码签名身份，但不能替代 Apple Developer ID 或公证，也不能保证所有 macOS 版本都保留全部隐私授权。从以前的 ad-hoc、本地开发证书或其他发布证书迁移过来时，用户可能需要重新授权一次。

## 只初始化一次，之后复用

首次建立项目发布身份、且仓库尚未包含固定公开证书时，由维护者在自己的 Mac 上执行一次：

```bash
bash script/release_identity.sh init
```

私有归档存放于 `~/Library/Application Support/ForgeSweep/release-signing/identity.p12`，密码文件为同目录的 `identity-password`。初始化同时生成仓库内可以公开的证书与身份记录。仓库已有公开证书但本机缺少私钥时，`init` 会故意拒绝生成新的身份；新维护者或新 Mac 必须导入原来的备份。后续构建通常先确保原身份可用，再打包：

```bash
bash script/release_identity.sh ensure
bash script/package_release.sh
```

请先建立加密备份，再对外发布第一个版本。下面的目标目录必须尚不存在，而且必须在 Git 仓库之外；可以将它换成你的加密备份卷路径：

```bash
bash script/release_identity.sh export "$HOME/ForgeSweep-release-backup"
```

导出目录包含 `signing-certificate.p12`、`signing-certificate.base64` 和 `signing-password`，用于备份及配置 GitHub Secrets。脚本限制目录和文件的访问权限，但这不等同于备份介质加密；应妥善保管整个目录。

在新 Mac 上，可从相同导出目录恢复身份，秘密只传入进程环境，不要把实际内容写进命令或日志：

```bash
set +x
FORGESWEEP_SIGNING_P12_BASE64="$(cat "$HOME/ForgeSweep-release-backup/signing-certificate.base64")" \
FORGESWEEP_SIGNING_P12_PASSWORD="$(cat "$HOME/ForgeSweep-release-backup/signing-password")" \
  bash script/release_identity.sh import
```

本机导入会为该证书配置用户域的代码签名信任，macOS 可能弹出系统确认；若没有完成授权，私有归档会保留，完成代码签名信任设置后可重跑 `ensure`。该信任设置用于维护者的构建环境，不是用户安装 App 的步骤。

## 配置 GitHub Actions

推荐先安装并登录 GitHub CLI（`gh auth login`），再执行：

```bash
bash script/configure_release_secrets.sh
```

脚本从 Git `origin` 推断仓库，或接受显式的 `owner/repository` 参数。它验证本地固定身份，经临时私有目录导出，使用标准输入上传秘密，并在结束时删除临时文件。如果下面任一同名 secret 已存在，脚本会拒绝覆盖，防止替换已发布的身份。若上传中断只写入了一个 secret，需先检查仓库现状，再由维护者恢复缺失项，不要直接更换发布证书。

也可在 GitHub 仓库的 **Settings → Secrets and variables → Actions** 手动配置两个 repository secrets：

| Secret | 内容 |
| --- | --- |
| `FORGESWEEP_SIGNING_P12_BASE64` | 固定发布身份的加密 PKCS#12 文件经过 Base64 编码后的完整内容 |
| `FORGESWEEP_SIGNING_P12_PASSWORD` | 该 PKCS#12 文件的密码 |

两个 secret 分别对应导出目录中的 `signing-certificate.base64` 和 `signing-password` 文件。

必须备份同一份加密 PKCS#12 和密码。遗失私钥之后，单凭仓库中的公开证书无法恢复签名能力。不要把 `.p12`、`.pfx`、私钥、密码文件、临时钥匙串或 Base64 秘密提交到 Git，也不要放进 Release 附件、CI artifact、缓存或日志。

公开证书和 `release.plist` 应随代码提交。CI 导入时会检查 secret 中的身份是否匹配仓库固定的公开证书；没有配置 secrets 或身份不匹配时，发布构建会失败，不会退回 ad-hoc 签名。

## 构建和发布

1. 先把经过审核的工作流、发布脚本和公开证书推送到仓库默认分支。
2. 在 **Actions → Signed macOS release → Run workflow** 选择默认分支试跑。手动运行只生成 `ForgeSweep-macos` artifact，不发布 GitHub Release。
3. 下载 artifact，检查 Apple 芯片和 Intel 两个 DMG。确认版本号正确后，为待发布提交创建并推送 `v*` 标签，例如 `v1.0.1`。
4. 标签构建成功后会创建 **draft Release**，附上两个 DMG 和 `SHA256SUMS`。完成安装与跨版本授权验证、补充更新说明后，再手动公开草稿。

已有同名 Release 时，工作流不会覆盖其附件。排查失败后重试前，先检查是否已经产生该标签的草稿。

CI 使用 `macos-15` 和 `/Applications/Xcode_26.2.app/Contents/Developer`，串行交叉编译 `arm64`、`x86_64` 两种架构。它先跑回归检查，再导入私钥、打包和校验，最后清理临时钥匙串；上传范围只包含两个 DMG 与校验和。该工作流不接受 pull request 事件，手动运行限定默认分支。仅向经过审核的分支和标签开放发布权限；建议用 GitHub rulesets 保护默认分支和 `v*` 标签。

CI 签名仅支持一次性的 GitHub-hosted runner。导入脚本使用 `sudo -n` 在管理员域临时加入仅限代码签名的证书信任，`always` 清理步骤对称移除该信任与临时钥匙串；此分支不适用于自托管机器。本机长期保存的私钥不会由 CI 的 `cleanup` 删除。

若 GitHub 从 runner 镜像移除固定的 Xcode 路径，流程会明确失败。维护者应查阅 [runner 镜像清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md)，验证替代稳定版本后再更新工作流，不要自动回退到未经验证的 beta SDK。

## 安装和升级验证

用户从 DMG 将 `ForgeSweep.app` 拖到 `/Applications`，在相同位置覆盖升级。首次打开若因未经公证而被拦截，可尝试“系统设置 → 隐私与安全性 → 仍要打开”。无需给用户安装你的证书，也不应要求他们关闭 Gatekeeper。

公开前至少在另一台未导入、未信任发布证书的 Mac 上验证，使用浏览器下载 DMG 并保留系统的下载隔离标记，模拟真实用户安装。先安装旧版固定签名 App，授予完全磁盘访问与屏幕录制权限并使用对应功能，退出后以同样方式下载、覆盖安装同证书签署的新版，再确认打开流程、权限与功能。这里的旧版也必须来自同一个发布身份；本机 ad-hoc 构建不能用于证明跨版本授权保留。

下载后可以在两个 DMG 与 `SHA256SUMS` 所在目录检查文件完整性：

```bash
shasum -a 256 -c SHA256SUMS
```

若拥有源码中的固定公开证书，还可以对安装包内的 App 执行身份检查：

```bash
bash script/verify_release.sh /Applications/ForgeSweep.app
```

此检查成功只证明签名有效且应用的指定要求（designated requirement）符合固定身份；不能证明 Gatekeeper 会放行，或 macOS 隐私授权会在升级后保留，后两项仍需上述真实安装验证。
