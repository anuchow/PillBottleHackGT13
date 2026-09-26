//
//  MedBotClient.swift
//  Talks to the MedBot server on the demo Mac (`swift run medbot-server` in the repo root):
//  sends the patient's messages with their scanned medications, and polls the chat and
//  provider-call state so the MedBot tab stays live.
//

import Foundation
import Observation

// MARK: - Server state

struct MedBotState: Decodable, Equatable {
    struct Message: Decodable, Equatable, Identifiable {
        let id: Int
        let role: String        // "patient", "bot", or "error"
        let text: String
    }

    struct CallLine: Decodable, Equatable, Identifiable {
        let id: Int
        let speaker: String     // "assistant", "provider", or "status"
        let text: String
    }

    struct Call: Decodable, Equatable {
        let status: String      // "idle", "inCall", or "ended"
        let detail: String
        let lines: [CallLine]
    }

    let busy: Bool
    let patientName: String
    let providerName: String
    let messages: [Message]
    let call: Call

    static let empty = MedBotState(
        busy: false, patientName: "", providerName: "your doctor", messages: [],
        call: Call(status: "idle", detail: "", lines: [])
    )
}

// MARK: - Scanned medications

/// One scanned medication, in the shape the server expects.
struct MedBotMedication: Encodable {
    let name: String
    let dose: String
    let schedule: String
    let lastTaken: String       // "yyyy-MM-dd'T'HH:mm:ss" in local time, or "" if no dose is logged
}

extension Prescription {
    var medBotMedication: MedBotMedication {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let lastDose = doses.map(\.takenAt).max()
        let schedule = instructions?.lowercased()
            ?? (timesOfDay.isEmpty ? "as directed" : timesOfDay.joined(separator: ", "))
        return MedBotMedication(
            name: displayName,
            dose: doseSummary.isEmpty ? (dosage ?? "") : doseSummary,
            schedule: schedule,
            lastTaken: lastDose.map(formatter.string(from:)) ?? ""
        )
    }
}

// MARK: - Client

enum MedBotError: LocalizedError {
    case notConfigured, wrongToken, server(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Add the MedBot server URL and token in settings."
        case .wrongToken: "The server rejected the token. Check it in settings."
        case .server(let status): "The MedBot server returned an error (\(status))."
        }
    }
}

@MainActor
@Observable
final class MedBotModel {
    private(set) var state = MedBotState.empty
    /// Set when the server can't be reached; cleared on the next successful refresh.
    private(set) var connectionError: String?
    /// A one-off problem with the last message, e.g. MedBot was still busy.
    var sendError: String?

    var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: "medbot.serverURL") }
    }
    var token: String {
        didSet { UserDefaults.standard.set(token, forKey: "medbot.token") }
    }

    init() {
        serverURL = UserDefaults.standard.string(forKey: "medbot.serverURL") ?? ""
        token = UserDefaults.standard.string(forKey: "medbot.token") ?? ""
    }

    var isConfigured: Bool {
        baseURL != nil && !token.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var baseURL: URL? {
        let text = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text.hasSuffix("/") ? String(text.dropLast()) : text), url.host != nil else { return nil }
        return url
    }

    func send(_ text: String, medications: [MedBotMedication]) async {
        struct Body: Encodable {
            let message: String
            let medications: [MedBotMedication]?
        }
        sendError = nil
        do {
            let body = try JSONEncoder().encode(Body(message: text, medications: medications.isEmpty ? nil : medications))
            let (_, status) = try await request("POST", "/chat", body: body)
            if status == 409 { sendError = "MedBot is still answering. Try again in a moment." }
        } catch {
            sendError = error.localizedDescription
        }
        await refresh()
    }

    func refresh() async {
        do {
            let (data, _) = try await request("GET", "/state")
            let newState = try JSONDecoder().decode(MedBotState.self, from: data)
            if newState != state { state = newState }
            connectionError = nil
        } catch {
            connectionError = error.localizedDescription
        }
    }

    func reset() async {
        _ = try? await request("POST", "/reset")
        await refresh()
    }

    /// Keeps the chat and call screens live while the MedBot tab is on screen.
    func poll() async {
        while !Task.isCancelled {
            if isConfigured { await refresh() }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func request(_ method: String, _ path: String, body: Data? = nil) async throws -> (Data, Int) {
        guard let baseURL else { throw MedBotError.notConfigured }
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("Bearer \(token.trimmingCharacters(in: .whitespaces))", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw MedBotError.wrongToken }
        if status >= 500 || (status >= 400 && status != 409) { throw MedBotError.server(status) }
        return (data, status)
    }
}
