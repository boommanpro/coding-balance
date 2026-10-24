import SwiftUI

/// 设置窗口：账户列表 + 增删改
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var editor: AccountEditor?
    @State private var launchError: String?
    @State private var proxyURL = UserDefaults.standard.string(forKey: VeniceProvider.proxyDefaultsKey) ?? ""
    @State private var savedProxyURL = (UserDefaults.standard.string(forKey: VeniceProvider.proxyDefaultsKey) ?? "")
        .trimmingCharacters(in: .whitespaces)
    @State private var proxySaved = false

    /// 保存代理配置到 UserDefaults；下次刷新生效
    private func saveProxy() {
        let trimmed = proxyURL.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: VeniceProvider.proxyDefaultsKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: VeniceProvider.proxyDefaultsKey)
        }
        savedProxyURL = trimmed
        proxySaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { proxySaved = false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("账户管理")
                .font(.title2.weight(.semibold))

            if appState.accounts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.2.slash")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("暂无账户")
                        .font(.headline)
                    Text("添加火山方舟或 Venice 账户，配置凭据后即可在菜单栏查看额度/余额。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                List {
                    ForEach(appState.accounts) { account in
                        HStack(spacing: 10) {
                            Image(systemName: "person.crop.circle.fill")
                                .foregroundColor(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.name.isEmpty ? account.provider.displayName : account.name)
                                    .font(.body.weight(.medium))
                                Text("\(account.provider.displayName) · \(account.credentialPreview)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            if let error = appState.errors[account.id] {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                    .help(error)
                            } else if appState.balances[account.id] != nil {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            }
                        }
                        .contextMenu {
                            Button("编辑") { editor = AccountEditor(account: account) }
                            Button("删除", role: .destructive) { appState.deleteAccount(account) }
                        }
                    }
                    .onDelete { offsets in
                        offsets.map { appState.accounts[$0] }.forEach { appState.deleteAccount($0) }
                    }
                }
                .frame(minHeight: 180)
            }

            HStack {
                Button {
                    editor = AccountEditor(account: nil)
                } label: {
                    Label("添加账户", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)

                Button("刷新全部") { appState.refreshAll() }
                    .disabled(appState.accounts.isEmpty)

                Spacer()

                Button("退出登录全部") {
                    appState.logoutAll()
                }
                .disabled(appState.accounts.isEmpty)
                .foregroundColor(.secondary)
            }

            Divider()

            GroupBox {
                Toggle("开机自启动", isOn: Binding(
                    get: { appState.launchAtLoginEnabled },
                    set: { enabled in
                        if let error = appState.setLaunchAtLogin(enabled) {
                            launchError = error
                        }
                    }
                ))
                .toggleStyle(.switch)
                .help("登录 macOS 后自动启动本应用")

                Text("登录 macOS 后自动在菜单栏启动本应用。\n需将应用放置于「应用程序」文件夹后该功能才会生效（当前路径：\(Bundle.main.bundlePath)）。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 2)

                Divider().padding(.vertical, 6)

                HStack {
                    TextField("网络代理（可选）", text: $proxyURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .help("例如 http://127.0.0.1:7897；仅 Venice 请求使用，留空走系统代理")
                    Button(proxySaved ? "已保存" : "保存") {
                        saveProxy()
                    }
                    .disabled(proxyURL.trimmingCharacters(in: .whitespaces) == savedProxyURL)
                }
                Text("仅 Venice 请求使用（api.venice.ai 需可直连或经代理访问）；留空时跟随系统代理，修改后下次刷新生效。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
            } label: {
                Label("通用", systemImage: "gearshape.2")
            }
        }
        .padding(20)
        .frame(width: 560)
        .alert("无法设置开机自启动", isPresented: Binding(
            get: { launchError != nil },
            set: { if !$0 { launchError = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(launchError ?? "")
        }
        .sheet(item: $editor) { editor in
            AccountEditorView(account: editor.account) { account, validated in
                Task {
                    try? await appState.upsertAccount(account, validateFirst: validated)
                }
                self.editor = nil
            }
        }
    }
}

/// 用于 sheet(item:) 的编辑态包装
struct AccountEditor: Identifiable {
    let id = UUID()
    var account: Account?
}

// MARK: - 账户编辑表单

struct AccountEditorView: View {
    let account: Account?
    let onSave: (Account, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var provider: ProviderKind
    @State private var accessKey: String
    @State private var secretKey: String
    @State private var apiKey: String
    @State private var isTesting = false
    @State private var testResult: String?
    @State private var testSuccess = false

    init(account: Account?, onSave: @escaping (Account, Bool) -> Void) {
        self.account = account
        self.onSave = onSave
        _name = State(initialValue: account?.name ?? "")
        _provider = State(initialValue: account?.provider ?? .ark)
        _accessKey = State(initialValue: account?.accessKey ?? "")
        _secretKey = State(initialValue: account?.secretKey ?? "")
        _apiKey = State(initialValue: account?.apiKey ?? "")
    }

    private var isEditing: Bool { account != nil }
    private var canSave: Bool {
        switch provider {
        case .ark:
            return !accessKey.trimmingCharacters(in: .whitespaces).isEmpty &&
                !secretKey.trimmingCharacters(in: .whitespaces).isEmpty
        case .venice:
            return !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isEditing ? "编辑账户" : "添加账户")
                .font(.title3.weight(.semibold))

            Form {
                TextField("账户名称（可选）", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .help("例如：我的 Pro 套餐")

                Picker("平台", selection: $provider) {
                    ForEach(ProviderKind.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .disabled(isEditing) // 暂不允许切换平台，后续扩展

                switch provider {
                case .ark:
                    SecureField("Access Key ID", text: $accessKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))

                    SecureField("Secret Access Key", text: $secretKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))

                case .venice:
                    SecureField("API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))

                    Text("在 venice.ai/settings/api 生成；Inference / Admin 类型均可查询余额与限流。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let testResult = testResult {
                    Label(testResult, systemImage: testSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(testSuccess ? .green : .red)
                }
            }

            HStack {
                Button(isTesting ? "测试中…" : "测试连接") {
                    testConnection()
                }
                .disabled(isTesting || !canSave)

                Spacer()

                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("保存") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func testConnection() {
        guard canSave else { return }
        isTesting = true
        testResult = nil
        let candidate = buildAccount()
        Task {
            do {
                try await makeProvider(candidate.provider).validate(account: candidate)
                await MainActor.run {
                    testResult = "连接成功，凭据有效"
                    testSuccess = true
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testResult = (error as? ProviderError)?.errorDescription ?? error.localizedDescription
                    testSuccess = false
                    isTesting = false
                }
            }
        }
    }

    private func buildAccount() -> Account {
        Account(id: account?.id ?? UUID(),
                name: name.trimmingCharacters(in: .whitespaces),
                provider: provider,
                accessKey: accessKey.trimmingCharacters(in: .whitespaces),
                secretKey: secretKey.trimmingCharacters(in: .whitespaces),
                apiKey: provider == .venice ? apiKey.trimmingCharacters(in: .whitespaces) : nil)
    }

    private func save() {
        onSave(buildAccount(), false)
    }
}
