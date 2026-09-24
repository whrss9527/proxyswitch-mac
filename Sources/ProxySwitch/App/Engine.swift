import AppKit
import Combine

/// 内置代理：管内核进程、节点列表、模式和订阅。只在主线程上用。
@MainActor
final class Engine: ObservableObject {
    enum Status: Equatable {
        /// 没启用，或者还没有订阅。
        case off
        case starting
        /// 内核在跑，附带版本号。
        case running(String)
        case failed(String)
    }

    struct Node: Identifiable, Equatable {
        var name: String
        var type: String
        /// nil 没测过；0 测试失败。
        var delay: Int?
        var subscription: String

        var id: String { name }

        var delayText: String {
            guard let delay else { return "" }
            return delay > 0 ? "\(delay) ms" : "超时"
        }
    }

    struct SubscriptionStatus: Equatable {
        var nodeCount: Int
        var info: CoreSubscriptionInfo?
        var updatedAt: Date?
    }

    static let selectorGroup = CoreConfigBuilder.selectorGroup
    static let autoGroup = CoreConfigBuilder.autoGroup

    @Published private(set) var status: Status = .off
    @Published private(set) var nodes: [Node] = []
    /// 「节点」组当前选中的：某个节点、自动选择或 DIRECT。
    @Published private(set) var currentSelection: String?
    /// 自动选择现在用的节点。
    @Published private(set) var autoNode: String?
    @Published private(set) var subscriptionStatus: [UUID: SubscriptionStatus] = [:]
    @Published private(set) var testing = false
    @Published private(set) var updatingSubscription: UUID?
    @Published private(set) var rulesInfo = ""
    @Published var lastError: String?

    var readConfig: () -> AppConfig = { AppConfig() }
    var writeEngine: ((EngineConfig) -> Void)?
    var onStatusChanged: (@MainActor () -> Void)?

    private let runner = CoreRunner()
    private var api: CoreAPI?
    private let secret = CoreConfigBuilder.makeSecret()
    private var lastConfigText: String?
    private var refreshTimer: Timer?
    private var restartAttempts = 0
    private var reconcileTask: Task<Void, Never>?
    private var ruleCache: (source: RuleSource, rules: [String])?

    static var directory: URL { Store.directory.appendingPathComponent("core", isDirectory: true) }
    var configURL: URL { Self.directory.appendingPathComponent("config.yaml") }
    var engineConfig: EngineConfig { readConfig().engine }
    var coreAvailable: Bool { CoreBinary.executableURL != nil }

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    /// 当前实际在用的节点名（自动选择时是它选中的那个）。
    var effectiveNode: String? {
        guard let currentSelection else { return nil }
        if currentSelection == Self.autoGroup { return autoNode }
        return currentSelection
    }

    var effectiveNodeInfo: Node? {
        guard let name = effectiveNode else { return nil }
        return nodes.first { $0.name == name }
    }

    var logTail: String { runner.logTail }

    /// 内核的实时流量流；没在跑时是 nil。
    func trafficStream() async throws -> URLSession.AsyncBytes? {
        guard let api, isRunning else { return nil }
        return try await api.trafficBytes()
    }

    // MARK: - 生命周期

    func start() {
        runner.onExit = { [weak self] code in self?.coreExited(code) }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        scheduleReconcile()
    }

    /// 退出时停掉内核。
    func shutdown() {
        runner.stop()
        api = nil
    }

    /// 配置变了：该跑就跑（配置内容变了就重新加载），不该跑就停。多次调用合并成一次。
    func scheduleReconcile() {
        reconcileTask?.cancel()
        reconcileTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.reconcile()
        }
    }

    func reconcile() async {
        let engine = engineConfig
        guard engine.wantsCore else {
            if api != nil || runner.isRunning {
                stopCore()
            } else if status != .off {
                status = .off
            }
            return
        }
        do {
            let text = try await generateConfig(engine)
            if runner.isRunning, let api {
                if text != lastConfigText {
                    if portsChanged(from: lastConfigText, to: text) {
                        stopCore()
                        try await startCore(with: text)
                    } else {
                        try write(text)
                        try await api.reload(configPath: configURL.path)
                        lastConfigText = text
                        Log.info("内核配置已重新加载")
                        await refresh()
                    }
                }
            } else {
                try await startCore(with: text)
            }
            lastError = nil
        } catch {
            status = .failed(error.localizedDescription)
            lastError = error.localizedDescription
            Log.error("内置代理出错：\(error.localizedDescription)")
            onStatusChanged?()
        }
    }

    /// 开启内置配置前确保内核在跑。
    func ensureRunning() async throws {
        if isRunning, runner.isRunning { return }
        reconcileTask?.cancel()
        await reconcile()
        guard isRunning else {
            if case .failed(let message) = status { throw CoreRunnerError.notReady(message) }
            throw CoreRunnerError.notReady(engineConfig.wantsCore ? "内核没有启动" : "还没有添加订阅")
        }
    }

    func restartCore() async {
        stopCore()
        await reconcile()
    }

    private func startCore(with text: String) async throws {
        guard let executable = CoreBinary.executableURL else { throw CoreRunnerError.missingBinary }
        status = .starting
        onStatusChanged?()
        CoreRunner.killStrays()
        try prepareDirectory()
        try write(text)
        try runner.start(executable: executable, directory: Self.directory, config: configURL)
        let api = CoreAPI(port: engineConfig.apiPort, secret: secret)
        self.api = api
        var version: String?
        for _ in 0..<50 {
            if !runner.isRunning { break }
            if let found = try? await api.version() {
                version = found
                break
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard let version else {
            let tail = runner.logTail.split(separator: "\n").suffix(3).joined(separator: " ")
            runner.stop()
            self.api = nil
            throw CoreRunnerError.notReady(tail.isEmpty ? "没有响应" : tail)
        }
        lastConfigText = text
        restartAttempts = 0
        status = .running(version)
        Log.info("内核已启动，版本 \(version)，代理端口 \(engineConfig.mixedPort)")
        if let selected = engineConfig.selectedNode {
            try? await api.select(group: Self.selectorGroup, node: selected)
        }
        await refresh()
        onStatusChanged?()
    }

    func stopCore() {
        runner.stop()
        api = nil
        lastConfigText = nil
        status = .off
        nodes = []
        currentSelection = nil
        autoNode = nil
        subscriptionStatus = [:]
        onStatusChanged?()
    }

    private func coreExited(_ code: Int32) {
        // 启动阶段的退出由 startCore 自己处理（配置错误时反复重启没有意义）。
        guard api != nil, status != .starting else { return }
        api = nil
        lastConfigText = nil
        if engineConfig.wantsCore && restartAttempts < 3 {
            restartAttempts += 1
            status = .starting
            Log.error("内核意外退出（状态 \(code)），第 \(restartAttempts) 次重新启动")
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                await self?.reconcile()
            }
        } else {
            status = .failed("内核退出了（状态 \(code)）：\(runner.logTail.split(separator: "\n").suffix(2).joined(separator: " "))")
        }
        onStatusChanged?()
    }

    /// file:// 订阅复制到内核目录里（内核不读别处的文件）。
    private func copyFileSubscriptions(_ engine: EngineConfig) throws {
        let fm = FileManager.default
        for subscription in engine.activeSubscriptions {
            guard let source = subscription.filePath else { continue }
            let target = CoreConfigBuilder.providerPath(for: subscription, directory: Self.directory)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Data(contentsOf: URL(fileURLWithPath: source))
            try data.write(to: target, options: .atomic)
        }
    }

    private func prepareDirectory() throws {
        let directory = Self.directory
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("providers"), withIntermediateDirectories: true)
        // GeoIP 数据库：从 app 里复制一份（内核按 Country.mmdb 这个名字找）。
        if let bundled = CoreBinary.geoIPURL {
            let target = directory.appendingPathComponent("Country.mmdb")
            let bundledSize = (try? FileManager.default.attributesOfItem(atPath: bundled.path)[.size] as? Int) ?? 0
            let targetSize = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) ?? -1
            if bundledSize != targetSize {
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: bundled, to: target)
            }
        }
    }

    private func write(_ text: String) throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try text.write(to: configURL, atomically: true, encoding: .utf8)
    }

    private func portsChanged(from old: String?, to new: String) -> Bool {
        guard let old else { return true }
        func ports(_ text: String) -> [String] {
            text.split(separator: "\n").filter { $0.hasPrefix("mixed-port:") || $0.hasPrefix("external-controller:") }.map(String.init)
        }
        return ports(old) != ports(new)
    }

    // MARK: - 配置生成

    private func generateConfig(_ engine: EngineConfig) async throws -> String {
        try copyFileSubscriptions(engine)
        let rules = try await rules(for: engine)
        let input = CoreConfigBuilder.Input(engine: engine, secret: secret, directory: Self.directory, testURL: readConfig().testURL, rules: rules)
        return CoreConfigBuilder.yaml(input)
    }

    private func rules(for engine: EngineConfig) async throws -> [String] {
        switch engine.mode {
        case .global:
            rulesInfo = "全局代理：全部走节点"
            return RuleConverter.globalRules
        case .rule:
            switch engine.ruleSource {
            case .chinaDirect:
                rulesInfo = "内置规则：局域网和国内 IP 直连，其余走节点"
                return RuleConverter.chinaDirectRules
            case .url(let url):
                if let cache = ruleCache, cache.source == engine.ruleSource {
                    return cache.rules
                }
                rulesInfo = "正在下载规则…"
                let result = try await RuleFetcher.fetch(url: url, directory: Self.directory)
                ruleCache = (engine.ruleSource, result.rules)
                var info = "\(result.rules.count) 条规则"
                info += result.fromCache ? "（缓存，\(Self.relative(result.fetchedAt))）" : "（刚下载）"
                if !result.warnings.isEmpty {
                    info += "，" + result.warnings.joined(separator: "，")
                }
                rulesInfo = info
                return result.rules
            }
        }
    }

    /// 重新下载规则并应用。
    func updateRules() async {
        guard case .url(let url) = engineConfig.ruleSource else { return }
        do {
            let result = try await RuleFetcher.fetch(url: url, directory: Self.directory, force: true)
            ruleCache = (engineConfig.ruleSource, result.rules)
            rulesInfo = "\(result.rules.count) 条规则（刚下载）" + (result.warnings.isEmpty ? "" : "，" + result.warnings.joined(separator: "，"))
            lastConfigText = nil
            await reconcile()
        } catch {
            lastError = error.localizedDescription
            rulesInfo = "下载规则失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 节点

    func refresh() async {
        guard let api else { return }
        do {
            async let proxiesTask = api.proxies()
            async let providersTask = api.providers()
            let (proxies, providers) = try await (proxiesTask, providersTask)
            currentSelection = proxies[Self.selectorGroup]?.now
            autoNode = proxies[Self.autoGroup]?.now
            var list: [Node] = []
            var statuses: [UUID: SubscriptionStatus] = [:]
            for subscription in engineConfig.activeSubscriptions {
                guard let provider = providers[subscription.providerName] else { continue }
                statuses[subscription.id] = SubscriptionStatus(nodeCount: provider.proxies.count, info: provider.subscriptionInfo, updatedAt: Self.parseDate(provider.updatedAt))
                for proxy in provider.proxies {
                    list.append(Node(name: proxy.name, type: proxy.type, delay: proxy.lastDelay, subscription: subscription.name))
                }
            }
            if list.map(\.name) != nodes.map(\.name) {
                Log.info("读取到 \(list.count) 个节点")
            }
            nodes = list
            subscriptionStatus = statuses
            onStatusChanged?()
        } catch {
            Log.error("读取节点列表失败：\(error.localizedDescription)")
        }
    }

    /// 选节点；nil 是自动选择。
    func select(_ node: String?) async {
        guard let api else { return }
        let target = node ?? Self.autoGroup
        do {
            try await api.select(group: Self.selectorGroup, node: target)
            var engine = engineConfig
            engine.selectedNode = node
            writeEngine?(engine)
            await refresh()
            Log.info("已切换到节点：\(target)")
        } catch {
            lastError = "切换节点失败：\(error.localizedDescription)"
        }
    }

    func testAll() async {
        guard let api, !testing else { return }
        testing = true
        let delays = (try? await api.groupDelay(group: Self.selectorGroup, url: readConfig().testURL)) ?? [:]
        nodes = nodes.map { node in
            var node = node
            node.delay = delays[node.name] ?? 0
            return node
        }
        testing = false
        await refresh()
    }

    func test(node name: String) async {
        guard let api else { return }
        let delay = (try? await api.delay(node: name, url: readConfig().testURL)) ?? 0
        if let index = nodes.firstIndex(where: { $0.name == name }) {
            nodes[index].delay = delay
        }
    }

    // MARK: - 设置

    func setEnabled(_ enabled: Bool) {
        var engine = engineConfig
        engine.enabled = enabled
        writeEngine?(engine)
    }

    func setMode(_ mode: EngineMode) {
        var engine = engineConfig
        engine.mode = mode
        writeEngine?(engine)
    }

    func setRuleSource(_ source: RuleSource) {
        var engine = engineConfig
        engine.ruleSource = source
        writeEngine?(engine)
    }

    func setPorts(mixed: Int, api: Int) {
        var engine = engineConfig
        engine.mixedPort = mixed
        engine.apiPort = api
        writeEngine?(engine)
    }

    @discardableResult
    func addSubscription(name: String, url: String) -> String? {
        if let problem = Subscription.validate(url: url) { return problem }
        var engine = engineConfig
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        engine.subscriptions.append(Subscription(name: trimmedName.isEmpty ? "订阅 \(engine.subscriptions.count + 1)" : trimmedName, url: url.trimmingCharacters(in: .whitespacesAndNewlines)))
        writeEngine?(engine)
        return nil
    }

    func removeSubscription(_ id: UUID) {
        var engine = engineConfig
        engine.subscriptions.removeAll { $0.id == id }
        writeEngine?(engine)
        subscriptionStatus[id] = nil
    }

    func setSubscription(_ id: UUID, enabled: Bool) {
        var engine = engineConfig
        guard let index = engine.subscriptions.firstIndex(where: { $0.id == id }) else { return }
        engine.subscriptions[index].enabled = enabled
        writeEngine?(engine)
    }

    /// 让内核重新下载订阅（file:// 的先重新复制）。
    func updateSubscription(_ id: UUID) async {
        guard let api, let subscription = engineConfig.subscriptions.first(where: { $0.id == id }) else { return }
        updatingSubscription = id
        do {
            if subscription.filePath != nil {
                try copyFileSubscriptions(engineConfig)
            }
            try await api.updateProvider(subscription.providerName)
            await refresh()
            Log.info("订阅「\(subscription.name)」已更新")
        } catch {
            lastError = "更新订阅「\(subscription.name)」失败：\(error.localizedDescription)"
        }
        updatingSubscription = nil
    }

    func updateAllSubscriptions() async {
        for subscription in engineConfig.activeSubscriptions {
            await updateSubscription(subscription.id)
        }
    }

    // MARK: - 工具

    private static let dateFormatters: [ISO8601DateFormatter] = {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [fractional, ISO8601DateFormatter()]
    }()

    static func parseDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        for formatter in dateFormatters {
            if let date = formatter.date(from: text) {
                // 内核还没更新过时给的是零时间（0001-01-01）。
                return date.timeIntervalSince1970 > 0 ? date : nil
            }
        }
        return nil
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func bytesText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }
}
