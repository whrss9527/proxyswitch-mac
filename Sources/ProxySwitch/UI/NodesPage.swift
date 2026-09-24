import AppKit
import SwiftUI

/// 节点与订阅页：订阅地址、代理模式、规则来源、端口、内核状态和日志。
struct NodesPage: View {
    @ObservedObject var state: AppState
    @ObservedObject var engine: Engine
    @State private var newName = ""
    @State private var newURL = ""
    @State private var addProblem: String?
    @State private var customMode = false
    @State private var customRuleURL = ""
    @State private var mixedPortText = ""
    @State private var apiPortText = ""
    @State private var showLog = false
    @State private var logText = ""

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "节点与订阅", subtitle: "填一个机场的订阅地址，节点就会出现在面板里；支持全局代理和按规则分流")
            Form {
                coreSection
                subscriptionsSection
                modeSection
                portsSection
                if showLog {
                    logSection
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .onAppear {
            mixedPortText = String(state.config.engine.mixedPort)
            apiPortText = String(state.config.engine.apiPort)
            customRuleURL = state.config.engine.ruleSource.url ?? ""
        }
    }

    // MARK: - 内核

    private var coreSection: some View {
        Section("内置代理") {
            Toggle("启用内置代理（内核 mihomo）", isOn: Binding(get: { state.config.engine.enabled }, set: { engine.setEnabled($0) }))
            LabeledContent("状态") { statusView }
            if !engine.coreAvailable {
                Label("这个 ProxySwitch 里没有打包内核，请到发布页重新下载完整版本", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let profile = state.engineProfile {
                Text("配置列表里的「\(profile.name)」就是它：开启后系统代理指向 127.0.0.1:\(String(profile.port))，面板里可以选节点、切换模式。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("添加订阅后，配置列表里会多一条「节点代理」，开关它就是开关内置代理。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("重启内核") {
                    Task { await engine.restartCore() }
                }
                .disabled(!state.config.engine.wantsCore)
                Button(showLog ? "隐藏日志" : "查看日志") { showLog.toggle() }
            }
            if let error = engine.lastError {
                Label(error, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch engine.status {
        case .off:
            Text(state.config.engine.wantsCore ? "未运行" : "还没有订阅")
                .foregroundStyle(.secondary)
        case .starting:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("正在启动…")
                    .foregroundStyle(.secondary)
            }
        case .running(let version):
            Label("运行中 · mihomo \(version) · \(engine.nodes.count) 个节点", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle")
                .foregroundStyle(.red)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - 订阅

    private var subscriptionsSection: some View {
        Section("订阅") {
            if state.config.engine.subscriptions.isEmpty {
                Text("还没有订阅。把机场给你的订阅地址粘到下面，节点由内核下载和解析。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(state.config.engine.subscriptions) { subscription in
                SubscriptionRow(
                    subscription: subscription,
                    status: engine.subscriptionStatus[subscription.id],
                    updating: engine.updatingSubscription == subscription.id,
                    canUpdate: engine.isRunning,
                    onUpdate: { Task { await engine.updateSubscription(subscription.id) } },
                    onToggle: { engine.setSubscription(subscription.id, enabled: $0) },
                    onDelete: { engine.removeSubscription(subscription.id) }
                )
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("", text: $newName, prompt: Text("名称（可选）"))
                        .labelsHidden()
                        .frame(width: 140)
                    TextField("", text: $newURL, prompt: Text("订阅地址 https://…"))
                        .labelsHidden()
                        .onSubmit { add() }
                    Button("添加") { add() }
                        .disabled(newURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let addProblem {
                    Text(addProblem)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            if !state.config.engine.subscriptions.isEmpty {
                Text("订阅每 \(String(state.config.engine.updateIntervalHours)) 小时自动更新一次。内核以 clash.meta 的身份下载，机场返回 Clash 配置或 base64 节点列表都可以。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func add() {
        addProblem = engine.addSubscription(name: newName, url: newURL)
        if addProblem == nil {
            newName = ""
            newURL = ""
            state.selectEngineProfile()
        }
    }

    // MARK: - 模式与规则

    private var modeSection: some View {
        Section("模式") {
            Picker("代理模式", selection: Binding(get: { state.config.engine.mode }, set: { engine.setMode($0) })) {
                ForEach(EngineMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text(state.config.engine.mode == .global ? "全局代理：除局域网外的全部流量都走选中的节点。" : "规则分流：按规则决定哪些走节点、哪些直连、哪些拦截，其余按规则文件里的默认策略。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if state.config.engine.mode == .rule {
                Picker("规则来源", selection: ruleSelection) {
                    Text("内置：国内直连，其余走节点").tag("builtin")
                    ForEach(RulePresets.all) { preset in
                        Text("\(preset.name) — \(preset.detail)").tag(preset.url)
                    }
                    Text("自定义地址…").tag("custom")
                }
                if isCustom {
                    HStack {
                        TextField("", text: $customRuleURL, prompt: Text("小火箭 / Surge / Clash 格式的规则地址"))
                            .labelsHidden()
                            .onSubmit { applyCustomRule() }
                        Button("应用") { applyCustomRule() }
                            .disabled(customRuleURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                HStack {
                    Text(engine.rulesInfo)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if state.config.engine.ruleSource.url != nil {
                        Button("重新下载规则") {
                            Task { await engine.updateRules() }
                        }
                        .controlSize(.small)
                    }
                }
                Text("预设来自 johnshall/Shadowrocket-ADBlock-Rules-Forever。规则里「Proxy」类的策略都走面板里选中的节点，规则每 7 天自动重新下载。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var isCustom: Bool {
        if customMode { return true }
        if let url = state.config.engine.ruleSource.url, RulePresets.preset(for: url) == nil { return true }
        return false
    }

    private var ruleSelection: Binding<String> {
        Binding(
            get: {
                if customMode { return "custom" }
                switch state.config.engine.ruleSource {
                case .chinaDirect: return "builtin"
                case .url(let url): return RulePresets.preset(for: url) != nil ? url : "custom"
                }
            },
            set: { value in
                switch value {
                case "builtin":
                    customMode = false
                    engine.setRuleSource(.chinaDirect)
                case "custom":
                    customMode = true
                default:
                    customMode = false
                    engine.setRuleSource(.url(value))
                }
            }
        )
    }

    private func applyCustomRule() {
        let url = customRuleURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        customMode = false
        engine.setRuleSource(.url(url))
    }

    // MARK: - 端口

    private var portsValid: Bool {
        guard let mixed = Int(mixedPortText), let api = Int(apiPortText) else { return false }
        return (1024...65535).contains(mixed) && (1024...65535).contains(api) && mixed != api
    }

    private var portsChanged: Bool {
        Int(mixedPortText) != state.config.engine.mixedPort || Int(apiPortText) != state.config.engine.apiPort
    }

    private var portsSection: some View {
        Section("端口") {
            HStack {
                TextField("代理端口", text: $mixedPortText)
                    .onChange(of: mixedPortText) { _, value in
                        let digits = value.filter(\.isNumber)
                        if digits != value { mixedPortText = digits }
                    }
                TextField("API 端口", text: $apiPortText)
                    .onChange(of: apiPortText) { _, value in
                        let digits = value.filter(\.isNumber)
                        if digits != value { apiPortText = digits }
                    }
                Button("应用") {
                    engine.setPorts(mixed: Int(mixedPortText) ?? 7890, api: Int(apiPortText) ?? 9097)
                }
                .disabled(!portsValid || !portsChanged)
            }
            Text("改端口后内核会重启，配置列表里「节点代理」的端口会跟着改。默认代理端口 7890、API 端口 9097。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 日志

    private var logSection: some View {
        Section("内核日志") {
            ScrollView {
                Text(logText.isEmpty ? "还没有日志" : logText)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 200)
            Text("完整日志在配置目录的 core/core.log。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task {
            while !Task.isCancelled {
                logText = engine.logTail
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

/// 订阅列表里的一行。
struct SubscriptionRow: View {
    var subscription: Subscription
    var status: Engine.SubscriptionStatus?
    var updating: Bool
    var canUpdate: Bool
    var onUpdate: () -> Void
    var onToggle: (Bool) -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Toggle("", isOn: Binding(get: { subscription.enabled }, set: onToggle))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(subscription.name)
                    .font(.system(size: 12, weight: .medium))
                Text(subscription.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if updating {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("更新") { onUpdate() }
                    .controlSize(.small)
                    .disabled(!canUpdate || !subscription.enabled)
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("删除这条订阅")
        }
    }

    private var detail: String {
        guard subscription.enabled else { return "已停用" }
        guard let status else { return "还没有读取到节点" }
        var parts = ["\(status.nodeCount) 个节点"]
        if let info = status.info {
            if let total = info.total, total > 0 {
                parts.append("已用 \(Engine.bytesText(info.used)) / \(Engine.bytesText(total))")
            }
            if let expire = info.expireDate {
                parts.append("到期 \(Self.dateFormatter.string(from: expire))")
            }
        }
        if let updated = status.updatedAt {
            parts.append("更新于 \(Engine.relative(updated))")
        }
        return parts.joined(separator: " · ")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
