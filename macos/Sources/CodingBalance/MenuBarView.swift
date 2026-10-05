import SwiftUI

/// 菜单栏详情弹窗（左键点击菜单栏状态项弹出）
struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @State private var tab: MenuTab = .balance

    enum MenuTab: String, CaseIterable, Identifiable {
        case balance = "额度"
        case models = "模型"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Picker("", selection: $tab) {
                ForEach(MenuTab.allCases) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.top, 8)

            Divider().padding(.vertical, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch tab {
                    case .balance: balanceContent
                    case .models: ModelsView()
                    }
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 6)
            }

            Divider().padding(.vertical, 10)
            footer
        }
        .padding(14)
        .frame(width: 400)
        .onAppear {
            appState.log("弹窗打开 账户=\(appState.accounts.count) 快照=\(appState.balances.count) 菜单栏=「\(appState.menuBarText)」")
        }
    }

    @ViewBuilder
    private var balanceContent: some View {
        if appState.accounts.isEmpty {
            EmptyConfigView()
        } else {
            if appState.accounts.count > 1 { accountPicker }
            if let active = appState.activeAccount {
                accountDetail(active)
            }
            if appState.accounts.count > 1 { accountOverview }
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "fuelpump.fill")
                .font(.system(size: 14))
                .foregroundColor(.accentColor)
            Text("Coding Balance")
                .font(.headline)
            if appState.isRefreshing {
                ProgressView().controlSize(.small)
            }
            Spacer()
            if let t = appState.lastRefresh {
                Text("更新于 \(formatTime(Int64(t.timeIntervalSince1970 * 1000)))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: 账户选择器

    private var accountPicker: some View {
        HStack {
            Text("当前使用账户")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Picker("", selection: Binding(
                get: { appState.activeAccountID },
                set: { id in
                    guard let id = id, let account = appState.accounts.first(where: { $0.id == id }) else { return }
                    appState.setActiveAccount(account)
                }
            )) {
                ForEach(appState.accounts) { account in
                    Text(account.shortLabel).tag(Optional(account.id))
                }
            }
            .labelsHidden()
            .frame(width: 160)
        }
    }

    // MARK: 账户详情

    @ViewBuilder
    private func accountDetail(_ account: Account) -> some View {
        if let error = appState.errors[account.id] {
            VStack(alignment: .leading, spacing: 8) {
                Label("数据获取失败", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundColor(.red)
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                Button("重试") { appState.refreshAll() }
                    .buttonStyle(.bordered)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
        } else if let snapshot = appState.balances[account.id] {
            heroCard(account: account, snapshot: snapshot)
            windowList(snapshot: snapshot)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在加载 \(account.shortLabel) 的额度…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 10)
        }
    }

    /// 主视觉卡片：近5小时剩余圆环
    private func heroCard(account: Account, snapshot: BalanceSnapshot) -> some View {
        HStack(spacing: 16) {
            RingView(remaining: snapshot.fiveHour?.remainingPercent ?? 0, size: 76, lineWidth: 9) {
                VStack(spacing: 0) {
                    Text("\(Int((snapshot.fiveHour?.remainingPercent ?? 0).rounded()))%")
                        .font(.system(.title2, design: .rounded).weight(.bold))
                    Text("5h剩余")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(account.shortLabel)
                    .font(.headline)
                Text(planLine(snapshot))
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 6) {
                    statPill(icon: "calendar.badge.clock", label: "周剩 \(Int((snapshot.weekly?.remainingPercent ?? 0).rounded()))%")
                    statPill(icon: "calendar", label: "月剩 \(Int((snapshot.monthly?.remainingPercent ?? 0).rounded()))%")
                }
            }
            Spacer()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func planLine(_ snapshot: BalanceSnapshot) -> String {
        var parts: [String] = []
        parts.append(snapshot.plan == .codingPlan ? "Coding Plan" : "Agent Plan")
        if let planType = snapshot.planType { parts.append(planType) }
        parts.append(planStatusText(snapshot.status))
        if let end = snapshot.endTime {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            let iso = ISO8601DateFormatter()
            let d = iso.date(from: end) ?? Date()
            parts.append("到期 \(fmt.string(from: d))")
        }
        return parts.joined(separator: " · ")
    }

    private func statPill(icon: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text(label).font(.caption2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
        .foregroundColor(.secondary)
    }

    /// 三个额度窗口明细
    private func windowList(snapshot: BalanceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("额度明细")
                .font(.caption)
                .foregroundColor(.secondary)
            if let f = snapshot.fiveHour { WindowRowView(title: "近5小时", window: f) }
            if let w = snapshot.weekly { WindowRowView(title: "近一周", window: w) }
            if let m = snapshot.monthly { WindowRowView(title: "近一月", window: m) }
            if !snapshot.hasAnyWindow {
                Text("暂无额度数据")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: 多账户总览

    private var accountOverview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("全部账户")
                .font(.caption)
                .foregroundColor(.secondary)
            ForEach(appState.accounts) { account in
                Button {
                    appState.setActiveAccount(account)
                } label: {
                    HStack {
                        Image(systemName: appState.activeAccountID == account.id ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(appState.activeAccountID == account.id ? .accentColor : .secondary)
                        Text(account.shortLabel)
                            .font(.callout)
                        Spacer()
                        if let snap = appState.balances[account.id], let five = snap.fiveHour {
                            Text("5h 剩 \(Int(five.remainingPercent.rounded()))%")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(five.remainingPercent < 20 ? .red : .primary)
                        } else if appState.balances[account.id] != nil {
                            Text("—").font(.caption).foregroundColor(.secondary)
                        } else {
                            Text("加载中…").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: 底部

    private var footer: some View {
        HStack {
            Button {
                appState.refreshAll()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(appState.isRefreshing || appState.accounts.isEmpty)

            Spacer()

            Button {
                appState.openSettings()
            } label: {
                Label("管理账户…", systemImage: "gearshape")
            }

            Button {
                appState.quit()
            } label: {
                Label("退出", systemImage: "power")
            }
            .foregroundColor(.secondary)
        }
    }
}

// MARK: - 圆形剩余指示（弹窗内大号版）

struct RingView<Content: View>: View {
    let remaining: Double
    var size: CGFloat = 76
    var lineWidth: CGFloat = 9
    let content: Content

    init(remaining: Double, size: CGFloat = 76, lineWidth: CGFloat = 9,
         @ViewBuilder content: () -> Content) {
        self.remaining = remaining
        self.size = size
        self.lineWidth = lineWidth
        self.content = content()
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.gray.opacity(0.22), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(1, remaining / 100))))
                .stroke(ringColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            content
        }
        .frame(width: size, height: size)
    }

    private var ringColor: Color {
        switch remaining {
        case ..<20: return .red
        case ..<50: return .orange
        default: return .green
        }
    }
}

// MARK: - 额度窗口行

struct WindowRowView: View {
    let title: String
    let window: PlanWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.callout)
                Spacer()
                if window.hasAbsolute, let used = window.used, let quota = window.quota {
                    Text("已用 \(formatFull(used)) / \(formatFull(quota)) AFP")
                        .font(.system(.caption, design: .monospaced))
                } else {
                    Text("已用 \(Int(window.usedPercent.rounded()))% · 剩余 \(Int(window.remainingPercent.rounded()))%")
                        .font(.system(.caption, design: .monospaced))
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gray.opacity(0.2))
                    Capsule()
                        .fill(ratioColor(window.ratio))
                        .frame(width: max(0, geo.size.width * CGFloat(min(max(window.ratio, 0), 1))))
                }
            }
            .frame(height: 6)
            HStack {
                Text("下次重置 \(formatTime(window.resetTime))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
    }

    private func ratioColor(_ ratio: Double) -> Color {
        switch ratio {
        case ..<0.7: return .green
        case ..<0.9: return .orange
        default: return .red
        }
    }
}

// MARK: - 未配置状态

struct EmptyConfigView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "gearshape")
                .font(.system(size: 30))
                .foregroundColor(.secondary)
            Text("尚未配置任何账户")
                .font(.headline)
            Text("添加火山方舟账户并配置 AK/SK 后，\n菜单栏将实时显示近5小时剩余额度。")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("添加账户…") {
                appState.openSettings()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}
