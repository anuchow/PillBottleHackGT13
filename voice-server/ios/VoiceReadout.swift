//
//  VoiceReadout.swift
//  Connects the app to the Pill Point voice server (voice-server/ in the repo).
//
//  To add it: drag this file into the "Pill App" folder in Xcode, then set
//  VoiceServer.baseURL below. See voice-server/ios/INTEGRATION.md for the
//  small changes to the existing screens.
//
//      let played = await VoiceReadout.shared.play(prescription, language: .spanish)
//      VoiceServer.sync(prescription)                        // after a scan
//      VoiceServer.syncDose(prescription, takenAt: .now)     // after "Log dose"
//

import Foundation
import AVFoundation
import Combine

// MARK: - Server settings

enum VoiceServer {
    /// The hosted server on Vultr (HTTPS, works from any network).
    /// For a laptop on the same Wi-Fi instead: "http://<laptop IP>:3000" + the Info.plist
    /// change in INTEGRATION.md.
    static let baseURL = URL(string: "https://96-30-206-230.sslip.io")!

    /// The server's app password (APP_TOKEN). Get it from Gargi; see INTEGRATION.md.
    static let appToken = "PASTE_APP_TOKEN_HERE"

    /// Saves a scanned bottle in Tiger Cloud. Call after `Prescription.upsert`.
    static func sync(_ prescription: Prescription) {
        let payload = PrescriptionPayload(prescription)
        Task {
            let _: Ignored? = try? await post("prescriptions", payload)
        }
    }

    /// Saves a logged dose in Tiger Cloud. Call after `logDose`.
    static func syncDose(_ prescription: Prescription, takenAt: Date, overrodeWarning: Bool = false) {
        let payload = DosePayload(prescriptionKey: prescription.key,
                                  takenAt: ISO8601DateFormatter().string(from: takenAt),
                                  overrodeWarning: overrodeWarning)
        Task {
            let _: Ignored? = try? await post("doses", payload)
        }
    }

    static func post<Body: Encodable, Response: Decodable>(_ path: String, _ body: Body) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !appToken.isEmpty { request.setValue(appToken, forHTTPHeaderField: "X-App-Token") }
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

// MARK: - Read aloud

/// Plays the server's readout (ElevenLabs audio). If the server sends text but no audio,
/// the iPhone voice reads the text instead.
@MainActor
final class VoiceReadout: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = VoiceReadout()

    @Published private(set) var isLoading = false
    @Published private(set) var isPlaying = false
    private var player: AVAudioPlayer?

    /// Returns false if the server couldn't be reached, so the caller can fall back
    /// to on-device translation.
    func play(_ prescription: Prescription, language: AppLanguage) async -> Bool {
        stop()
        isLoading = true
        defer { isLoading = false }

        let body = ReadoutRequest(
            prescription: PrescriptionPayload(prescription),
            language: language.rawValue,                       // "zh-Hans" is fine, the server maps it
            lastTakenAt: prescription.doses.map(\.takenAt).max().map { ISO8601DateFormatter().string(from: $0) },
            timeZone: TimeZone.current.identifier
        )

        do {
            let readout: ReadoutResponse = try await VoiceServer.post("readout", body)
            if let audio = readout.audio, let data = Data(base64Encoded: audio) {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                try AVAudioSession.sharedInstance().setActive(true)
                let player = try AVAudioPlayer(data: data)
                player.delegate = self
                player.play()
                self.player = player
                isPlaying = true
            } else {
                LabelSpeaker.shared.speak(text: readout.text, languageCode: language.speechCode)
            }
            return true
        } catch {
            print("Voice server unavailable: \(error)")
            return false
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.isPlaying = false }
    }
}

// MARK: - JSON sent to / received from the server

/// Same fields as Prescription. The Rx number itself is not sent (only the key).
struct PrescriptionPayload: Encodable {
    let key: String
    let drugName: String
    let dosage: String?
    let quantity: Int?
    let pharmacyName: String?
    let pharmacyAddress: String?
    let prescriber: String?
    let expirationDate: String?          // "yyyy-MM-dd"
    let instructions: String?
    let takeWithFood: Bool?
    let timesOfDay: [String]
    let sideEffects: [String]
    let minHoursBetweenDoses: Double?
    let maxDosesPerDay: Int?
    let asNeeded: Bool

    init(_ p: Prescription) {
        key = p.key
        drugName = p.drugName
        dosage = p.dosage
        quantity = p.quantity
        pharmacyName = p.pharmacyName
        pharmacyAddress = p.pharmacyAddress
        prescriber = p.prescriber
        expirationDate = p.expirationDate.map { Self.dayFormatter.string(from: $0) }
        instructions = p.instructions
        takeWithFood = p.takeWithFood
        timesOfDay = p.timesOfDay
        sideEffects = p.sideEffects
        minHoursBetweenDoses = p.minHoursBetweenDoses
        maxDosesPerDay = p.maxDosesPerDay
        asNeeded = p.asNeeded
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private struct ReadoutRequest: Encodable {
    let prescription: PrescriptionPayload
    let language: String
    let lastTakenAt: String?
    let timeZone: String
}

private struct ReadoutResponse: Decodable {
    let text: String
    let audio: String?
    let audioError: String?
}

private struct DosePayload: Encodable {
    let prescriptionKey: String
    let takenAt: String
    let overrodeWarning: Bool
}

/// For responses we don't need to read.
private struct Ignored: Decodable {}
