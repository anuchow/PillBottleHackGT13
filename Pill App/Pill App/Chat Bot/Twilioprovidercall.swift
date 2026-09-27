//
//  TwilioProviderCall.swift
//  Real phone calls to the provider, placed straight from the iPhone.
//
//  The Mac app does live back-and-forth calls, but that needs a public server for the
//  call audio, which a phone can't run. This version only uses Twilio's REST API:
//
//    1. Twilio calls PROVIDER_PHONE_NUMBER and reads the request aloud, ending with
//       "If you approve, please say yes."
//    2. It waits ~12 seconds for the answer, says goodbye, and hangs up. The call is recorded.
//    3. The app downloads the recording, Whisper transcribes it, and Gemini pulls out
//       what the office said and whether they approved.
//

import Foundation

struct TwilioProviderCall: Sendable {

    struct Outcome: Sendable {
        var summary: String
        var approved: Bool?          // nil = unclear, no answer, or didn't connect
        var connected = true         // false = busy, no answer, failed, or ended before anyone picked up
    }

    let accountSID: String
    let authToken: String
    let fromNumber: String
    let providerNumber: String
    let openAIKey: String
    let gemini: GeminiClient

    /// Seconds of silence left on the line for the office to answer.
    var answerWindow = 12

    /// Needs Twilio + OpenAI (transcription) + Gemini (reading the answer) keys.
    static func from(_ config: Config) -> TwilioProviderCall? {
        guard let sid = config["TWILIO_ACCOUNT_SID"], let token = config["TWILIO_AUTH_TOKEN"],
              let from = config["TWILIO_PHONE_NUMBER"], let to = config["PROVIDER_PHONE_NUMBER"],
              let openAI = config["OPENAI_API_KEY"], let geminiKey = config["GEMINI_API_KEY"] else { return nil }
        return TwilioProviderCall(accountSID: sid, authToken: token, fromNumber: from, providerNumber: to,
                                  openAIKey: openAI, gemini: GeminiClient(apiKey: geminiKey))
    }

    // MARK: Call

    func run(_ request: ProviderRequest, patient: Patient,
             log: @Sendable (CallSpeaker, String) async -> Void) async throws -> Outcome {
        let script = Self.script(for: request, patient: patient)

        await log(.status, "Calling \(Self.pretty(providerNumber))…")
        let callSID = try await startCall(script: script, patientName: patient.name)
        await log(.assistant, script)

        let finalStatus: String
        do {
            finalStatus = try await waitForCallToEnd(callSID, log: log)
        } catch where Task.isCancelled {
            // "End Call": hang up on Twilio's side. Runs detached because this task is cancelled.
            await Task.detached { try? await self.hangUp(callSID) }.value
            await log(.status, "You ended the call")
            return Outcome(summary: "You hung up before \(patient.providerName)'s office picked up.", approved: nil, connected: false)
        }
        guard finalStatus == "completed" else {
            let reason: String
            switch finalStatus {
            case "busy":      reason = "The line was busy."
            case "no-answer": reason = "Nobody picked up."
            case "failed":    reason = "The call didn't go through."
            case "canceled":  reason = "The call was canceled."
            default:          reason = "The call took too long and was stopped."
            }
            await log(.status, reason)
            return Outcome(summary: "\(reason) We couldn't reach \(patient.providerName)'s office.", approved: nil, connected: false)
        }

        await log(.status, "Call ended. Transcribing…")
        guard let recording = try await downloadRecording(callSID) else {
            return Outcome(summary: "The call finished, but the recording wasn't available, so the answer is unknown.", approved: nil)
        }
        let transcript = try await transcribe(recording)
        let reading = try await interpret(transcript: transcript, script: script)

        await log(.provider, reading.providerSaid.isEmpty ? "(no response)" : reading.providerSaid)
        switch reading.approved {
        case true?:  await log(.status, "The office said yes")
        case false?: await log(.status, "The office didn't approve")
        case nil:    await log(.status, "No clear answer")
        }
        return Outcome(summary: reading.summary, approved: reading.approved)
    }

    /// What the office hears.
    static func script(for request: ProviderRequest, patient: Patient) -> String {
        "Hi, this is \(patient.name)'s AI assistant, calling \(patient.providerName)'s office for your patient \(patient.name). "
        + "\(patient.name) is requesting a \(request.reason): \(request.details). "
        + "\(patient.spokenRecentDoses()) "
        + "If you approve, please say yes now. If not, please say what you would like instead."
    }

    private func startCall(script: String, patientName: String) async throws -> String {
        let twiml = """
        <Response>\
        <Pause length="1"/>\
        <Say voice="Polly.Joanna">\(Self.xmlEscape(script))</Say>\
        <Pause length="\(answerWindow)"/>\
        <Say voice="Polly.Joanna">Thank you. We'll let \(Self.xmlEscape(patientName)) know. Goodbye.</Say>\
        </Response>
        """
        let data = try await twilio("Calls.json", form: [
            "To": providerNumber, "From": fromNumber, "Twiml": twiml, "Record": "true",
        ])
        struct Call: Decodable { var sid: String }
        return try JSONDecoder().decode(Call.self, from: data).sid
    }

    private func hangUp(_ callSID: String) async throws {
        _ = try await twilio("Calls/\(callSID).json", form: ["Status": "completed"])
    }

    /// Polls the call until it ends. Returns Twilio's final status.
    private func waitForCallToEnd(_ callSID: String, log: @Sendable (CallSpeaker, String) async -> Void) async throws -> String {
        struct Call: Decodable { var status: String }
        var last = ""
        for _ in 0..<120 {                                   // about 4 minutes
            let status = try JSONDecoder().decode(Call.self, from: try await twilio("Calls/\(callSID).json")).status
            if status != last {
                last = status
                switch status {
                case "ringing":     await log(.status, "Ringing…")
                case "in-progress": await log(.status, "Connected. Reading the request…")
                default: break
                }
            }
            if ["completed", "busy", "no-answer", "failed", "canceled"].contains(status) { return status }
            try await Task.sleep(for: .seconds(2))
        }
        return "timeout"
    }

    /// Recordings take a few seconds to be ready after the call ends.
    private func downloadRecording(_ callSID: String) async throws -> Data? {
        struct List: Decodable {
            struct Recording: Decodable { var sid: String; var status: String? }
            var recordings: [Recording]
        }
        for _ in 0..<20 {
            let list = try JSONDecoder().decode(List.self, from: try await twilio("Calls/\(callSID)/Recordings.json"))
            if let recording = list.recordings.first(where: { $0.status == nil || $0.status == "completed" }) {
                return try await twilio("Recordings/\(recording.sid).wav")
            }
            try await Task.sleep(for: .seconds(2))
        }
        return nil
    }

    // MARK: Transcribe + interpret

    private func transcribe(_ wav: Data) async throws -> String {
        let boundary = "PillApp-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", "whisper-1")
        field("language", "en")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"call.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(openAIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        try APIError.check(data, response, service: "Whisper")
        struct Transcription: Decodable { var text: String }
        return try JSONDecoder().decode(Transcription.self, from: data).text
    }

    private struct Reading: Decodable {
        var providerSaid: String
        var approved: Bool?
        var summary: String
    }

    /// The recording has both sides of the call, so Gemini separates out the office's words.
    private func interpret(transcript: String, script: String) async throws -> Reading {
        let system = """
        You read transcripts of phone calls an AI assistant made to a doctor's office. The transcript contains both \
        the assistant's recorded message and the office's reply. Reply with JSON only, no code fences: \
        {"providerSaid": string, "approved": true | false | null, "summary": string}.
        providerSaid: only the office's own words, or "" if they said nothing.
        approved: true if they said yes or approved, false if they declined or asked for something else, null if unclear or silent.
        summary: one or two plain sentences telling the patient what the office said. Never add medical advice.
        """
        let reply = try await gemini.generate(
            systemInstruction: system,
            contents: [Content(role: "user", text: "Assistant's message:\n\(script)\n\nFull call transcript:\n\(transcript)")]
        )
        let text = reply.text
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
           let reading = try? JSONDecoder().decode(Reading.self, from: Data(text[start...end].utf8)) {
            return reading
        }
        return Reading(providerSaid: transcript, approved: nil,
                       summary: "The office replied, but the answer wasn't clear. Here's what was said: \(transcript)")
    }

    // MARK: Twilio REST

    private func twilio(_ path: String, form: [String: String]? = nil) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.twilio.com/2010-04-01/Accounts/\(accountSID)/\(path)")!)
        request.setValue("Basic " + Data("\(accountSID):\(authToken)".utf8).base64EncodedString(),
                         forHTTPHeaderField: "Authorization")
        if let form {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            request.httpBody = Data(form.map { key, value in
                "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
            }.joined(separator: "&").utf8)
        }
        let (data, response) = try await URLSession.shared.data(for: request, delegate: DropAuthOnRedirect())
        try APIError.check(data, response, service: "Twilio")
        return data
    }

    static func xmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// "+14704039904" -> "(470) 403-9904"
    static func pretty(_ number: String) -> String {
        let digits = number.filter(\.isNumber).suffix(10)
        guard digits.count == 10 else { return number }
        let d = Array(digits)
        return "(\(String(d[0..<3]))) \(String(d[3..<6]))-\(String(d[6..<10]))"
    }
}

/// Recording downloads can redirect to storage on another host; don't send our Twilio password there.
private final class DropAuthOnRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        var request = request
        if request.url?.host != "api.twilio.com" {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        return request
    }
}
