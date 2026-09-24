import Foundation

/// 一条订阅：机场给的地址，内核负责下载和解析节点。
struct Subscription: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String = "订阅"
    var url: String = ""
    var enabled: Bool = true

    init(name: String, url: String) {
        self.name = name
        self.url = url
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, url, enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "订阅"
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    /// 内核配置里 provider 的名字，只用 ASCII，省得在 YAML 里折腾引号。
    var providerName: String { "sub-" + id.uuidString.prefix(8).lowercased() }

    /// 校验地址，返回问题；没问题返回 nil。支持 http(s) 地址和本机的 file:// 文件。
    static func validate(url text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            return "订阅地址要以 http:// 或 https:// 开头"
        }
        if scheme == "file" {
            return url.path.isEmpty ? "文件地址不对" : nil
        }
        guard ["http", "https"].contains(scheme), url.host != nil else {
            return "订阅地址要以 http:// 或 https:// 开头"
        }
        return nil
    }

    /// 本机文件的路径（file:// 订阅）。
    var filePath: String? {
        guard let parsed = URL(string: url), parsed.scheme?.lowercased() == "file" else { return nil }
        return parsed.path
    }
}

/// 代理模式：按规则分流，或者全部走节点。
enum EngineMode: String, Codable, CaseIterable, Identifiable {
    case rule
    case global

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rule: return "规则分流"
        case .global: return "全局代理"
        }
    }
}

/// 分流规则的来源。
enum RuleSource: Equatable, Codable {
    /// 内置：局域网和国内 IP 直连，其余走节点。
    case chinaDirect
    /// 小火箭 / Surge / Clash 格式的规则地址。
    case url(String)

    private enum CodingKeys: String, CodingKey {
        case kind, url
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "chinaDirect"
        if kind == "url", let url = try container.decodeIfPresent(String.self, forKey: .url), !url.isEmpty {
            self = .url(url)
        } else {
            self = .chinaDirect
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .chinaDirect:
            try container.encode("chinaDirect", forKey: .kind)
        case .url(let url):
            try container.encode("url", forKey: .kind)
            try container.encode(url, forKey: .url)
        }
    }

    var url: String? {
        if case .url(let url) = self { return url }
        return nil
    }

    var title: String {
        switch self {
        case .chinaDirect: return "内置：国内直连，其余走节点"
        case .url(let url): return RulePresets.preset(for: url)?.name ?? url
        }
    }
}

/// 常用的小火箭分流规则（johnshall/Shadowrocket-ADBlock-Rules-Forever）。
enum RulePresets {
    struct Preset: Identifiable, Equatable {
        let name: String
        let file: String
        let detail: String

        var id: String { file }
        var url: String { RulePresets.base + file }
    }

    static let base = "https://raw.githubusercontent.com/johnshall/Shadowrocket-ADBlock-Rules-Forever/master/"

    static let all: [Preset] = [
        Preset(name: "黑名单", file: "sr_top500_banlist.conf", detail: "被墙的常用网站走节点，其余直连"),
        Preset(name: "黑名单 + 去广告", file: "sr_top500_banlist_ad.conf", detail: "黑名单，外加拦截广告和跟踪"),
        Preset(name: "白名单", file: "sr_top500_whitelist.conf", detail: "国内常用网站和国内 IP 直连，其余走节点"),
        Preset(name: "白名单 + 去广告", file: "sr_top500_whitelist_ad.conf", detail: "白名单，外加拦截广告和跟踪"),
        Preset(name: "国内 IP 直连", file: "sr_cnip.conf", detail: "只按 IP 归属分流：国内直连，国外走节点"),
        Preset(name: "国内 IP 直连 + 去广告", file: "sr_cnip_ad.conf", detail: "按 IP 归属分流，外加拦截广告"),
        Preset(name: "全部直连 + 去广告", file: "sr_direct_banad.conf", detail: "不走节点，只拦广告"),
        Preset(name: "全部走节点 + 去广告", file: "sr_proxy_banad.conf", detail: "全部走节点，外加拦截广告"),
    ]

    static func preset(for url: String) -> Preset? {
        all.first { $0.url == url }
    }
}

/// 内置代理（内核）的设置。
struct EngineConfig: Codable, Equatable {
    var enabled: Bool = true
    var subscriptions: [Subscription] = []
    var mode: EngineMode = .rule
    var ruleSource: RuleSource = .chinaDirect
    var mixedPort: Int = 7890
    var apiPort: Int = 9097
    /// 「节点」组里选中的节点；nil 表示自动选择。
    var selectedNode: String?
    /// 订阅自动更新的间隔（小时）。
    var updateIntervalHours: Int = 24

    init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, subscriptions, mode, ruleSource, mixedPort, apiPort, selectedNode, updateIntervalHours
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        subscriptions = try container.decodeIfPresent([Subscription].self, forKey: .subscriptions) ?? []
        mode = try container.decodeIfPresent(EngineMode.self, forKey: .mode) ?? .rule
        ruleSource = try container.decodeIfPresent(RuleSource.self, forKey: .ruleSource) ?? .chinaDirect
        mixedPort = try container.decodeIfPresent(Int.self, forKey: .mixedPort) ?? 7890
        apiPort = try container.decodeIfPresent(Int.self, forKey: .apiPort) ?? 9097
        selectedNode = try container.decodeIfPresent(String.self, forKey: .selectedNode)
        updateIntervalHours = try container.decodeIfPresent(Int.self, forKey: .updateIntervalHours) ?? 24
    }

    var activeSubscriptions: [Subscription] { subscriptions.filter { $0.enabled && !$0.url.isEmpty } }

    /// 有订阅且没关掉时内核才需要运行。
    var wantsCore: Bool { enabled && !activeSubscriptions.isEmpty }
}
