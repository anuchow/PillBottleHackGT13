//
//  Prescription.swift
//  Storage layer for scanned pill bottles (SwiftData, iOS 17+).
//
//  Register the container once in your App:
//      .modelContainer(for: [Prescription.self, DoseLog.self])
//

import Foundation
import SwiftData
import AVFoundation
import Combine

// MARK: - Prescription (one row per bottle / Rx)

@Model
final class Prescription {
    /// Primary key. Rx numbers are only unique *within* a pharmacy, so the key is
    /// "<pharmacy>-<rx number>", e.g. "CVS PHARMACY-1234567". A refill keeps the same
    /// Rx number, so rescanning a refill updates this row instead of duplicating it.
    @Attribute(.unique) var key: String

    var rxNumber: String                    // stored for the key only, never read aloud or shown
    var drugName: String                    // "LISINOPRIL"
    var dosage: String? = nil               // strength, e.g. "10 MG"
    var quantity: Int? = nil                // "QTY: 30" -> 30
    var pharmacyName: String? = nil         // "CVS Pharmacy"
    var pharmacyAddress: String? = nil      // "123 MAIN ST, ATLANTA GA 30332"
    var prescriber: String? = nil           // "DR JANE SMITH" (optional, if found)
    var manufacturer: String? = nil         // "MFR: ABC Manufacturer", narrows pill-appearance lookups
    var expirationDate: Date? = nil         // "DISCARD AFTER" / "USE BY" date
    var instructions: String? = nil         // raw directions: "TAKE 1 TABLET BY MOUTH TWICE DAILY WITH FOOD"
    var takeWithFood: Bool? = nil           // nil = the label doesn't say
    var timesOfDay: [String] = []           // only times the label names: "morning", "bedtime", ...
    var sideEffects: [String] = []          // warning stickers: "MAY CAUSE DROWSINESS"

    // Derived from `instructions` by ScheduleParser. Used by DoseGuard.
    var minHoursBetweenDoses: Double? = nil
    var maxDosesPerDay: Int? = nil
    var asNeeded: Bool = false

    var lastScannedAt: Date = Date.now

    @Relationship(deleteRule: .cascade, inverse: \DoseLog.prescription)
    var doses: [DoseLog] = []

    init(from label: ScannedLabel) {
        self.key = Prescription.makeKey(rxNumber: label.rxNumber, pharmacyName: label.pharmacyName)
        self.rxNumber = label.rxNumber
        self.drugName = label.drugName
        apply(label)
    }

    static func makeKey(rxNumber: String, pharmacyName: String?) -> String {
        // Scans finished early with "Done" may not have an Rx number yet.
        let rx = rxNumber.isEmpty ? "NORX-\(UUID().uuidString)" : rxNumber
        return "\((pharmacyName ?? "PHARMACY").uppercased())-\(rx)"
    }

    /// Copies scanned values in. Called on first save and on rescans (refills).
    func apply(_ label: ScannedLabel) {
        drugName = label.drugName
        dosage = label.dosage
        quantity = label.quantity
        pharmacyName = label.pharmacyName
        pharmacyAddress = label.pharmacyAddress
        prescriber = label.prescriber
        manufacturer = label.manufacturer
        expirationDate = label.expirationDate
        instructions = label.instructions
        takeWithFood = label.takeWithFood
        sideEffects = label.sideEffects

        let schedule = ScheduleParser.parse(label.instructions)
        // Prefer the checked boxes on the label's MORNING/MIDDAY/EVENING/BEDTIME grid.
        timesOfDay = label.timesOfDay.isEmpty ? schedule.timesOfDay : label.timesOfDay
        minHoursBetweenDoses = schedule.minHoursBetweenDoses
        maxDosesPerDay = schedule.maxDosesPerDay
        asNeeded = schedule.asNeeded

        lastScannedAt = .now
    }

    /// Insert a new prescription, or update the existing one with the same key.
    @discardableResult
    static func upsert(_ label: ScannedLabel, in context: ModelContext) throws -> Prescription {
        let key = makeKey(rxNumber: label.rxNumber, pharmacyName: label.pharmacyName)
        let descriptor = FetchDescriptor<Prescription>(predicate: #Predicate { $0.key == key })

        if let existing = try context.fetch(descriptor).first {
            existing.apply(label)
            try context.save()
            return existing
        }

        let prescription = Prescription(from: label)
        context.insert(prescription)
        try context.save()
        return prescription
    }

    // MARK: Read-aloud text (for the text-to-speech side)

    /// Plain-English summary for AVSpeechSynthesizer. Skips the Rx number on purpose.
    var spokenSummary: String {
        var parts: [String] = []

        let name = [drugName.capitalized, dosage?.lowercased()].compactMap { $0 }.joined(separator: " ")
        parts.append(name + ".")

        if let instructions {
            parts.append(instructions.prefix(1).uppercased() + instructions.dropFirst().lowercased() + ".")
        }
        if let takeWithFood {
            parts.append(takeWithFood ? "Take with food." : "Take on an empty stomach.")
        }
        if !timesOfDay.isEmpty {
            parts.append("Scheduled for the \(ListFormatter.localizedString(byJoining: timesOfDay)).")
        }
        if let quantity {
            parts.append("\(quantity) in this bottle.")
        }
        if let expirationDate {
            parts.append("Expires \(expirationDate.formatted(date: .long, time: .omitted)).")
        }
        if !sideEffects.isEmpty {
            parts.append("Warnings: " + sideEffects.map { $0.lowercased() }.joined(separator: ". ") + ".")
        }
        if let pharmacyName {
            let address = pharmacyAddress.map { ", \($0.lowercased())" } ?? ""
            parts.append("Filled at \(pharmacyName)\(address).")
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - DoseLog (one row per logged dose)

@Model
final class DoseLog {
    var takenAt: Date
    var overrodeWarning: Bool          // true if the user logged it anyway after a DoseGuard warning
    var prescription: Prescription?

    init(takenAt: Date = .now, overrodeWarning: Bool = false) {
        self.takenAt = takenAt
        self.overrodeWarning = overrodeWarning
    }
}

// MARK: - Speaker

/// Reads text out loud and publishes whether it's speaking (for Listen/Stop buttons).
///     LabelSpeaker.shared.speak(prescription)
///     LabelSpeaker.shared.speak(text: translated, languageCode: "es-MX")
final class LabelSpeaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = LabelSpeaker()

    @Published private(set) var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ prescription: Prescription) {
        speak(text: prescription.spokenSummary, languageCode: "en-US")
    }

    func speak(text: String, languageCode: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: languageCode)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.isSpeaking = true }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.isSpeaking = false }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.isSpeaking = false }
    }
}
