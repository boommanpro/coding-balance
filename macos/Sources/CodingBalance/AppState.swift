import AppKit
import Combine
import Foundation
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

    private var refreshTimer: Timer?
    private let activeKey = "codingbalance.activeAccountID"

    // MARK: 菜单栏状态项（NSStatusItem）

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        accounts = AccountStore.shared.load()
        log("App 启动，加载账户数=\(accounts.count)")
        restoreActiveAccount()
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
    }

    deinit {
        refreshTimer?.invalidate()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
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

    /// 菜单栏按钮：圆形「近5小时剩余」指示环 + 百分比
    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        button.imagePosition = .imageLeading
        if let active = activeAccount, let snap = balances[active.id],
           let fiveHour = snap.fiveHour {
            let remaining = fiveHour.remainingPercent
            button.image = makeRingImage(remainingPercent: remaining)
            button.title = "\(Int(remaining.rounded()))%"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            button.toolTip = "\(active.shortLabel) · 近5小时剩余 \(Int(remaining.rounded()))% · 左键详情 右键菜单"
        } else if hasConfiguredAccounts {
            button.image = makeLogoImage(size: 18)
            button.title = "…"
            button.toolTip = "Coding Balance · 数据加载中"
        } else {
            button.image = makeLogoImage(size: 18)
            button.title = ""
            button.toolTip = "Coding Balance · 点击配置账户"
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
            pop.contentSize = NSSize(width: 420, height: 560)
            // 调试/截图：CB_SHOW_TAB=models 时直接打开「模型」页
            let initialTab: MenuBarView.MenuTab =
                ProcessInfo.processInfo.environment["CB_SHOW_TAB"] == "models" ? .models : .balance
            pop.contentViewController = NSHostingController(
                rootView: MenuBarView(initialTab: initialTab).environmentObject(self))
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

    var activeAccount: Account? {
        guard let id = activeAccountID else { return nil }
        return accounts.first { $0.id == id }
    }

    private func restoreActiveAccount() {
        if let raw = UserDefaults.standard.string(forKey: activeKey),
           let id = UUID(uuidString: raw), accounts.contains(where: { $0.id == id }) {
            activeAccountID = id
        } else {
            activeAccountID = accounts.first?.id
        }
    }

    func setActiveAccount(_ account: Account) {
        activeAccountID = account.id
        UserDefaults.standard.set(account.id.uuidString, forKey: activeKey)
        Task { await refresh(account: account) }   // 切过去立刻刷新一次
    }

    // MARK: 菜单栏展示

    /// 未配置时返回空串（仅显示图标）；
    /// 已配置则显示「当前使用账户」的 5h / 周 / 月 剩余百分比（纯数字，简短防被菜单栏挤出）
    var menuBarText: String {
        guard let active = activeAccount else { return "" }
        guard let snap = balances[active.id] else { return "…" }
        var parts: [String] = []
        if let f = snap.fiveHour { parts.append("5h \(Int(f.remainingPercent.rounded()))%") }
        if let w = snap.weekly { parts.append("周 \(Int(w.remainingPercent.rounded()))%") }
        if let m = snap.monthly { parts.append("月 \(Int(m.remainingPercent.rounded()))%") }
        guard !parts.isEmpty else { return "—" }
        return parts.joined(separator: " ")
    }

    var hasConfiguredAccounts: Bool { !accounts.isEmpty }

    // MARK: 刷新

    func startAutoRefresh(interval: TimeInterval = 60) {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func refreshAll() {
        guard !accounts.isEmpty, !isRefreshing else { return }
        Task { await refreshAllAwait() }
    }

    /// 等待全部账户刷新完成（供下拉刷新等需要等待完成的场景）
    func refreshAllAwait() async {
        guard !accounts.isEmpty, !isRefreshing else { return }
        isRefreshing = true
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                group.addTask {
                    await self.refresh(account: account)
                }
            }
        }
        isRefreshing = false
        lastRefresh = Date()
        log("刷新完成 账户=\(accounts.count) 快照=\(balances.count) 菜单栏=「\(menuBarText)」")
    }

    func refresh(account: Account) async {
        let provider = makeProvider(account.provider)
        do {
            let snapshot = try await provider.fetchBalance(account: account)
            balances[account.id] = snapshot
            errors[account.id] = nil
            log("刷新成功 \(account.shortLabel): plan=\(snapshot.plan.rawValue) "
                + "5h=\(snapshot.fiveHour?.usedPercent ?? -1) 周=\(snapshot.weekly?.usedPercent ?? -1) "
                + "月=\(snapshot.monthly?.usedPercent ?? -1)")
        } catch {
            balances[account.id] = nil
            errors[account.id] = (error as? ProviderError)?.errorDescription ?? error.localizedDescription
            log("刷新失败 \(account.shortLabel): \(errors[account.id] ?? error.localizedDescription)")
        }
        await refreshModels(account: account, provider: provider)
    }

    /// 拉取可用模型 + 限流（QPS）+ 价格（与余额刷新一起，60s 一次）
    func refreshModels(account: Account, provider: Provider? = nil) async {
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
        if activeAccountID == nil {
            activeAccountID = account.id
        }
        await refresh(account: account)
    }

    func deleteAccount(_ account: Account) {
        accounts.removeAll { $0.id == account.id }
        balances[account.id] = nil
        errors[account.id] = nil
        modelInfos[account.id] = nil
        modelErrors[account.id] = nil
        if activeAccountID == account.id {
            activeAccountID = accounts.first?.id
            UserDefaults.standard.set(activeAccountID?.uuidString ?? "", forKey: activeKey)
        }
        AccountStore.shared.save(accounts)
    }

    func logoutAll() {
        accounts.removeAll()
        balances.removeAll()
        errors.removeAll()
        modelInfos.removeAll()
        modelErrors.removeAll()
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
