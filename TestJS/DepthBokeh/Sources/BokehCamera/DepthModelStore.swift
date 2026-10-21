// 从 DepthBokehCamera 2 迁移：准备 0.5× 超广角用的 AI 深度模型。优先顺序：
//   1. App 里打包的模型（任何名字里带 "depth" 的 .mlmodelc —— 把 DepthAnythingV2SmallF16.mlpackage 拖进 Xcode 工程即可）
//   2. 之前下载并编译好的模型（Application Support）
//   3. 从 Hugging Face（国内先试 hf-mirror.com）下载 Apple 的 Core ML 版 Depth Anything V2 Small F16（约 50 MB），在手机上编译
#if os(iOS)
import Foundation
import CoreML

enum DepthModelStatus: Equatable {
    case idle
    case downloading(Double)   // 0...1
    case compiling
    case ready
    case failed(String)
}

final class DepthModelStore: @unchecked Sendable {   // mutable state is guarded by `lock`

    static let shared = DepthModelStore()

    static let modelName = "DepthAnythingV2SmallF16"
    private static let repoPath = "/apple/coreml-depth-anything-v2-small/resolve/main/DepthAnythingV2SmallF16.mlpackage/"
    /// Files inside the .mlpackage and their exact sizes (used to verify the download).
    private static let files: [(path: String, size: Int64)] = [
        ("Manifest.json", 617),
        ("Data/com.apple.CoreML/model.mlmodel", 399_433),
        ("Data/com.apple.CoreML/weights/weight.bin", 49_419_072)
    ]

    private let lock = NSLock()
    private var currentStatus: DepthModelStatus = .idle
    private var loadedEstimator: MonocularDepthEstimator?
    private var statusHandler: (@Sendable (DepthModelStatus) -> Void)?
    private var progressObservation: NSKeyValueObservation?
    private var lastReportedProgress = -1.0
    private let work = DispatchQueue(label: "depthbokeh.depthmodel", qos: .userInitiated)
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20       // fail fast on a blocked host, then try the mirror
        config.timeoutIntervalForResource = 30 * 60
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    var status: DepthModelStatus {
        lock.lock()
        defer { lock.unlock() }
        return currentStatus
    }

    /// The loaded estimator, or nil while the model is not ready.
    var estimator: MonocularDepthEstimator? {
        lock.lock()
        defer { lock.unlock() }
        return loadedEstimator
    }

    /// A model is already on the phone (bundled or downloaded before): no network needed.
    var isAvailableOffline: Bool {
        Self.bundledModelURL() != nil || FileManager.default.fileExists(atPath: installedURL.path)
    }

    /// Called on every status change (on an arbitrary queue).
    func setStatusHandler(_ handler: @escaping @Sendable (DepthModelStatus) -> Void) {
        lock.lock()
        statusHandler = handler
        let status = currentStatus
        lock.unlock()
        handler(status)
    }

    /// Makes the model available (bundled → installed → download). Safe to call repeatedly.
    func prepare() {
        lock.lock()
        switch currentStatus {
        case .downloading, .compiling, .ready:
            lock.unlock()
            return
        case .idle, .failed:
            currentStatus = .compiling   // "preparing"; becomes .downloading if a download is needed
        }
        lock.unlock()
        work.async { self.start() }
    }

    // MARK: - Steps

    private func start() {
        if let bundled = Self.bundledModelURL() {
            load(compiledURL: bundled)
            return
        }
        if FileManager.default.fileExists(atPath: installedURL.path) {
            load(compiledURL: installedURL)
            return
        }
        setStatus(.downloading(0))
        download(hostIndex: 0, fileIndex: 0, stagingDir: freshStagingDirectory())
    }

    /// Any compiled model in the app bundle whose name mentions "depth".
    static func bundledModelURL() -> URL? {
        for bundle in [Bundle.main, Bundle.module] {
            let urls = bundle.urls(forResourcesWithExtension: "mlmodelc", subdirectory: nil) ?? []
            if let url = urls.first(where: { $0.lastPathComponent.lowercased().contains("depth") }) { return url }
        }
        return nil
    }

    private var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DepthModels", isDirectory: true)
    }

    private var installedURL: URL {
        modelsDirectory.appendingPathComponent(Self.modelName + ".mlmodelc", isDirectory: true)
    }

    private func freshStagingDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DepthModelDownload", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        return dir
    }

    /// Mainland China first tries the mirror (huggingface.co is usually unreachable there).
    private var hosts: [String] {
        let official = "https://huggingface.co"
        let mirror = "https://hf-mirror.com"
        return Locale.current.region?.identifier == "CN" ? [mirror, official] : [official, mirror]
    }

    private func download(hostIndex: Int, fileIndex: Int, stagingDir: URL) {
        let hosts = self.hosts
        guard hostIndex < hosts.count else {
            setStatus(.failed("模型下载失败，请检查网络后点击重试"))
            return
        }
        let package = stagingDir.appendingPathComponent(Self.modelName + ".mlpackage", isDirectory: true)
        guard fileIndex < Self.files.count else {
            compile(packageURL: package, stagingDir: stagingDir)
            return
        }

        let file = Self.files[fileIndex]
        guard let url = URL(string: hosts[hostIndex] + Self.repoPath + file.path) else {
            setStatus(.failed("模型地址无效"))
            return
        }
        if fileIndex == 0 {
            lock.lock()
            lastReportedProgress = -1
            lock.unlock()
        }
        let totalBytes = Self.files.reduce(Int64(0)) { $0 + $1.size }
        let doneBytes = Self.files.prefix(fileIndex).reduce(Int64(0)) { $0 + $1.size }

        let task = session.downloadTask(with: url) { tempURL, response, error in
            let destination = package.appendingPathComponent(file.path)
            var ok = false
            if error == nil, let tempURL,
               let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                do {
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: tempURL, to: destination)
                    let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? -1
                    ok = size == file.size
                } catch {
                    ok = false
                }
            }
            let succeeded = ok
            self.work.async {
                if succeeded {
                    self.download(hostIndex: hostIndex, fileIndex: fileIndex + 1, stagingDir: stagingDir)
                } else {
                    print("[DepthModel] \(url.host ?? "") failed for \(file.path): \(String(describing: error))")
                    // Start over on the next host.
                    self.download(hostIndex: hostIndex + 1, fileIndex: 0, stagingDir: self.freshStagingDirectory())
                }
            }
        }
        lock.lock()
        progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            guard let self else { return }
            let bytes = Double(doneBytes) + progress.fractionCompleted * Double(file.size)
            self.reportProgress(bytes / Double(totalBytes))
        }
        lock.unlock()
        task.resume()
    }

    private func reportProgress(_ value: Double) {
        lock.lock()
        let shouldReport = value - lastReportedProgress >= 0.01 || value >= 1
        if shouldReport { lastReportedProgress = value }
        lock.unlock()
        if shouldReport { setStatus(.downloading(min(max(value, 0), 1))) }
    }

    private func compile(packageURL: URL, stagingDir: URL) {
        setStatus(.compiling)
        let installed = installedURL
        let modelsDir = modelsDirectory
        Task.detached(priority: .userInitiated) {
            do {
                let compiled = try await MLModel.compileModel(at: packageURL)
                try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: installed)
                try FileManager.default.moveItem(at: compiled, to: installed)
                var target = installed
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? target.setResourceValues(values)
                try? FileManager.default.removeItem(at: stagingDir)
                self.work.async { self.load(compiledURL: installed) }
            } catch {
                print("[DepthModel] compile failed: \(error)")
                self.setStatus(.failed("模型编译失败，点击重试"))
            }
        }
    }

    private func load(compiledURL: URL) {
        setStatus(.compiling)
        if let estimator = MonocularDepthEstimator(compiledModelURL: compiledURL) {
            lock.lock()
            loadedEstimator = estimator
            lock.unlock()
            setStatus(.ready)
        } else {
            // A damaged install: delete it so the next attempt downloads a fresh copy.
            if compiledURL == installedURL { try? FileManager.default.removeItem(at: compiledURL) }
            setStatus(.failed("模型加载失败，点击重试"))
        }
    }

    private func setStatus(_ status: DepthModelStatus) {
        lock.lock()
        currentStatus = status
        if case .downloading = status {} else { lastReportedProgress = -1 }
        let handler = statusHandler
        lock.unlock()
        handler?(status)
    }
}
#endif
