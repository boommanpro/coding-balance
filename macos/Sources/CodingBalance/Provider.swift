import Foundation

// MARK: - Provider 抽象（当前仅火山方舟，后续可扩展其他平台）

enum ProviderError: LocalizedError {
    case network(String)
    case http(Int, String)
    case invalidResponse
    case api(code: String, message: String)
    case notImplemented

    var errorDescription: String? {
        switch self {
        case .network(let s): return "网络错误：\(s)"
        case .http(let code, let body): return "HTTP \(code)：\(body.prefix(200))"
        case .invalidResponse: return "响应格式异常"
        case .api(let code, let message): return "[\(code)] \(message)"
        case .notImplemented: return "该平台暂未支持"
        }
    }
}

protocol Provider {
    var kind: ProviderKind { get }
    /// 拉取账户余额快照
    func fetchBalance(account: Account) async throws -> BalanceSnapshot
    /// 校验凭据是否可用
    func validate(account: Account) async throws
}

func makeProvider(_ kind: ProviderKind) -> Provider {
    switch kind {
    case .ark: return ArkProvider()
    }
}
