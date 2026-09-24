import CryptoKit
import Foundation

/// 下载并转换分流规则，结果缓存在内核目录里（7 天内直接用缓存）。RULE-SET 引用的规则集也下载后内联。
enum RuleFetcher {
    struct Result: Equatable {
        var rules: [String]
        var warnings: [String]
        var fromCache: Bool
        var fetchedAt: Date
    }

    static let cacheMaxAge: TimeInterval = 7 * 24 * 3600
    static let maxBytes = 20 * 1024 * 1024

    static func cacheURL(for url: String, directory: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("rules-\(digest).txt")
    }

    static func fetch(url: String, directory: URL, force: Bool = false) async throws -> Result {
        let cache = cacheURL(for: url, directory: directory)
        if !force, let cached = load(cache: cache), Date().timeIntervalSince(cached.fetchedAt) < cacheMaxAge {
            return cached
        }
        let text = try await download(url)
        let converted = RuleConverter.convert(text)
        var ruleSets: [String: [String]] = [:]
        var warnings: [String] = []
        if converted.skipped > 0 {
            warnings.append("跳过了 \(converted.skipped) 条不支持的规则")
        }
        for reference in converted.ruleSets where ruleSets[reference.url] == nil {
            do {
                let listText = try await download(reference.url)
                ruleSets[reference.url] = RuleConverter.convert(listText, defaultPolicy: reference.policy).rules
            } catch {
                warnings.append("规则集下载失败：\(reference.url)")
            }
        }
        let rules = RuleConverter.merge(converted, ruleSetRules: ruleSets)
        guard !rules.isEmpty else { throw RuleFetcherError.empty }
        let result = Result(rules: rules, warnings: warnings, fromCache: false, fetchedAt: Date())
        save(result, source: url, to: cache)
        return result
    }

    static func download(_ text: String) async throws -> String {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)) else { throw RuleFetcherError.badURL(text) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(UpdateChecker.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RuleFetcherError.status(http.statusCode)
        }
        guard data.count <= maxBytes else { throw RuleFetcherError.tooLarge }
        return String(decoding: data, as: UTF8.self)
    }

    private static let dateFormatter = ISO8601DateFormatter()

    static func load(cache: URL) -> Result? {
        guard let text = try? String(contentsOf: cache, encoding: .utf8) else { return nil }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let header = lines.first, header.hasPrefix("# fetched ") else { return nil }
        lines.removeFirst()
        let stamp = header.dropFirst("# fetched ".count).split(separator: " ").first.map(String.init) ?? ""
        guard let date = dateFormatter.date(from: stamp) else { return nil }
        var warnings: [String] = []
        while let first = lines.first, first.hasPrefix("# warning ") {
            warnings.append(String(first.dropFirst("# warning ".count)))
            lines.removeFirst()
        }
        return Result(rules: lines, warnings: warnings, fromCache: true, fetchedAt: date)
    }

    static func save(_ result: Result, source: String, to cache: URL) {
        var lines = ["# fetched \(dateFormatter.string(from: result.fetchedAt)) \(source)"]
        lines += result.warnings.map { "# warning \($0)" }
        lines += result.rules
        try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: cache, atomically: true, encoding: .utf8)
    }
}

enum RuleFetcherError: LocalizedError {
    case badURL(String)
    case status(Int)
    case tooLarge
    case empty

    var errorDescription: String? {
        switch self {
        case .badURL(let text): return "规则地址不对：\(text)"
        case .status(let code): return "下载规则失败：服务器返回 \(code)"
        case .tooLarge: return "规则文件太大"
        case .empty: return "规则文件里没有能用的规则"
        }
    }
}
