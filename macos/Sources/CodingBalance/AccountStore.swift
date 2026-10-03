import Foundation

/// 账户持久化：~/.config/CodingBalance/accounts.json
/// （目录选择与配置类应用一致，便于后续扩展数据库等）
final class AccountStore {

    static let shared = AccountStore()

    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("CodingBalance", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("accounts.json")
    }

    func load() -> [Account] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Account].self, from: data)) ?? []
    }

    func save(_ accounts: [Account]) {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
