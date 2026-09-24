import Foundation

/// GitHub 上的一个发布版本，以及一键更新需要的附件。
struct ReleaseInfo: Equatable {
    var version: String
    var tag: String
    var pageURL: URL
    var notes: String
    var publishedAt: Date?
    var archiveURL: URL?
    var archiveSize: Int?
    var checksumsURL: URL?

    /// 有 zip 和校验文件才能在程序里直接安装，否则只能去发布页下载。
    var canInstall: Bool { archiveURL != nil && checksumsURL != nil }
}

enum UpdateError: LocalizedError {
    case server(Int)
    case badResponse
    case noArchive
    case checksumsMissing
    case checksumMismatch
    case extract(String)
    case appNotFound
    case wrongApp(String)
    case notInstallable(String)
    case install(String)
    case cancelledByUser

    var errorDescription: String? {
        switch self {
        case .server(let code): return "服务器返回了 \(code)"
        case .badResponse: return "读不懂服务器返回的内容"
        case .noArchive: return "这个版本没有可以直接安装的附件，请到发布页下载"
        case .checksumsMissing: return "校验文件里没有这个附件的校验和"
        case .checksumMismatch: return "下载的文件校验和不对，可能没下载完整或被篡改"
        case .extract(let text): return "解压失败：\(text)"
        case .appNotFound: return "压缩包里没有 ProxySwitch.app"
        case .wrongApp(let text): return "下载的程序不对：\(text)"
        case .notInstallable(let text): return text
        case .install(let text): return "替换程序失败：\(text)"
        case .cancelledByUser: return "已取消授权，程序没有改动"
        }
    }
}

/// 检查 GitHub 上的最新发布。
enum UpdateChecker {
    static let archiveName = "ProxySwitch-macos.zip"
    static let checksumsName = "SHA256SUMS.txt"
    /// 测试用：把这个环境变量指向别的地址，就能从本地服务器「发布」新版本。
    static let overrideVariable = "PROXYSWITCH_UPDATE_URL"

    static var releasesURL: URL { URL(string: "https://github.com/\(AppInfo.repository)/releases")! }

    static var apiURL: URL {
        if let text = ProcessInfo.processInfo.environment[overrideVariable], let url = URL(string: text) {
            return url
        }
        return URL(string: "https://api.github.com/repos/\(AppInfo.repository)/releases/latest")!
    }

    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    static var userAgent: String { "ProxySwitch/\(currentVersion) (macOS)" }

    static func latest() async throws -> ReleaseInfo {
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError.server(http.statusCode)
        }
        guard let release = parse(data) else { throw UpdateError.badResponse }
        return release
    }

    /// 解析 GitHub releases 接口返回的 JSON。
    static func parse(_ data: Data) -> ReleaseInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String, !tag.isEmpty else {
            return nil
        }
        let assets = (json["assets"] as? [[String: Any]]) ?? []
        func asset(named name: String) -> [String: Any]? {
            assets.first { ($0["name"] as? String) == name }
        }
        let archive = asset(named: archiveName)
        let publishedAt = (json["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return ReleaseInfo(
            version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
            tag: tag,
            pageURL: (json["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesURL,
            notes: (json["body"] as? String) ?? "",
            publishedAt: publishedAt,
            archiveURL: (archive?["browser_download_url"] as? String).flatMap(URL.init(string:)),
            archiveSize: archive?["size"] as? Int,
            checksumsURL: (asset(named: checksumsName)?["browser_download_url"] as? String).flatMap(URL.init(string:))
        )
    }

    /// 比较版本号：first 比 second 新返回 true。数字逐段比较；带 -beta 之类后缀的预发布版本比同号的正式版本旧。
    static func isNewer(_ first: String, than second: String) -> Bool {
        let a = components(first)
        let b = components(second)
        for index in 0..<max(a.numbers.count, b.numbers.count) {
            let x = index < a.numbers.count ? a.numbers[index] : 0
            let y = index < b.numbers.count ? b.numbers[index] : 0
            if x != y { return x > y }
        }
        return !a.prerelease && b.prerelease
    }

    private static func components(_ version: String) -> (numbers: [Int], prerelease: Bool) {
        var text = version.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") {
            text.removeFirst()
        }
        let parts = text.split(separator: "-", maxSplits: 1)
        let numbers = (parts.first ?? "").split(separator: ".").map { Int($0) ?? 0 }
        return (numbers, parts.count > 1)
    }
}
