import AVFoundation

/// Plays audio through the Mac's speaker and records the Mac's microphone.
/// Stands in for the WhatsApp call's audio so the call flow can be tested on a laptop.
public final class LocalAudioChannel: @unchecked Sendable {
    public var speechDetector = SpeechDetector()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    public init() {
        engine.attach(player)
    }

    public func play(_ clip: AudioClip) async throws {
        guard clip.frameCount > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(clip.sampleRate), channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(clip.frameCount))
        else { return }

        buffer.frameLength = buffer.frameCapacity
        let samples = buffer.floatChannelData![0]
        clip.pcm.withUnsafeBytes { bytes in
            for i in 0..<clip.frameCount {
                let value = Int16(bitPattern: UInt16(bytes[2 * i]) | UInt16(bytes[2 * i + 1]) << 8)
                samples[i] = Float(value) / Float(Int16.max)
            }
        }

        engine.stop()
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.start()
        player.play()
        await withCheckedContinuation { continuation in
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in continuation.resume() }
        }
        player.stop()
    }

    /// Records until the speaker stops talking. Returns an empty clip if nobody spoke.
    public func record() async throws -> AudioClip {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let recorder = Recorder(channel: self, sampleRate: format.sampleRate, detector: speechDetector)

        engine.stop()
        return try await withCheckedThrowingContinuation { continuation in
            recorder.continuation = continuation
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
                recorder.consume(buffer)
            }
            do {
                try engine.start()
            } catch {
                input.removeTap(onBus: 0)
                continuation.resume(throwing: error)
            }
        }
    }

    fileprivate func stopRecording() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// Collects microphone samples and decides when the speaker has finished.
private final class Recorder: @unchecked Sendable {
    var continuation: CheckedContinuation<AudioClip, Error>?

    private let channel: LocalAudioChannel
    private let sampleRate: Double
    private let lock = NSLock()
    private var pcm = Data()
    private var detector: SpeechDetector

    init(channel: LocalAudioChannel, sampleRate: Double, detector: SpeechDetector) {
        self.channel = channel
        self.sampleRate = sampleRate
        self.detector = detector
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        let seconds = Double(count) / sampleRate

        var sumOfSquares: Float = 0
        var chunk = Data(capacity: count * 2)
        for i in 0..<count {
            let sample = max(-1, min(1, samples[i]))
            sumOfSquares += sample * sample
            withUnsafeBytes(of: Int16(sample * Float(Int16.max)).littleEndian) { chunk.append(contentsOf: $0) }
        }
        let rms = (sumOfSquares / Float(max(count, 1))).squareRoot()

        lock.lock()
        defer { lock.unlock() }
        guard let continuation else { return }
        let finished = detector.update(rms: rms, seconds: seconds)
        if detector.heardSpeech { pcm.append(chunk) }
        guard finished else { return }

        self.continuation = nil
        let clip = AudioClip(pcm: detector.heardSpeech ? pcm : Data(), sampleRate: Int(sampleRate))
        // Removing a tap from inside its own callback can deadlock, so stop from another queue.
        DispatchQueue.global().async { [channel] in
            channel.stopRecording()
            continuation.resume(returning: clip)
        }
    }
}
