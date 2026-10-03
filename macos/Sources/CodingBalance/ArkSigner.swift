import Foundation
import CryptoKit

// MARK: - 火山引擎 HMAC-SHA256 签名（对应官方《签名方法》doc/6369/67269）

enum ArkSigner {

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hmac(key: Data, data: Data) -> Data {
        var mac = HMAC<SHA256>(key: SymmetricKey(data: key))
        mac.update(data: data)
        return Data(mac.finalize())
    }

    static func rfc3986(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// 构造已签名的 POST 请求。
    static func sign(accessKey: String, secretKey: String,
                     host: String, region: String, service: String,
                     action: String, version: String,
                     body: [String: Any], date: Date = Date())
        -> (url: URL, headers: [String: String], bodyData: Data) {

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let xDate = fmt.string(from: date)
        let day = String(xDate.prefix(8))

        // JSON 紧凑序列化（与 Python 版 separators=(",",":") 一致）
        let bodyData = (try? JSONSerialization.data(withJSONObject: body, options: [])) ?? Data("{}".utf8)
        let payloadHash = sha256Hex(bodyData)

        let headers: [String: String] = [
            "content-type": "application/json",
            "host": host,
            "x-content-sha256": payloadHash,
            "x-date": xDate,
        ]
        let sortedKeys = headers.keys.sorted()
        let signedHeaders = sortedKeys.joined(separator: ";")
        let canonicalHeaders = sortedKeys
            .map { "\($0):\(headers[$0]!.trimmingCharacters(in: .whitespaces))" }
            .joined(separator: "\n") + "\n"

        let query: [String: String] = ["Action": action, "Version": version]
        let canonicalQuery = query.keys.sorted()
            .map { "\(rfc3986($0))=\(rfc3986(query[$0]!))" }
            .joined(separator: "&")

        let canonicalRequest = ["POST", "/", canonicalQuery, canonicalHeaders, signedHeaders, payloadHash]
            .joined(separator: "\n")

        let scope = "\(day)/\(region)/\(service)/request"
        let stringToSign = ["HMAC-SHA256", xDate, scope, sha256Hex(Data(canonicalRequest.utf8))]
            .joined(separator: "\n")

        // 逐级派生签名密钥：kDate -> kRegion -> kService -> kSigning（使用原始摘要字节作为下一步密钥）
        let kDate = hmac(key: Data(secretKey.utf8), data: Data(day.utf8))
        let kRegion = hmac(key: kDate, data: Data(region.utf8))
        let kService = hmac(key: kRegion, data: Data(service.utf8))
        let kSigning = hmac(key: kService, data: Data("request".utf8))
        let signature = hmac(key: kSigning, data: Data(stringToSign.utf8))
            .map { String(format: "%02x", $0) }.joined()

        let authorization = "HMAC-SHA256 Credential=\(accessKey)/\(scope), " +
                            "SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var urlComponents = URLComponents()
        urlComponents.scheme = "https"
        urlComponents.host = host
        urlComponents.queryItems = [
            URLQueryItem(name: "Action", value: action),
            URLQueryItem(name: "Version", value: version),
        ]
        let url = urlComponents.url!

        return (url,
                ["Authorization": authorization,
                 "Content-Type": "application/json",
                 "X-Content-Sha256": payloadHash,
                 "X-Date": xDate],
                bodyData)
    }
}
