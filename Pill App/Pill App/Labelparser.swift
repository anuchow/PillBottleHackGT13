//
//  LabelParser.swift
//  Turns OCR text from a CVS label into fields, and votes across frames
//  so one bad OCR read can't sneak into the database.
//
//  Tuned for the CVS ScriptPath layout:
//    left panel:   CVS logo + store address, TEL, RX, QTY, PRSCBR, DISCARD AFTER
//    schedule:     MORNING / MIDDAY / EVENING / BEDTIME boxes with "1 TABLET" in filled slots
//    main panel:   patient name, drug name, strength + form on the next line, directions
//    right panel:  Important Information (warnings)
//

import Foundation
import CoreGraphics

// MARK: - Fields

enum LabelField: String, CaseIterable, Hashable {
    case rxNumber, drugName, dosage, quantity, pharmacy, pharmacyAddress,
         prescriber, expiration, instructions, withFood, schedule

    var displayName: String {
        switch self {
        case .rxNumber:        return "Rx number"
        case .drugName:        return "drug name"
        case .dosage:          return "strength"
        case .quantity:        return "quantity"
        case .pharmacy:        return "pharmacy"
        case .pharmacyAddress: return "pharmacy address"
        case .prescriber:      return "prescriber"
        case .expiration:      return "expiration date"
        case .instructions:    return "directions"
        case .withFood:        return "food instructions"
        case .schedule:        return "dose times"
        }
    }
}

/// One line of OCR text plus where it sits (Vision coords: normalized, lower-left origin).
struct TextLine {
    let text: String
    let box: CGRect
}

/// Final result of a scan, before it's saved as a Prescription.
struct ScannedLabel {
    var rxNumber: String                 // "" if the scan ended before the Rx number was found
    var drugName: String
    var dosage: String?
    var quantity: Int?
    var pharmacyName: String?
    var pharmacyAddress: String?
    var prescriber: String?
    var expirationDate: Date?
    var instructions: String?
    var takeWithFood: Bool?
    var timesOfDay: [String]             // from the MORNING/MIDDAY/EVENING/BEDTIME grid
    var sideEffects: [String]
}

/// What a single camera frame produced.
struct FrameParse {
    var fields: [LabelField: String] = [:]
    var sideEffects: Set<String> = []
}

// MARK: - Parser (one frame)

enum LabelParser {

    static func parse(_ input: [TextLine]) -> FrameParse {
        let items = input.map {
            TextLine(text: $0.text.uppercased().trimmingCharacters(in: .whitespaces), box: $0.box)
        }
        let lines = items.map(\.text)
        let all = lines.joined(separator: " ")
        var out = FrameParse()

        // Rx number: "RX 105004", "RX# 105004"
        if let m = all.firstMatch(of: /RX\s*(?:#|NO\.?|NUMBER)?\s*:?\s*(\d{5,10})/) {
            out.fields[.rxNumber] = String(m.1)
        }

        // Quantity: "QTY: 60"
        if let m = all.firstMatch(of: /(?:QTY|QUANTITY)\s*:?\s*(\d{1,4})/) {
            out.fields[.quantity] = String(m.1)
        }

        // Expiration: "DISCARD AFTER: 03/15/2027"
        if let m = all.firstMatch(of: /(?:DISCARD AFTER|DO NOT USE AFTER|USE BY|EXP(?:IRES|IRATION)?\.?(?: DATE)?)\s*:?\s*(\d{1,2}\/\d{1,2}\/\d{2,4})/) {
            out.fields[.expiration] = String(m.1)
        }

        // Drug name + strength
        parseDrug(items, into: &out)

        // Directions: "TAKE ONE TABLET BY MOUTH TWICE DAILY", possibly wrapped onto
        // the lines directly below it (found by position, not list order, because
        // the label has several columns side by side).
        if let start = items.first(where: {
            $0.text.firstMatch(of: /^(?:TAKE|APPLY|USE|INHALE|INSTILL|PLACE|INJECT|CHEW|DISSOLVE)\b/) != nil
        }) {
            var text = start.text
            var current = start
            for _ in 0..<2 {
                guard let next = neighbor(of: current, in: items, above: false),
                      !isStopLine(next.text) else { break }
                text += " " + next.text
                current = next
            }
            out.fields[.instructions] = text
        }

        // Dose-time grid
        let slots = parseScheduleGrid(items)
        if !slots.isEmpty {
            out.fields[.schedule] = slots.joined(separator: ",")
        }

        // Pharmacy
        if lines.contains(where: { $0.contains("CVS") }) {
            out.fields[.pharmacy] = "CVS Pharmacy"
        }

        // Store address: street line, plus "CITY, ST 12345" directly below it.
        if let street = items.first(where: {
            $0.text.firstMatch(of: /^\d{1,6}\s+[A-Z0-9 .]+\s(?:ST|STREET|AVE|AVENUE|RD|ROAD|BLVD|DR|DRIVE|HWY|PKWY|LN|LANE|WAY|CT|PL|PIKE|CIR)\b/) != nil
        }) {
            var address = street.text
            if let city = neighbor(of: street, in: items, above: false),
               city.text.firstMatch(of: /[A-Z .]+,?\s+[A-Z]{2}\s+\d{5}/) != nil {
                address += ", " + city.text
            }
            out.fields[.pharmacyAddress] = address
        }

        // Prescriber: "PRSCBR: J. DOE"
        for line in lines {
            if let m = line.firstMatch(of: /^(?:PRSCBR|PRESCRIBER|DR\.?)\s*:?\s*([A-Z][A-Z.'\- ]{1,40})/) {
                out.fields[.prescriber] = String(m.1).trimmingCharacters(in: .whitespaces)
                break
            }
        }

        // Food
        if ["WITH FOOD", "WITH MEALS", "WITH A MEAL"].contains(where: all.contains) {
            out.fields[.withFood] = "yes"
        } else if ["EMPTY STOMACH", "WITHOUT FOOD"].contains(where: all.contains) {
            out.fields[.withFood] = "no"
        }

        // Warnings (Important Information panel + stickers)
        let warningKeywords = ["MAY CAUSE", "DROWSINESS", "DIZZINESS", "ALCOHOL", "SUNLIGHT", "DO NOT"]
        for line in lines where warningKeywords.contains(where: line.contains) {
            out.sideEffects.insert(line)
        }

        return out
    }

    // MARK: Drug name + strength

    /// CVS prints the drug name on one line and "500 MG TABLET" on the line below.
    /// Find the strength line first, then take the line directly above it as the name.
    private static func parseDrug(_ items: [TextLine], into out: inout FrameParse) {
        let strengthOnly = /^(\d+(?:\.\d+)?\s?(?:MG|MCG|ML|G|%|UNITS?)(?:\s?\/\s?\d*\s?ML)?)(?:\s+([A-Z][A-Z ]*))?$/

        // The same strength shows up on the small side strip ("500 MG") and the main
        // panel ("500 MG TABLET"). The main panel's text is bigger, so prefer that.
        let candidates = items.compactMap { item in
            item.text.firstMatch(of: strengthOnly).map { (line: item, match: $0) }
        }
        if let best = candidates.max(by: { $0.line.box.height < $1.line.box.height }) {
            let strength = String(best.match.1)
            let form = best.match.2.map { " " + String($0).trimmingCharacters(in: .whitespaces) } ?? ""

            if let above = neighbor(of: best.line, in: items, above: true),
               let name = cleanDrugName(above.text) {
                out.fields[.drugName] = name
                out.fields[.dosage] = strength + form
                return
            }
        }

        // Fallback: name and strength on the same line ("LISINOPRIL 10 MG TAB").
        let notDrugPrefixes = ["TAKE", "DO NOT", "MAY ", "CAUTION", "QTY", "RX"]
        for item in items where !notDrugPrefixes.contains(where: { item.text.hasPrefix($0) }) {
            if let m = item.text.firstMatch(of: /^(?:GENERIC FOR:?\s*)?([A-Z][A-Z\- ]{2,}?)\s+(\d+(?:\.\d+)?\s?(?:MG|MCG|ML|G|%)(?:\s?\/\s?\d*\s?ML)?(?:\s+[A-Z]+)?)/) {
                out.fields[.drugName] = String(m.1).trimmingCharacters(in: .whitespaces)
                out.fields[.dosage] = String(m.2)
                return
            }
        }
    }

    private static func cleanDrugName(_ raw: String) -> String? {
        var name = raw
        if let range = name.range(of: "GENERIC FOR") { name.removeSubrange(range) }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " :"))

        let notNames = ["TAKE", "TABLET", "CAPSULE", "IMPORTANT", "MORNING", "MIDDAY", "EVENING", "BEDTIME"]
        guard name.firstMatch(of: /^[A-Z][A-Z\- ]{2,}$/) != nil,
              !notNames.contains(where: { name.hasPrefix($0) }) else { return nil }
        return name
    }

    // MARK: Schedule grid

    /// A slot is "filled" if there's a number or TABLET/CAPSULE in the box to the right of its label.
    private static func parseScheduleGrid(_ items: [TextLine]) -> [String] {
        let slots: [(word: String, name: String)] = [
            ("MORNING", "morning"), ("MIDDAY", "midday"), ("EVENING", "evening"), ("BEDTIME", "bedtime")
        ]
        let doseWords = ["TAB", "CAP", "ML", "PUFF", "DROP"]
        var filled: [String] = []

        for slot in slots {
            guard let label = items.first(where: { $0.text.contains(slot.word) }) else { continue }
            let h = label.box.height

            // The dose box sits to the right of the slot label, spanning from the
            // label's baseline up to a few line-heights above it (Vision y points up).
            let hasDose = items.contains { item in
                guard item.box.minX > label.box.midX,
                      item.box.minX - label.box.maxX < h * 6,
                      item.box.midY > label.box.minY - h * 0.5,
                      item.box.midY < label.box.maxY + h * 4,
                      !slots.contains(where: { item.text.contains($0.word) }) else { return false }
                return item.text.contains(where: \.isNumber) || doseWords.contains(where: item.text.contains)
            }
            if hasDose { filled.append(slot.name) }
        }
        return filled
    }

    // MARK: Helpers

    /// The closest line directly above/below `target` that overlaps it horizontally.
    static func neighbor(of target: TextLine, in items: [TextLine], above: Bool) -> TextLine? {
        let maxGap = target.box.height * 1.5
        return items
            .filter { c in
                guard c.box.maxX > target.box.minX, c.box.minX < target.box.maxX else { return false }
                let gap = above ? c.box.minY - target.box.maxY : target.box.minY - c.box.maxY
                return gap > -target.box.height * 0.3 && gap < maxGap
            }
            .min { a, b in above ? a.box.minY < b.box.minY : a.box.maxY > b.box.maxY }
    }

    private static func isStopLine(_ line: String) -> Bool {
        line.firstMatch(of: /^(?:QTY|QUANTITY|RX|REFILL|DR\b|DR\.|PRSCBR|PRESCRIBER|RPH|TEL|DISCARD|USE BY|MFG|MFR|GENERIC|FILLED|DATE|CVS|IMPORTANT)/) != nil
    }

    static func parseDate(_ s: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let year = s.split(separator: "/").last ?? ""
        formatter.dateFormat = year.count == 4 ? "M/d/yyyy" : "M/d/yy"
        return formatter.date(from: s)
    }
}

// MARK: - Accumulator (many frames)

/// The bottle is curved, so no single frame shows the whole label. Each frame adds
/// votes, and a value only counts once it has been read the same way twice.
struct LabelAccumulator {

    /// Scan finishes on its own when all of these are confirmed.
    static let required: [LabelField] = [
        .rxNumber, .drugName, .dosage, .quantity, .pharmacyAddress, .expiration, .instructions
    ]

    var confirmationsNeeded = 2

    private var votes: [LabelField: [String: Int]] = [:]
    private var sideEffectVotes: [String: Int] = [:]

    mutating func ingest(_ frame: FrameParse) {
        for (field, value) in frame.fields {
            votes[field, default: [:]][value, default: 0] += 1
        }
        for effect in frame.sideEffects {
            sideEffectVotes[effect, default: 0] += 1
        }
    }

    /// Confirmed value (seen at least `confirmationsNeeded` times).
    func value(_ field: LabelField) -> String? {
        guard let best = votes[field]?.max(by: { $0.value < $1.value }),
              best.value >= confirmationsNeeded else { return nil }
        return best.key
    }

    /// Most-seen value, even if it's only been read once.
    func bestGuess(_ field: LabelField) -> String? {
        votes[field]?.max(by: { $0.value < $1.value })?.key
    }

    var foundCount: Int { LabelField.allCases.filter { value($0) != nil }.count }
    var missingRequired: [LabelField] { Self.required.filter { value($0) == nil } }
    var isComplete: Bool { missingRequired.isEmpty }

    /// "Done" is allowed once we at least know what the medication is.
    var canFinishEarly: Bool { bestGuess(.drugName) != nil }

    var progress: Double {
        Double(Self.required.count - missingRequired.count) / Double(Self.required.count)
    }

    /// `allowUnconfirmed` is used by the Done button: fall back to single reads for
    /// anything not confirmed yet. The user checks these on the review screen.
    func makeScannedLabel(allowUnconfirmed: Bool = false) -> ScannedLabel? {
        func get(_ field: LabelField) -> String? {
            allowUnconfirmed ? (value(field) ?? bestGuess(field)) : value(field)
        }
        guard let drug = get(.drugName) else { return nil }

        return ScannedLabel(
            rxNumber: get(.rxNumber) ?? "",
            drugName: drug,
            dosage: get(.dosage),
            quantity: get(.quantity).flatMap { Int($0) },
            pharmacyName: get(.pharmacy),
            pharmacyAddress: get(.pharmacyAddress),
            prescriber: get(.prescriber),
            expirationDate: get(.expiration).flatMap { LabelParser.parseDate($0) },
            instructions: get(.instructions),
            takeWithFood: get(.withFood).map { $0 == "yes" },
            timesOfDay: get(.schedule)?.split(separator: ",").map(String.init) ?? [],
            sideEffects: sideEffectVotes.filter { $0.value >= confirmationsNeeded }.map(\.key).sorted()
        )
    }
}
