import Foundation

/// Sends scanned bottles and logged doses to the Vultr server, which saves them in Tiger Data.
/// SwiftData on the phone stays the source of truth. If the network fails, nothing breaks locally.
final class TigerSync {
    static let shared = TigerSync()

    // Vultr server address
    private let baseURL = URL(string: "http://96.30.206.230:3001")!
    // Same value as API_KEY in the server .env file
    private let apiKey = "eea32c00d48ab2d6a023a8b4e5035bf95c622e2712a1a41518ca0e7222184ca7"

    /// One random ID per phone, saved so it stays the same between launches.
    var patientID: String {
        if let id = UserDefaults.standard.string(forKey: "patientID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "patientID")
        return id
    }

    // MARK: - Upload a scanned bottle

    func upload(_ rx: Prescription) async {
        let body = PrescriptionPayload(
            patientId: patientID,
            key: rx.key,
            drugName: rx.drugName,
            dosage: rx.dosage,
            quantity: rx.quantity,
            instructions: rx.instructions,
            takeWithFood: rx.takeWithFood,
            timesOfDay: rx.timesOfDay,
            minHoursBetweenDoses: rx.minHoursBetweenDoses,
            maxDosesPerDay: rx.maxDosesPerDay,
            asNeeded: rx.asNeeded,
            expirationDate: rx.expirationDate
        )
        await send("PUT", "/prescriptions", body)
    }

    // MARK: - Upload a logged dose

    /// Pass the same eventID if you retry, so the dose isn't counted twice.
    func logDose(for rx: Prescription, takenAt: Date, overrodeWarning: Bool, eventID: UUID = UUID()) async {
        let body = DosePayload(
            patientId: patientID,
            key: rx.key,
            eventId: eventID.uuidString,
            takenAt: takenAt,
            overrodeWarning: overrodeWarning
        )
        await send("POST", "/doses", body)
    }

    // MARK: - Ask the database if a dose is safe now

    func checkDose(for rx: Prescription) async throws -> TigerDoseCheck {
        var comps = URLComponents(url: baseURL.appendingPathComponent("check-dose"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "patientId", value: patientID),
            URLQueryItem(name: "key", value: rx.key)
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        let (data, _) = try await URLSession.shared.data(for: req)
        return try Self.decoder.decode(TigerDoseCheck.self, from: data)
    }

    // MARK: - Plumbing

    private func send<T: Encodable>(_ method: String, _ path: String, _ body: T) async {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        do {
            req.httpBody = try Self.encoder.encode(body)
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code != 200 {
                print("TigerSync \(path) failed \(code):", String(data: data, encoding: .utf8) ?? "")
            }
        } catch {
            print("TigerSync \(path) error:", error)
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let s = try container.decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: s) { return date }
            f.formatOptions = [.withInternetDateTime]
            if let date = f.date(from: s) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Bad date: \(s)")
        }
        return d
    }()
}

// MARK: - What gets sent / received

private struct PrescriptionPayload: Encodable {
    let patientId: String
    let key: String
    let drugName: String
    let dosage: String?
    let quantity: Int?
    let instructions: String?
    let takeWithFood: Bool?
    let timesOfDay: [String]
    let minHoursBetweenDoses: Double?
    let maxDosesPerDay: Int?
    let asNeeded: Bool
    let expirationDate: Date?
}

private struct DosePayload: Encodable {
    let patientId: String
    let key: String
    let eventId: String
    let takenAt: Date
    let overrodeWarning: Bool
}

struct TigerDoseCheck: Decodable {
    let status: String          // "ok", "too_soon", or "daily_limit"
    let lastTaken: Date?
    let nextAllowed: Date?
    let dosesLast24h: Int?
    let dailyLimit: Int?
}
