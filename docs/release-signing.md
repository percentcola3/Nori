# Stable GitHub release signing

Nori's public releases use the original publisher-owned, self-signed certificate. Keep all three parts of the code identity unchanged across updates:

| Identity | Pinned value |
| --- | --- |
| Bundle identifier | `com.nori.app` |
| Certificate SHA-1 (identity fingerprint) | `ABF7136A66689BF6437F7C4252A3168401FF33F6` |
| Designated requirement | `identifier "com.nori.app" and certificate root = H"abf7136a66689bf6437f7c4252a3168401ff33f6"` |

The certificate is valid through September 23, 2036. Its historical name, **ForgeSweep Release Signing**, is intentionally preserved. Renaming or regenerating it would create a different signing identity. `signing/release.cer` and `signing/release.plist` are public; the private key, encrypted PKCS#12 backup and passwords stay outside Git.

This policy provides stable code identity. These releases are **not Apple Developer ID-signed or notarized**, and no code-signing check can guarantee macOS privacy-grant retention. Migration from local/ad-hoc signing or the former ForgeSweep bundle may require one-time reauthorization. Cross-version retention on a separate Mac is currently unverified. `script/release.sh` is a separate, opt-in Developer ID/notarization path; do not use it to silently change an existing public release's identity.

## Maintain the original private key

On the original publisher Mac, reuse the archived identity:

```bash
bash script/release_identity.sh ensure
bash script/package_release.sh
```

The private archive is `~/Library/Application Support/Nori/release-signing/identity.p12`; its password is in `identity-password` beside it. `init` is only for an unpublished project with no committed identity. In this repository it refuses to generate a replacement if the key is missing. Restore the original backup on another Mac instead.

Export an encrypted backup to a new private directory outside the repository:

```bash
bash script/release_identity.sh export "$HOME/Nori-release-backup"
```

The exported directory holds the encrypted PKCS#12, Base64 representation and password. Its restrictive file permissions do not encrypt the backup medium; store it on an encrypted backup volume. Never upload these files to releases, CI artifacts, caches or logs.

To restore from that backup, pass the secrets through the process environment, with tracing off:

```bash
set +x
FORGESWEEP_SIGNING_P12_BASE64="$(cat "$HOME/Nori-release-backup/signing-certificate.base64")" \
FORGESWEEP_SIGNING_P12_PASSWORD="$(cat "$HOME/Nori-release-backup/signing-password")" \
  bash script/release_identity.sh import
```

The importer validates the original certificate pin and matching private key before persisting anything. Local imports configure code-signing trust on the publisher's machine; temporary CI trust is described below. End users do not install this certificate.

## GitHub Actions and release assets

Repository Actions secrets are `FORGESWEEP_SIGNING_P12_BASE64` and `FORGESWEEP_SIGNING_P12_PASSWORD`. Keep their legacy names to reuse the existing identity. On a repository without these secrets, `bash script/configure_release_secrets.sh` uploads them from the local archive without logging their values. It refuses to overwrite either existing secret.

The **Signed macOS release** workflow uses a GitHub-hosted `macos-15` runner and the stable Xcode 26.2 toolchain. It never creates signing keys and never falls back to ad-hoc signing.

CI signing supports only disposable GitHub-hosted runners. Before adding its dedicated release keychain, the importer records the runner user's existing keychain search list, then temporarily adds the release keychain to that list. It uses `sudo -n` to configure temporary, code-signing-only trust in the administrator domain. This setup is not intended for self-hosted machines.

An imported identity is accepted only after an actual signing probe succeeds: the importer copies a Mach-O executable, signs that copy with the fixed certificate fingerprint, the `com.nori.app` identifier, an explicit `--keychain`, `--options runtime` and `--timestamp=none`, then verifies the signature. It also extracts the signing leaf certificate and checks its fingerprint, and compares the probe's entire designated requirement with the fixed release identity. Merely finding an identity in the keychain is insufficient. The probe does not change the app's pinned bundle identifier, certificate or designated requirement.

Trust and keychain commands have bounded execution times. A provisioning timeout, failed signing probe or identity mismatch stops the release instead of accepting an unverified identity. The `always()` cleanup step first restores the recorded search list, then removes temporary code-signing trust, the dedicated keychain and private files. Only a timeout while removing administrator trust for the public certificate on a verified, disposable GitHub-hosted runner becomes an explicit warning: the runner VM's teardown removes the remaining public trust. Other trust errors, search-list restoration failures, keychain deletion failures or private-file removal failures still stop the release. Cleanup does not delete the publisher's locally archived private key.

For each release:

1. Commit the complete, tested product source, public signing policy, README/screenshots and release notes. A tag must describe that committed source; do not attach an uncommitted build to an older tag.
2. Update `CFBundleShortVersionString` and `CFBundleVersion` in `SimpleMole/Support/Info.plist`, and add bilingual `docs/releases/v<version>.md` notes. The workflow rejects a tag that differs from the embedded app version.
3. Push reviewed source to the default branch. A manual workflow run on that branch builds an artifact for inspection without creating a Release.
4. Tag the exact commit, for example `v1.0.0`, and push that tag. The tag workflow creates a draft Release using the checked-in notes. Publishing that draft is a separate maintainer action; an explicit release request can authorize it.

Each Release includes `Nori-arm64.dmg`, `Nori-x86_64.dmg`, `RELEASE-IDENTITY.txt` and `SHA256SUMS`. The identity file records the exact source commit, version, certificate fingerprint and entire verified designated requirement for both architectures. Before importing secrets for a later release, CI compares the repository policy with the latest published identity file. Changing both the certificate and its committed pin cannot silently pass this continuity check. Existing Release attachments are never overwritten automatically.

Check downloads with:

```bash
shasum -a 256 -c SHA256SUMS
bash script/verify_release.sh /Applications/Nori.app
# When both app bundles are available:
bash script/verify_release.sh /path/to/New/Nori.app --previous-app /path/to/Old/Nori.app
```

These checks establish file integrity and stable code identity, not Gatekeeper acceptance or privacy-grant retention. A recommended user-environment test is to download and install a quarantined DMG on a separate Mac that does not trust the publisher certificate, grant permissions, then replace it with the next fixed-signature build and exercise those features again. Record whether this test was performed instead of claiming unverified permission retention.

## Local installation updates

`script/install_update.sh` detects the pinned certificate on an installed public release and automatically selects its original keychain for the update. A conflicting identity, missing release private key, ad-hoc opt-in or changed designated requirement stops before replacing the installation. It verifies the staged destination copy, preserves the previous app until the replacement verifies and restores it on an installation-verification failure.

For the first migration from a local development build to the fixed public identity:

```bash
SM_CODESIGN_IDENTITY=ABF7136A66689BF6437F7C4252A3168401FF33F6 \
  bash script/install_update.sh
```

This intentional first change may require reauthorization. Later `install_update.sh` runs preserve the installed public identity without an override. The app remains self-signed; if first launch is blocked, use System Settings → Privacy & Security → Open Anyway where available, without disabling Gatekeeper.

---

# 中文：无 Apple 开发者账号的 GitHub 发布

项目使用一份固定的自签名证书签署公开版本。`signing/release.cer` 是可以公开的 DER 证书，`signing/release.plist` 记录证书指纹、Bundle ID 和签名名称；私钥及其密码始终留在仓库之外。每个版本都必须使用同一份私钥和证书，不能在 GitHub Actions 每次构建时重新生成。

固定签名让版本更新保持相同的代码签名身份，但不能替代 Apple Developer ID 或公证，也不能保证所有 macOS 版本都保留全部隐私授权。从以前的 ad-hoc、本地开发证书或其他发布证书迁移过来时，用户可能需要重新授权一次。

## 只初始化一次，之后复用

首次建立项目发布身份、且仓库尚未包含固定公开证书时，由维护者在自己的 Mac 上执行一次：

```bash
bash script/release_identity.sh init
```

私有归档存放于 `~/Library/Application Support/Nori/release-signing/identity.p12`，密码文件为同目录的 `identity-password`。产品由 ForgeSweep 更名为 Nori 后，`ensure`/`init` 会一次性把旧 ForgeSweep 路径下的归档搬移到新路径（显式设置 `SM_RELEASE_SIGNING_DIR` 的 CI 目录不受影响）。初始化同时生成仓库内可以公开的证书与身份记录。仓库已有公开证书但本机缺少私钥时，`init` 会故意拒绝生成新的身份；新维护者或新 Mac 必须导入原来的备份。发布证书 CN 为历史名称 "ForgeSweep Release Signing"，属于已固定发布的身份，不做更换。后续构建通常先确保原身份可用，再打包：

```bash
bash script/release_identity.sh ensure
bash script/package_release.sh
```

请先建立加密备份，再对外发布第一个版本。下面的目标目录必须尚不存在，而且必须在 Git 仓库之外；可以将它换成你的加密备份卷路径：

```bash
bash script/release_identity.sh export "$HOME/Nori-release-backup"
```

导出目录包含 `signing-certificate.p12`、`signing-certificate.base64` 和 `signing-password`，用于备份及配置 GitHub Secrets。脚本限制目录和文件的访问权限，但这不等同于备份介质加密；应妥善保管整个目录。

在新 Mac 上，可从相同导出目录恢复身份，秘密只传入进程环境，不要把实际内容写进命令或日志：

```bash
set +x
FORGESWEEP_SIGNING_P12_BASE64="$(cat "$HOME/Nori-release-backup/signing-certificate.base64")" \
FORGESWEEP_SIGNING_P12_PASSWORD="$(cat "$HOME/Nori-release-backup/signing-password")" \
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
2. 在 **Actions → Signed macOS release → Run workflow** 选择默认分支试跑。手动运行只生成 `Nori-macos` artifact，不发布 GitHub Release。
3. 下载 artifact，检查 Apple 芯片和 Intel 两个 DMG。先更新 `Info.plist` 中的版本与构建号，并提交 `docs/releases/v<版本>.md` 双语说明；标签必须与 App 内的版本完全一致，例如版本 `1.0.1` 对应 `v1.0.1`。标签指向的源码必须完整包含实际发布功能，不能用旧提交的标签发布未提交的构建。
4. 标签构建成功后会创建 **draft Release**，附上两个 DMG、`RELEASE-IDENTITY.txt` 和 `SHA256SUMS`，采用仓库中已提交的更新说明。确认构建与安装验证结果后，由维护者公开草稿；明确的发布请求可授权这一步。跨版本授权在另一台 Mac 上尚未验证，应如实记录。

`RELEASE-IDENTITY.txt` 记录源码提交、版本、证书指纹及两个架构的完整 designated requirement。后续 CI 导入秘密前会与最新公开版本的身份记录对比；即使误改了公开证书及其指纹，也不能静默改变已发布身份。`install_update.sh` 遇到已安装的固定公开版本时自动复用原证书，拒绝切回本地/ad-hoc 签名，在替换前对比新旧身份、验证暂存副本，并在安装验签失败时恢复原版本。

已有同名 Release 时，工作流不会覆盖其附件。排查失败后重试前，先检查是否已经产生该标签的草稿。

CI 使用 `macos-15` 和 `/Applications/Xcode_26.2.app/Contents/Developer`，串行交叉编译 `arm64`、`x86_64` 两种架构。它先跑回归检查并验证版本/身份连续性，再导入私钥、打包和校验，最后清理临时钥匙串；上传范围只包含两个 DMG、公开身份记录与校验和。该工作流不接受 pull request 事件，手动运行限定默认分支。仅向经过审核的分支和标签开放发布权限；建议用 GitHub rulesets 保护默认分支和 `v*` 标签。

CI 签名仅支持一次性的 GitHub-hosted runner。导入脚本先记录 runner 用户已有的钥匙串搜索列表，再把专用发布钥匙串临时加入列表，并使用 `sudo -n` 在管理员域临时加入仅限代码签名的证书信任；此分支不适用于自托管机器。

导入身份只有通过实际签名探针后才会被接受：脚本复制一个 Mach-O 可执行文件，用固定证书指纹、`com.nori.app` 标识、显式 `--keychain`、`--options runtime` 和 `--timestamp=none` 签署副本，再验证签名。它还会提取签名叶证书、核对指纹，并将探针的完整 designated requirement 与固定发布身份比较。只在钥匙串中找到身份不能证明签名可用。这项探针检查不会改变 App 已固定的 Bundle ID、证书或 designated requirement。

信任与钥匙串命令都有执行时间上限。配置身份时命令超时、签名探针失败或身份不匹配都会停止发布，不会接受未经验证的身份。`always()` 清理步骤先恢复已记录的搜索列表，再移除临时代码签名信任、专用钥匙串和私有文件。只有在已验证的一次性 GitHub-hosted runner 上，撤销公开证书的管理员域信任超时，才会明确发出警告，由 runner 虚拟机销毁时移除剩余公开信任。其他信任错误、搜索列表恢复失败、钥匙串删除失败或私有文件删除失败仍会停止发布。本机长期归档的私钥不会由 CI 的 `cleanup` 删除。

若 GitHub 从 runner 镜像移除固定的 Xcode 路径，流程会明确失败。维护者应查阅 [runner 镜像清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md)，验证替代稳定版本后再更新工作流，不要自动回退到未经验证的 beta SDK。

## 安装和升级验证

用户从 DMG 将 `Nori.app` 拖到 `/Applications`。旧版 `ForgeSweep.app` 不会在相同位置覆盖升级：首次启动新版会自动迁移偏好与数据，建议确认功能正常后手动删除旧的 `ForgeSweep.app`；因 Bundle ID 变化，完全磁盘访问与屏幕录制等系统权限需重新授予一次。首次打开若因未经公证而被拦截，可尝试“系统设置 → 隐私与安全性 → 仍要打开”。无需给用户安装你的证书，也不应要求他们关闭 Gatekeeper。

推荐在另一台未导入、未信任发布证书的 Mac 上验证，使用浏览器下载 DMG 并保留系统的下载隔离标记，模拟真实用户安装。先安装旧版固定签名 App，授予完全磁盘访问与屏幕录制权限并使用对应功能，退出后以同样方式下载、覆盖安装同证书签署的新版，再确认打开流程、权限与功能。这里的旧版也必须来自同一个发布身份；本机 ad-hoc 构建不能用于证明跨版本授权保留。当前尚未在另一台 Mac 验证这项行为，请不要把固定签名表述成所有 macOS 授权必然保留的保证。

下载后可以在两个 DMG 与 `SHA256SUMS` 所在目录检查文件完整性：

```bash
shasum -a 256 -c SHA256SUMS
```

若拥有源码中的固定公开证书，还可以对安装包内的 App 执行身份检查：

```bash
bash script/verify_release.sh /Applications/Nori.app
```

此检查成功只证明签名有效且应用的指定要求（designated requirement）符合固定身份；不能证明 Gatekeeper 会放行，或 macOS 隐私授权会在升级后保留，后两项仍需上述真实安装验证。
