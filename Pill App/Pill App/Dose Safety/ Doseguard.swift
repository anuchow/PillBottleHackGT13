//
//  DoseGuard.swift
//  Overdose prevention: warns when a dose is logged too soon after the last one,
//  or when the daily count from the label's directions is already reached.
//
//  The spacing rules below are app heuristics meant to catch accidental
//  double-logging. They are not clinical guidance — have the team review them
//  (ideally with a pharmacist) and let users adjust per prescription.
//

import Foundation
import SwiftData

// MARK: - Schedule parsing

struct DoseSchedule {
    var timesOfDay: [String] = []
    var minHoursBetweenDoses: Double?
    var maxDosesPerDay: Int?
    var asNeeded = false
}

enum ScheduleParser {

    static func parse(_ instructions: String?) -> DoseSchedule {
        guard let text = instructions?.uppercased() else { return DoseSchedule() }
        var schedule = DoseSchedule()

        schedule.asNeeded = text.contains("AS NEEDED") || text.contains("PRN")

        // "EVERY 6 HOURS", "EVERY 4 TO 6 HOURS" -> the lower bound is the minimum gap.
        if let m = text.firstMatch(of: /EVERY\s+(\d+)(?:\s*(?:TO|-)\s*\d+)?\s*HOURS?/),
           let hours = Double(m.1), hours > 0 {
            schedule.minHoursBetweenDoses = hours
            schedule.maxDosesPerDay = Int(24 / hours)
        }

        // "TWICE DAILY", "3 TIMES A DAY", ... Checked high-to-low so "TWICE DAILY" isn't read as "DAILY".
        if schedule.maxDosesPerDay == nil {
            let perDay: [(String, Int)] = [
                ("FOUR TIMES", 4), ("4 TIMES", 4),
                ("THREE TIMES", 3), ("3 TIMES", 3),
                ("TWICE", 2), ("2 TIMES", 2),
                ("ONCE", 1), ("DAILY", 1), ("EVERY DAY", 1), ("AT BEDTIME", 1)
            ]
            if let match = perDay.first(where: { text.contains($0.0) }) {
                schedule.maxDosesPerDay = match.1
                // Floor to catch a double dose: 12h for once daily, 6h for twice, 4h for three times...
                schedule.minHoursBetweenDoses = 12.0 / Double(match.1)
            }
        }

        // "DO NOT EXCEED 4 TABLETS IN 24 HOURS" tightens the daily cap.
        // (Counts tablets, which equals doses only when each dose is 1 tablet.)
        if let m = text.firstMatch(of: /DO NOT (?:EXCEED|TAKE MORE THAN)\s+(\d+)\s+\w+\s+(?:IN|PER|WITHIN)\s+24\s+HOURS/),
           let cap = Int(m.1) {
            schedule.maxDosesPerDay = min(schedule.maxDosesPerDay ?? cap, cap)
        }

        // Only times the label actually names. If it just says "twice daily",
        // leave this empty and ask the user to pick their times.
        let timeWords: [(String, String)] = [
            ("MORNING", "morning"), ("NOON", "midday"), ("LUNCH", "midday"),
            ("AFTERNOON", "afternoon"), ("EVENING", "evening"),
            ("BEDTIME", "bedtime"), ("AT NIGHT", "bedtime"), ("NIGHTLY", "bedtime")
        ]
        for (word, name) in timeWords where text.contains(word) && !schedule.timesOfDay.contains(name) {
            schedule.timesOfDay.append(name)
        }

        return schedule
    }
}

// MARK: - Dose check

enum DoseCheck: Equatable {
    case ok
    case tooSoon(lastDose: Date, nextAllowed: Date)
    case dailyLimitReached(limit: Int)

    var warning: String? {
        switch self {
        case .ok:
            return nil
        case .tooSoon(let last, let next):
            return "You logged a dose at \(last.formatted(date: .omitted, time: .shortened)). "
                 + "Based on the label's directions, the next dose is due around \(next.formatted(date: .omitted, time: .shortened))."
        case .dailyLimitReached(let limit):
            return "You've already logged \(limit) dose\(limit == 1 ? "" : "s") in the last 24 hours, the most the label's directions allow."
        }
    }
}

enum DoseGuard {
    static func check(proposed: Date = .now,
                      previous: [Date],
                      minHours: Double?,
                      maxPerDay: Int?) -> DoseCheck {
        let earlier = previous.filter { $0 <= proposed }.sorted()

        if let minHours, let last = earlier.last {
            let nextAllowed = last.addingTimeInterval(minHours * 3600)
            if proposed < nextAllowed { return .tooSoon(lastDose: last, nextAllowed: nextAllowed) }
        }

        if let maxPerDay {
            let windowStart = proposed.addingTimeInterval(-24 * 3600)
            let count = earlier.filter { $0 > windowStart }.count
            if count >= maxPerDay { return .dailyLimitReached(limit: maxPerDay) }
        }

        return .ok
    }
}

// MARK: - Convenience on Prescription

extension Prescription {
    func checkDose(at date: Date = .now) -> DoseCheck {
        DoseGuard.check(proposed: date,
                        previous: doses.map(\.takenAt),
                        minHours: minHoursBetweenDoses,
                        maxPerDay: maxDosesPerDay)
    }

    func logDose(at date: Date = .now, overrodeWarning: Bool = false, in context: ModelContext) {
        let log = DoseLog(takenAt: date, overrodeWarning: overrodeWarning)
        log.prescription = self
        context.insert(log)
        try? context.save()
    }
}

// MARK: - Usage in a view
//
// @State private var pendingWarning: String?
//
// Button("Log dose") {
//     if let warning = prescription.checkDose().warning {
//         pendingWarning = warning                      // show the alert first
//     } else {
//         prescription.logDose(in: modelContext)
//     }
// }
// .alert("Check before logging",
//        isPresented: Binding(get: { pendingWarning != nil }, set: { if !$0 { pendingWarning = nil } })) {
//     Button("Cancel", role: .cancel) { }
//     Button("Log anyway", role: .destructive) {
//         prescription.logDose(overrodeWarning: true, in: modelContext)
//     }
// } message: {
//     Text(pendingWarning ?? "")
// }
