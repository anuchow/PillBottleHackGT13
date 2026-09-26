import Foundation

/// What the provider did on their turn: spoke (empty if silent) or pressed a key on the dial pad.
public enum ProviderInput: Sendable, Equatable {
    case speech(String)
    case key(String)

    /// Typed input: a single dial-pad character counts as a key press, anything else as speech.
    public static func typed(_ text: String) -> ProviderInput {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count == 1 && "0123456789*#".contains(text) ? .key(text) : .speech(text)
    }
}

/// One side of a call with the provider: something that can speak to them and hear their reply.
/// Implementations: typed text (testing), laptop speaker/mic, and a real phone call through Twilio.
public protocol ProviderLine: Sendable {
    /// Whether the provider can press dial-pad keys (a phone, or typed digits when testing).
    var supportsKeypad: Bool { get }
    /// Gets the provider on the line (e.g. dials and waits for an answer). `status` reports progress.
    func connect(for request: ProviderRequest, status: @Sendable (String) async -> Void) async throws
    func say(_ text: String) async throws
    /// Waits for the provider's turn. Throws `ProviderHungUp` if the call dropped.
    func listen() async throws -> ProviderInput
    func hangUp() async
}

extension ProviderLine {
    public var supportsKeypad: Bool { false }
    public func connect(for request: ProviderRequest, status: @Sendable (String) async -> Void) async throws {}
    public func hangUp() async {}
}

public enum CallSpeaker: Sendable {
    case assistant, provider, status
}

public enum CallMode: String, Sendable {
    case phone = "Phone", voice = "Voice", typed = "Typed"
}

/// Runs a phone conversation with the provider on the patient's behalf, one spoken turn at a time.
public struct ProviderCall: Sendable {
    static let endCall = FunctionDeclaration(
        name: "end_call",
        description: "End the call once the provider has confirmed your read-back of their answer, or wants to hang up.",
        parameters: ["summary": "What the provider confirmed, in one or two sentences for the patient."]
    )
    static let keypadMenu = "You can press 1 to hear her medications, 2 for her recent doses, or 3 to hear this request again."
    static let confirmKey = "9"

    private let gemini: GeminiClient
    private let patient: Patient
    /// Limits how long a call can run, counting both spoken turns and key presses.
    public var maxSteps = 16

    public init(gemini: GeminiClient, patient: Patient) {
        self.gemini = gemini
        self.patient = patient
    }

    /// The best provider line the settings allow: a real phone call (Twilio + ElevenLabs + Whisper keys),
    /// else the laptop speaker and mic (ElevenLabs + Whisper keys). Nil means only typed calls are possible.
    public static func configuredLine(_ config: Config, patient: Patient) -> (line: any ProviderLine, mode: CallMode)? {
        guard let elevenLabsKey = config["ELEVENLABS_API_KEY"], let voiceID = config["ELEVENLABS_VOICE_ID"],
              let openAIKey = config["OPENAI_API_KEY"] else { return nil }
        let voice = ElevenLabsClient(apiKey: elevenLabsKey, voiceID: voiceID)
        let transcriber = WhisperClient(apiKey: openAIKey)

        guard let accountSID = config["TWILIO_ACCOUNT_SID"], let authToken = config["TWILIO_AUTH_TOKEN"],
              let fromNumber = config["TWILIO_PHONE_NUMBER"], let providerNumber = config["PROVIDER_PHONE_NUMBER"]
        else {
            return (VoiceProviderLine(voice: voice, transcriber: transcriber, audio: LocalAudioChannel()), .voice)
        }

        var headsUp: PhoneCallLine.WhatsAppHeadsUp?
        if let token = config["WHATSAPP_ACCESS_TOKEN"], let phoneNumberID = config["WHATSAPP_PHONE_NUMBER_ID"],
           let providerWhatsApp = config["PROVIDER_WHATSAPP_NUMBER"] {
            headsUp = .init(
                client: WhatsAppClient(accessToken: token, phoneNumberID: phoneNumberID),
                to: providerWhatsApp, patientName: patient.name
            )
        }
        let line = PhoneCallLine(
            twilio: TwilioClient(accountSID: accountSID, authToken: authToken),
            from: fromNumber, providerNumber: providerNumber,
            voice: voice, transcriber: transcriber, headsUp: headsUp,
            publicURL: config["PUBLIC_URL"].flatMap(URL.init(string:)),
            port: config["MEDIA_STREAM_PORT"].flatMap(UInt16.init) ?? 8080
        )
        return (line, .phone)
    }

    /// Returns a summary of what the provider confirmed. `log` receives each line of the conversation as it happens.
    public func run(
        _ request: ProviderRequest, over line: any ProviderLine, log: @Sendable (CallSpeaker, String) async -> Void
    ) async throws -> String {
        do {
            try await line.connect(for: request) { await log(.status, $0) }
            let summary = try await converse(request, over: line, log: log)
            await line.hangUp()
            return summary
        } catch {
            await line.hangUp()
            throw error
        }
    }

    private func converse(
        _ request: ProviderRequest, over line: any ProviderLine, log: @Sendable (CallSpeaker, String) async -> Void
    ) async throws -> String {
        let systemPrompt = """
        You are \(patient.name)'s AI assistant, on a phone call with \(patient.providerName)'s office on behalf of \
        their patient \(patient.name).
        \(patient.spokenMedicationList)
        \(patient.spokenRecentDoses())
        The patient's request (\(request.reason)): \(request.details)

        Your first turn must begin with exactly: "Hi, this is \(patient.name)'s AI assistant." Then state the request, \
        and briefly give the medication's dose, schedule, and when \(patient.name) last took it.
        Whenever the provider gives an answer, instruction, or decision, read it back before doing anything else: \
        start with "Just to confirm," repeat their key details (medication, dose, quantity, pharmacy, timing, any changes), \
        and end with "If that's correct, say yes or press \(Self.confirmKey)."
        If they correct you, read back the corrected version the same way.
        Only after the provider confirms, say a short goodbye and call end_call. The summary must contain only what they confirmed.
        Everything you write is read aloud, so speak naturally in short sentences, with no lists or formatting.
        Never make medical decisions yourself; only relay the request and collect the provider's answer.
        """

        var contents = [Content(role: "user", text: "The provider's office has picked up. Start speaking.")]
        /// Things the provider heard from the dial-pad menu since their last spoken turn, so the model knows.
        var keypadNotes: [String] = []
        var needsReply = true
        var isFirstTurn = true

        for _ in 0..<maxSteps {
            do {
                if needsReply {
                    let reply = try await gemini.generate(systemInstruction: systemPrompt, contents: contents, functions: [Self.endCall])
                    contents.append(reply)
                    let end = reply.functionCall(named: Self.endCall.name)

                    // Never hang up in silence: if the model ends the call without a closing line, add one.
                    var spoken = reply.text.isEmpty && end != nil ? "Thank you so much. Goodbye!" : reply.text
                    if isFirstTurn && line.supportsKeypad { spoken += " " + Self.keypadMenu }
                    isFirstTurn = false
                    if !spoken.isEmpty {
                        await log(.assistant, spoken)
                        try await line.say(spoken)
                    }
                    if let end {
                        return end.args?["summary"] ?? "The call ended without an answer."
                    }
                }

                switch try await line.listen() {
                case .key(let key):
                    await log(.status, "Provider pressed \(key)")
                    if key == Self.confirmKey {
                        contents.append(Content(role: "user", text: turn(keypadNotes, "(The provider pressed \(key): yes, that's correct.)")))
                        keypadNotes = []
                        needsReply = true
                    } else {
                        let answer = keypadAnswer(key, request)
                        await log(.assistant, answer)
                        try await line.say(answer)
                        keypadNotes.append("(The provider pressed \(key) and heard: \(answer))")
                        needsReply = false
                    }
                case .speech(let heard):
                    await log(.provider, heard.isEmpty ? "(no response)" : heard)
                    contents.append(Content(role: "user", text: turn(keypadNotes, heard.isEmpty ? "(The provider said nothing.)" : heard)))
                    keypadNotes = []
                    needsReply = true
                }
            } catch is ProviderHungUp {
                await log(.status, "The provider hung up")
                contents.append(Content(role: "user", text: turn(keypadNotes, "(The provider hung up. Call end_call with a summary of only what they confirmed.)")))
                let final = try await gemini.generate(systemInstruction: systemPrompt, contents: contents, functions: [Self.endCall])
                return final.functionCall(named: Self.endCall.name)?.args?["summary"]
                    ?? (final.text.isEmpty ? "The provider hung up before answering." : final.text)
            }
        }
        return "The call ran too long and ended without a clear answer."
    }

    /// Dial-pad answers come straight from the patient's data, so they are exact and instant.
    func keypadAnswer(_ key: String, _ request: ProviderRequest) -> String {
        switch key {
        case "1": patient.spokenMedicationList
        case "2": patient.spokenRecentDoses()
        case "3": "\(patient.name)'s request is a \(request.reason): \(request.details)"
        default: "Sorry, that key isn't an option. \(Self.keypadMenu)"
        }
    }

    private func turn(_ notes: [String], _ text: String) -> String {
        (notes + [text]).joined(separator: "\n")
    }
}

/// Provider side typed in the terminal. For testing the call flow without audio. A single digit is a key press.
public struct TerminalProviderLine: ProviderLine {
    public init() {}

    public var supportsKeypad: Bool { true }

    public func say(_ text: String) async throws {}

    public func listen() async throws -> ProviderInput {
        print("Provider (you, or a digit for the keypad): ", terminator: "")
        return .typed(readLine() ?? "")
    }
}

/// Provider side spoken aloud: ElevenLabs voices the assistant, Whisper transcribes the provider.
public struct VoiceProviderLine: ProviderLine {
    private let voice: ElevenLabsClient
    private let transcriber: WhisperClient
    private let audio: LocalAudioChannel

    public init(voice: ElevenLabsClient, transcriber: WhisperClient, audio: LocalAudioChannel) {
        self.voice = voice
        self.transcriber = transcriber
        self.audio = audio
    }

    public func say(_ text: String) async throws {
        try await audio.play(voice.synthesize(text))
    }

    public func listen() async throws -> ProviderInput {
        let clip = try await audio.record()
        return .speech(clip.isEmpty ? "" : try await transcriber.transcribe(clip))
    }
}
