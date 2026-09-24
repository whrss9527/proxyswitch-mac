import XCTest
@testable import ProxySwitch

final class DesiredProxyTests: XCTestCase {
    func testHttpProfileCommands() {
        var profile = Profile(name: "本机", color: "#16a34a", kind: .http, host: "127.0.0.1", port: 7890)
        profile.bypass = "localhost, 10.*, <local>"
        let commands = DesiredProxy(profile: profile).commands(service: "Wi-Fi").map { $0.joined(separator: " ") }
        XCTAssertEqual(commands, [
            "-setwebproxy Wi-Fi 127.0.0.1 7890",
            "-setwebproxystate Wi-Fi on",
            "-setsecurewebproxy Wi-Fi 127.0.0.1 7890",
            "-setsecurewebproxystate Wi-Fi on",
            "-setsocksfirewallproxystate Wi-Fi off",
            "-setautoproxystate Wi-Fi off",
            "-setproxyautodiscovery Wi-Fi off",
            "-setproxybypassdomains Wi-Fi localhost 10.0.0.0/8",
        ])
    }

    func testOffKeepsAddressesAndRestoresDiscovery() {
        let commands = DesiredProxy(offWithAutoDiscovery: true, bypassDomains: []).commands(service: "以太网").map { $0.joined(separator: " ") }
        XCTAssertFalse(commands.contains { $0.hasPrefix("-setwebproxy ") || $0.hasPrefix("-setsecurewebproxy ") || $0.hasPrefix("-setautoproxyurl") })
        XCTAssertTrue(commands.contains("-setproxyautodiscovery 以太网 on"))
        XCTAssertEqual(commands.last, "-setproxybypassdomains 以太网 Empty")
    }

    func testPacAndSocks() {
        let pac = Profile(name: "PAC", color: "#000000", kind: .pac, pacURL: "http://127.0.0.1:7890/proxy.pac")
        let pacCommands = DesiredProxy(profile: pac).commands(service: "Wi-Fi").map { $0.joined(separator: " ") }
        XCTAssertTrue(pacCommands.contains("-setautoproxyurl Wi-Fi http://127.0.0.1:7890/proxy.pac"))
        XCTAssertTrue(pacCommands.contains("-setautoproxystate Wi-Fi on"))
        XCTAssertTrue(pacCommands.contains("-setwebproxystate Wi-Fi off"))

        let socks = Profile(name: "SOCKS", color: "#000000", kind: .socks5, host: "127.0.0.1", port: 1080)
        let socksCommands = DesiredProxy(profile: socks).commands(service: "Wi-Fi").map { $0.joined(separator: " ") }
        XCTAssertTrue(socksCommands.contains("-setsocksfirewallproxy Wi-Fi 127.0.0.1 1080"))
        XCTAssertTrue(socksCommands.contains("-setsocksfirewallproxystate Wi-Fi on"))
        XCTAssertTrue(socksCommands.contains("-setwebproxystate Wi-Fi off"))
    }

    func testRestoreSnapshot() {
        var snapshot = ProxySnapshot()
        snapshot.httpEnabled = true
        snapshot.httpHost = "proxy.corp"
        snapshot.httpPort = 3128
        snapshot.autoDiscovery = true
        snapshot.exceptions = ["*.corp"]
        let desired = DesiredProxy(restoring: snapshot)
        XCTAssertEqual(desired.http, DesiredProxy.Endpoint(host: "proxy.corp", port: 3128))
        XCTAssertTrue(desired.autoDiscovery)
        XCTAssertEqual(desired.bypassDomains, ["*.corp"])
    }
}

final class BypassListTests: XCTestCase {
    func testConversion() {
        XCTAssertEqual(BypassList.domains(from: "localhost;127.*;10.*;172.16.*;192.168.1.*;<local>;*.local, 169.254/16"),
                       ["localhost", "127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/16", "192.168.1.0/24", "*.local", "169.254/16"])
        XCTAssertEqual(BypassList.domains(from: ""), [])
        XCTAssertEqual(BypassList.domains(from: "a.com, a.com"), ["a.com"])
    }
}

final class ProxySnapshotTests: XCTestCase {
    func testParseAndMatch() {
        let snapshot = ProxySnapshot(dictionary: [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 7890,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7890,
            "SOCKSEnable": 0, "SOCKSProxy": "127.0.0.1", "SOCKSPort": 7891,
            "ProxyAutoConfigEnable": 0, "ProxyAutoConfigURLString": "http://x/proxy.pac",
            "ProxyAutoDiscoveryEnable": 1, "ExceptionsList": ["*.local", "169.254/16"],
        ])
        XCTAssertTrue(snapshot.isActive)
        XCTAssertTrue(snapshot.httpActive)
        XCTAssertFalse(snapshot.socksActive)
        XCTAssertFalse(snapshot.pacActive)
        XCTAssertTrue(snapshot.autoDiscovery)
        XCTAssertEqual(snapshot.summary, "127.0.0.1:7890")
        let profile = Profile(name: "本机", color: "#16a34a", kind: .http, host: "127.0.0.1", port: 7890)
        XCTAssertTrue(snapshot.matches(profile))
        let other = Profile(name: "其他", color: "#16a34a", kind: .http, host: "127.0.0.1", port: 8080)
        XCTAssertFalse(snapshot.matches(other))
        let socks = Profile(name: "SOCKS", color: "#16a34a", kind: .socks5, host: "127.0.0.1", port: 7891)
        XCTAssertFalse(snapshot.matches(socks))
        XCTAssertEqual(snapshot.asProfile(name: "系统代理")?.serverAddress, "127.0.0.1:7890")
        XCTAssertFalse(ProxySnapshot(dictionary: [:]).isActive)
        XCTAssertEqual(ProxySnapshot(dictionary: [:]).summary, "未开启")
    }

    func testPacMatchIgnoresCase() {
        let snapshot = ProxySnapshot(dictionary: ["ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "http://127.0.0.1:7890/Proxy.pac"])
        let profile = Profile(name: "PAC", color: "#000", kind: .pac, pacURL: "http://127.0.0.1:7890/proxy.pac")
        XCTAssertTrue(snapshot.matches(profile))
        XCTAssertEqual(snapshot.summary, "PAC http://127.0.0.1:7890/Proxy.pac")
    }
}

final class NpmProxyTests: XCTestCase {
    func testUpdate() {
        let content = "registry=https://registry.npmmirror.com\nproxy=http://old:1\nhttps-proxy=http://old:1\n"
        let updated = NpmProxy.update(content, proxyURL: "http://127.0.0.1:7890", noProxy: "localhost")
        XCTAssertEqual(updated, "registry=https://registry.npmmirror.com\nproxy=http://127.0.0.1:7890\nhttps-proxy=http://127.0.0.1:7890\nnoproxy=localhost\n")
        XCTAssertEqual(NpmProxy.update(updated, proxyURL: "", noProxy: ""), "registry=https://registry.npmmirror.com\n")
        XCTAssertEqual(NpmProxy.update("", proxyURL: "", noProxy: ""), "")
    }
}

final class TerminalCommandsTests: XCTestCase {
    func testExportAndFish() {
        let export = TerminalCommands.export(proxyURL: "http://127.0.0.1:7890", noProxy: "it's")
        XCTAssertTrue(export.hasPrefix("export http_proxy='http://127.0.0.1:7890' https_proxy='http://127.0.0.1:7890' no_proxy='it'\\''s' HTTP_PROXY="))
        let fish = TerminalCommands.fish(proxyURL: "socks5://127.0.0.1:1080", noProxy: "")
        XCTAssertTrue(fish.hasPrefix("set -gx http_proxy 'socks5://127.0.0.1:1080'; set -gx HTTP_PROXY 'socks5://127.0.0.1:1080'; "))
        XCTAssertTrue(fish.contains("set -gx no_proxy '\(Profile.defaultNoProxy)'"))
    }
}

final class ParsingTests: XCTestCase {
    func testLsof() {
        let output = "p512\ncClashX\nf23\nn*:7890\nf24\nn127.0.0.1:7891\np9000\ncnode\nf18\nn[::1]:3000\n"
        let listeners = LocalProxyDetector.parseLsof(output)
        XCTAssertEqual(listeners, [
            LocalProxyDetector.Listener(port: 7890, process: "ClashX"),
            LocalProxyDetector.Listener(port: 7891, process: "ClashX"),
            LocalProxyDetector.Listener(port: 3000, process: "node"),
        ])
    }

    func testURLCommands() {
        XCTAssertEqual(URLCommand.parse(URL(string: "proxyswitch://toggle")!), .toggle)
        XCTAssertEqual(URLCommand.parse(URL(string: "proxyswitch://on")!), .turnOn)
        XCTAssertEqual(URLCommand.parse(URL(string: "proxyswitch://off")!), .turnOff)
        XCTAssertEqual(URLCommand.parse(URL(string: "proxyswitch://settings")!), .settings(nil))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxyswitch://settings?page=about")!), .settings(.about))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxyswitch://settings?page=nope")!), .settings(nil))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxyswitch://panel")!), .panel)
        XCTAssertEqual(URLCommand.parse(URL(string: "proxyswitch://update")!), .update)
        XCTAssertEqual(URLCommand.parse(URL(string: "proxyswitch://use?name=%E5%85%AC%E5%8F%B8")!), .use("公司"))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxyswitch://use/home")!), .use("home"))
        XCTAssertNil(URLCommand.parse(URL(string: "proxyswitch://nope")!))
        XCTAssertNil(URLCommand.parse(URL(string: "https://example.com/toggle")!))
    }

    func testServiceSelection() {
        let services = [
            NetworkServices.Service(name: "Wi-Fi", bsdName: "en0", enabled: true),
            NetworkServices.Service(name: "Thunderbolt Bridge", bsdName: "bridge0", enabled: true),
            NetworkServices.Service(name: "Bluetooth PAN", bsdName: "en3", enabled: false),
            NetworkServices.Service(name: "VPN", bsdName: nil, enabled: true),
        ]
        XCTAssertEqual(NetworkServices.select(services: services) { $0 == "en0" || $0 == "en3" }, ["Wi-Fi"])
        XCTAssertEqual(NetworkServices.select(services: services) { _ in false }, ["Wi-Fi", "Thunderbolt Bridge", "VPN"])
    }

    func testVersionCompare() {
        XCTAssertTrue(UpdateChecker.isNewer("1.2.0", than: "1.1.9"))
        XCTAssertTrue(UpdateChecker.isNewer("1.2", than: "1.1.9"))
        XCTAssertFalse(UpdateChecker.isNewer("1.1.9", than: "1.1.9"))
        XCTAssertFalse(UpdateChecker.isNewer("0.9", than: "1.0"))
        XCTAssertTrue(UpdateChecker.isNewer("v0.2.0", than: "0.1.9"))
        // 预发布版本比同号的正式版本旧，但比更早的正式版本新。
        XCTAssertTrue(UpdateChecker.isNewer("0.2.0-beta.1", than: "0.1.1"))
        XCTAssertFalse(UpdateChecker.isNewer("0.2.0-beta.1", than: "0.2.0"))
        XCTAssertTrue(UpdateChecker.isNewer("0.2.0", than: "0.2.0-beta.1"))
    }

    func testReleaseParse() throws {
        let json = """
        {"tag_name":"v0.2.0","html_url":"https://github.com/whrss9527/proxyswitch-mac/releases/tag/v0.2.0",
         "body":"- 一键更新\\n- 修复","published_at":"2026-09-24T08:56:44Z","draft":false,"prerelease":false,
         "assets":[{"name":"ProxySwitch-macos.zip","size":1186132,"browser_download_url":"https://github.com/whrss9527/proxyswitch-mac/releases/download/v0.2.0/ProxySwitch-macos.zip"},
                   {"name":"SHA256SUMS.txt","size":89,"browser_download_url":"https://github.com/whrss9527/proxyswitch-mac/releases/download/v0.2.0/SHA256SUMS.txt"}]}
        """
        let release = try XCTUnwrap(UpdateChecker.parse(Data(json.utf8)))
        XCTAssertEqual(release.version, "0.2.0")
        XCTAssertEqual(release.tag, "v0.2.0")
        XCTAssertEqual(release.pageURL.absoluteString, "https://github.com/whrss9527/proxyswitch-mac/releases/tag/v0.2.0")
        XCTAssertEqual(release.notes, "- 一键更新\n- 修复")
        XCTAssertNotNil(release.publishedAt)
        XCTAssertEqual(release.archiveSize, 1186132)
        XCTAssertEqual(release.archiveURL?.lastPathComponent, "ProxySwitch-macos.zip")
        XCTAssertEqual(release.checksumsURL?.lastPathComponent, "SHA256SUMS.txt")
        XCTAssertTrue(release.canInstall)

        let bare = try XCTUnwrap(UpdateChecker.parse(Data(#"{"tag_name":"0.3.0","assets":[]}"#.utf8)))
        XCTAssertEqual(bare.version, "0.3.0")
        XCTAssertFalse(bare.canInstall)
        XCTAssertEqual(bare.pageURL, UpdateChecker.releasesURL)
        XCTAssertNil(UpdateChecker.parse(Data("{}".utf8)))
        XCTAssertNil(UpdateChecker.parse(Data("not json".utf8)))
    }

    func testChecksums() throws {
        let text = """
        说明行
        0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0  ProxySwitch-macos.zip
        DEADBEEF  太短的
        5891B5B522D5DF086D0FF0B110FBD9D21BB4FC7163AF34D08286A2E846F6BE03 *hello.txt
        """
        XCTAssertEqual(Checksums.parse(text), [
            "ProxySwitch-macos.zip": "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0",
            "hello.txt": "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03",
        ])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("checksum-\(UUID().uuidString).bin")
        try Data("hello\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try Checksums.sha256(of: file), "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03")
    }

    func testInstallability() {
        let installed = URL(fileURLWithPath: "/Applications/ProxySwitch.app")
        XCTAssertEqual(Installability.check(bundleURL: installed), .ok(installed))
        XCTAssertNil(Installability.check(bundleURL: installed).problem)
        let translocated = URL(fileURLWithPath: "/private/var/folders/ab/T/AppTranslocation/1234-5678/d/ProxySwitch.app")
        XCTAssertEqual(Installability.check(bundleURL: translocated), .translocated)
        XCTAssertNotNil(Installability.check(bundleURL: translocated).problem)
        XCTAssertEqual(Installability.check(bundleURL: URL(fileURLWithPath: "/Users/me/.build/debug")), .notBundle)
    }

    func testSyncedConfigRoundTripAndMerge() throws {
        var config = AppConfig()
        config.profiles = [Profile(name: "a", color: "#111111", kind: .socks5, host: "h", port: 1)]
        let synced = SyncedConfig(updatedAt: Date(timeIntervalSince1970: 1_800_000_000), device: "MacBook", config: config)
        let data = try CloudFile.encoder.encode(synced)
        let decoded = try CloudFile.decoder.decode(SyncedConfig.self, from: data)
        XCTAssertEqual(decoded, synced)
        // 只有 config 的老文件也能读。
        let minimal = try CloudFile.decoder.decode(SyncedConfig.self, from: Data(#"{"config":{"profiles":[]}}"#.utf8))
        XCTAssertEqual(minimal.device, "未知设备")
        XCTAssertEqual(minimal.updatedAt, .distantPast)

        let shared = Profile(name: "共有", color: "#111111", host: "1.1.1.1", port: 1)
        var local = AppConfig()
        local.profiles = [shared, Profile(name: "本机独有", color: "#222222", host: "2.2.2.2", port: 2), Profile(name: "同名同地址", color: "#333333", host: "3.3.3.3", port: 3)]
        local.offMode = .restore
        var cloud = AppConfig()
        cloud.profiles = [Profile(name: "云端独有", color: "#444444", host: "4.4.4.4", port: 4), shared, Profile(name: "同名同地址", color: "#555555", host: "3.3.3.3", port: 3)]
        cloud.offMode = .direct
        let merged = local.merging(cloud: cloud)
        XCTAssertEqual(merged.profiles.map(\.name), ["云端独有", "共有", "同名同地址", "本机独有"])
        XCTAssertEqual(merged.offMode, .restore)

        let older = SyncedConfig(updatedAt: Date(timeIntervalSince1970: 1), device: "old", config: AppConfig())
        let newer = SyncedConfig(updatedAt: Date(timeIntervalSince1970: 2), device: "new", config: AppConfig())
        XCTAssertEqual(CloudFile.newest([older, newer, older])?.device, "new")
        XCTAssertNil(CloudFile.newest([]))
    }

    func testDriveDetection() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertNil(CloudFile.driveURL(home: home))
        let drive = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        XCTAssertEqual(CloudFile.driveURL(home: home)?.lastPathComponent, "com~apple~CloudDocs")
    }

    func testReleaseNotesCleaning() {
        let notes = "## 0.2.0\r\n\r\n- 一键更新\r\n  * 子项\r\n普通一行"
        XCTAssertEqual(ReleaseNotes.cleaned(notes), "0.2.0\n\n• 一键更新\n• 子项\n普通一行")
    }

    func testProxyAddressParse() {
        XCTAssertEqual(ProxyAddress.parse("127.0.0.1:7890"), ProxyAddress(kind: nil, host: "127.0.0.1", port: 7890))
        XCTAssertEqual(ProxyAddress.parse(" http://127.0.0.1:7890/ "), ProxyAddress(kind: .http, host: "127.0.0.1", port: 7890))
        XCTAssertEqual(ProxyAddress.parse("socks5://user:pass@proxy.corp:1080"), ProxyAddress(kind: .socks5, host: "proxy.corp", port: 1080))
        XCTAssertEqual(ProxyAddress.parse("[::1]:1080"), ProxyAddress(kind: nil, host: "::1", port: 1080))
        XCTAssertEqual(ProxyAddress.parse("https://proxy.corp"), ProxyAddress(kind: .http, host: "proxy.corp", port: nil))
        XCTAssertEqual(ProxyAddress.parse("proxy.corp"), ProxyAddress(kind: nil, host: "proxy.corp", port: nil))
        XCTAssertFalse(ProxyAddress.parse("proxy.corp")!.splitsFields)
        XCTAssertTrue(ProxyAddress.parse("proxy.corp:3128")!.splitsFields)
        XCTAssertNil(ProxyAddress.parse(""))
        XCTAssertNil(ProxyAddress.parse("ftp://x:1"))
        XCTAssertNil(ProxyAddress.parse("host:abc"))
        XCTAssertNil(ProxyAddress.parse("host:70000"))
    }

    func testProfileValidation() {
        var profile = Profile(name: "x", color: "#000", kind: .http, host: "127.0.0.1", port: 7890)
        XCTAssertNil(profile.validate())
        profile.port = 70000
        XCTAssertNotNil(profile.validate())
        profile.port = 80
        profile.host = "a b"
        XCTAssertNotNil(profile.validate())
        var pac = Profile(name: "p", color: "#000", kind: .pac, pacURL: "ftp://x")
        XCTAssertNotNil(pac.validate())
        pac.pacURL = "http://127.0.0.1/proxy.pac"
        XCTAssertNil(pac.validate())
        var empty = Profile(name: "e", color: "#000")
        empty.targets = []
        XCTAssertNotNil(empty.validate())
    }

    @MainActor
    func testCloudSyncPullAndPush() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("config.json")
        var remoteConfig = AppConfig()
        remoteConfig.profiles = [Profile(name: "云端", color: "#111111", host: "10.0.0.1", port: 8080)]
        try CloudFile.write(SyncedConfig(updatedAt: Date(), device: "另一台 Mac", config: remoteConfig), to: file)

        let sync = CloudSync(folder: folder)
        var current = AppConfig()
        var applied: AppConfig?
        var enabledFlags: [Bool] = []
        sync.currentConfig = { current }
        sync.applyRemote = { applied = $0; current = $0 }
        sync.onEnabledChanged = { enabledFlags.append($0) }

        // 启动时按记录的开关恢复：读到云端的配置就应用。
        sync.start(enabled: true)
        await sync.syncNow()
        XCTAssertEqual(applied, remoteConfig)
        guard case .synced(_, let device) = sync.status else { return XCTFail("状态不对：\(sync.status)") }
        XCTAssertEqual(device, "另一台 Mac")

        // 本机改动稍后写到云端。
        current.profiles.append(Profile(name: "本机", color: "#222222", host: "10.0.0.2", port: 9090))
        sync.localChanged(current)
        try await Task.sleep(for: .seconds(2))
        let written = try XCTUnwrap(try CloudFile.read(at: file))
        XCTAssertEqual(written.config, current)
        XCTAssertEqual(written.device, CloudFile.deviceName)

        // 关掉后不再写。
        sync.disable()
        XCTAssertEqual(enabledFlags, [false])
        XCTAssertEqual(sync.status, .off)
        current.profiles.removeAll()
        sync.localChanged(current)
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertEqual(try CloudFile.read(at: file)?.config.profiles.count, 2)
    }

    @MainActor
    func testCloudSyncEnableAsksWhenCloudDiffers() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("config.json")
        var remoteConfig = AppConfig()
        remoteConfig.profiles = [Profile(name: "云端", color: "#111111", host: "10.0.0.1", port: 8080)]
        try CloudFile.write(SyncedConfig(updatedAt: Date(), device: "另一台 Mac", config: remoteConfig), to: file)

        let sync = CloudSync(folder: folder)
        var current = AppConfig()
        current.profiles = [Profile(name: "本机", color: "#222222", host: "10.0.0.2", port: 9090)]
        sync.currentConfig = { current }
        sync.applyRemote = { current = $0 }
        await sync.enable()
        XCTAssertFalse(sync.enabled)
        XCTAssertEqual(sync.pending?.device, "另一台 Mac")

        sync.resolve(.merge)
        XCTAssertNil(sync.pending)
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(sync.enabled)
        XCTAssertEqual(current.profiles.map(\.name), ["云端", "本机"])
        let written = try XCTUnwrap(try CloudFile.read(at: file))
        XCTAssertEqual(written.config.profiles.map(\.name), ["云端", "本机"])

        // 云端没有文件时直接开启并把本机的写上去。
        let empty = CloudSync(folder: folder.appendingPathComponent("empty", isDirectory: true))
        empty.currentConfig = { current }
        await empty.enable()
        XCTAssertTrue(empty.enabled)
        XCTAssertEqual(try CloudFile.read(at: folder.appendingPathComponent("empty/config.json"))?.config, current)
    }

    func testConfigRoundTrip() throws {
        var config = AppConfig()
        config.profiles = [Profile(name: "a", color: "#111111", kind: .socks5, host: "h", port: 1)]
        config.toggleHotkey = nil
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(decoded, config)
        XCTAssertNil(decoded.toggleHotkey)
        XCTAssertTrue(decoded.autoCheckUpdates)
        // 缺少 toggleHotkey 键时用默认快捷键。
        let minimal = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(minimal.toggleHotkey, HotkeyBinding.defaultToggle)
    }
}
