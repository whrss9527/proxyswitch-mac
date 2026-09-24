import Foundation

/// 网卡的收发字节数。只算 en* 网卡（有线、Wi‑Fi、雷雳桥接），不算回环和 VPN 隧道（隧道流量最终也走物理网卡，算上会重复）。
enum InterfaceCounters {
    struct Sample: Equatable {
        var received: UInt32
        var sent: UInt32
    }

    /// 每个网卡当前的计数（系统给的是 32 位计数，会回绕，所以按网卡分别记）。
    static func read() -> [String: Sample] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let start = first else { return [:] }
        defer { freeifaddrs(start) }
        var result: [String: Sample] = [:]
        var pointer: UnsafeMutablePointer<ifaddrs>? = start
        while let current = pointer {
            let interface = current.pointee
            pointer = interface.ifa_next
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK), let data = interface.ifa_data else { continue }
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en"),
                  interface.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            result[name] = Sample(received: stats.ifi_ibytes, sent: stats.ifi_obytes)
        }
        return result
    }

    /// 两次采样之间的收发字节数（处理 32 位回绕）。
    static func delta(from old: [String: Sample], to new: [String: Sample]) -> (received: UInt64, sent: UInt64) {
        var received: UInt64 = 0
        var sent: UInt64 = 0
        for (name, sample) in new {
            guard let previous = old[name] else { continue }
            received += UInt64(sample.received &- previous.received)
            sent += UInt64(sample.sent &- previous.sent)
        }
        return (received, sent)
    }
}

/// 网速的显示文字：固定 5 个字符宽（数字用等宽字体），例如「   0B」「 9.9K」「 999K」「 1.2M」。
enum SpeedFormatter {
    static func compact(bytesPerSecond: Int) -> String {
        let value = max(0, bytesPerSecond)
        let text: String
        if value < 1000 {
            text = "\(value)B"
        } else {
            let units: [(Double, String)] = [(1_073_741_824, "G"), (1_048_576, "M"), (1024, "K")]
            var chosen = "\(value)B"
            for (size, unit) in units where Double(value) >= size * 0.9995 {
                let scaled = Double(value) / size
                chosen = scaled < 9.95 ? String(format: "%.1f%@", scaled, unit) : String(format: "%.0f%@", scaled, unit)
                break
            }
            text = chosen
        }
        // 用「数字宽度的空格」补到 5 位，等宽数字下宽度稳定，图标不会跟着抖。
        let padding = max(0, 5 - text.count)
        return String(repeating: "\u{2007}", count: padding) + text
    }

    /// 带单位的完整写法，提示和面板里用。
    static func full(bytesPerSecond: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, bytesPerSecond)), countStyle: .binary) + "/s"
    }
}
