import Foundation

/// Venice.ai Provider（按量计费余额型）
///
/// API（Bearer API Key 鉴权，Inference / Admin 类型 Key 均可）：
///   - GET /api_keys/rate_limits   余额（USD/DIEM/附赠）+ key 层级/到期 + 每模型限流 RPM/TPM/RPD
///   - GET /models?type=all        全量模型目录（公开），含各模态价格
final class VeniceProvider: Provider {

    var kind: ProviderKind { .venice }

    private let baseURL = "https://api.venice.ai/api/v1"

    /// 出网代理配置（仅 Venice 请求使用），如 http://127.0.0.1:7897；留空走系统代理/直连
    static let proxyDefaultsKey = "codingbalance.proxyURL"

    // MARK: Provider

    func fetchBalance(account: Account) async throws -> BalanceSnapshot {
        let payload = try await getJSON("/api_keys/rate_limits", account: account)
        let data = payload["data"] as? [String: Any] ?? [:]

        var credits: [CreditBalance] = []
        if let balances = data["balances"] as? [String: Any] {
            if let usd = asDouble(balances["USD"]) {
                credits.append(CreditBalance(label: "USD", amount: usd))
            }
            if let diem = asDouble(balances["DIEM"]) {
                credits.append(CreditBalance(label: "DIEM", amount: diem))
            }
            if let bundled = asDouble(balances["BUNDLED_CREDITS"]) {
                credits.append(CreditBalance(label: "附赠额度", amount: bundled))
            }
        }
        let tier = (data["apiTier"] as? [String: Any]).flatMap { asString($0["id"]) }

        return BalanceSnapshot(
            accountID: account.id,
            provider: .venice,
            plan: .credit,
            planType: tier,
            status: nil,
            endTime: asString(data["keyExpiration"]),
            fiveHour: nil,
            daily: nil,
            weekly: nil,
            monthly: nil,
            updatedAt: Date(),
            credits: credits.isEmpty ? nil : credits,
            canConsume: data["accessPermitted"] as? Bool,
            tier: tier,
            nextEpochBegins: asString(data["nextEpochBegins"]))
    }

    func validate(account: Account) async throws {
        _ = try await getJSON("/api_keys/rate_limits", account: account)
    }

    /// 模型 + 限流（RPM/TPM，QPS≈RPM/60）+ 价格
    ///
    /// 数据来源：
    ///   - /models?type=all     全量目录（id/type/model_spec.pricing），offline 剔除
    ///   - /api_keys/rate_limits 每模型限流 RPM/TPM/RPD，同时圈定当前 Key 实际可用的模型
    ///
    /// 价格：text 模型取 pricing.input/output（$/百万tokens）；
    /// 图像等按张/按分辨率档计价的模型放入 priceExtra（如「图像 $0.045/张」）。
    func fetchModels(account: Account) async throws -> [ModelInfo] {
        async let catalogTask = getJSON("/models?type=all", account: account)
        async let limitsTask = getJSON("/api_keys/rate_limits", account: account)
        let catalog = try await catalogTask
        let limitMap = parseRateLimits(try await limitsTask)

        var models: [ModelInfo] = []
        for item in catalog["data"] as? [[String: Any]] ?? [] {
            guard let id = asString(item["id"]) else { continue }
            let spec = item["model_spec"] as? [String: Any] ?? [:]
            if (spec["offline"] as? Bool) == true { continue }   // 已下线模型不展示
            guard let limits = limitMap[id] else { continue }    // 仅展示当前 Key 可用的模型

            let type = asString(item["type"]) ?? "text"
            let pricing = spec["pricing"] as? [String: Any]
            var priceIn: Double?
            var priceOut: Double?
            var extra: String?
            if type == "text" {
                priceIn = (pricing?["input"] as? [String: Any]).flatMap { asDouble($0["usd"]) }
                priceOut = (pricing?["output"] as? [String: Any]).flatMap { asDouble($0["usd"]) }
            } else {
                extra = parseExtraPricing(pricing)
            }
            models.append(ModelInfo(name: id,
                                    rpm: limits.rpm,
                                    tpm: limits.tpm,
                                    tpd: limits.rpd,
                                    priceIn: priceIn,
                                    priceOut: priceOut,
                                    priceExtra: extra,
                                    isCodingPlan: false,
                                    modality: modality(for: type),
                                    priceCurrency: .usd))
        }
        return models.sorted { $0.name < $1.name }
    }

    // MARK: 内部

    /// 解析 /api_keys/rate_limits 的每模型限流条目
    private func parseRateLimits(_ payload: [String: Any]) -> [String: (rpm: Double?, tpm: Double?, rpd: Double?)] {
        var map: [String: (rpm: Double?, tpm: Double?, rpd: Double?)] = [:]
        let data = payload["data"] as? [String: Any] ?? [:]
        for item in data["rateLimits"] as? [[String: Any]] ?? [] {
            guard let id = asString(item["apiModelId"]) else { continue }
            var rpm: Double?
            var tpm: Double?
            var rpd: Double?
            for rl in item["rateLimits"] as? [[String: Any]] ?? [] {
                guard let amount = asDouble(rl["amount"]) else { continue }
                switch asString(rl["type"]) ?? "" {
                case "RPM": rpm = amount
                case "TPM": tpm = amount
                case "RPD": rpd = amount
                default: break
                }
            }
            map[id] = (rpm, tpm, rpd)
        }
        return map
    }

    /// 目录模态类型 -> 展示模态
    private func modality(for type: String) -> ModelModality {
        switch type {
        case "text": return .text
        case "image", "inpaint", "upscale": return .image
        case "video": return .video
        case "tts", "asr", "music": return .audio
        case "embedding", "decision": return .embedding
        default: return .other
        }
    }

    /// 非 text 模型的计价说明（按张 / 按分辨率档 / 按秒等，单位美元）
    private func parseExtraPricing(_ pricing: [String: Any]?) -> String? {
        guard let pricing else { return nil }
        if let generation = pricing["generation"] as? [String: Any],
           let usd = asDouble(generation["usd"]) {
            return "$\(formatPriceShort(usd))/次"
        }
        if let resolutions = pricing["resolutions"] as? [String: Any], !resolutions.isEmpty {
            let parts = resolutions.sorted { $0.key < $1.key }
                .prefix(3)
                .compactMap { key, value -> String? in
                    guard let usd = asDouble((value as? [String: Any])?["usd"]) else { return nil }
                    return "\(key) $\(formatPriceShort(usd))"
                }
            if !parts.isEmpty { return parts.joined(separator: " · ") }
        }
        if let durations = pricing["durations"] as? [String: Any], !durations.isEmpty {
            let parts = durations.sorted { $0.key < $1.key }
                .prefix(3)
                .compactMap { key, value -> String? in
                    guard let usd = asDouble((value as? [String: Any])?["usd"]) else { return nil }
                    return "\(key)s $\(formatPriceShort(usd))"
                }
            if !parts.isEmpty { return parts.joined(separator: " · ") }
        }
        return nil
    }

    /// GET 并解析 JSON（顶层字典）；HTTP/网络/格式错误统一抛 ProviderError
    private func getJSON(_ path: String, account: Account) async throws -> [String: Any] {
        guard let key = account.apiKey?.trimmingCharacters(in: .whitespaces), !key.isEmpty else {
            throw ProviderError.api(code: "VENICE_NO_KEY", message: "未配置 Venice API Key")
        }
        // 直接字符串拼接：URL(string:relativeTo:) 在 base 无尾斜杠、相对串以 / 开头时会丢掉 base 路径
        guard let url = URL(string: baseURL + path) else {
            throw ProviderError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let session = Self.makeSession(proxyURL: UserDefaults.standard.string(forKey: Self.proxyDefaultsKey))
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProviderError.network(
                "\(error.localizedDescription)（Venice 需访问 api.venice.ai，必要时在设置中配置代理）")
        }

        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8) ?? ""
            let message = Self.errorMessage(fromBody: body)
            switch http.statusCode {
            case 401:
                throw ProviderError.api(code: "401", message: "API Key 无效或类型不正确")
            case 403:
                throw ProviderError.api(code: "403",
                                        message: message.isEmpty ? "Key 受 IP 白名单限制，当前网络 IP 不在允许范围" : message)
            case 404:
                throw ProviderError.api(code: "404", message: "接口不存在：\(path)")
            default:
                throw ProviderError.api(code: String(http.statusCode),
                                        message: message.isEmpty ? String(body.prefix(200)) : message)
            }
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.invalidResponse
        }
        return json
    }

    /// Venice 标准错误体：{"error": "..."} 或 {"error": {"message": "..."}}
    private static func errorMessage(fromBody body: String) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else {
            return ""
        }
        if let error = json["error"] as? String { return error }
        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String { return message }
        return json["message"] as? String ?? ""
    }

    // MARK: URLSession（可选代理，按代理地址缓存复用）

    private static let sessionLock = NSLock()
    private static var sessionCache: [String: URLSession] = [:]

    private static func makeSession(proxyURL: String?) -> URLSession {
        let trimmed = proxyURL?.trimmingCharacters(in: .whitespaces) ?? ""
        sessionLock.lock()
        defer { sessionLock.unlock() }
        if let cached = sessionCache[trimmed] { return cached }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        if !trimmed.isEmpty,
           let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           let host = url.host,
           ["http", "https"].contains(scheme) {
            let port = url.port ?? (scheme == "https" ? 443 : 80)
            config.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: true,
                kCFNetworkProxiesHTTPProxy as String: host,
                kCFNetworkProxiesHTTPPort as String: port,
                kCFNetworkProxiesHTTPSEnable as String: true,
                kCFNetworkProxiesHTTPSProxy as String: host,
                kCFNetworkProxiesHTTPSPort as String: port,
            ]
        }
        let session = URLSession(configuration: config)
        sessionCache[trimmed] = session
        return session
    }
}
