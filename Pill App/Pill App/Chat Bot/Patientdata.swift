import Foundation

public struct Medication: Codable, Sendable {
    public var name: String
    public var dose: String
    public var schedule: String
    public var lastTaken: String

    public init(name: String, dose: String, schedule: String, lastTaken: String) {
        self.name = name
        self.dose = dose
        self.schedule = schedule
        self.lastTaken = lastTaken
    }
}

public struct Patient: Codable, Sendable {
    public var name: String
    public var providerName: String
    public var medications: [Medication]

    public init(name: String, providerName: String, medications: [Medication]) {
        self.name = name
        self.providerName = providerName
        self.medications = medications
    }

    /// e.g. "Eleanor takes Lisinopril 10 milligrams, once daily, morning, and Metformin 500 milligrams, twice daily."
    public var spokenMedicationList: String {
        let items = medications.map { "\($0.name) \($0.spokenDose), \($0.schedule)" }
        return "\(name) takes \(items.formatted(.list(type: .and)))."
    }

    /// e.g. "Eleanor last took Lisinopril today at 8:15 AM, and Metformin yesterday at 8:00 PM."
    public func spokenRecentDoses(now: Date = .now) -> String {
        let items = medications.map { "\($0.name) \($0.spokenLastTaken(now: now))" }
        return "\(name) last took \(items.formatted(.list(type: .and)))."
    }

    var medicationsJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(medications)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }
}

extension Medication {
    /// "10mg" read aloud as "10 milligrams".
    var spokenDose: String {
        dose.replacingOccurrences(of: "mg", with: " milligrams")
    }

    /// When it was last taken, as it would be said aloud: "today at 8:15 AM", "yesterday at 8:00 PM", "on September 20 at 9:00 AM".
    public func spokenLastTaken(now: Date = .now) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        if lastTaken.isEmpty { return "with no doses logged yet" }
        guard let date = parser.date(from: lastTaken) else { return "at \(lastTaken)" }

        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "today at \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday at \(time)"
        }
        return "on \(date.formatted(.dateTime.month(.wide).day())) at \(time)"
    }
}

extension Patient {
    /// Mocked for now; will be replaced with real patient data later.
    public static let sample = Patient(
        name: "Eleanor",
        providerName: "Dr. Chowdhury",
        medications: [
            Medication(name: "Lisinopril", dose: "10mg", schedule: "once daily, morning", lastTaken: "2026-09-26T08:15:00"),
            Medication(name: "Metformin", dose: "500mg", schedule: "twice daily", lastTaken: "2026-09-25T20:00:00"),
        ]
    )
}
