import SwiftUI

/// 设置窗口：账户列表 + 增删改
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var editor: AccountEditor?

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
                    Text("添加一个火山方舟账户，配置 AK/SK 后即可在菜单栏查看余额。")
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
                                Text("\(account.provider.displayName) · \(account.accessKey)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
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
        }
        .padding(20)
        .frame(width: 560)
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
    }

    private var isEditing: Bool { account != nil }
    private var canSave: Bool {
        !accessKey.trimmingCharacters(in: .whitespaces).isEmpty &&
        !secretKey.trimmingCharacters(in: .whitespaces).isEmpty
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

                SecureField("Access Key ID", text: $accessKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                SecureField("Secret Access Key", text: $secretKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

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
                secretKey: secretKey.trimmingCharacters(in: .whitespaces))
    }

    private func save() {
        onSave(buildAccount(), false)
    }
}
