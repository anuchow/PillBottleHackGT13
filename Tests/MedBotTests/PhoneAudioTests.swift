import Foundation
import Testing
@testable import MedBot

@Test func muLawDecodesKnownValues() {
    #expect(MuLaw.decode(0xFF) == 0)
    #expect(MuLaw.decode(0x7F) == 0)
    #expect(MuLaw.decode(0x80) == 32124)
    #expect(MuLaw.decode(0x00) == -32124)
}

@Test func speechDetectorEndsTurnAfterSilence() {
    var detector = SpeechDetector(threshold: 0.02, endOfSpeechSilence: 1.0)
    let talking = detector.update(rms: 0.2, seconds: 0.5)
    let pausing = detector.update(rms: 0.0, seconds: 0.5)
    let finished = detector.update(rms: 0.0, seconds: 0.5)
    #expect(!talking && !pausing && finished)
    #expect(detector.heardSpeech)
}

@Test func typedDigitsAreKeyPresses() {
    #expect(ProviderInput.typed(" 1 ") == .key("1"))
    #expect(ProviderInput.typed("#") == .key("#"))
    #expect(ProviderInput.typed("12") == .speech("12"))
    #expect(ProviderInput.typed("Yes, approved") == .speech("Yes, approved"))
}

@Test func lastDoseIsSpokenRelativeToNow() {
    let medication = Medication(name: "Metformin", dose: "500mg", schedule: "twice daily", lastTaken: "2026-09-25T20:00:00")
    let parser = DateFormatter()
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.dateFormat = "yyyy-MM-dd'T'HH:mm"
    #expect(medication.spokenLastTaken(now: parser.date(from: "2026-09-25T22:00")!).hasPrefix("today at 8:00"))
    #expect(medication.spokenLastTaken(now: parser.date(from: "2026-09-26T09:00")!).hasPrefix("yesterday at 8:00"))
    #expect(medication.spokenLastTaken(now: parser.date(from: "2026-09-30T09:00")!).hasPrefix("on September 25 at 8:00"))
    #expect(medication.spokenDose == "500 milligrams")
}

@Test func speechDetectorGivesUpWhenNobodySpeaks() {
    var detector = SpeechDetector(noSpeechTimeout: 2)
    let waiting = detector.update(rms: 0, seconds: 1)
    let gaveUp = detector.update(rms: 0, seconds: 1)
    #expect(!waiting && gaveUp)
    #expect(!detector.heardSpeech)
}

/// Plays the part of Twilio: connects to the media stream server and exchanges call audio.
@Test func mediaStreamPlaysAndRecordsLikeTwilio() async throws {
    let server = try MediaStreamServer(port: 18_080)
    defer { server.stop() }
    try await Task.sleep(for: .milliseconds(200))

    let twilio = URLSession.shared.webSocketTask(with: URL(string: "ws://localhost:18080/media")!)
    twilio.resume()
    func send(_ message: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: message)
        try await twilio.send(.string(String(decoding: data, as: UTF8.self)))
    }
    func receive() async throws -> [String: Any] {
        guard case .string(let text) = try await twilio.receive() else { return [:] }
        return try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    try await send(["event": "connected"])
    try await send(["event": "start", "streamSid": "MZtest", "start": ["streamSid": "MZtest", "callSid": "CAtest"]])
    let stream = try await server.nextStream(timeout: 5)

    // MedBot speaks: 1600 bytes of audio arrives as media chunks, then a mark. Echoing the mark ends playback.
    async let playback: Void = stream.play(Data(repeating: 0xFF, count: 1600))
    var received = 0
    var markName: String?
    while markName == nil {
        let message = try await receive()
        #expect(message["streamSid"] as? String == "MZtest")
        if message["event"] as? String == "media",
           let payload = (message["media"] as? [String: String])?["payload"] {
            received += Data(base64Encoded: payload)!.count
        }
        markName = (message["mark"] as? [String: String])?["name"]
    }
    #expect(received == 1600)
    try await send(["event": "mark", "streamSid": "MZtest", "mark": ["name": markName!]])
    try await playback

    // The provider talks for 1s, then goes quiet: recording should stop and keep the speech.
    async let recording = stream.record(SpeechDetector(threshold: 0.015, endOfSpeechSilence: 1.0))
    try await Task.sleep(for: .milliseconds(100))
    let loud = Data(repeating: 0x90, count: 160).base64EncodedString()
    let quiet = Data(repeating: 0xFF, count: 160).base64EncodedString()
    for index in 0..<120 {
        try await send(["event": "media", "streamSid": "MZtest", "media": ["payload": index < 50 ? loud : quiet]])
    }
    guard case .audio(let clip) = try await recording else { Issue.record("expected audio"); return }
    #expect(clip.sampleRate == 8000)
    #expect(clip.frameCount >= 50 * 160)

    // Pressing a key while MedBot listens ends the turn with that key.
    async let keyTurn = stream.record(SpeechDetector())
    try await Task.sleep(for: .milliseconds(100))
    try await send(["event": "dtmf", "streamSid": "MZtest", "dtmf": ["track": "inbound_track", "digit": "1"]])
    guard case .key(let pressed) = try await keyTurn else { Issue.record("expected a key"); return }
    #expect(pressed == "1")

    // Pressing a key while MedBot talks interrupts it: MedBot asks Twilio to clear its audio,
    // Twilio returns the pending mark, and the key is waiting for the next turn.
    async let interrupted: Void = stream.play(Data(repeating: 0xFF, count: 8000))
    var interruptMark: String?
    var sentKey = false
    var cleared = false
    while !cleared {
        let message = try await receive()
        if let name = (message["mark"] as? [String: String])?["name"] { interruptMark = name }
        if message["event"] as? String == "clear" { cleared = true }
        if interruptMark != nil && !sentKey {
            sentKey = true
            try await send(["event": "dtmf", "streamSid": "MZtest", "dtmf": ["track": "inbound_track", "digit": "2"]])
        }
    }
    try await send(["event": "mark", "streamSid": "MZtest", "mark": ["name": interruptMark!]])
    try await interrupted
    guard case .key(let queued) = try await stream.record(SpeechDetector()) else { Issue.record("expected the queued key"); return }
    #expect(queued == "2")

    // The provider hangs up: the next turn reports it instead of waiting forever.
    try await send(["event": "stop", "streamSid": "MZtest"])
    try await Task.sleep(for: .milliseconds(200))
    await #expect(throws: ProviderHungUp.self) {
        _ = try await stream.record(SpeechDetector())
    }
    twilio.cancel()
}

/// Opens a real Cloudflare quick tunnel and connects through it, as Twilio will. Needs internet and cloudflared.
/// Run with: MEDBOT_NETWORK_TESTS=1 swift test
@Test(.enabled(if: ProcessInfo.processInfo.environment["MEDBOT_NETWORK_TESTS"] == "1"))
func quickTunnelReachesMediaStreamServer() async throws {
    let server = try MediaStreamServer(port: 18_081)
    defer { server.stop() }
    let publicURL = try await QuickTunnel.start(port: 18_081)
    #expect(publicURL.host()?.hasSuffix(".trycloudflare.com") == true)

    var components = URLComponents(url: publicURL, resolvingAgainstBaseURL: false)!
    components.scheme = "wss"
    components.path = "/media"
    let twilio = URLSession.shared.webSocketTask(with: components.url!)
    twilio.resume()
    try await twilio.send(.string(#"{"event":"start","streamSid":"MZtunnel","start":{"streamSid":"MZtunnel"}}"#))
    _ = try await server.nextStream(timeout: 20)
    twilio.cancel()
}

/// Places a real phone call to PROVIDER_PHONE_NUMBER and speaks one line, then hangs up. Costs a few cents.
/// Run with: MEDBOT_LIVE_CALL=1 swift test --filter liveCall
@Test(.enabled(if: ProcessInfo.processInfo.environment["MEDBOT_LIVE_CALL"] == "1"))
func liveCallSpeaksToProvider() async throws {
    let config = Config.load()
    let line = PhoneCallLine(
        twilio: TwilioClient(accountSID: config["TWILIO_ACCOUNT_SID"]!, authToken: config["TWILIO_AUTH_TOKEN"]!),
        from: config["TWILIO_PHONE_NUMBER"]!, providerNumber: config["PROVIDER_PHONE_NUMBER"]!,
        voice: ElevenLabsClient(apiKey: config["ELEVENLABS_API_KEY"]!, voiceID: config["ELEVENLABS_VOICE_ID"]!),
        transcriber: WhisperClient(apiKey: config["OPENAI_API_KEY"] ?? "unused")
    )
    let request = ProviderRequest(reason: "refill", details: "Metformin 500mg")
    try await line.connect(for: request) { print("   · \($0)") }
    try await line.say("Hi, this is Eleanor's AI assistant. This is a test call from MedBot. If you can hear me, the phone connection works. Goodbye!")
    await line.hangUp()
}
