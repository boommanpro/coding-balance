import SwiftUI

/// 菜单栏详情弹窗（左键点击菜单栏状态项弹出）
struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @State private var tab: MenuTab

    init(initialTab: MenuTab = .balance) {
        _tab = State(initialValue: initialTab)
    }

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
                // 内容区始终略高于可视高度，保证可滚动以支持下拉刷新
                .frame(minHeight: 470, alignment: .top)
                .padding(.horizontal, 2)
                .padding(.bottom, 6)
            }
            .refreshable { await appState.refreshAllAwait() }

            Divider().padding(.vertical, 10)
            footer
        }
        .padding(14)
        // 固定内容尺寸：账户切换/加载态变化不再引起弹窗尺寸变化与重锚定漂移
        .frame(width: 400, height: 560)
        .onAppear {
            appState.log("弹窗打开 账户=\(appState.accounts.count) 快照=\(appState.balances.count) 菜单栏=「\(appState.menuBarText)」")
        }
    }

    @ViewBuilder
    private var balanceContent: some View {
        // 已禁用的账户不在此展示：全部禁用时给出空态（区别于「尚未配置」）
        if appState.enabledAccounts.isEmpty {
            EmptyConfigView(allDisabled: !appState.accounts.isEmpty)
        } else {
            if appState.enabledAccounts.count > 1 { accountPicker }
            if let active = appState.activeAccount {
                accountDetail(active)
            }
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 8) {
            BrandLogoView(size: 20)
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
                    guard let id = id, let account = appState.enabledAccounts.first(where: { $0.id == id }) else { return }
                    appState.setActiveAccount(account)
                }
            )) {
                ForEach(appState.enabledAccounts) { account in
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
            if snapshot.plan == .credit {
                CreditBalanceCard(account: account, snapshot: snapshot)
            } else {
                heroCard(account: account, snapshot: snapshot)
                windowList(snapshot: snapshot)
            }
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

    // MARK: 底部

    private var footer: some View {
        HStack {
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

// MARK: - 按量余额卡（Venice 等信用型账户）

/// 信用型账户主卡：大号主余额 + 可消费状态 + 账户信息行 + 各币种余额明细
struct CreditBalanceCard: View {
    let account: Account
    let snapshot: BalanceSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let primary = snapshot.primaryCredit {
                    // 大字只放金额，类型用小字标注，避免「附赠 $77.51」整串大号太占宽度
                    Text(formatUSD(primary.amount))
                        .font(.system(.title, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .lineLimit(1)
                    Text(primary.label.hasPrefix("附赠") ? "附赠额度" : "余额")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("$ —")
                        .font(.system(.title, design: .rounded).weight(.bold))
                        .foregroundColor(.secondary)
                }
                Spacer()
                consumeBadge
            }
            Text(subtitleLine)
                .font(.caption)
                .foregroundColor(.secondary)
            Divider()
            ForEach(snapshot.credits ?? []) { credit in
                HStack {
                    Text(credit.label)
                        .font(.callout)
                    Spacer()
                    Text(credit.displayText)
                        .font(.system(.callout, design: .monospaced))
                }
            }
            if let epoch = parseISODate(snapshot.nextEpochBegins) {
                Text("限额周期重置 \(Self.epochFormatter.string(from: epoch))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            // 账单日为用户按账户自定义（接口不下发），未设置时不展示
            if let cycle = account.billingCycle {
                BillingCycleView(cycle: cycle)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private static let epochFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm"
        fmt.timeZone = .current
        return fmt
    }()

    /// 可消费状态徽标
    @ViewBuilder
    private var consumeBadge: some View {
        switch snapshot.canConsume {
        case .some(true):
            HStack(spacing: 4) {
                Circle().fill(.green).frame(width: 6, height: 6)
                Text("可消费").font(.caption)
            }
            .foregroundColor(.secondary)
        case .some(false):
            HStack(spacing: 4) {
                Circle().fill(.red).frame(width: 6, height: 6)
                Text("不可消费").font(.caption)
            }
            .foregroundColor(.red)
        case .none:
            EmptyView()
        }
    }

    /// 账户信息行：账户名 · 层级 · Key 到期
    private var subtitleLine: String {
        var parts = [account.shortLabel]
        if let tier = snapshot.tier, !tier.isEmpty {
            parts.append(tier.lowercased() == "paid" ? "付费层" : "\(tier) 层")
        }
        if let end = parseISODate(snapshot.endTime) {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            parts.append("到期 \(fmt.string(from: end))")
        } else {
            parts.append("Key 永久有效")
        }
        return parts.joined(separator: " · ")
    }
}

/// 月度账单周期行：本期起止 + 已过进度 + 距刷新天数（如 Venice 附赠额度按月刷新）
struct BillingCycleView: View {
    let cycle: BillingCycle

    private static let dayFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd"
        fmt.timeZone = .current
        return fmt
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("账单周期")
                    .font(.callout)
                Spacer()
                Text("\(Self.dayFormatter.string(from: cycle.start)) ~ \(Self.dayFormatter.string(from: cycle.lastDay))")
                    .font(.system(.callout, design: .monospaced))
            }
            RatioBar(fraction: CGFloat(cycle.elapsedFraction), color: .accentColor)
            HStack {
                Text("本期已过 \(Int((cycle.elapsedFraction * 100).rounded()))%")
                Spacer()
                Text("还有 \(cycle.daysRemaining) 天刷新")
            }
            .font(.caption2)
            .foregroundColor(.secondary)
        }
        .padding(.top, 4)
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
            RatioBar(fraction: CGFloat(window.ratio), color: ratioColor(window.ratio))
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

/// 细比例条（fraction 会被夹到 0...1），额度窗口 / 账单周期共用
struct RatioBar: View {
    let fraction: CGFloat
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.gray.opacity(0.2))
                Capsule()
                    .fill(color)
                    .frame(width: max(0, geo.size.width * CGFloat(min(max(fraction, 0), 1))))
            }
        }
        .frame(height: 6)
    }
}

// MARK: - 未配置状态

struct EmptyConfigView: View {
    @EnvironmentObject var appState: AppState
    /// true：已有账户但全部被禁用（文案与入口不同）
    var allDisabled = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: allDisabled ? "pause.circle" : "gearshape")
                .font(.system(size: 30))
                .foregroundColor(.secondary)
            Text(allDisabled ? "所有账户均已禁用" : "尚未配置任何账户")
                .font(.headline)
            Text(allDisabled ? "在「管理账户」中启用账户后，\n菜单栏将恢复显示额度与余额。"
                             : "添加火山方舟或 Venice 账户后，\n菜单栏将实时显示剩余额度与余额。")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button(allDisabled ? "管理账户…" : "添加账户…") {
                appState.openSettings()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}
