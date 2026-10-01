import SwiftUI

/// Instantiated by the developer workbench. Entering the tab refreshes the
/// read-only snapshot; repairs and writes always need an explicit action.
struct DeveloperNetworkPanel: View {
    @ObservedObject var state: AppState
    let refreshToken: Int
    var isExpanded = true
    @ObservedObject private var l10n = L10n.shared
    @State private var snapshot: DeveloperNetworkService.Snapshot?
    @State private var isLoading = false
    @State private var isEditingHosts = false
    @State private var hostsDraft = ""
    @State private var isSavingHosts = false
    @State private var hostsStatus = ""
    @State private var hostsError: DeveloperNetworkService.HostsError?
    @State private var backupPath: String?
    @State private var externalChange = false
    @State private var completedRefreshToken: Int?

    private var chinese: Bool { l10n.resolved == .zhHans || l10n.resolved == .zhHant }
    private func text(_ zh: String, _ en: String) -> String { chinese ? zh : en }

    var body: some View {
        DeveloperWorkspaceContent(isExpanded: isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                if isLoading {
                    ProgressView(text("读取网络配置…", "Reading network configuration…"))
                        .controlSize(.small).font(.system(size: 11))
                }
                if let snapshot {
                    DeveloperNetworkServicesView(snapshot: snapshot, chinese: chinese)
                    hostsSection(snapshot.hosts)
                    if !snapshot.warnings.isEmpty {
                        Label(text("部分配置无法读取。", "Some settings are unavailable."), systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12)).foregroundStyle(Color.warning)
                    }
                }
                DeveloperNetworkRepairsView(state: state, chinese: chinese)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: refreshToken) {
            await refresh()
            guard !Task.isCancelled else { return }
            completedRefreshToken = refreshToken
        }
        .preference(key: DeveloperWorkspaceSearchKey.self, value: [
            .network: DeveloperWorkspaceSearchState(
                refreshToken: refreshToken,
                isSearching: completedRefreshToken != refreshToken || isLoading)
        ])
    }

    @ViewBuilder private func hostsSection(_ document: DeveloperNetworkService.HostsDocument?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("hosts", systemImage: "list.bullet.rectangle").font(.system(size: 14, weight: .semibold))
                Text("/etc/hosts").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                if let document {
                    Text(text("\(document.customEntryCount) 条自定义映射", "\(document.customEntryCount) custom mappings"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if let document {
                if isEditingHosts {
                    Text(text("影响所有应用；保存前备份并申请管理员授权。", "Affects all apps. Saving backs up the file and requests administrator access."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    TextEditor(text: $hostsDraft)
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 220, maxHeight: 340)
                        .accessibilityLabel(text("编辑 hosts 内容", "Edit hosts content"))
                        .disabled(isSavingHosts)
                    Text(text("127.0.0.1 api.local · 保留 localhost / broadcasthost。", "127.0.0.1 api.local · Keep localhost / broadcasthost."))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    if externalChange {
                        Label(text("文件已变更；草稿保留，重新载入后保存。", "File changed. Draft kept; reload before saving."), systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12)).foregroundStyle(Color.warning)
                        Button(text("放弃草稿并载入当前文件", "Discard draft and reload current file")) { reloadHosts() }
                            .buttonStyle(MolePlainButtonStyle()).foregroundStyle(Color.accentText)
                    }
                    HStack(spacing: 18) {
                        Button { requestSave(document) } label: {
                            Label(text("备份并保存…", "Back up & save…"), systemImage: "checkmark.circle")
                        }
                        .disabled(isSavingHosts || externalChange || hostsDraft == document.text)
                        .foregroundStyle(Color.accentText)
                        Button(text("取消编辑", "Cancel editing")) {
                            isEditingHosts = false
                            hostsError = nil
                            externalChange = false
                        }.disabled(isSavingHosts)
                        if isSavingHosts { ProgressView().controlSize(.small) }
                    }
                    .buttonStyle(MolePlainButtonStyle())
                    .font(.system(size: 12, weight: .medium))
                } else {
                    let lines = document.text.split(separator: "\n", omittingEmptySubsequences: false)
                    let isTruncated = lines.count > 12
                    Text(document.text.isEmpty ? text("文件为空", "Empty file") : lines.prefix(12).joined(separator: "\n"))
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Button {
                        hostsDraft = document.text
                        hostsError = nil
                        hostsStatus = ""
                        externalChange = false
                        isEditingHosts = true
                    } label: {
                        Label(isTruncated ? text("查看 / 编辑全部…", "View / edit all…") : text("编辑映射", "Edit mappings"),
                              systemImage: "pencil")
                    }
                    .buttonStyle(MolePlainButtonStyle())
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.accentText)
                }
            } else {
                Text(text("无法安全读取 hosts，编辑暂不可用。", "Hosts cannot be read safely. Editing is unavailable."))
                    .font(.system(size: 12)).foregroundStyle(Color.warning)
            }
            if let hostsError {
                Text(errorMessage(hostsError)).font(.system(size: 12)).foregroundStyle(Color.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !hostsStatus.isEmpty {
                Text(hostsStatus).font(.system(size: 12)).foregroundStyle(Color.success)
            }
            if let backupPath {
                Text(text("备份：", "Backup: ") + backupPath)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(16)
        .clipped()
        .modifier(ListRowGlass())
    }

    @MainActor private func refresh() async {
        isLoading = true
        let fresh = await DeveloperNetworkService.scan()
        guard !Task.isCancelled else { return }
        if isEditingHosts, let old = snapshot?.hosts, fresh.hosts?.fingerprint != old.fingerprint {
            externalChange = true
        } else if !isEditingHosts {
            hostsDraft = fresh.hosts?.text ?? ""
        }
        snapshot = fresh
        isLoading = false
    }

    private func reloadHosts() {
        guard let current = try? DeveloperNetworkService.readHosts(), let snapshot else { return }
        self.snapshot = .init(services: snapshot.services, resolverServers: snapshot.resolverServers,
                              hosts: current, warnings: snapshot.warnings.filter { $0 != "hosts" })
        hostsDraft = current.text
        externalChange = false
        hostsError = nil
    }

    private func requestSave(_ original: DeveloperNetworkService.HostsDocument) {
        do { try DeveloperNetworkService.validateHosts(hostsDraft) }
        catch { hostsError = error as? DeveloperNetworkService.HostsError ?? .saveFailed; return }
        let draft = hostsDraft
        state.confirmation = AppState.Confirmation(
            title: text("保存 hosts 映射？", "Save hosts mappings?"),
            message: text("此操作影响所有应用的域名解析。Nori 将备份当前 /etc/hosts，确认文件未被外部修改后保存你的内容，并申请管理员授权。保留的草稿不会自动执行 DNS 刷新。", "This affects name resolution in all apps. Nori backs up /etc/hosts, checks that it has not changed outside the editor, and saves your content with administrator authorization. DNS flushing remains a separate action."),
            confirmLabel: text("备份并保存", "Back up & save")) {
                isSavingHosts = true
                hostsError = nil
                Task { @MainActor in
                    defer { isSavingHosts = false }
                    do {
                        let saved = try await DeveloperNetworkService.saveHosts(draft, original: original)
                        backupPath = saved.backupPath
                        hostsStatus = text("已保存，可按需刷新 DNS。", "Saved. Flush DNS if needed.")
                        state.log(hostsStatus)
                        isEditingHosts = false
                        await refresh()
                    } catch {
                        let failure = error as? DeveloperNetworkService.HostsError ?? .saveFailed
                        hostsError = failure
                        externalChange = failure == .changedExternally
                    }
                }
            }
    }

    private func errorMessage(_ error: DeveloperNetworkService.HostsError) -> String {
        guard chinese else { return error.localizedDescription }
        switch error {
        case .unavailable: return "hosts 不是可安全编辑的系统文件，或当前无法读取。"
        case .tooLarge: return "hosts 超过 64 KB，暂不支持在此编辑。"
        case .invalidLine(let line): return "第 \(line) 行的 IP 地址或域名格式不正确。"
        case .protectedMapping: return "请保留 127.0.0.1 localhost、::1 localhost 和 255.255.255.255 broadcasthost。"
        case .changedExternally: return "hosts 已被其他应用修改。重新载入后再保存，当前草稿已保留。"
        case .saveFailed: return "hosts 未能保存，请检查管理员授权；当前草稿已保留。"
        case .skippedInTestMode: return "测试模式下不会修改系统配置。"
        }
    }
}

private struct DeveloperNetworkServicesView: View {
    let snapshot: DeveloperNetworkService.Snapshot
    let chinese: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(chinese ? "网络服务" : "Network services", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 14, weight: .semibold))
            if !snapshot.resolverServers.isEmpty {
                Text((chinese ? "当前解析器：" : "Active resolvers: ") + snapshot.resolverServers.joined(separator: " · "))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if snapshot.services.isEmpty {
                Text(chinese ? "没有可读取的网络服务。" : "No readable network services.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(snapshot.services) { service in
                DeveloperNetworkServiceRow(service: service, chinese: chinese)
            }
        }
        .padding(16)
        .clipped()
        .modifier(ListRowGlass())
    }
}

private struct DeveloperNetworkServiceRow: View {
    let service: DeveloperNetworkService.NetworkService
    let chinese: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(service.name).font(.system(size: 12, weight: .semibold))
                if !service.enabled { Text(chinese ? "已停用" : "Disabled").foregroundStyle(.secondary) }
                if !service.readable { Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.warning) }
                Spacer()
                Text(service.address ?? (chinese ? "未分配 IPv4" : "No IPv4 address"))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            Text("DNS · " + (!service.dnsReadable ? (chinese ? "无法读取" : "Unavailable") : service.dnsServers.isEmpty ? (chinese ? "自动 / DHCP" : "Automatic / DHCP") : service.dnsServers.joined(separator: " · ")))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if !service.proxiesReadable {
                Text(chinese ? "代理 · 部分配置无法读取" : "Proxy · Some settings unavailable")
                    .font(.system(size: 11)).foregroundStyle(Color.warning)
            } else if service.proxies.isEmpty {
                Text(chinese ? "代理 · 未启用 HTTP / HTTPS / SOCKS / PAC" : "Proxy · HTTP / HTTPS / SOCKS / PAC disabled")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ForEach(service.proxies) { proxy in
                    Text("\(proxy.kind) · \(proxy.endpoint)")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.warning)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 4).accessibilityElement(children: .combine)
    }
}

private struct DeveloperNetworkRepairsView: View {
    @ObservedObject var state: AppState
    let chinese: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(chinese ? "网络修复" : "Network repairs", systemImage: "wrench.and.screwdriver")
                .font(.system(size: 14, weight: .semibold))
            DeveloperNetworkRepairRow(
                title: chinese ? "域名解析仍指向旧地址" : "A hostname resolves to an old address",
                detail: chinese ? "刷新缓存，保留 DNS 与代理配置。" : "Flush cached lookups. Keeps DNS and proxy settings.",
                actionLabel: chinese ? "刷新 DNS…" : "Flush DNS…", symbol: "arrow.clockwise.circle",
                disabled: state.isNetworkToolRunning) { state.runAdminNetworkTask("dns") }
            DeveloperNetworkRepairRow(
                title: chinese ? "切换 VPN / 网络后无法连接" : "Cannot connect after switching a VPN or network",
                detail: chinese ? "刷新路由与 ARP；连接可能短暂中断。" : "Refresh routes and ARP. Connections may briefly drop.",
                actionLabel: chinese ? "刷新网络栈…" : "Refresh network stack…", symbol: "network.badge.shield.half.filled",
                disabled: state.isNetworkToolRunning) { state.runAdminNetworkTask("network-stack") }
            if state.isNetworkToolRunning {
                HStack { ProgressView().controlSize(.small); Text(chinese ? "正在执行网络操作…" : "Running network operation…") }
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else if !state.networkToolStatus.isEmpty {
                Text(state.networkToolStatus).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .clipped()
        .modifier(ListRowGlass())
    }
}

private struct DeveloperNetworkRepairRow: View {
    let title: String
    let detail: String
    let actionLabel: String
    let symbol: String
    let disabled: Bool
    let action: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(action: action) { Label(actionLabel, systemImage: symbol) }
                .buttonStyle(MolePlainButtonStyle()).foregroundStyle(Color.accentText)
                .font(.system(size: 12, weight: .medium)).disabled(disabled)
        }
    }
}
