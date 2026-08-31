import AVFoundation

/// Records the default microphone, converting on the fly to 16 kHz mono Int16 —
/// the format whisper.cpp expects.
final class Recorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Int16] = []
    private let lock = NSLock()
    private(set) var isRecording = false

    /// Called from the audio tap queue with the peak level (0...1) of each chunk.
    var levelHandler: ((Float) -> Void)?

    /// Called once per recording, from the audio tap queue, when the first real
    /// samples arrive — i.e. the mic hardware is actually capturing. Before this
    /// moment anything spoken is lost, so the UI should not claim "recording" yet.
    var onFirstBuffer: (() -> Void)?
    private var firstBufferReported = false

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

        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw RecorderError.noInput
        }
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true
        ), let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw RecorderError.converterFailed
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.append(buffer, to: outFormat)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        isRecording = true
    }

    /// Stops and returns a WAV file URL, or nil if nothing meaningful was recorded.
    func stop() -> URL? {
        finishEngine()
        lock.lock()
        let captured = samples
        samples.removeAll()
        lock.unlock()
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

    private func finishEngine() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        converter = nil
    }

    private func append(_ buffer: AVAudioPCMBuffer, to outFormat: AVAudioFormat) {
        guard let converter else { return }
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

        if !firstBufferReported {
            firstBufferReported = true
            onFirstBuffer?()
        }

        if let levelHandler {
            var peak: Int16 = 0
            for s in chunk {
                let magnitude = s == Int16.min ? Int16.max : abs(s)
                if magnitude > peak { peak = magnitude }
            }
            levelHandler(Float(peak) / 32767)
        }
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
