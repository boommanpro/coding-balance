import AppKit
import Combine
import Foundation
import ServiceManagement
import SwiftUI

/// 全局应用状态：多账户 + 当前使用账户 + 余额缓存 + 定时刷新
/// 使用 AppKit NSStatusItem 渲染菜单栏（比 SwiftUI MenuBarExtra 稳定，任何 macOS 版本都可靠刷新）
@MainActor
final class AppState: NSObject, ObservableObject {

    @Published var accounts: [Account] = []
    @Published var balances: [UUID: BalanceSnapshot] = [:]
    @Published var errors: [UUID: String] = [:]
    /// 模型限流信息（QPS≈RPM/60）与价格缓存
    @Published var modelInfos: [UUID: [ModelInfo]] = [:]
    @Published var modelErrors: [UUID: String] = [:]
    @Published var isRefreshing = false
    @Published var lastRefresh: Date?
    /// 当前使用账户（决定菜单栏展示哪个账户的额度）
    @Published var activeAccountID: UUID?
    /// 是否已启用开机自启动（SMAppService.mainApp，macOS 13+）
    @Published private(set) var launchAtLoginEnabled = false

    private var refreshTimer: Timer?
    /// 每账户上次发起刷新的时间（按平台间隔节流的依据；手动刷新同样会更新）
    private var lastRefreshedAt: [UUID: Date] = [:]
    private let activeKey = "codingbalance.activeAccountID"

    /// 各平台定时刷新间隔：默认见 ProviderKind.defaultRefreshInterval（方舟 60s、Venice 20min），
    /// 可用 UserDefaults 键 `codingbalance.refreshInterval.<rawValue>` 覆盖；非法值（<30s）回落默认
    static func refreshInterval(for kind: ProviderKind) -> TimeInterval {
        let configured = UserDefaults.standard.double(forKey: "codingbalance.refreshInterval.\(kind.rawValue)")
        return configured >= 30 ? configured : kind.defaultRefreshInterval
    }

    // MARK: 菜单栏状态项（NSStatusItem）

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        accounts = AccountStore.shared.load()
        log("App 启动，加载账户数=\(accounts.count)")
        restoreActiveAccount()
        refreshLaunchAtLoginStatus()
        setupStatusItem()
        startAutoRefresh()
        refreshAll()
        // 调试/截图：环境变量 CB_SHOW_POPOVER=1 / CB_SHOW_SETTINGS=1 时自动打开对应窗口
        let env = ProcessInfo.processInfo.environment
        if env["CB_SHOW_POPOVER"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.togglePopover() }
        }
        if env["CB_SHOW_SETTINGS"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.openSettings() }
        }
        // 调试/截图：CB_RENDER_PREVIEW=<png路径> 把弹窗内容离屏渲染为 PNG（配合 CB_SHOW_TAB 选页）
        if let path = env["CB_RENDER_PREVIEW"], !path.isEmpty {
            let tab: MenuBarView.MenuTab = env["CB_SHOW_TAB"] == "models" ? .models : .balance
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                self?.renderPopoverPreview(path: path, tab: tab)
            }
        }
        // 调试：CB_FRAME_WATCH=1 后台持续监视弹窗位置变化（用于复现/定位弹窗漂移）
        if env["CB_FRAME_WATCH"] == "1" {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                var last = ""
                let deadline = Date().addingTimeInterval(120)
                while Date() < deadline {
                    if let s = self?.popoverFrameString(), s != last {
                        last = s
                        self?.log("[探针]位置变化 \(s)")
                    }
                    Thread.sleep(forTimeInterval: 0.2)
                }
            }
        }
    }

    /// 调试：当前弹窗的屏幕坐标描述
    private func popoverFrameString() -> String? {
        guard let window = popover?.contentViewController?.view.window else { return nil }
        let f = window.frame
        return "弹窗[x=\(Int(f.minX)) y=\(Int(f.minY)) w=\(Int(f.width)) h=\(Int(f.height))]"
    }

    deinit {
        refreshTimer?.invalidate()
    }

    private func setupStatusItem() {
        // 定宽：方舟「圆环+百分比」与 Venice「$余额」内容宽度不同，
        // 变宽会让弹窗锚点左右移动（面板漂移），固定宽度保证锚点恒定。
        // 注意：直接以定宽创建(withLength:)会让弹窗锚点解析异常（漂到屏幕左侧），
        // 先按变宽创建再设 length 可规避
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.length = 80
        statusItem = item
        if let button = item.button {
            button.target = self
            button.action = #selector(buttonClicked(_:))
            // 左键弹详情，右键弹菜单
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateStatusItem()

        // 状态变化时同步刷新菜单栏标题
        $balances
            .combineLatest($activeAccountID, $isRefreshing, $accounts)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateStatusItem() }
            }
            .store(in: &cancellables)
    }

    /// 菜单栏按钮：窗口型账户显示圆形「近5小时剩余」指示环 + 百分比；
    /// 余额型账户（Venice）显示 Logo + 余额金额
    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        button.imagePosition = .imageLeading
        if let active = activeAccount, let snap = balances[active.id] {
            if let fiveHour = snap.fiveHour {
                let remaining = fiveHour.remainingPercent
                button.image = makeRingImage(remainingPercent: remaining)
                button.title = "\(Int(remaining.rounded()))%"
                button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
                button.toolTip = "\(active.shortLabel) · 近5小时剩余 \(Int(remaining.rounded()))% · 左键详情 右键菜单"
            } else if let primary = snap.primaryCredit, let summary = snap.creditSummary {
                button.image = makeLogoImage(size: 18)
                button.title = summary
                button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
                let what = primary.label.hasPrefix("附赠") ? "附赠额度" : "余额"
                var tip = "\(active.shortLabel) · \(what) \(formatUSD(primary.amount))\(snap.canConsume == false ? " · 不可消费" : "")"
                // 设置了账单日的账户附上距刷新天数
                if let cycle = active.billingCycle { tip += " · \(cycle.daysRemaining) 天后刷新" }
                button.toolTip = tip + " · 左键详情 右键菜单"
            } else {
                button.image = makeLogoImage(size: 18)
                button.title = "—"
                button.toolTip = "\(active.shortLabel) · 暂无额度数据"
            }
        } else if hasConfiguredAccounts {
            button.image = makeLogoImage(size: 18)
            button.title = "…"
            button.toolTip = "Coding Balance · 数据加载中"
        } else {
            button.image = makeLogoImage(size: 18)
            button.title = ""
            button.toolTip = accounts.isEmpty ? "Coding Balance · 点击配置账户" : "Coding Balance · 账户均已禁用"
        }
    }

    /// 品牌 Logo 小图（蓝底 + 白色 </>），与弹窗头部 BrandLogoView / AppIcon 一致
    private func makeLogoImage(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.isTemplate = false
        image.lockFocus()
        defer { image.unlockFocus() }

        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        NSColor(calibratedRed: 47 / 255, green: 124 / 255, blue: 246 / 255, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: size * 0.27, yRadius: size * 0.27).fill()

        let path = NSBezierPath()
        let lw = size * 0.115
        path.lineWidth = lw
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let insetX = size * 0.26          // 尖括号左右端点
        let insetM = size * 0.05          // 尖括号臂到中心距离
        let y0 = size * 0.32
        let y1 = size * 0.68
        let midX = size / 2
        let midY = size / 2
        // 左尖括号 <
        path.move(to: NSPoint(x: insetX, y: midY))
        path.line(to: NSPoint(x: midX - insetM, y: y0))
        path.move(to: NSPoint(x: insetX, y: midY))
        path.line(to: NSPoint(x: midX - insetM, y: y1))
        // 右尖括号 >
        path.move(to: NSPoint(x: size - insetX, y: midY))
        path.line(to: NSPoint(x: midX + insetM, y: y0))
        path.move(to: NSPoint(x: size - insetX, y: midY))
        path.line(to: NSPoint(x: midX + insetM, y: y1))
        // 斜杠 /
        path.move(to: NSPoint(x: midX + lw * 0.5, y: y0))
        path.line(to: NSPoint(x: midX - lw * 0.5, y: y1))
        NSColor.white.setStroke()
        path.stroke()
        return image
    }

    /// 生成圆形剩余指示图（5h 剩余百分比），12 点方向顺时针
    private func makeRingImage(remainingPercent: Double, size: CGFloat = 20, lineWidth: CGFloat = 2.8) -> NSImage {
        let fraction = max(0, min(1, remainingPercent / 100))
        let image = NSImage(size: NSSize(width: size, height: size))
        image.isTemplate = false
        image.lockFocus()
        defer { image.unlockFocus() }
        let center = NSPoint(x: size / 2, y: size / 2)
        let radius = (size - lineWidth) / 2
        let rect = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        NSColor.systemGray.withAlphaComponent(0.35).setStroke()
        let track = NSBezierPath(ovalIn: rect)
        track.lineWidth = lineWidth
        track.stroke()
        if fraction > 0 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius,
                          startAngle: -90, endAngle: -90 + 360 * fraction, clockwise: false)
            ringColor(remainingPercent).setStroke()
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .round
            arc.stroke()
        }
        return image
    }

    private func ringColor(_ remaining: Double) -> NSColor {
        switch remaining {
        case ..<20: return .systemRed
        case ..<50: return .systemOrange
        default: return .systemGreen
        }
    }

    @objc private func buttonClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    /// 右键菜单：刷新 / 管理账户 / 退出
    private func showContextMenu() {
        guard let button = statusItem?.button else { return }
        let menu = NSMenu()
        let refresh = NSMenuItem(title: "刷新", action: #selector(menuRefresh), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        menu.addItem(.separator())
        let manage = NSMenuItem(title: "管理账户…", action: #selector(menuManage), keyEquivalent: ",")
        manage.target = self
        menu.addItem(manage)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Coding Balance", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem?.menu = menu
        button.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func menuRefresh() { refreshAll() }
    @objc private func menuManage() { openSettings() }

    /// 调试用：把弹窗内容离屏渲染为 PNG（无需屏幕录制权限，供自动化视觉验证）
    private func renderPopoverPreview(path: String, tab: MenuBarView.MenuTab) {
        let hosting = NSHostingController(rootView: MenuBarView(initialTab: tab).environmentObject(self))
        let view = hosting.view
        view.setFrameSize(NSSize(width: 420, height: 560))
        // 大列表（模型页）需要额外的布局周期才能完成排版
        view.layoutSubtreeIfNeeded()
        view.needsLayout = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            let captured = NSImage()
            captured.addRepresentation(rep)
            // 离屏视图背景透明，PNG 中透明区呈黑色：合成到白底便于查看
            let canvas = NSImage(size: view.bounds.size)
            canvas.lockFocus()
            NSColor.white.setFill()
            view.bounds.fill()
            captured.draw(in: view.bounds)
            canvas.unlockFocus()
            guard let tiff = canvas.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                self.log("预览渲染失败 \(path)")
                return
            }
            try? png.write(to: URL(fileURLWithPath: path))
            self.log("预览已渲染 \(path)")
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover?.isShown == true {
            popover?.performClose(nil)
            return
        }
        if popover == nil {
            let pop = NSPopover()
            // 调试/截图：CB_KEEP_POPOVER=1 时保持弹窗常驻
            pop.behavior = ProcessInfo.processInfo.environment["CB_KEEP_POPOVER"] == "1" ? .applicationDefined : .transient
            // 调试/截图：CB_SHOW_TAB=models 时直接打开「模型」页
            let initialTab: MenuBarView.MenuTab =
                ProcessInfo.processInfo.environment["CB_SHOW_TAB"] == "models" ? .models : .balance
            // 固定内容尺寸：SwiftUI 内容尺寸随账户/加载态变化会让弹窗反复重锚定，出现位置漂移
            let hosting = NSHostingController(
                rootView: MenuBarView(initialTab: initialTab).environmentObject(self))
            hosting.sizingOptions = .preferredContentSize
            hosting.preferredContentSize = NSSize(width: 400, height: 560)
            pop.contentViewController = hosting
            pop.contentSize = NSSize(width: 400, height: 560)
            popover = pop
        }
        popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover?.contentViewController?.view.window?.makeKey()
        log("弹窗打开 账户=\(accounts.count) 快照=\(balances.count) 菜单栏=「\(menuBarText)」")
    }

    // MARK: 设置窗口

    private var settingsWindow: NSWindow?

    func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView().environmentObject(self))
            let win = NSWindow(contentViewController: hosting)
            win.title = "管理账户"
            win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            win.setContentSize(hosting.view.fittingSize)
            settingsWindow = win
        }
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func quit() {
        NSApp.terminate(nil)
    }

    // MARK: 当前使用账户

    /// 未禁用的账户：参与定时刷新与「当前使用账户」切换；已禁用的仅保留配置
    var enabledAccounts: [Account] { accounts.filter { !$0.isDisabled } }

    var activeAccount: Account? {
        guard let id = activeAccountID else { return nil }
        return enabledAccounts.first { $0.id == id }
    }

    private func restoreActiveAccount() {
        if let raw = UserDefaults.standard.string(forKey: activeKey),
           let id = UUID(uuidString: raw) {
            activeAccountID = id
        }
        ensureActiveAccount()
    }

    /// 「当前使用账户」不可用时（为空 / 已删除 / 已禁用）回落到第一个未禁用账户并持久化
    private func ensureActiveAccount() {
        if let id = activeAccountID, enabledAccounts.contains(where: { $0.id == id }) { return }
        activeAccountID = enabledAccounts.first?.id
        UserDefaults.standard.set(activeAccountID?.uuidString ?? "", forKey: activeKey)
    }

    func setActiveAccount(_ account: Account) {
        guard !account.isDisabled else { return }
        activeAccountID = account.id
        UserDefaults.standard.set(account.id.uuidString, forKey: activeKey)
        Task { await refresh(account: account) }   // 切过去立刻刷新一次
    }

    // MARK: 菜单栏展示

    /// 未配置时返回空串（仅显示图标）；
    /// 窗口型账户显示「当前使用账户」的 5h / 周 / 月 剩余百分比（纯数字，简短防被菜单栏挤出）；
    /// 余额型账户（Venice）显示余额金额
    var menuBarText: String {
        guard let active = activeAccount else { return "" }
        guard let snap = balances[active.id] else { return "…" }
        var parts: [String] = []
        if snap.plan == .credit {
            if let summary = snap.creditSummary { parts.append(summary) }
        } else {
            if let f = snap.fiveHour { parts.append("5h \(Int(f.remainingPercent.rounded()))%") }
            if let w = snap.weekly { parts.append("周 \(Int(w.remainingPercent.rounded()))%") }
            if let m = snap.monthly { parts.append("月 \(Int(m.remainingPercent.rounded()))%") }
        }
        guard !parts.isEmpty else { return "—" }
        return parts.joined(separator: " ")
    }

    /// 是否有参与刷新的账户（全部禁用时视为未配置，菜单栏仅显示图标）
    var hasConfiguredAccounts: Bool { !enabledAccounts.isEmpty }

    // MARK: 刷新

    /// 定时调度：30s tick，逐账户检查是否到达其平台的刷新间隔（方舟默认 60s、Venice 默认 20min）；
    /// 已禁用的账户不参与
    func startAutoRefresh() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshDueAccounts()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    /// 刷新已到期的账户（手动刷新不受此节流限制）
    private func refreshDueAccounts() {
        let enabled = enabledAccounts
        guard !enabled.isEmpty, !isRefreshing else { return }
        let now = Date()
        let due = enabled.filter { account in
            guard let last = lastRefreshedAt[account.id] else { return true }
            return now.timeIntervalSince(last) >= Self.refreshInterval(for: account.provider)
        }
        guard !due.isEmpty else { return }
        log("定时调度：\(due.count)/\(enabled.count) 个账户到期刷新")
        Task { await refreshAccounts(due) }
    }

    func refreshAll() {
        guard !enabledAccounts.isEmpty, !isRefreshing else { return }
        Task { await refreshAllAwait() }
    }

    /// 等待全部账户刷新完成（供下拉刷新等需要等待完成的场景）
    func refreshAllAwait() async {
        await refreshAccounts(enabledAccounts)
    }

    private func refreshAccounts(_ targets: [Account]) async {
        guard !targets.isEmpty, !isRefreshing else { return }
        isRefreshing = true
        await withTaskGroup(of: Void.self) { group in
            for account in targets {
                group.addTask {
                    await self.refresh(account: account)
                }
            }
        }
        isRefreshing = false
        lastRefresh = Date()
        log("刷新完成 账户=\(targets.count) 快照=\(balances.count) 菜单栏=「\(menuBarText)」")
    }

    /// 账户是否仍可刷新（未被删除且未禁用）
    private func isRefreshable(_ id: UUID) -> Bool {
        accounts.contains { $0.id == id && !$0.isDisabled }
    }

    func refresh(account: Account) async {
        guard isRefreshable(account.id) else { return }
        lastRefreshedAt[account.id] = Date()
        let provider = makeProvider(account.provider)
        do {
            let snapshot = try await provider.fetchBalance(account: account)
            // 请求期间账户可能被禁用/删除：丢弃结果，不再回填缓存
            guard isRefreshable(account.id) else { return }
            balances[account.id] = snapshot
            errors[account.id] = nil
            if snapshot.plan == .credit {
                log("刷新成功 \(account.shortLabel): plan=\(snapshot.plan.rawValue) "
                    + "余额=\(snapshot.creditSummary ?? "-") 可消费=\(snapshot.canConsume.map(String.init) ?? "-")")
            } else {
                log("刷新成功 \(account.shortLabel): plan=\(snapshot.plan.rawValue) "
                    + "5h=\(snapshot.fiveHour?.usedPercent ?? -1) 周=\(snapshot.weekly?.usedPercent ?? -1) "
                    + "月=\(snapshot.monthly?.usedPercent ?? -1)")
            }
        } catch {
            guard isRefreshable(account.id) else { return }
            balances[account.id] = nil
            errors[account.id] = (error as? ProviderError)?.errorDescription ?? error.localizedDescription
            log("刷新失败 \(account.shortLabel): \(errors[account.id] ?? error.localizedDescription)")
        }
        await refreshModels(account: account, provider: provider)
    }

    /// 拉取可用模型 + 限流（QPS）+ 价格（与余额刷新一起，60s 一次）
    func refreshModels(account: Account, provider: Provider? = nil) async {
        guard isRefreshable(account.id) else { return }
        let provider = provider ?? makeProvider(account.provider)
        do {
            let models = try await provider.fetchModels(account: account)
            modelInfos[account.id] = models
            modelErrors[account.id] = nil
            let sample = models.prefix(3).map {
                "\($0.name)(QPS≈\(formatCompact($0.qps ?? 0)), RPM=\(formatCompact($0.rpm ?? 0)), "
                    + "入=\($0.priceIn.map(formatPriceShort) ?? "-"), 出=\($0.priceOut.map(formatPriceShort) ?? "-"), 套餐=\($0.isCodingPlan))"
            }.joined(separator: ", ")
            log("模型刷新成功 \(account.shortLabel): \(models.count) 个 · \(sample)")
        } catch {
            modelInfos[account.id] = []
            modelErrors[account.id] = (error as? ProviderError)?.errorDescription ?? error.localizedDescription
            log("模型刷新失败 \(account.shortLabel): \(modelErrors[account.id] ?? error.localizedDescription)")
        }
    }

    // MARK: 开机自启动（SMAppService.mainApp）

    /// 同步当前开机自启动注册状态
    func refreshLaunchAtLoginStatus() {
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    /// 设置开机自启动，失败时返回错误描述（如应用不在「应用程序」文件夹时注册会失败）
    @discardableResult
    func setLaunchAtLogin(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLaunchAtLoginStatus()
            log("开机自启动\(enabled ? "开启" : "关闭") 状态=\(SMAppService.mainApp.status.rawValue)")
            return nil
        } catch {
            refreshLaunchAtLoginStatus()
            log("开机自启动设置失败: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }

    // MARK: 账户增删改

    func upsertAccount(_ account: Account, validateFirst: Bool = false) async throws {
        if validateFirst {
            _ = try await makeProvider(account.provider).validate(account: account)
        }
        if let idx = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[idx] = account
        } else {
            accounts.append(account)
        }
        AccountStore.shared.save(accounts)
        if account.isDisabled {
            // 保存为禁用态：清掉缓存，「当前使用账户」必要时回落
            purgeCache(for: account.id)
            ensureActiveAccount()
            return
        }
        if activeAccountID == nil {
            activeAccountID = account.id
        }
        await refresh(account: account)
    }

    /// 禁用/启用账户。禁用后保留凭据配置，但停止刷新并从「当前使用账户」切换中移除，
    /// 可随时恢复；作为删除的替代，适合临时下线某个账户
    func setDisabled(_ disabled: Bool, for account: Account) {
        guard let idx = accounts.firstIndex(where: { $0.id == account.id }),
              accounts[idx].isDisabled != disabled else { return }
        accounts[idx].disabled = disabled
        AccountStore.shared.save(accounts)
        // 当前使用账户不可用时（刚被禁用，或此前全部禁用）回落/恢复为第一个未禁用账户
        ensureActiveAccount()
        if disabled {
            purgeCache(for: account.id)
        } else {
            let enabled = accounts[idx]   // 先取值：Task 执行时下标可能已变化
            Task { await refresh(account: enabled) }
        }
        log("\(disabled ? "禁用" : "启用")账户 \(account.shortLabel)")
    }

    private func purgeCache(for id: UUID) {
        balances[id] = nil
        errors[id] = nil
        modelInfos[id] = nil
        modelErrors[id] = nil
        lastRefreshedAt[id] = nil
    }

    func deleteAccount(_ account: Account) {
        accounts.removeAll { $0.id == account.id }
        purgeCache(for: account.id)
        ensureActiveAccount()
        AccountStore.shared.save(accounts)
    }

    func logoutAll() {
        accounts.removeAll()
        balances.removeAll()
        errors.removeAll()
        modelInfos.removeAll()
        modelErrors.removeAll()
        lastRefreshedAt.removeAll()
        activeAccountID = nil
        UserDefaults.standard.removeObject(forKey: activeKey)
        AccountStore.shared.save(accounts)
    }

    // MARK: 日志

    private static let logURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("CodingBalance", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("log.txt")
    }()

    func log(_ msg: String) {
        let line = "[\(Date())] \(msg)\n"
        if let handle = try? FileHandle(forWritingTo: Self.logURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8) ?? Data())
        } else {
            try? line.data(using: .utf8)?.write(to: Self.logURL)
        }
    }
}
