import Foundation

/// 火山方舟 Provider
///
/// 管控面 API（Access Key 鉴权）：
///   - GetPersonalPlan        查询个人版套餐（CodingPlan -> Lite/Pro）
///   - GetCodingPlanUsage     查询 Coding Plan 个人版各周期已用百分比（公网 OpenAPI）
///   - GetAFPUsage            查询 Agent Plan 个人版 AFP 额度（5h/日/周/月 窗口）
final class ArkProvider: Provider {

    var kind: ProviderKind { .ark }

    private let host = "ark.cn-beijing.volcengineapi.com"
    /// Coding Plan 个人版额度走公网 OpenAPI 入口（与 arkcli 一致）
    private let openHost = "open.volcengineapi.com"
    private let region = "cn-beijing"
    private let service = "ark"
    private let version = "2024-01-01"

    // MARK: Provider

    func fetchBalance(account: Account) async throws -> BalanceSnapshot {
        // 元数据（GetPersonalPlan 缺权限时不阻塞额度查询）
        var plan: [String: Any] = [:]
        do {
            plan = try await apiCall(account: account, action: "GetPersonalPlan",
                                     body: ["Plan": "CodingPlan"])
        } catch {
            // ignore：继续尝试额度接口
        }
        // 1) Coding Plan 个人版优先；2) 未订阅/失败自动回退 Agent Plan
        if let coding = try? await fetchCodingPlanBalance(account: account, plan: plan),
           coding.hasAnyWindow {
            return coding
        }
        return try await fetchAgentPlanBalance(account: account, plan: plan)
    }

    func validate(account: Account) async throws {
        // 核心是 GetCodingPlanUsage 可用；缺 GetPersonalPlan 权限也放行
        do {
            _ = try await apiCall(account: account, action: "GetCodingPlanUsage",
                                  body: [:], host: openHost)
        } catch {
            _ = try await apiCall(account: account, action: "GetPersonalPlan",
                                  body: ["Plan": "CodingPlan"])
        }
    }

    /// 模型 + 限流（RPM/TPM，QPS≈RPM/60）+ 价格
    ///
    /// 数据来源：
    ///   - ListArkCodingPlanModel   Coding Plan 可用模型（失败时回退到全部基础模型）
    ///   - ListModelActivations     价格（WithPrice=true，取不到时价格显示 "-"）
    ///   - ListModelRateLimit       限流 RPM/TPM/TPD（失败则整体报错）
    ///
    /// 命名空间差异：Coding Plan 的 ModelID 用点号版本（doubao-seed-2.1-turbo），
    /// 而平台接口的 FoundationModelName 用连字符版本（doubao-seed-2-1-turbo），
    /// 匹配时统一把 "." 归一化为 "-"。
    func fetchModels(account: Account) async throws -> [ModelInfo] {
        func normalized(_ name: String) -> String {
            name.replacingOccurrences(of: ".", with: "-")
        }

        // 1) Coding Plan 可用模型
        var codingPlanModels: [String] = []
        do {
            let r = try await apiCall(account: account, action: "ListArkCodingPlanModel", body: [:])
            codingPlanModels = (r["Datas"] as? [[String: Any]])?
                .compactMap { asString($0["ModelID"]) } ?? []
        } catch {
            // 无 ListArkCodingPlanModel 权限等：回退到全部基础模型
        }

        // 2) 价格：ListModelActivations 分页
        var prices: [String: String] = [:]
        do {
            let pageSize = 100
            var page = 1
            while true {
                let r = try await apiCall(account: account, action: "ListModelActivations",
                                          body: ["PageNumber": page, "PageSize": pageSize,
                                                 "Filter": ["IncludeDeprecatedModels": false],
                                                 "WithPrice": true, "WithFreeUsage": true])
                let items = r["Items"] as? [[String: Any]] ?? []
                for item in items {
                    if let name = asString(item["FoundationModelName"]),
                       let price = chargeItemsText(item["ChargeItems"]) {
                        prices[normalized(name)] = price
                    }
                }
                if items.count < pageSize { break }
                page += 1
            }
        } catch {
            // 价格取不到时显示 "-"
        }

        // 3) 限流：ListModelRateLimit
        var rateLimits: [String: (rpm: Double?, tpm: Double?, tpd: Double?)] = [:]
        let rr = try await apiCall(account: account, action: "ListModelRateLimit", body: [:])
        for item in rr["Items"] as? [[String: Any]] ?? [] {
            guard let name = asString(item["FoundationModelName"]) else { continue }
            let cur = item["CurrentRateLimit"] as? [String: Any] ?? [:]
            rateLimits[normalized(name)] = (asDouble(cur["Rpm"]),
                                            asDouble(cur["Tpm"]),
                                            asDouble(item["CurrentTpd"]))
        }

        // 4) 合并：优先 Coding Plan 模型，否则全部基础模型
        let names = codingPlanModels.isEmpty ? Array(rateLimits.keys) : codingPlanModels
        return names.sorted().map { name in
            let key = normalized(name)
            // 平台价格/限流可能以 "-ga"（GA 稳定版）后缀登记，精确匹配失败时回退
            let limit = rateLimits[key] ?? rateLimits[key + "-ga"]
            return ModelInfo(name: name,
                             rpm: limit?.rpm,
                             tpm: limit?.tpm,
                             tpd: limit?.tpd,
                             price: prices[key] ?? prices[key + "-ga"])
        }
    }

    /// 解析 ListModelActivations 的 ChargeItems 为价格文本（如 "InferencePrompt 0.008元/千tokens"）
    /// 优先展示输入/输出单价，最多两个计费项，避免超长。
    private func chargeItemsText(_ chargeItems: Any?) -> String? {
        guard let items = chargeItems as? [[String: Any]], !items.isEmpty else { return nil }
        let parts = items.compactMap { c -> String? in
            let price: String
            if let d = asDouble(c["Price"]) {
                price = formatPrice(d)
            } else {
                price = asString(c["Price"]) ?? "-"
            }
            let unit = asString(c["UnitCode"]) ?? asString(c["Unit"]) ?? "-"
            let type = asString(c["Type"]) ?? "-"
            return "\(type) \(price)/\(unit)"
        }
        guard !parts.isEmpty else { return nil }
        let preferred = parts.filter {
            $0.hasPrefix("InferencePrompt") || $0.hasPrefix("InferenceCompletion")
        }
        return (preferred.isEmpty ? parts : preferred).prefix(2).joined(separator: " · ")
    }

    /// 格式化价格，消除浮点精度噪声（0.008999999999999999 -> 0.009）
    private func formatPrice(_ value: Double) -> String {
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    // MARK: 各套餐

    /// Coding Plan 个人版：GetCodingPlanUsage 只返回各周期已用百分比
    private func fetchCodingPlanBalance(account: Account, plan: [String: Any]) async throws -> BalanceSnapshot {
        let usage = try await apiCall(account: account, action: "GetCodingPlanUsage",
                                      body: [:], host: openHost)

        var fiveHour: PlanWindow?
        var daily: PlanWindow?
        var weekly: PlanWindow?
        var monthly: PlanWindow?

        if let items = usage["QuotaUsage"] as? [[String: Any]] {
            for item in items {
                guard let window = PlanWindow(codingDict: item) else { continue }
                switch (asString(item["Level"]) ?? "").lowercased() {
                case "session", "5h", "fivehour", "five_hour":
                    fiveHour = window
                case "day", "daily":
                    daily = window
                case "weekly", "week", "7d":
                    weekly = window
                case "monthly", "month", "30d":
                    monthly = window
                default:
                    break
                }
            }
        }

        return BalanceSnapshot(
            accountID: account.id,
            provider: .ark,
            plan: .codingPlan,
            planType: asString(plan["PlanType"]),
            status: asString(plan["Status"]),
            endTime: asString(plan["EndTime"]),
            fiveHour: fiveHour,
            daily: daily,
            weekly: weekly,
            monthly: monthly,
            updatedAt: Date()
        )
    }

    /// Agent Plan 个人版：GetAFPUsage 返回 5h/日/周/月 绝对配额
    private func fetchAgentPlanBalance(account: Account, plan: [String: Any]) async throws -> BalanceSnapshot {
        let usage = try await apiCall(account: account, action: "GetAFPUsage", body: [:])
        return BalanceSnapshot(
            accountID: account.id,
            provider: .ark,
            plan: .agentPlan,
            planType: asString(usage["PlanType"]) ?? asString(plan["PlanType"]),
            status: asString(plan["Status"]),
            endTime: asString(plan["EndTime"]),
            fiveHour: PlanWindow(afpDict: usage["AFPFiveHour"] as? [String: Any] ?? [:]),
            daily: PlanWindow(afpDict: usage["AFPDaily"] as? [String: Any] ?? [:]),
            weekly: PlanWindow(afpDict: usage["AFPWeekly"] as? [String: Any] ?? [:]),
            monthly: PlanWindow(afpDict: usage["AFPMonthly"] as? [String: Any] ?? [:]),
            updatedAt: Date()
        )
    }

    // MARK: 内部

    private func apiCall(account: Account, action: String, body: [String: Any],
                         host: String? = nil) async throws -> [String: Any] {
        let targetHost = host ?? self.host
        let signed = ArkSigner.sign(accessKey: account.accessKey,
                                    secretKey: account.secretKey,
                                    host: targetHost, region: region, service: service,
                                    action: action, version: version,
                                    body: body)
        var request = URLRequest(url: signed.url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.allHTTPHeaderFields = signed.headers
        request.httpBody = signed.bodyData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw ProviderError.http(http.statusCode, raw)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meta = json["ResponseMetadata"] as? [String: Any] else {
            throw ProviderError.invalidResponse
        }
        if let error = meta["Error"] as? [String: Any] {
            let code = error["Code"] as? String ?? "UnknownError"
            let message = error["Message"] as? String ?? "未知错误"
            throw ProviderError.api(code: code, message: message)
        }
        return json["Result"] as? [String: Any] ?? [:]
    }
}
