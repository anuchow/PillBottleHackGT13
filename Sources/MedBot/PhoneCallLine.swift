import Foundation

/// Calls the provider's real phone through Twilio. ElevenLabs speaks, Whisper listens.
/// Optionally sends a WhatsApp heads-up message first.
public actor PhoneCallLine: ProviderLine {
    public struct WhatsAppHeadsUp: Sendable {
        var client: WhatsAppClient
        var to: String
        var patientName: String

        public init(client: WhatsAppClient, to: String, patientName: String) {
            self.client = client
            self.to = to
            self.patientName = patientName
        }
    }

    private let twilio: TwilioClient
    private let fromNumber: String
    private let providerNumber: String
    private let voice: ElevenLabsClient
    private let transcriber: WhisperClient
    private let headsUp: WhatsAppHeadsUp?
    private let port: UInt16
    private var publicURL: URL?

    private var server: MediaStreamServer?
    private var stream: MediaStream?
    private var callSID: String?

    public init(
        twilio: TwilioClient, from fromNumber: String, providerNumber: String,
        voice: ElevenLabsClient, transcriber: WhisperClient,
        headsUp: WhatsAppHeadsUp? = nil, publicURL: URL? = nil, port: UInt16 = 8080
    ) {
        self.twilio = twilio
        self.fromNumber = fromNumber
        self.providerNumber = providerNumber
        self.voice = voice
        self.transcriber = transcriber
        self.headsUp = headsUp
        self.publicURL = publicURL
        self.port = port
    }

    public func connect(for request: ProviderRequest, status: @Sendable (String) async -> Void) async throws {
        let server = try server ?? MediaStreamServer(port: port)
        self.server = server

        if publicURL == nil {
            await status("Opening a tunnel for call audio…")
            publicURL = try await QuickTunnel.start(port: Int(port))
        }
        var streamURL = URLComponents(url: publicURL!, resolvingAgainstBaseURL: false)!
        streamURL.scheme = "wss"
        streamURL.path = "/media"

        if let headsUp {
            do {
                try await headsUp.client.sendText(
                    to: headsUp.to,
                    body: "This is \(headsUp.patientName)'s AI assistant. I'm calling you now about a \(request.reason): \(request.details)"
                )
                await status("Sent WhatsApp heads-up")
            } catch {
                await status("WhatsApp heads-up failed: \(error.localizedDescription)")
            }
        }

        await status("Calling \(providerNumber)…")
        callSID = try await twilio.startCall(to: providerNumber, from: fromNumber, streamURL: streamURL.url!)
        stream = try await server.nextStream(timeout: 60)
        await status("Connected")
    }

    public func say(_ text: String) async throws {
        guard let stream else { throw ProviderHungUp() }
        try await stream.play(voice.audio(for: text, format: "ulaw_8000"))
    }

    public nonisolated var supportsKeypad: Bool { true }

    public func listen() async throws -> ProviderInput {
        guard let stream else { throw ProviderHungUp() }
        switch try await stream.record(SpeechDetector(threshold: 0.015, endOfSpeechSilence: 0.9)) {
        case .key(let key):
            return .key(key)
        case .audio(let clip):
            return .speech(clip.isEmpty ? "" : try await transcriber.transcribe(clip))
        }
    }

    public func hangUp() async {
        if let callSID { try? await twilio.hangUp(callSID: callSID) }
        stream?.close()
        stream = nil
        callSID = nil
    }
}

/// Sends WhatsApp messages through the Meta Cloud API.
public struct WhatsAppClient: Sendable {
    private let accessToken: String
    private let phoneNumberID: String
    private let apiVersion: String

    public init(accessToken: String, phoneNumberID: String, apiVersion: String = "v23.0") {
        self.accessToken = accessToken
        self.phoneNumberID = phoneNumberID
        self.apiVersion = apiVersion
    }

    /// Free-form text only reaches people who messaged this number in the last 24 hours.
    public func sendText(to: String, body: String) async throws {
        var request = URLRequest(url: URL(string: "https://graph.facebook.com/\(apiVersion)/\(phoneNumberID)/messages")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "messaging_product": "whatsapp",
            "to": to.filter(\.isNumber),
            "type": "text",
            "text": ["body": body],
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        try APIError.check(data, response, service: "WhatsApp")
    }
}

/// A temporary public HTTPS address for a local port, via `cloudflared tunnel --url` (no account needed).
public enum QuickTunnel {
    nonisolated(unsafe) private static var processes: [Process] = []

    public static func start(port: Int) async throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["cloudflared", "tunnel", "--no-autoupdate", "--url", "http://localhost:\(port)"]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "")
        process.environment = environment
        let output = Pipe()
        process.standardError = output
        process.standardOutput = output

        let url: URL = try await withCheckedThrowingContinuation { continuation in
            let found = Box(continuation)
            output.fileHandleForReading.readabilityHandler = { handle in
                let text = String(decoding: handle.availableData, as: UTF8.self)
                if let match = text.firstMatch(of: /https:\/\/[a-z0-9-]+\.trycloudflare\.com/),
                   let url = URL(string: String(match.output)) {
                    found.resume(.success(url))
                }
            }
            process.terminationHandler = { _ in
                found.resume(.failure(APIError(service: "cloudflared", statusCode: 0, message: "Tunnel exited. Is cloudflared installed? (brew install cloudflared)")))
            }
            do {
                try process.run()
            } catch {
                found.resume(.failure(error))
            }
        }
        output.fileHandleForReading.readabilityHandler = { _ in }  // keep draining so cloudflared never blocks
        processes.append(process)
        if processes.count == 1 {
            atexit { QuickTunnel.processes.forEach { $0.terminate() } }
        }
        // Give the new hostname a moment to become reachable before Twilio connects to it.
        try await Task.sleep(for: .seconds(3))
        return url
    }

    /// Resumes a continuation at most once, from whichever callback gets there first.
    private final class Box: @unchecked Sendable {
        private var continuation: CheckedContinuation<URL, Error>?
        private let lock = NSLock()

        init(_ continuation: CheckedContinuation<URL, Error>) { self.continuation = continuation }

        func resume(_ result: Result<URL, Error>) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }
    }
}
