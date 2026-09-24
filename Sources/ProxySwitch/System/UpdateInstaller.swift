import CryptoKit
import Foundation

/// shasum -a 256 输出的校验文件：每行「哈希  文件名」。
enum Checksums {
    static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let hash = parts[0].lowercased()
            guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { continue }
            var name = parts[1...].joined(separator: " ")
            if name.hasPrefix("*") {
                name.removeFirst()
            }
            result[name] = hash
        }
        return result
    }

    /// 分块读文件算 SHA-256，返回小写十六进制。
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// 当前程序能不能就地替换。
enum Installability: Equatable {
    case ok(URL)
    /// 不是从 .app 运行（swift run）。
    case notBundle
    /// 被系统搬到了只读的临时位置（在下载文件夹里直接打开的程序会这样）。
    case translocated

    static func check(bundleURL: URL) -> Installability {
        guard bundleURL.pathExtension == "app" else { return .notBundle }
        if bundleURL.path.contains("/AppTranslocation/") {
            return .translocated
        }
        return .ok(bundleURL)
    }

    var problem: String? {
        switch self {
        case .ok: return nil
        case .notBundle: return "不是从 ProxySwitch.app 运行的，没法就地更新，请到发布页下载"
        case .translocated: return "程序正从只读的临时位置运行（通常是在下载文件夹里直接打开的），请先把 ProxySwitch.app 移到「应用程序」再更新"
        }
    }
}

/// 下载、校验、解压、替换、重新启动。除了 relaunch 都是异步的，不阻塞界面。
enum UpdateInstaller {
    static let dittoPath = "/usr/bin/ditto"
    static let xattrPath = "/usr/bin/xattr"
    static let codesignPath = "/usr/bin/codesign"

    /// 下载到 destination，progress 收到 0…1 的进度（总大小未知时是 nil）。
    static func download(_ url: URL, expectedSize: Int?, to destination: URL, progress: @escaping @Sendable (Double?) -> Void) async throws {
        let delegate = DownloadDelegate(destination: destination, expectedSize: expectedSize, progress: progress)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 15 * 60
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue(UpdateChecker.userAgent, forHTTPHeaderField: "User-Agent")
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.completion = { result in continuation.resume(with: result) }
                session.downloadTask(with: request).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    /// 下载校验文件并比对 zip 的 SHA-256。
    static func verify(archive: URL, checksumsURL: URL) async throws {
        var request = URLRequest(url: checksumsURL)
        request.setValue(UpdateChecker.userAgent, forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError.server(http.statusCode)
        }
        let expected = Checksums.parse(String(decoding: data, as: UTF8.self))
        guard let hash = expected[archive.lastPathComponent] else { throw UpdateError.checksumsMissing }
        let actual = try Checksums.sha256(of: archive)
        guard actual == hash else { throw UpdateError.checksumMismatch }
    }

    /// 解压到 directory，返回里面的 .app。
    static func extract(archive: URL, to directory: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = try await Shell.run(dittoPath, ["-x", "-k", archive.path, directory.path], timeout: 120)
        guard result.succeeded else { throw UpdateError.extract(result.trimmedOutput) }
        let items = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard let app = items.first(where: { $0.pathExtension == "app" }) else { throw UpdateError.appNotFound }
        // 自己下载并校验过的更新，去掉隔离标记，否则换上去之后系统会再拦一次。
        _ = try? await Shell.run(xattrPath, ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    /// 确认解压出来的确实是对应版本的 ProxySwitch，签名完整。
    static func validate(app: URL, expectedVersion: String) async throws {
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw UpdateError.wrongApp("读不到 Info.plist")
        }
        let identifier = plist["CFBundleIdentifier"] as? String ?? ""
        if let ours = Bundle.main.bundleIdentifier, identifier != ours {
            throw UpdateError.wrongApp("bundle identifier 是 \(identifier)")
        }
        let version = plist["CFBundleShortVersionString"] as? String ?? ""
        guard version == expectedVersion else {
            throw UpdateError.wrongApp("版本是 \(version)，不是 \(expectedVersion)")
        }
        let result = try await Shell.run(codesignPath, ["--verify", "--deep", "--strict", app.path], timeout: 120)
        guard result.succeeded else { throw UpdateError.wrongApp("签名校验失败：\(result.trimmedOutput)") }
    }

    /// 把 newApp 换到 target 的位置：先挪到同一个目录里的隐藏名字，再改名，失败就换回去。
    /// 目录没有写权限（标准账户装在「应用程序」里）时，改用系统的授权对话框以管理员身份做同样的事。
    static func install(newApp: URL, replacing target: URL) async throws {
        let parent = target.deletingLastPathComponent()
        let staged = parent.appendingPathComponent(".\(target.lastPathComponent).update")
        let backup = parent.appendingPathComponent(".\(target.lastPathComponent).previous")
        do {
            try swap(newApp: newApp, target: target, staged: staged, backup: backup)
        } catch let error as NSError where isPermissionError(error) {
            Log.info("替换程序需要管理员权限，改用授权对话框（\(error.localizedDescription)）")
            let source = FileManager.default.fileExists(atPath: staged.path) ? staged : newApp
            try await swapPrivileged(source: source, target: target, staged: staged, backup: backup)
        } catch {
            throw UpdateError.install(error.localizedDescription)
        }
    }

    private static func swap(newApp: URL, target: URL, staged: URL, backup: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: staged)
        try? fm.removeItem(at: backup)
        try fm.moveItem(at: newApp, to: staged)
        try fm.moveItem(at: target, to: backup)
        do {
            try fm.moveItem(at: staged, to: target)
        } catch {
            try? fm.moveItem(at: backup, to: target)
            throw error
        }
        try? fm.removeItem(at: backup)
    }

    private static func swapPrivileged(source: URL, target: URL, staged: URL, backup: URL) async throws {
        let q = Shell.shellQuote
        let script = [
            "rm -rf \(q(staged.path)) \(q(backup.path))",
            "mv \(q(source.path)) \(q(staged.path))",
            "mv \(q(target.path)) \(q(backup.path))",
            "{ mv \(q(staged.path)) \(q(target.path)) || { mv \(q(backup.path)) \(q(target.path)); exit 1; }; }",
            "rm -rf \(q(backup.path))",
        ].joined(separator: " && ")
        let appleScript = "do shell script " + Shell.appleScriptString(script) + " with administrator privileges"
        let result = try await Shell.run(SystemProxy.osascriptPath, ["-e", appleScript], timeout: 300)
        guard result.succeeded else {
            let text = result.trimmedOutput
            if text.contains("-128") {
                throw UpdateError.cancelledByUser
            }
            throw UpdateError.install(text)
        }
    }

    static func isPermissionError(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain,
           [NSFileReadNoPermissionError, NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError].contains(error.code) {
            return true
        }
        if error.domain == NSPOSIXErrorDomain, [Int(EACCES), Int(EPERM), Int(EROFS)].contains(error.code) {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isPermissionError(underlying)
        }
        return false
    }

    /// 等当前进程退出后再打开新程序：起一个独立的 sh 等着，自己退出时它不受影响。
    static func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "n=0; while /bin/kill -0 \(pid) 2>/dev/null && [ $n -lt 300 ]; do /bin/sleep 0.2; n=$((n+1)); done; /usr/bin/open \(Shell.shellQuote(app.path))"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Log.error("启动重新打开程序的辅助进程失败：\(error)")
        }
    }
}

/// 把 URLSession 的下载回调接到 async 调用上，顺便报告进度。
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let destination: URL
    let expectedSize: Int?
    let progress: @Sendable (Double?) -> Void
    var completion: ((Result<Void, Error>) -> Void)?

    init(destination: URL, expectedSize: Int?, progress: @escaping @Sendable (Double?) -> Void) {
        self.destination = destination
        self.expectedSize = expectedSize
        self.progress = progress
    }

    private func finish(_ result: Result<Void, Error>) {
        completion?(result)
        completion = nil
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        var total = totalBytesExpectedToWrite
        if total <= 0, let expectedSize, expectedSize > 0 {
            total = Int64(expectedSize)
        }
        progress(total > 0 ? min(1, Double(totalBytesWritten) / Double(total)) : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(.failure(UpdateError.server(http.statusCode)))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else {
            finish(.failure(UpdateError.badResponse))
            return
        }
        if (error as? URLError)?.code == .cancelled {
            finish(.failure(CancellationError()))
        } else {
            finish(.failure(error))
        }
    }
}
