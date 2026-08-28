import Foundation

/// Runs whisper.cpp's whisper-cli against a WAV file.
enum Transcriber {
    enum TranscriberError: LocalizedError {
        case cliNotFound
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cliNotFound:
                return "Не найден whisper-cli. Установите его: brew install whisper-cpp"
            case .failed(let message):
                return "Ошибка распознавания: \(message)"
            }
        }
    }

    static func findCLI() -> String? {
        let candidates = [
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
            "/opt/homebrew/bin/whisper-cpp",
            "/usr/local/bin/whisper-cpp",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Blocking; call from a background queue.
    static func transcribe(wav: URL, model: URL, language: String) throws -> String {
        guard let cli = findCLI() else { throw TranscriberError.cliNotFound }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = [
            "-m", model.path,
            "-f", wav.path,
            "-l", language,
            "-nt", // no timestamps
            "-np", // no extra prints
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errData, encoding: .utf8) ?? "код \(process.terminationStatus)"
            throw TranscriberError.failed(String(message.suffix(300)))
        }

        let raw = String(data: outData, encoding: .utf8) ?? ""
        // Segments arrive one per line; dictation should be a single flowing text.
        let text = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return text
    }
}
