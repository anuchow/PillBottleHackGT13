//
//  CloudSync.swift
//  Keeps a copy of prescriptions and every logged dose in the cloud:
//    iPhone  ->  Pill App API on Vultr  ->  Tiger Cloud (TimescaleDB)
//
//  SwiftData on the phone is still what the screens use. The cloud copy adds:
//    - a server-side overdose check that sees doses logged on *any* device
//      (a caregiver's phone, a second iPhone), not just this one
//    - dose history for adherence charts (the daily_doses continuous aggregate)
//
//  Writes are queued and retried, so logging works offline and syncs later.
//  Needs PILL_API_URL and PILL_API_KEY in Secrets.plist; without them it does nothing.
//

import Foundation

final class CloudSync: @unchecked Sendable {
    static let shared = CloudSync()

    /// Random ID for this install. The server never sees your name.
    let patientID: UUID

    private let baseURL: URL?
    private let apiKey: String?
    private let lock = NSLock()
    private var pending: [PendingRequest]
    private var isFlushing = false

    private static let pendingKey = "cloudSyncPending"
    private static let patientKey = "cloudPatientID"
    private static let backfillKey = "cloudBackfillDone"

    struct PendingRequest: Codable {
        let method: String
        let path: String
        let body: Data?
    }

    private init() {
        let config = Config.load()
        baseURL = config["PILL_API_URL"].flatMap { URL(string: $0) }
        apiKey = config["PILL_API_KEY"]

        if let saved = UserDefaults.standard.string(forKey: Self.patientKey), let id = UUID(uuidString: saved) {
            patientID = id
        } else {
            patientID = UUID()
            UserDefaults.standard.set(patientID.uuidString, forKey: Self.patientKey)
        }
        pending = UserDefaults.standard.data(forKey: Self.pendingKey)
            .flatMap { try? JSONDecoder().decode([PendingRequest].self, from: $0) } ?? []
    }

    var isEnabled: Bool { baseURL != nil && apiKey != nil }

    // MARK: What gets synced (call from the main thread; reads SwiftData models)

    func upsert(_ prescription: Prescription) {
        send("POST", "/prescriptions", PrescriptionPayload(prescription))
    }

    func recordDose(_ log: DoseLog, key: String, source: String) {
        send("POST", "/doses", DosePayload(eventId: log.eventID, prescriptionKey: key, takenAt: log.takenAt,
                                          overrodeWarning: log.overrodeWarning, source: source))
    }

    func deleteDose(_ eventID: UUID) {
        enqueue(PendingRequest(method: "DELETE", path: "/doses/\(eventID.uuidString)", body: nil))
    }

    /// First launch with the cloud turned on: upload everything already on the phone.
    func backfillIfNeeded(_ prescriptions: [Prescription]) {
        guard isEnabled, !UserDefaults.standard.bool(forKey: Self.backfillKey) else { flush(); return }
        for prescription in prescriptions {
            upsert(prescription)
            for log in prescription.doses { recordDose(log, key: prescription.key, source: "backfill") }
        }
        UserDefaults.standard.set(true, forKey: Self.backfillKey)
    }

    // MARK: Server-side overdose check

    /// Asks the server whether it's too soon, counting doses from every device.
    /// Returns nil when offline or not set up, so callers fall back to the on-phone check.
    func remoteCheck(key: String) async -> DoseCheck? {
        guard let baseURL, let apiKey,
              var components = URLComponents(url: baseURL.appending(path: "check"), resolvingAgainstBaseURL: false)
        else { return nil }
        components.queryItems = [URLQueryItem(name: "key", value: key)]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url, timeoutInterval: 3)     // don't keep someone waiting to log
        addHeaders(to: &request, apiKey: apiKey)

        struct Response: Decodable {
            let status: String
            let last_taken: Double?
            let next_allowed: Double?
            let daily_limit: Int?
        }
        guard let reply = try? await URLSession.shared.data(for: request),
              (reply.1 as? HTTPURLResponse)?.statusCode == 200,
              let result = try? JSONDecoder().decode(Response.self, from: reply.0) else { return nil }

        switch result.status {
        case "too_soon":
            guard let last = result.last_taken, let next = result.next_allowed else { return .ok }
            return .tooSoon(lastDose: Date(timeIntervalSince1970: last), nextAllowed: Date(timeIntervalSince1970: next))
        case "daily_limit":
            return .dailyLimitReached(limit: result.daily_limit ?? 0)
        default:
            return .ok
        }
    }

    // MARK: Queue

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private func send<T: Encodable>(_ method: String, _ path: String, _ body: T) {
        guard let data = try? Self.encoder.encode(body) else { return }
        enqueue(PendingRequest(method: method, path: path, body: data))
    }

    private func enqueue(_ request: PendingRequest) {
        guard isEnabled else { return }
        lock.withLock {
            pending.append(request)
            savePending()
        }
        flush()
    }

    /// Sends queued requests in order. Stops at the first network failure and tries again next time.
    func flush() {
        guard beginDraining() else { return }
        Task.detached(priority: .utility) { [self] in await drainQueue() }
    }

    /// Sends anything still queued right now (used before reading data back, so it includes
    /// the dose that was just logged).
    private func flushNow() async {
        guard beginDraining() else { return }
        await drainQueue()
    }

    private func beginDraining() -> Bool {
        guard isEnabled else { return false }
        return lock.withLock { () -> Bool in
            if isFlushing { return false }
            isFlushing = true
            return true
        }
    }

    private func drainQueue() async {
        while let next = lock.withLock({ pending.first }) {
            do {
                try await perform(next)
            } catch let error as APIError where (400..<500).contains(error.statusCode) && error.statusCode != 401 {
                print("Cloud sync dropped a bad request: \(error.localizedDescription)")   // would never succeed
            } catch {
                break      // offline or server down: keep it for later
            }
            lock.withLock {
                if !pending.isEmpty { pending.removeFirst() }
                savePending()
            }
        }
        lock.withLock { isFlushing = false }
    }

    // MARK: Reading back from Tiger Data

    /// Doses taken vs. expected per day, from the daily_doses continuous aggregate in Tiger Cloud.
    func fetchAdherence(days: Int) async -> CloudAdherence? {
        guard let baseURL, let apiKey,
              var components = URLComponents(url: baseURL.appending(path: "adherence/summary"),
                                             resolvingAgainstBaseURL: false) else { return nil }
        await flushNow()
        components.queryItems = [URLQueryItem(name: "days", value: String(days))]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url, timeoutInterval: 8)
        addHeaders(to: &request, apiKey: apiKey)
        guard let reply = try? await URLSession.shared.data(for: request),
              (reply.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(CloudAdherence.self, from: reply.0)
    }

    /// Every dose saved in Tiger Data for the last `days` days (from any device).
    /// Sends anything still queued first, so the list includes doses just logged here.
    func fetchDoses(days: Int) async -> [CloudDose]? {
        guard let baseURL, let apiKey,
              var components = URLComponents(url: baseURL.appending(path: "doses"),
                                             resolvingAgainstBaseURL: false) else { return nil }
        await flushNow()
        components.queryItems = [URLQueryItem(name: "days", value: String(days))]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url, timeoutInterval: 8)
        addHeaders(to: &request, apiKey: apiKey)
        guard let reply = try? await URLSession.shared.data(for: request),
              (reply.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode([CloudDose].self, from: reply.0)
    }

    private func perform(_ item: PendingRequest) async throws {
        guard let baseURL, let apiKey else { return }
        var request = URLRequest(url: baseURL.appending(path: item.path), timeoutInterval: 10)
        request.httpMethod = item.method
        request.httpBody = item.body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addHeaders(to: &request, apiKey: apiKey)
        let (data, response) = try await URLSession.shared.data(for: request)
        try APIError.check(data, response, service: "Pill API")
    }

    private func addHeaders(to request: inout URLRequest, apiKey: String) {
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(patientID.uuidString, forHTTPHeaderField: "x-patient-id")
    }

    /// Call inside `lock`.
    private func savePending() {
        if let data = try? JSONEncoder().encode(pending) {
            UserDefaults.standard.set(data, forKey: Self.pendingKey)
        }
    }
}

// MARK: - Payloads (sent as snake_case JSON)

private struct PrescriptionPayload: Encodable {
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
    let isSupplement: Bool
    let expirationDate: Date?

    init(_ p: Prescription) {
        key = p.key
        drugName = p.drugName
        dosage = p.dosage
        quantity = p.quantity
        instructions = p.instructions
        takeWithFood = p.takeWithFood
        timesOfDay = p.timesOfDay
        minHoursBetweenDoses = p.minHoursBetweenDoses
        maxDosesPerDay = p.maxDosesPerDay
        asNeeded = p.asNeeded
        isSupplement = p.isSupplement
        expirationDate = p.expirationDate
    }
}

private struct DosePayload: Encodable {
    let eventId: UUID
    let prescriptionKey: String
    let takenAt: Date
    let overrodeWarning: Bool
    let source: String
}

// MARK: - Doses from Tiger Data

struct CloudDose: Decodable {
    let event_id: UUID
    let key: String
    let taken_at: Double
    let overrode_warning: Bool
}

// MARK: - Adherence from Tiger Data

struct CloudAdherence: Decodable {
    struct Day: Decodable, Identifiable {
        let day: String          // "2026-09-26"
        let taken: Int
        let expected: Int
        let overrides: Int

        var id: String { day }
        var missed: Int { max(expected - taken, 0) }
        var date: Date {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: day) ?? .now
        }
    }
    let days: [Day]
    let taken: Int
    let expected: Int
    let overrides: Int
}
