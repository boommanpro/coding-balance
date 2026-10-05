import Foundation

// MARK: - 平台类型（当前仅火山方舟，后续可扩展）

enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case ark = "ark"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ark: return "火山方舟"
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

    /// 菜单栏/弹窗里展示的短名称
    var shortLabel: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? provider.displayName : trimmed
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
}

// MARK: - 余额快照

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
}

// MARK: - 模型限流信息（模型 + QPS/RPM/TPM + 价格）

/// 单个模型的可用性、限流与价格信息。
/// - QPS ≈ RPM / 60（火山引擎限流以 RPM=每分钟请求数 / TPM=每分钟Token数 表达）
/// - 价格统一换算为「元/百万tokens」（API 原始单位为千tokens，×1000 换算）
struct ModelInfo: Identifiable, Hashable {
    var id: String { name }

    let name: String          // 模型 ID / 基础模型名
    let rpm: Double?          // 当前每分钟请求数上限
    let tpm: Double?          // 当前每分钟 Token 数上限
    let tpd: Double?          // 当前每日 Token 限额
    let priceIn: Double?      // 输入单价（元/百万tokens）
    let priceOut: Double?     // 输出单价（元/百万tokens）
    let priceExtra: String?   // 其他计费项（如按张计费的图像模型）
    let isCodingPlan: Bool    // 是否 Coding Plan 套餐内模型

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

func planStatusText(_ status: String?) -> String {
    switch status {
    case "Running": return "生效中"
    case "Expired": return "已过期"
    default: return status ?? "-"
    }
}
