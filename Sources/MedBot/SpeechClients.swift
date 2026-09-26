import Foundation

/// Mono 16-bit little-endian PCM audio.
public struct AudioClip: Sendable {
    public var pcm: Data
    public var sampleRate: Int

    public init(pcm: Data, sampleRate: Int) {
        self.pcm = pcm
        self.sampleRate = sampleRate
    }

    public var frameCount: Int { pcm.count / 2 }
    public var isEmpty: Bool { pcm.isEmpty }

    /// The clip wrapped in a WAV header, for uploading.
    public var wavData: Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + pcm.count))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1))                        // PCM, mono
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2))  // sample rate, byte rate
        append(UInt16(2)); append(UInt16(16))                       // block align, bits per sample
        data.append(contentsOf: Array("data".utf8)); append(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}

/// Decides when someone has finished speaking, from the loudness of successive audio chunks.
public struct SpeechDetector: Sendable {
    /// Loudness (RMS, 0–1) that counts as someone talking.
    public var threshold: Float
    /// Seconds of quiet after speech before the turn counts as finished.
    public var endOfSpeechSilence: Double
    /// Give up if nobody starts talking within this many seconds.
    public var noSpeechTimeout: Double
    public var maxDuration: Double

    public private(set) var heardSpeech = false
    private var elapsed = 0.0
    private var quietFor = 0.0

    public init(threshold: Float = 0.02, endOfSpeechSilence: Double = 1.5, noSpeechTimeout: Double = 10, maxDuration: Double = 30) {
        self.threshold = threshold
        self.endOfSpeechSilence = endOfSpeechSilence
        self.noSpeechTimeout = noSpeechTimeout
        self.maxDuration = maxDuration
    }

    /// Feeds one chunk of audio. Returns true once the speaker's turn is over.
    public mutating func update(rms: Float, seconds: Double) -> Bool {
        let loud = rms > threshold
        elapsed += seconds
        if loud { heardSpeech = true }
        if heardSpeech { quietFor = loud ? 0 : quietFor + seconds }
        return (heardSpeech && quietFor >= endOfSpeechSilence)
            || (!heardSpeech && elapsed >= noSpeechTimeout)
            || elapsed >= maxDuration
    }
}

/// Text-to-speech with ElevenLabs.
public struct ElevenLabsClient: Sendable {
    private let apiKey: String
    private let voiceID: String
    private let modelID: String
    private let sampleRate: Int

    public init(apiKey: String, voiceID: String, modelID: String = "eleven_flash_v2_5", sampleRate: Int = 24000) {
        self.apiKey = apiKey
        self.voiceID = voiceID
        self.modelID = modelID
        self.sampleRate = sampleRate
    }

    public func synthesize(_ text: String) async throws -> AudioClip {
        AudioClip(pcm: try await audio(for: text, format: "pcm_\(sampleRate)"), sampleRate: sampleRate)
    }

    /// Raw audio in any ElevenLabs output format, e.g. "ulaw_8000" for phone calls.
    public func audio(for text: String, format: String) async throws -> Data {
        let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)?output_format=\(format)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.httpBody = try JSONEncoder().encode(["text": text, "model_id": modelID])

        let (data, response) = try await URLSession.shared.data(for: request)
        try APIError.check(data, response, service: "ElevenLabs")
        return data
    }
}

/// Speech-to-text with OpenAI Whisper.
public struct WhisperClient: Sendable {
    private let apiKey: String
    private let model: String

    public init(apiKey: String, model: String = "whisper-1") {
        self.apiKey = apiKey
        self.model = model
    }

    public func transcribe(_ clip: AudioClip) async throws -> String {
        let boundary = "MedBot-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        field("language", "en")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(clip.wavData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        try APIError.check(data, response, service: "Whisper")
        struct Transcription: Decodable { var text: String }
        return try JSONDecoder().decode(Transcription.self, from: data).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
