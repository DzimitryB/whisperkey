import AudioToolbox
import AVFoundation
import CoreAudio

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

    /// Input device the running engine was built for, so spurious configuration
    /// notifications (macOS posts one right after every engine start) don't cause
    /// an endless teardown/restart loop that captures nothing.
    private var activeInputDevice = AudioDeviceID(0)
    /// Format the tap was installed with. Playing audio elsewhere can make CoreAudio
    /// switch the input's sample rate — same device, engine still "running", but the
    /// tap stops delivering, so the format has to be compared too.
    private var activeInputSampleRate: Double = 0
    private var activeInputChannels: AVAudioChannelCount = 0
    private(set) var restartCount = 0
    private static let maxRestartsPerRecording = 5

    /// Buffers seen in this recording, regardless of loudness — tells "engine is
    /// alive but the user is quiet" apart from "engine is dead".
    private var bufferCount = 0
    private var lastBufferAt: Date?

    /// Seconds since audio last arrived, or since the recording started.
    var secondsSinceAudio: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(lastBufferAt ?? startedAt ?? Date())
    }
    private var startedAt: Date?
    var hasIncomingAudio: Bool { capturedBufferCount > 0 }

    var capturedBufferCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return bufferCount
    }

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
        bufferCount = 0
        lastBufferAt = nil
        startedAt = Date()
        lock.unlock()
        firstBufferReported = false
        restartCount = 0

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
        // Pin the chosen device before touching the format: the input unit reports
        // the format of whatever device it is bound to at that moment.
        if let device = Self.pinnedDevice(), let unit = engine.inputNode.audioUnit {
            var id = device
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &id, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw RecorderError.noInput
        }
        let target = outFormat
        guard let converter = AVAudioConverter(from: inFormat, to: target) else {
            throw RecorderError.converterFailed
        }
        // The converter is captured by the tap closure: each engine gets its own,
        // so a mid-recording rebuild never races the audio thread.
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.append(buffer, converter: converter, to: target)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        activeInputDevice = Self.defaultInputDevice()
        activeInputSampleRate = inFormat.sampleRate
        activeInputChannels = inFormat.channelCount
    }

    /// Rebuilds the capture chain when audio has stopped flowing for `stallSeconds`,
    /// covering configuration changes that arrive without a usable notification
    /// (Bluetooth mode switches, sample-rate changes while media plays).
    /// Returns true if a restart was attempted.
    @discardableResult
    func restartIfStalled(stallSeconds: TimeInterval) -> Bool {
        guard isRecording, secondsSinceAudio >= stallSeconds else { return false }
        guard restartCount < Self.maxRestartsPerRecording else { return false }
        restartCount += 1
        teardownEngine()
        try? startEngine()
        lock.lock()
        // Treat the restart as fresh activity so the next check waits again.
        lastBufferAt = Date()
        lock.unlock()
        return true
    }

    /// Device the user pinned in the menu, or nil when following the system default.
    static func pinnedDevice() -> AudioDeviceID? {
        guard let uid = UserDefaults.standard.string(forKey: "inputDeviceUID"), !uid.isEmpty
        else { return nil }
        return AudioDevices.id(forUID: uid)
    }

    static func currentInputDeviceName() -> String {
        let device = pinnedDevice() ?? AudioDevices.systemDefaultInput()
        guard device != 0 else { return "none" }
        let pinned = pinnedDevice() != nil ? " (pinned)" : " (system default)"
        return (AudioDevices.name(forID: device) ?? "unknown id \(device)") + pinned
    }

    /// The device capture should be running on right now.
    private static func defaultInputDevice() -> AudioDeviceID {
        pinnedDevice() ?? AudioDevices.systemDefaultInput()
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
        // macOS posts this notification for harmless reasons too — including right
        // after our own engine starts. Rebuilding on those would loop forever and
        // capture nothing, so only react when the device really changed or died.
        let device = Self.defaultInputDevice()
        let engineAlive = engine?.isRunning ?? false
        let format = engine?.inputNode.outputFormat(forBus: 0)
        let formatChanged = format.map {
            $0.sampleRate != activeInputSampleRate || $0.channelCount != activeInputChannels
        } ?? false
        guard device != activeInputDevice || formatChanged || !engineAlive else { return }
        guard restartCount < Self.maxRestartsPerRecording else { return }
        restartCount += 1

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
        bufferCount += 1
        lastBufferAt = Date()
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
