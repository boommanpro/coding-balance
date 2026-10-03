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
