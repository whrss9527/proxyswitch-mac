import Foundation

/// 生成内核（mihomo）的配置文件。
enum CoreConfigBuilder {
    struct Input {
        var engine: EngineConfig
        var secret: String
        var directory: URL
        var testURL: String
        /// 已经转换好的分流规则（不含局域网前缀，最后一条应是 MATCH）。
        var rules: [String]
    }

    static let selectorGroup = RuleConverter.proxyGroup
    static let autoGroup = "自动选择"
    static let providerUserAgent = "clash.meta"

    static func yaml(_ input: Input) -> String {
        let engine = input.engine
        let providers = engine.activeSubscriptions
        let providerNames = providers.map(\.providerName)
        var lines: [String] = []
        lines.append("# 由 ProxySwitch 生成，改动会被覆盖。")
        lines.append("mixed-port: \(engine.mixedPort)")
        lines.append("allow-lan: false")
        lines.append("bind-address: \"127.0.0.1\"")
        lines.append("mode: rule")
        lines.append("log-level: warning")
        lines.append("ipv6: false")
        lines.append("find-process-mode: \"off\"")
        lines.append("external-controller: \"127.0.0.1:\(engine.apiPort)\"")
        lines.append("secret: \(quote(input.secret))")
        lines.append("unified-delay: true")
        lines.append("tcp-concurrent: true")
        lines.append("geodata-mode: false")
        lines.append("geo-auto-update: false")
        lines.append("profile:")
        lines.append("  store-selected: true")
        lines.append("  store-fake-ip: false")
        if !providers.isEmpty {
            lines.append("proxy-providers:")
            for subscription in providers {
                let path = input.directory.appendingPathComponent("providers/\(subscription.providerName).yaml").path
                lines.append("  \(subscription.providerName):")
                lines.append("    type: http")
                lines.append("    url: \(quote(subscription.url))")
                lines.append("    path: \(quote(path))")
                lines.append("    interval: \(max(1, engine.updateIntervalHours) * 3600)")
                lines.append("    header:")
                lines.append("      User-Agent: [\(quote(providerUserAgent))]")
                lines.append("    health-check:")
                lines.append("      enable: true")
                lines.append("      url: \(quote(input.testURL))")
                lines.append("      interval: 600")
                lines.append("      lazy: true")
            }
        }
        let useLine = providerNames.isEmpty ? "" : "    use: [\(providerNames.joined(separator: ", "))]"
        lines.append("proxy-groups:")
        lines.append("  - name: \(quote(selectorGroup))")
        lines.append("    type: select")
        lines.append("    proxies: [\(quote(autoGroup)), \"DIRECT\"]")
        if !useLine.isEmpty { lines.append(useLine) }
        lines.append("  - name: \(quote(autoGroup))")
        lines.append("    type: url-test")
        lines.append("    url: \(quote(input.testURL))")
        lines.append("    interval: 600")
        lines.append("    tolerance: 80")
        lines.append("    lazy: true")
        lines.append("    proxies: [\"DIRECT\"]")
        if !useLine.isEmpty { lines.append(useLine) }
        lines.append("rules:")
        var rules = RuleConverter.lanRules + input.rules
        if !(rules.last?.hasPrefix("MATCH,") ?? false) {
            rules.append("MATCH,\(selectorGroup)")
        }
        for rule in rules {
            lines.append("  - \(quote(rule))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// YAML 的双引号字符串。
    static func quote(_ text: String) -> String {
        var escaped = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default:
                if scalar.value < 0x20 {
                    escaped += String(format: "\\u%04x", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return "\"" + escaped + "\""
    }

    /// 随机的 API 密钥。
    static func makeSecret() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<32).map { _ in alphabet.randomElement()! })
    }
}
