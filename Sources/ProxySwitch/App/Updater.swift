import AppKit
import Combine

/// 更新：检查 GitHub 上的新版本，下载、校验、替换程序并重新启动。状态只在主线程上改，界面直接观察它。
@MainActor
final class Updater: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        /// 有新版本，但用户选择过跳过它。
        case skipped(ReleaseInfo)
        case available(ReleaseInfo)
        case downloading(ReleaseInfo, Double?)
        case verifying(ReleaseInfo)
        case installing(ReleaseInfo)
        case relaunching(ReleaseInfo)
        /// 安装失败。
        case failed(ReleaseInfo, String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastChecked: Date?
    /// 最近一次检查失败的原因（手动检查时显示）。
    @Published private(set) var checkError: String?

    /// 自动检查发现新版本时通知（标题、正文）。
    var notify: (@MainActor (String, String) -> Void)?
    /// 新程序已经换好、该退出了。
    var onRelaunch: (@MainActor () -> Void)?

    static let checkInterval: TimeInterval = 6 * 3600
    private static let skippedKey = "update.skippedVersion"
    private static let notifiedKey = "update.notifiedVersion"

    private var timer: Timer?
    private var installTask: Task<Void, Never>?

    /// 发现的新版本（含正在安装和安装失败的），跳过的不算。
    var release: ReleaseInfo? {
        switch phase {
        case .available(let release), .downloading(let release, _), .verifying(let release),
             .installing(let release), .relaunching(let release), .failed(let release, _):
            return release
        case .idle, .checking, .upToDate, .skipped:
            return nil
        }
    }

    var isInstalling: Bool {
        switch phase {
        case .downloading, .verifying, .installing, .relaunching: return true
        default: return false
        }
    }

    /// 就地更新做不到时的原因（不是从 .app 运行、被系统搬到了只读的临时位置）。
    var installProblem: String? {
        Installability.check(bundleURL: Bundle.main.bundleURL).problem
    }

    var skippedVersion: String? {
        get { UserDefaults.standard.string(forKey: Self.skippedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.skippedKey) }
    }

    // MARK: - 检查

    /// 启动几秒后检查一次，之后每 6 小时一次；enabled 返回 false 时不检查。
    func startAutomaticChecks(enabled: @escaping @MainActor () -> Bool) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                if enabled() { await self?.check(manual: false) }
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if enabled() { await self?.check(manual: false) }
        }
    }

    /// 检查一次。manual：用户点的，失败要显示，跳过的版本也显示。返回可以安装的新版本。
    @discardableResult
    func check(manual: Bool) async -> ReleaseInfo? {
        if isInstalling { return release }
        if case .checking = phase { return nil }
        let previous = phase
        phase = .checking
        checkError = nil
        do {
            let latest = try await UpdateChecker.latest()
            lastChecked = Date()
            let current = UpdateChecker.currentVersion
            guard UpdateChecker.isNewer(latest.version, than: current) else {
                Log.info("检查更新：当前 \(current) 已是最新（最新发布 \(latest.version)）")
                phase = .upToDate
                return nil
            }
            if !manual, latest.version == skippedVersion {
                Log.info("检查更新：有新版本 \(latest.version)，之前选择过跳过")
                phase = .skipped(latest)
                return nil
            }
            Log.info("检查更新：有新版本 \(latest.version)（当前 \(current)）")
            phase = .available(latest)
            if !manual, UserDefaults.standard.string(forKey: Self.notifiedKey) != latest.version {
                UserDefaults.standard.set(latest.version, forKey: Self.notifiedKey)
                notify?("ProxySwitch 有新版本 \(latest.version)", "点击查看更新内容，可以一键安装")
            }
            return latest
        } catch {
            Log.error("检查更新失败：\(error.localizedDescription)")
            phase = previous
            if manual {
                checkError = "检查更新失败：\(error.localizedDescription)"
            }
            return nil
        }
    }

    func skipAvailableVersion() {
        guard case .available(let release) = phase else { return }
        skippedVersion = release.version
        phase = .skipped(release)
    }

    /// 跳过的版本重新拿出来看。
    func showSkippedVersion() {
        guard case .skipped(let release) = phase else { return }
        phase = .available(release)
    }

    // MARK: - 安装

    /// 下载并安装 release（当前发现的新版本），完成后重新启动。
    func install() {
        guard let release, !isInstalling, installTask == nil else { return }
        if let problem = installProblem {
            phase = .failed(release, problem)
            return
        }
        guard release.canInstall else {
            phase = .failed(release, UpdateError.noArchive.localizedDescription)
            return
        }
        installTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.perform(release)
            } catch is CancellationError {
                Log.info("更新已取消")
                self.phase = .available(release)
            } catch {
                Log.error("更新到 \(release.version) 失败：\(error.localizedDescription)")
                self.phase = .failed(release, error.localizedDescription)
            }
            self.installTask = nil
        }
    }

    func cancel() {
        installTask?.cancel()
    }

    /// 检查并直接安装（proxyswitch://update）。
    func checkAndInstall() async {
        if case .skipped = phase {
            showSkippedVersion()
        } else {
            await check(manual: true)
        }
        install()
    }

    private func perform(_ release: ReleaseInfo) async throws {
        guard case .ok(let target) = Installability.check(bundleURL: Bundle.main.bundleURL) else {
            throw UpdateError.notInstallable(installProblem ?? "")
        }
        guard let archiveURL = release.archiveURL, let checksumsURL = release.checksumsURL else {
            throw UpdateError.noArchive
        }
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("ProxySwitch-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        Log.info("开始更新到 \(release.version)：下载 \(archiveURL.absoluteString)")
        phase = .downloading(release, nil)
        let archive = workDir.appendingPathComponent(UpdateChecker.archiveName)
        try await UpdateInstaller.download(archiveURL, expectedSize: release.archiveSize, to: archive) { [weak self] fraction in
            Task { @MainActor in
                guard let self, case .downloading = self.phase else { return }
                self.phase = .downloading(release, fraction)
            }
        }
        try Task.checkCancellation()
        phase = .verifying(release)
        try await UpdateInstaller.verify(archive: archive, checksumsURL: checksumsURL)
        let app = try await UpdateInstaller.extract(archive: archive, to: workDir.appendingPathComponent("extracted", isDirectory: true))
        try await UpdateInstaller.validate(app: app, expectedVersion: release.version)
        try Task.checkCancellation()
        phase = .installing(release)
        try await UpdateInstaller.install(newApp: app, replacing: target)
        try? fm.removeItem(at: workDir)
        Log.info("已更新到 \(release.version)，重新启动")
        phase = .relaunching(release)
        UpdateInstaller.relaunch(target)
        try? await Task.sleep(for: .milliseconds(600))
        onRelaunch?()
    }
}
