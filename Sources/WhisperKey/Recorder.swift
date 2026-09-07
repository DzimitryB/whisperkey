import AVFoundation

/// Records the default microphone, converting on the fly to 16 kHz mono Int16 —
/// the format whisper.cpp expects.
///
/// A fresh AVAudioEngine is created for every recording so the CURRENT default
/// input device is always picked up (a long-lived engine stays bound to the device
/// that was default at first use — switching headphones → built-in mic would leave
/// it capturing silence). If the audio configuration changes mid-recording, the
/// engine is rebuilt on the new device and capture continues.
final class Recorder {
    private var engine: AVAudioEngine?
    private var samples: [Int16] = []
    private let lock = NSLock()
    private var configObserver: NSObjectProtocol?
    private(set) var isRecording = false

    /// Called from the audio tap queue with the peak level (0...1) of each chunk.
    var levelHandler: ((Float) -> Void)?

    /// Called once per recording, from the audio tap queue, when the first samples
    /// with an actual signal arrive — the hardware can deliver zero-filled buffers
    /// while warming up, so buffer arrival alone doesn't mean audio is captured yet.
    var onFirstBuffer: (() -> Void)?
    private var firstBufferReported = false

    /// Below this int16 peak a chunk is treated as digital silence from a warming-up mic.
    private static let signalThreshold: Int16 = 10

    private let outFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true
    )!

    enum RecorderError: LocalizedError {
        case noInput
        case converterFailed

        var errorDescription: String? {
            switch self {
            case .noInput: return L("err.noInput")
            case .converterFailed: return L("err.converter")
            }
        }
    }

    func start() throws {
        lock.lock()
        samples.removeAll()
        lock.unlock()
        firstBufferReported = false

        try startEngine()
        isRecording = true

        // Rebuild the engine if the audio device changes mid-recording
        // (e.g. switching from headphones to the built-in mic).
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    /// Stops and returns a WAV file URL, or nil if nothing meaningful was recorded.
    func stop() -> URL? {
        finishEngine()
        lock.lock()
        var captured = samples
        samples.removeAll()
        lock.unlock()

        // Drop the leading digital silence from mic warm-up (keep a 0.1s margin).
        guard let firstSignal = captured.firstIndex(where: {
            $0 >= Self.signalThreshold || $0 <= -Self.signalThreshold
        }) else { return nil }
        captured.removeFirst(max(0, firstSignal - 1600))

        // Less than ~0.3s of audio is a misfire.
        guard captured.count > 4800 else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperkey-\(UUID().uuidString).wav")
        do {
            try Self.writeWAV(samples: captured, to: url)
            return url
        } catch {
            return nil
        }
    }

    func cancel() {
        finishEngine()
        lock.lock()
        samples.removeAll()
        lock.unlock()
    }

    // MARK: - Engine lifecycle

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw RecorderError.noInput
        }
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw RecorderError.converterFailed
        }
        // The converter is captured by the tap closure: each engine gets its own,
        // so a mid-recording rebuild never races the audio thread.
        let outFormat = self.outFormat
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.append(buffer, converter: converter, to: outFormat)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
    }

    private func teardownEngine() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }

    private func handleConfigurationChange() {
        guard isRecording else { return }
        teardownEngine()
        // Give CoreAudio a moment to settle on the new device, then resume capture.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.isRecording, self.engine == nil else { return }
            try? self.startEngine()
        }
    }

    private func finishEngine() {
        guard isRecording else { return }
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
        configObserver = nil
        teardownEngine()
        isRecording = false
    }

    // MARK: - Audio data

    private func append(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, to outFormat: AVAudioFormat) {
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let channel = out.int16ChannelData else { return }
        let chunk = Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()

        var peak: Int16 = 0
        for s in chunk {
            let magnitude = s == Int16.min ? Int16.max : abs(s)
            if magnitude > peak { peak = magnitude }
        }

        if !firstBufferReported && peak >= Self.signalThreshold {
            firstBufferReported = true
            onFirstBuffer?()
        }

        levelHandler?(Float(peak) / 32767)
    }

    private static func writeWAV(samples: [Int16], to url: URL) throws {
        let sampleRate: UInt32 = 16000
        let dataSize = UInt32(samples.count * 2)
        var data = Data(capacity: Int(dataSize) + 44)

        func append16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func append32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        data.append(contentsOf: Array("RIFF".utf8))
        append32(36 + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append32(16)
        append16(1) // PCM
        append16(1) // mono
        append32(sampleRate)
        append32(sampleRate * 2) // byte rate
        append16(2) // block align
        append16(16) // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append32(dataSize)
        samples.withUnsafeBytes { data.append(contentsOf: $0) }

        try data.write(to: url)
    }
}
