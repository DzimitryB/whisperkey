import Foundation

struct CatalogModel {
    let title: String
    let file: String
}

/// Manages whisper.cpp GGML models in ~/Library/Application Support/WhisperKey/models.
final class ModelManager: NSObject {
    static let shared = ModelManager()

    static let catalog: [CatalogModel] = [
        CatalogModel(title: "large-v3-turbo q5 — рекомендуется (~574 МБ)", file: "ggml-large-v3-turbo-q5_0.bin"),
        CatalogModel(title: "large-v3-turbo (~1.6 ГБ)", file: "ggml-large-v3-turbo.bin"),
        CatalogModel(title: "large-v3 — максимум качества (~3.1 ГБ)", file: "ggml-large-v3.bin"),
        CatalogModel(title: "medium (~1.5 ГБ)", file: "ggml-medium.bin"),
        CatalogModel(title: "small (~488 МБ)", file: "ggml-small.bin"),
        CatalogModel(title: "base (~148 МБ)", file: "ggml-base.bin"),
    ]

    static let baseURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/")!

    let modelsDirectory: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhisperKey/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Files currently being downloaded, mapped to progress 0...1.
    private(set) var downloads: [String: Double] = [:]
    /// Called on the main thread whenever download state changes.
    var onDownloadStateChange: (() -> Void)?

    func installedModels() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: modelsDirectory.path)) ?? []
        return files.filter { $0.hasSuffix(".bin") }.sorted()
    }

    var defaultModelFile: String? {
        get {
            let stored = UserDefaults.standard.string(forKey: "defaultModel")
            let installed = installedModels()
            if let stored, installed.contains(stored) { return stored }
            return installed.first
        }
        set { UserDefaults.standard.set(newValue, forKey: "defaultModel") }
    }

    var defaultModelURL: URL? {
        guard let file = defaultModelFile else { return nil }
        return modelsDirectory.appendingPathComponent(file)
    }

    func download(file: String) {
        guard downloads[file] == nil else { return }
        downloads[file] = 0
        notify()
        let url = Self.baseURL.appendingPathComponent(file)
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.downloadTask(with: url)
        task.taskDescription = file
        task.resume()
    }

    private func notify() {
        DispatchQueue.main.async { [weak self] in self?.onDownloadStateChange?() }
    }
}

extension ModelManager: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard let file = downloadTask.taskDescription, totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.downloads[file] = progress
            self.onDownloadStateChange?()
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let file = downloadTask.taskDescription else { return }
        let dest = modelsDirectory.appendingPathComponent(file)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.moveItem(at: location, to: dest)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.downloads[file] = nil
            if self.defaultModelFile == nil || self.installedModels().count == 1 {
                self.defaultModelFile = file
            }
            self.onDownloadStateChange?()
        }
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard error != nil, let file = task.taskDescription else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.downloads[file] = nil
            self.onDownloadStateChange?()
        }
        session.finishTasksAndInvalidate()
    }
}
