import Foundation

// MARK: - 平台类型

enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case ark = "ark"
    case venice = "venice"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ark: return "火山方舟"
        case .venice: return "Venice"
        }
    }

    /// 各平台定时刷新默认间隔（秒）。可用 UserDefaults 键
    /// `codingbalance.refreshInterval.<rawValue>` 覆盖，非法值（<30s）一律回落默认。
    var defaultRefreshInterval: TimeInterval {
        switch self {
        case .ark: return 60
        case .venice: return 20 * 60
        }
    }
}

// MARK: - 账户

struct Account: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var provider: ProviderKind
    var accessKey: String
    var secretKey: String
    /// 单 Key 凭据平台（如 Venice 的 Bearer API Key）；方舟不使用
    var apiKey: String? = nil
    /// 是否已禁用：保留配置但不再刷新、不出现在「当前使用账户」切换中；旧数据缺省为未禁用
    var disabled: Bool? = nil
    /// 账单日（每月几号，1–31）。Venice 附赠额度与账户订阅绑定、按月刷新，但接口不下发该日期，
    /// 由用户按账户自定义；方舟各周期重置时间由接口下发，不使用
    var billingDay: Int? = nil

    var isDisabled: Bool { disabled == true }

    /// 当前所在的月度账单周期（未设置账单日时为 nil）
    var billingCycle: BillingCycle? {
        guard let day = billingDay else { return nil }
        return BillingCycle.current(day: day)
    }

    /// 菜单栏/弹窗里展示的短名称
    var shortLabel: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? provider.displayName : trimmed
    }

    /// 账户列表展示用的凭据缩写
    var credentialPreview: String {
        func abbreviate(_ raw: String, limit: Int = 12) -> String {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return "未填写" }
            return trimmed.count <= limit ? trimmed : trimmed.prefix(limit) + "…"
        }
        switch provider {
        case .ark: return abbreviate(accessKey)
        case .venice: return abbreviate(apiKey ?? "")
        }
    }
}

// MARK: - 月度账单周期

/// 按月刷新的账单周期（如 Venice 附赠额度：以账户订阅日为账单日每月刷新）。
/// 平台接口不下发账单日，故由用户按账户自定义，本地按自然月推算。
struct BillingCycle: Equatable {
    /// 本期首日 0 点
    let start: Date
    /// 下期首日 0 点（即本期结束）
    let end: Date
    let totalDays: Int
    /// 距下期刷新的自然日数（刷新当天已计入下一期，故至少为 1）
    let daysRemaining: Int

    /// 本期已过天数
    var daysElapsed: Int { max(0, totalDays - daysRemaining) }
    /// 本期已过比例（0..<1），用于进度条
    var elapsedFraction: Double { totalDays > 0 ? Double(daysElapsed) / Double(totalDays) : 0 }
    /// 本期最后一天
    var lastDay: Date { Calendar.current.date(byAdding: .day, value: -1, to: end) ?? end }

    /// `now` 所在的账单周期：每月 `day` 日（calendar 时区 0 点）刷新；
    /// 当月天数不足时（如 31 日遇 2 月 / 30 天的月份）按当月最后一天计
    static func current(day: Int, at now: Date = Date(), calendar: Calendar = .current) -> BillingCycle? {
        guard (1...31).contains(day) else { return nil }
        let comps = calendar.dateComponents([.year, .month], from: now)
        guard let monthStart = calendar.date(from: DateComponents(year: comps.year, month: comps.month, day: 1)),
              let prevMonth = calendar.date(byAdding: .month, value: -1, to: monthStart),
              let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart) else {
            return nil
        }
        /// `monthStart` 所在月份的账单日 0 点
        func billingDate(_ monthStart: Date) -> Date? {
            let length = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 0
            return calendar.date(byAdding: .day, value: min(day, length) - 1, to: monthStart)
        }
        guard let thisMonth = billingDate(monthStart), let next = billingDate(nextMonth),
              let prev = billingDate(prevMonth) else { return nil }
        // 本月账单日已到则本期从本月起算，否则仍在上期（上月账单日 ~ 本月账单日）
        let start = thisMonth <= now ? thisMonth : prev
        let end = thisMonth <= now ? next : thisMonth
        return BillingCycle(start: start,
                            end: end,
                            totalDays: calendar.dateComponents([.day], from: start, to: end).day ?? 0,
                            daysRemaining: calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: end).day ?? 0)
    }
}

// MARK: - 额度窗口

/// 一个滚动窗口的额度信息。
/// - Agent Plan（GetAFPUsage）：有绝对 Quota / Used（AFP）
/// - Coding Plan（GetCodingPlanUsage）：只有已用百分比 Percent + 重置时间
struct PlanWindow: Hashable {
    var quota: Double?
    var used: Double?
    var usedPercent: Double
    var resetTime: Int64?
    var updateTimestamp: Int64?

    var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }
    var ratio: Double { min(max(usedPercent / 100, 0), 1) }
    var remainingAFP: Double? {
        if let q = quota, let u = used { return q - u }
        return nil
    }
    /// 是否有绝对额度（AFP）
    var hasAbsolute: Bool { quota != nil }

    init(quota: Double?, used: Double?, usedPercent: Double, resetTime: Int64?, updateTimestamp: Int64? = nil) {
        self.quota = quota
        self.used = used
        self.usedPercent = usedPercent
        self.resetTime = resetTime
        self.updateTimestamp = updateTimestamp
    }

    /// 解析 Agent Plan 的 AFP 窗口：{ Quota, Used, SubscribeTime, ResetTime }
    init?(afpDict: [String: Any]) {
        guard let quota = asDouble(afpDict["Quota"]),
              let used = asDouble(afpDict["Used"]) else { return nil }
        self.quota = quota
        self.used = used
        self.usedPercent = quota > 0 ? used / quota * 100 : 0
        self.resetTime = asInt64(afpDict["ResetTime"])
        self.updateTimestamp = nil
    }

    /// 解析 Coding Plan 的周期项：{ Level, Percent, ResetTimestamp }
    init?(codingDict: [String: Any]) {
        guard let percent = asDouble(codingDict["Percent"]) else { return nil }
        self.quota = nil
        self.used = nil
        self.usedPercent = percent
        var reset = asInt64(codingDict["ResetTimestamp"]) ?? asInt64(codingDict["ResetTime"])
        if let r = reset, r < 100_000_000_000 { reset = r * 1000 }   // 秒 -> 毫秒
        self.resetTime = reset
        self.updateTimestamp = asInt64(codingDict["UpdateTimestamp"])
    }
}

/// 套餐类型（决定展示单位）
enum PlanKind: String {
    case codingPlan = "coding"
    case agentPlan = "agent"
    /// 按量余额型（Venice 等）：无周期窗口，只有货币余额
    case credit = "credit"
}

// MARK: - 余额快照

/// 一项货币余额（如 USD 12.34、DIEM 90.5）
struct CreditBalance: Hashable, Identifiable {
    var id: String { label }
    let label: String
    let amount: Double

    /// 展示文本：USD 及美元计价的附赠额度带 $ 前缀（负数为 -$x），其余原样
    var displayText: String {
        if label == "USD" || label.hasPrefix("附赠") {
            return formatUSD(amount)
        }
        return formatFull(amount)
    }
}

struct BalanceSnapshot: Identifiable, Hashable {
    var id: UUID { accountID }

    let accountID: UUID
    let provider: ProviderKind
    let plan: PlanKind
    let planType: String?
    let status: String?
    let endTime: String?
    let fiveHour: PlanWindow?
    let daily: PlanWindow?
    let weekly: PlanWindow?
    let monthly: PlanWindow?
    let updatedAt: Date

    var hasAnyWindow: Bool {
        fiveHour != nil || daily != nil || weekly != nil || monthly != nil
    }

    // 以下为按量余额型（plan == .credit）字段，方舟快照均为 nil
    /// 货币余额明细，首项为主余额
    var credits: [CreditBalance]? = nil
    /// Key 是否允许消费（余额充足且未受限）
    var canConsume: Bool? = nil
    /// API 层级（如 paid）
    var tier: String? = nil
    /// 限流周期重置时间（ISO8601）
    var nextEpochBegins: String? = nil

    /// 主展示余额：优先「附赠额度」（Venice 订阅的主要消耗池，USD 余额可能为负或不变动），否则第一项（USD）
    var primaryCredit: CreditBalance? {
        guard plan == .credit, let list = credits, !list.isEmpty else { return nil }
        return list.first(where: { $0.label.hasPrefix("附赠") }) ?? list[0]
    }

    /// 信用型主摘要（菜单栏/总览用，如 "$77.5"）
    var creditSummary: String? {
        guard let primary = primaryCredit else { return nil }
        return formatUSD(primary.amount, compact: true)
    }

    /// 主展示余额是否告急（<1 或不允许消费）
    var creditIsLow: Bool {
        guard plan == .credit else { return false }
        if canConsume == false { return true }
        return (primaryCredit?.amount ?? 1) < 1
    }
}

// MARK: - 模型限流信息（模型 + QPS/RPM/TPM + 价格）

/// 价格币种（方舟为元，Venice 为美元）
enum PriceCurrency: String, Hashable {
    case cny, usd
}

/// 模型模态（Venice 等多模态平台用；方舟为 LLM，不设置）
enum ModelModality: String, Hashable {
    case text, image, video, audio, embedding, other

    var displayName: String {
        switch self {
        case .text: return "文本"
        case .image: return "图像"
        case .video: return "视频"
        case .audio: return "语音"
        case .embedding: return "嵌入"
        case .other: return "其他"
        }
    }
}

/// 单个模型的可用性、限流与价格信息。
/// - QPS ≈ RPM / 60（火山引擎限流以 RPM=每分钟请求数 / TPM=每分钟Token数 表达）
/// - 价格统一换算为「元/百万tokens」（API 原始单位为千tokens，×1000 换算）；
///   Venice 平台为美元/百万tokens（priceCurrency = .usd）
struct ModelInfo: Identifiable, Hashable {
    var id: String { name }

    let name: String          // 模型 ID / 基础模型名
    let rpm: Double?          // 当前每分钟请求数上限
    let tpm: Double?          // 当前每分钟 Token 数上限
    let tpd: Double?          // 当前每日 Token 限额
    let priceIn: Double?      // 输入单价（百万tokens，币种见 priceCurrency）
    let priceOut: Double?     // 输出单价（百万tokens，币种见 priceCurrency）
    let priceExtra: String?   // 其他计费项（如按张计费的图像模型）
    let isCodingPlan: Bool    // 是否 Coding Plan 套餐内模型
    var modality: ModelModality? = nil
    var priceCurrency: PriceCurrency = .cny

    var qps: Double? { rpm.map { $0 / 60 } }

    var hasPrice: Bool { priceIn != nil || priceOut != nil || priceExtra != nil }
}

// MARK: - 通用数值转换（API 中数字可能是 number 也可能是 string）

func asDouble(_ value: Any?) -> Double? {
    if let d = value as? Double { return d }
    if let n = value as? NSNumber { return n.doubleValue }
    if let s = value as? String { return Double(s) }
    return nil
}

func asInt64(_ value: Any?) -> Int64? {
    if let n = value as? NSNumber { return n.int64Value }
    if let s = value as? String { return Int64(s) }
    return nil
}

func asString(_ value: Any?) -> String? {
    if let s = value as? String { return s }
    if let n = value as? NSNumber { return n.stringValue }
    return nil
}

// MARK: - 格式化

func formatCompact(_ value: Double) -> String {
    if value >= 1_000_000 {
        return String(format: "%.1fM", value / 1_000_000)
    } else if value >= 1_000 {
        return String(format: "%.1fk", value / 1_000)
    }
    return String(format: "%.0f", value)
}

func formatFull(_ value: Double) -> String {
    if value == value.rounded() {
        return String(format: "%.0f", value)
    }
    return String(format: "%.2f", value)
}

/// 价格展示（元/百万tokens）：去掉无意义尾零，如 9 / 0.7 / 9.5 / 0.16
func formatPriceShort(_ value: Double) -> String {
    if value == value.rounded() {
        return String(format: "%.0f", value)
    }
    var text = String(format: "%.4f", value)
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return text
}

func formatTime(_ ts: Int64?) -> String {
    guard let ts = ts else { return "-" }
    let date = Date(timeIntervalSince1970: TimeInterval(ts) / 1000)
    let fmt = DateFormatter()
    fmt.dateFormat = "MM-dd HH:mm"
    fmt.timeZone = .current
    return fmt.string(from: date)
}

/// 余额短显示（菜单栏等窄空间）：$123 / $12.3 / $0.98
func formatMoneyShort(_ value: Double) -> String {
    if value >= 100 { return String(format: "%.0f", value) }
    if value >= 10 { return String(format: "%.1f", value) }
    return String(format: "%.2f", value)
}

/// 美元金额展示（负数为 -$0.18 形式）；compact=true 用于菜单栏等窄空间
func formatUSD(_ value: Double, compact: Bool = false) -> String {
    let magnitude = compact ? formatMoneyShort(abs(value)) : formatFull(abs(value))
    return value < 0 ? "-$\(magnitude)" : "$\(magnitude)"
}

/// ISO8601 时间串解析（兼容毫秒精度），失败返回 nil
func parseISODate(_ iso: String?) -> Date? {
    guard let iso, !iso.isEmpty else { return nil }
    let plain = ISO8601DateFormatter()
    if let d = plain.date(from: iso) { return d }
    let frac = ISO8601DateFormatter()
    frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return frac.date(from: iso)
}

func planStatusText(_ status: String?) -> String {
    switch status {
    case "Running": return "生效中"
    case "Expired": return "已过期"
    default: return status ?? "-"
    }
}
