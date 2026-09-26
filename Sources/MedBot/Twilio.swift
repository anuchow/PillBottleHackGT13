import Foundation
import Network

/// The provider hung up (or the call dropped) mid-conversation.
public struct ProviderHungUp: Error, LocalizedError, Sendable {
    public var errorDescription: String? { "The provider hung up." }
}

/// Places and ends phone calls through the Twilio REST API.
public struct TwilioClient: Sendable {
    private let accountSID: String
    private let authToken: String

    public init(accountSID: String, authToken: String) {
        self.accountSID = accountSID
        self.authToken = authToken
    }

    /// Starts a call that streams its audio to `streamURL` (a wss:// URL). Returns the call SID.
    public func startCall(to: String, from: String, streamURL: URL) async throws -> String {
        let twiml = "<Response><Connect><Stream url=\"\(streamURL.absoluteString)\"/></Connect></Response>"
        let data = try await post("Calls.json", form: ["To": to, "From": from, "Twiml": twiml])
        struct Call: Decodable { var sid: String }
        return try JSONDecoder().decode(Call.self, from: data).sid
    }

    public func hangUp(callSID: String) async throws {
        _ = try await post("Calls/\(callSID).json", form: ["Status": "completed"])
    }

    private func post(_ path: String, form: [String: String]) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.twilio.com/2010-04-01/Accounts/\(accountSID)/\(path)")!)
        request.httpMethod = "POST"
        request.setValue("Basic " + Data("\(accountSID):\(authToken)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        try APIError.check(data, response, service: "Twilio")
        return data
    }
}

/// WebSocket server that Twilio Media Streams connect to. Each answered call arrives as a `MediaStream`.
final class MediaStreamServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "MediaStreamServer")
    private var waiter: CheckedContinuation<MediaStream, Error>?
    private var waiterID = 0
    private var unclaimed: MediaStream?

    init(port: UInt16) throws {
        let parameters = NWParameters.tcp
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let stream = MediaStream(connection: connection, queue: self.queue)
            stream.onStart = { [weak self] in self?.deliver(stream) }
            stream.start()
        }
        listener.start(queue: queue)
    }

    /// Waits for the next call to connect its media stream, or throws if nobody answers in time.
    func nextStream(timeout: TimeInterval) async throws -> MediaStream {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if let stream = unclaimed {
                    unclaimed = nil
                    continuation.resume(returning: stream)
                    return
                }
                waiter = continuation
                waiterID += 1
                let id = waiterID
                queue.asyncAfter(deadline: .now() + timeout) { [self] in
                    guard waiterID == id, let waiter else { return }
                    self.waiter = nil
                    waiter.resume(throwing: APIError(service: "Twilio", statusCode: 0, message: "The provider didn't answer."))
                }
            }
        }
    }

    /// Called on `queue`.
    private func deliver(_ stream: MediaStream) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: stream)
        } else {
            unclaimed = stream
        }
    }

    func stop() {
        listener.cancel()
    }
}

/// One call's audio over a Twilio Media Stream WebSocket: μ-law 8 kHz in both directions.
/// All state is touched only on `queue`.
final class MediaStream: @unchecked Sendable {
    enum Input {
        case audio(AudioClip)
        case key(String)
    }

    var onStart: (() -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var streamSID: String?
    private var closed = false
    private var playbackWaiters: [String: CheckedContinuation<Void, Error>] = [:]
    private var recording: (detector: SpeechDetector, pcm: Data, continuation: CheckedContinuation<Input, Error>)?
    /// Dial-pad presses not yet handed to a `record` call.
    private var pendingKeys: [String] = []

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.markClosed()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    /// Sends μ-law audio to the caller and returns once Twilio reports it has finished playing.
    func play(_ mulaw: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard !closed, let streamSID else { return continuation.resume(throwing: ProviderHungUp()) }
                var offset = 0
                while offset < mulaw.count {
                    let chunk = mulaw[offset..<min(offset + 640, mulaw.count)]
                    send(["event": "media", "streamSid": streamSID, "media": ["payload": chunk.base64EncodedString()]])
                    offset += 640
                }
                let mark = UUID().uuidString
                playbackWaiters[mark] = continuation
                send(["event": "mark", "streamSid": streamSID, "mark": ["name": mark]])
            }
        }
    }

    /// Records the caller until they stop talking (an empty clip if they said nothing),
    /// or returns a dial-pad key if they press one.
    func record(_ detector: SpeechDetector) async throws -> Input {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !closed else { return continuation.resume(throwing: ProviderHungUp()) }
                if !pendingKeys.isEmpty { return continuation.resume(returning: .key(pendingKeys.removeFirst())) }
                recording = (detector, Data(), continuation)
            }
        }
    }

    func close() {
        queue.async { [self] in
            connection.cancel()
            markClosed()
        }
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.handle(data) }
            if error == nil, !self.closed { self.receive() } else { self.markClosed() }
        }
    }

    private func handle(_ data: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = message["event"] as? String else { return }
        switch event {
        case "start":
            streamSID = (message["start"] as? [String: Any])?["streamSid"] as? String ?? message["streamSid"] as? String
            onStart?()
        case "media":
            guard let payload = (message["media"] as? [String: Any])?["payload"] as? String,
                  let mulaw = Data(base64Encoded: payload) else { return }
            consume(mulaw)
        case "dtmf":
            guard let digit = (message["dtmf"] as? [String: Any])?["digit"] as? String else { return }
            if let current = recording {
                recording = nil
                current.continuation.resume(returning: .key(digit))
            } else {
                pendingKeys.append(digit)
                // A key press interrupts whatever we're saying. Twilio then returns our pending marks, ending playback.
                if !playbackWaiters.isEmpty, let streamSID { send(["event": "clear", "streamSid": streamSID]) }
            }
        case "mark":
            if let name = (message["mark"] as? [String: Any])?["name"] as? String {
                playbackWaiters.removeValue(forKey: name)?.resume()
            }
        case "stop":
            markClosed()
        default:
            break
        }
    }

    private func consume(_ mulaw: Data) {
        guard var current = recording else { return }
        var pcm = Data(capacity: mulaw.count * 2)
        var sumOfSquares: Float = 0
        for byte in mulaw {
            let sample = MuLaw.decode(byte)
            let normalized = Float(sample) / Float(Int16.max)
            sumOfSquares += normalized * normalized
            withUnsafeBytes(of: sample.littleEndian) { pcm.append(contentsOf: $0) }
        }
        let rms = (sumOfSquares / Float(max(mulaw.count, 1))).squareRoot()
        let finished = current.detector.update(rms: rms, seconds: Double(mulaw.count) / 8000)
        if current.detector.heardSpeech { current.pcm.append(pcm) }

        if finished {
            recording = nil
            current.continuation.resume(returning: .audio(AudioClip(pcm: current.detector.heardSpeech ? current.pcm : Data(), sampleRate: 8000)))
        } else {
            recording = current
        }
    }

    private func markClosed() {
        guard !closed else { return }
        closed = true
        for waiter in playbackWaiters.values { waiter.resume(throwing: ProviderHungUp()) }
        playbackWaiters = [:]
        recording?.continuation.resume(throwing: ProviderHungUp())
        recording = nil
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        let context = NWConnection.ContentContext(
            identifier: "media", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)]
        )
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }
}

/// G.711 μ-law, the audio encoding used by phone calls.
enum MuLaw {
    static func decode(_ byte: UInt8) -> Int16 {
        let value = ~byte
        let exponent = Int32((value >> 4) & 0x07)
        let mantissa = Int32(value & 0x0F)
        let magnitude = (((mantissa << 3) + 0x84) << exponent) - 0x84
        return Int16(value & 0x80 != 0 ? -magnitude : magnitude)
    }
}
