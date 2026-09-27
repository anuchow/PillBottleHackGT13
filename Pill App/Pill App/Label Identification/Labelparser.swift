//
//  LabelParser.swift
//  Turns OCR text from a bottle label into fields, and votes across frames
//  so one bad OCR read can't sneak into the database.
//
//  Handles two kinds of bottles:
//
//  CVS prescription (ScriptPath layout)
//    left panel:  CVS logo + store address, TEL, RX, QTY, PRSCBR, DISCARD AFTER, MFR
//    schedule:    MORNING / MIDDAY / EVENING / BEDTIME boxes
//    main panel:  patient name, drug name, strength + form below it, directions
//
//  Nature Made supplement
//    front:  NATURE MADE logo, product name in big red letters ("D3", "IRON"),
//            strength ("2000 IU (50 MCG)"), count ("90 SOFTGELS"), "DIETARY SUPPLEMENT"
//    back:   SUGGESTED USE: ..., Supplement Facts, warnings, list number (some bottles),
//            Lot/Exp printed sideways
//
//  The primary key is the Rx number for prescriptions and the list number for supplements.
//  The bottle type is detected automatically from each frame, so both kinds scan the same way.
//

import Foundation
import CoreGraphics

// MARK: - Fields

enum LabelField: String, CaseIterable, Hashable {
    case rxNumber, listNumber, drugName, dosage, quantity, pharmacy, pharmacyAddress,
         prescriber, expiration, instructions, withFood, schedule, manufacturer

    var displayName: String {
        switch self {
        case .rxNumber:        return "Rx number"
        case .listNumber:      return "list number"
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
        case .manufacturer:    return "manufacturer"
        }
    }

    /// "Rx number", "Drug name", ... for the checklist.
    var title: String { displayName.prefix(1).uppercased() + displayName.dropFirst() }
}

/// Which kind of bottle the camera is looking at.
enum LabelKind: Hashable {
    case pharmacy, supplement
}

/// One line of OCR text plus where it sits (Vision coords: normalized, lower-left origin).
struct TextLine {
    let text: String
    let box: CGRect
}

/// Final result of a scan, before it's saved as a Prescription.
struct ScannedLabel {
    var rxNumber: String                 // prescriptions: Rx number; supplements: "LIST-<list number>"
    var drugName: String
    var dosage: String?
    var quantity: Int?
    var pharmacyName: String?            // "CVS Pharmacy", or the brand for supplements
    var pharmacyAddress: String?
    var prescriber: String?
    var expirationDate: Date?
    var instructions: String?
    var takeWithFood: Bool?
    var timesOfDay: [String]             // from the MORNING/MIDDAY/EVENING/BEDTIME grid
    var sideEffects: [String]
    var manufacturer: String? = nil      // "MFR: ABC Manufacturer", or "Nature Made"
    var isSupplement: Bool = false

    /// The list number without the "LIST-" prefix, for supplements.
    var listNumber: String? {
        isSupplement && rxNumber.hasPrefix("LIST-") ? String(rxNumber.dropFirst(5)) : nil
    }
}

/// What a single camera frame produced.
struct FrameParse {
    var fields: [LabelField: String] = [:]
    var sideEffects: Set<String> = []
    var kind: LabelKind?
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

        // Which kind of bottle is this frame showing?
        let hasBrand = all.contains("NATURE MADE") || all.contains("NATUREMADE")
        let isSupplement = hasBrand
            || ["DIETARY SUPPLEMENT", "SUPPLEMENT FACTS", "SUGGESTED USE"].contains(where: all.contains)
        if isSupplement {
            out.kind = .supplement
        } else if all.contains("CVS") || all.firstMatch(of: /\bRX\s*(?:#|NO\.?)?\s*:?\s*\d{5,}/) != nil {
            out.kind = .pharmacy
        }

        // Rx number: "RX 105004", "RX# 105004"
        if !isSupplement, let m = all.firstMatch(of: /RX\s*(?:#|NO\.?|NUMBER)?\s*:?\s*(\d{5,10})/) {
            out.fields[.rxNumber] = String(m.1)
        }

        // List number (Nature Made): "LIST 12345", "LIST NO. 12345"
        // TODO: check the exact wording on your bottles and adjust if needed.
        if let m = all.firstMatch(of: /LIST\s*(?:NO\.?|NUMBER|#)?\s*:?\s*(\d{3,8})/) {
            out.fields[.listNumber] = String(m.1)
        }

        // Quantity: "QTY: 60", or a supplement count like "180 TABLETS"
        if let m = all.firstMatch(of: /(?:QTY|QUANTITY)\s*:?\s*(\d{1,4})/) {
            out.fields[.quantity] = String(m.1)
        } else if let m = all.firstMatch(of: /(\d{2,4})\s+(?:TABLETS|CAPLETS|SOFTGELS|CAPSULES|GUMMIES)\b/) {
            out.fields[.quantity] = String(m.1)
        }

        // Expiration: "DISCARD AFTER: 03/15/2027", "EXP 03/2027", "EXP MAR 2027"
        if let m = all.firstMatch(of: /(?:DISCARD AFTER|DO NOT USE AFTER|USE BY|BEST BY|EXP(?:IRES|IRATION)?\.?(?: DATE)?)\s*:?\s*(\d{1,2}\/\d{2,4}(?:\/\d{2,4})?)/) {
            out.fields[.expiration] = String(m.1)
        } else if let m = all.firstMatch(of: /(?:EXP(?:IRES|IRATION)?\.?(?: DATE)?|BEST BY)\s*:?\s*(JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)[A-Z]*\.?\s*(\d{2,4})/) {
            out.fields[.expiration] = "\(m.1) \(m.2)"
        }

        // Name + strength
        if isSupplement {
            // Only trust the name from the front panel. The Supplement Facts table on
            // the back is full of "VITAMIN C 300 MG" rows that would look like names.
            // The script logo doesn't always OCR, so the count line ("90 SOFTGELS") also marks the front.
            let isBack = all.contains("SUPPLEMENT FACTS") || all.contains("SUGGESTED USE") || all.contains("INGREDIENTS")
            let hasCount = all.firstMatch(of: /\d{2,4}\s+(?:TABLETS|CAPLETS|SOFTGELS|CAPSULES|GUMMIES)\b/) != nil
            if !isBack && (hasBrand || hasCount || all.contains("DIETARY SUPPLEMENT")) {
                parseSupplementFront(items, into: &out)
            }
        } else {
            parseDrug(items, into: &out)
        }

        // Directions
        if isSupplement {
            parseSuggestedUse(items, into: &out)
        } else if let start = items.first(where: {
            $0.text.firstMatch(of: /^(?:TAKE|APPLY|USE|INHALE|INSTILL|PLACE|INJECT|CHEW|DISSOLVE)\b/) != nil
        }) {
            // Wrapped lines are found by position, since the label has side-by-side columns.
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

        // Dose-time grid (CVS)
        if !isSupplement {
            let slots = parseScheduleGrid(items)
            if !slots.isEmpty { out.fields[.schedule] = slots.joined(separator: ",") }
        }

        // Pharmacy or brand
        if hasBrand {
            out.fields[.pharmacy] = "Nature Made"
            out.fields[.manufacturer] = "Nature Made"
        } else if lines.contains(where: { $0.contains("CVS") }) {
            out.fields[.pharmacy] = "CVS Pharmacy"
        }

        if !isSupplement {
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

            // Manufacturer: "MFR: ABC MANUFACTURER" (used to look up what the pill looks like)
            for line in lines {
                if let m = line.firstMatch(of: /^(?:MFR|MFG|MANUFACTURER)\s*:?\s*([A-Z][A-Z0-9.&,'\- ]{1,50})/) {
                    out.fields[.manufacturer] = String(m.1).trimmingCharacters(in: .whitespaces)
                    break
                }
            }
        }

        // Food
        if ["WITH FOOD", "WITH MEALS", "WITH A MEAL", "AND A MEAL", "WITH MEAL"].contains(where: all.contains) {
            out.fields[.withFood] = "yes"
        } else if ["EMPTY STOMACH", "WITHOUT FOOD"].contains(where: all.contains) {
            out.fields[.withFood] = "no"
        }

        // Warnings (CVS Important Information panel, stickers, supplement warnings)
        let warningKeywords = ["MAY CAUSE", "DROWSINESS", "DIZZINESS", "ALCOHOL", "SUNLIGHT", "DO NOT",
                               "OVERDOSE", "KEEP OUT OF REACH", "CONSULT"]
        for line in lines where warningKeywords.contains(where: line.contains) {
            out.sideEffects.insert(line)
        }

        return out
    }

    // MARK: Prescription name + strength

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

    // MARK: Supplement name, strength, directions

    /// Nature Made front panel: the product name is the big red wording, which is the
    /// tallest text on the label once the logo and marketing lines are skipped.
    /// The strength is the line starting with an amount, e.g. "2000 IU (50 MCG)" or "65 MG".
    private static func parseSupplementFront(_ items: [TextLine], into out: inout FrameParse) {
        let strengthLine = /^(\d[\d,]*(?:\.\d+)?\s?(?:MG|MCG|G|IU))\b/
        if let best = items
            .compactMap({ item in item.text.firstMatch(of: strengthLine).map { (item, $0) } })
            .max(by: { $0.0.box.height < $1.0.box.height }) {
            out.fields[.dosage] = String(best.1.1)
        }

        let notNames = ["NATURE", "MADE", "PHARMACIST", "RECOMMENDED", "SUPPLEMENT", "USP", "VERIFIED",
                        "TABLETS", "CAPLETS", "SOFTGELS", "GUMMIES", "VITAL", "SUPPORT", "HEALTH", "FOR ",
                        "IMMUNE", "BONE", "MUSCLE", "BRAND", "VITAMIN &"]
        if let title = items
            .filter({ $0.text.firstMatch(of: /^[A-Z][A-Z0-9\- ]{1,30}$/) != nil })
            .filter({ item in !notNames.contains(where: { item.text.contains($0) }) })
            .max(by: { $0.box.height < $1.box.height }) {
            var name = title.text.trimmingCharacters(in: .whitespaces)
            // "D3" -> "VITAMIN D3", "B12" -> "VITAMIN B12"
            if name.firstMatch(of: /^[ABCDEK]\d{0,2}$/) != nil { name = "VITAMIN " + name }
            out.fields[.drugName] = name
        }
    }

    /// Nature Made directions. The "1 softgel daily with water and a meal" line usually has
    /// everything on its own, so check every line first; only fall back to piecing lines
    /// together under the green "SUGGESTED USE" heading if no single line has it.
    private static func parseSuggestedUse(_ items: [TextLine], into out: inout FrameParse) {
        for item in items {
            if let directions = canonicalDirections(item.text) {
                out.fields[.instructions] = directions
                return
            }
        }

        guard let start = items.first(where: { $0.text.contains("SUGGESTED USE") || $0.text.hasPrefix("DIRECTIONS") })
                ?? items.first(where: { $0.text.firstMatch(of: /\bTAKE\b/) != nil })
        else { return }

        var text = start.text
        let sameRow = items
            .filter { $0.box.minX > start.box.midX && abs($0.box.midY - start.box.midY) < start.box.height * 0.6 }
            .sorted { $0.box.minX < $1.box.minX }
        for piece in sameRow where !text.contains(piece.text) { text += " " + piece.text }

        var current = start
        for _ in 0..<2 {
            guard let next = neighbor(of: current, in: items, above: false), !isStopLine(next.text) else { break }
            text += " " + next.text
            current = next
        }

        if let directions = canonicalDirections(text) {
            out.fields[.instructions] = directions
        }
    }

    /// Boils the directions down to one fixed wording, so every frame reads the same thing even
    /// when the end of the line is cut off by the bottle's curve:
    ///   "ADULTS, TAKE 1 SOFTGEL DAILY WITH WATER AND A MEAL."  ->  "TAKE 1 SOFTGEL DAILY"
    ///   "1 softgel daily with water and a"                     ->  "TAKE 1 SOFTGEL DAILY"
    /// "With a meal" is read separately (withFood) and added back when the label is saved.
    static func canonicalDirections(_ raw: String) -> String? {
        let text = raw.uppercased()
            .replacingOccurrences(of: "SOFT GEL", with: "SOFTGEL")
            .replacingOccurrences(of: "|", with: "1")

        guard let m = text.firstMatch(of: /\b(\d+|ONE|TWO|THREE|I|L)\s+(SOFTGEL|TABLET|CAPLET|CAPSULE|GUMMY|GUMMIE)S?\b[\s,]*(ONCE\s+DAILY|ONCE\s+A\s+DAY|TWICE\s+DAILY|TWICE\s+A\s+DAY|TWO\s+TIMES|THREE\s+TIMES|DAILY|EVERY\s+DAY|PER\s+DAY|A\s+DAY)/)
        else { return nil }

        let numbers = ["ONE": "1", "TWO": "2", "THREE": "3", "I": "1", "L": "1"]
        let count = numbers[String(m.1)] ?? String(m.1)
        var unit = String(m.2)
        if unit.hasPrefix("GUMM") { unit = count == "1" ? "GUMMY" : "GUMMIES" }
        else if count != "1" { unit += "S" }

        let frequency = String(m.3)
        let often: String
        if frequency.hasPrefix("TWICE") || frequency.hasPrefix("TWO") { often = "TWICE DAILY" }
        else if frequency.hasPrefix("THREE") { often = "3 TIMES DAILY" }
        else { often = "DAILY" }

        return "TAKE \(count) \(unit) \(often)"
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
        line.firstMatch(of: /^(?:QTY|QUANTITY|RX|REFILL|DR\b|DR\.|PRSCBR|PRESCRIBER|RPH|TEL|DISCARD|USE BY|MFG|MFR|GENERIC|FILLED|DATE|CVS|IMPORTANT|WARNING|KEEP|STORE|SUPPLEMENT|OTHER INGREDIENTS|CONTAINS)/) != nil
    }

    /// "3/15/2027", "3/15/27", "03/2027", "MAR 2027". Month-only dates expire at the end of that month.
    static func parseDate(_ s: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.isLenient = true

        let parts = s.split(whereSeparator: { $0 == "/" || $0 == " " })
        guard let last = parts.last else { return nil }
        let fourDigitYear = last.count == 4

        if parts.count == 3 {
            formatter.dateFormat = fourDigitYear ? "M/d/yyyy" : "M/d/yy"
            return formatter.date(from: s)
        }
        if parts.count == 2, let first = parts.first?.first {
            if first.isLetter {
                formatter.dateFormat = fourDigitYear ? "MMM yyyy" : "MMM yy"
            } else {
                formatter.dateFormat = fourDigitYear ? "M/yyyy" : "M/yy"
            }
            guard let startOfMonth = formatter.date(from: s.capitalized) else { return nil }
            return Calendar.current.date(byAdding: DateComponents(month: 1, day: -1), to: startOfMonth)
        }
        return nil
    }
}

// MARK: - Accumulator (many frames)

/// The bottle is curved, so no single frame shows the whole label. Each frame adds
/// votes, and a value only counts once it has been read the same way twice.
struct LabelAccumulator {

    /// Checklist for CVS prescriptions. Scan finishes on its own when all are confirmed.
    static let pharmacyRequired: [LabelField] = [
        .rxNumber, .drugName, .dosage, .quantity, .instructions, .expiration
    ]

    /// Checklist for supplements. The list number is the database key.
    static let supplementRequired: [LabelField] = [
        .listNumber, .drugName, .dosage, .quantity, .instructions, .expiration
    ]

    var confirmationsNeeded = 2

    private var votes: [LabelField: [String: Int]] = [:]
    private var sideEffectVotes: [String: Int] = [:]
    private var kindVotes: [LabelKind: Int] = [:]

    mutating func ingest(_ frame: FrameParse) {
        for (field, value) in frame.fields {
            votes[field, default: [:]][value, default: 0] += 1
        }
        for effect in frame.sideEffects {
            sideEffectVotes[effect, default: 0] += 1
        }
        if let kind = frame.kind {
            kindVotes[kind, default: 0] += 1
        }
    }

    var kind: LabelKind {
        (kindVotes[.supplement] ?? 0) > (kindVotes[.pharmacy] ?? 0) ? .supplement : .pharmacy
    }

    var required: [LabelField] {
        kind == .supplement ? Self.supplementRequired : Self.pharmacyRequired
    }

    /// Must be confirmed before "Done" is allowed. These make up the database key.
    var mandatory: Set<LabelField> {
        kind == .supplement ? [.listNumber, .drugName] : [.rxNumber, .drugName]
    }

    /// Confirmed value (seen at least `confirmationsNeeded` times).
    func value(_ field: LabelField) -> String? {
        guard let best = votes[field]?.max(by: { $0.value < $1.value }),
              best.value >= readsNeeded(for: field) else { return nil }
        return best.key
    }

    /// Supplement directions are matched against a strict pattern ("TAKE 1 SOFTGEL DAILY"),
    /// so one clean read is enough. Everything else needs two matching reads.
    private func readsNeeded(for field: LabelField) -> Int {
        kind == .supplement && field == .instructions ? 1 : confirmationsNeeded
    }

    /// Most-seen value, even if it's only been read once.
    func bestGuess(_ field: LabelField) -> String? {
        votes[field]?.max(by: { $0.value < $1.value })?.key
    }

    var foundCount: Int { LabelField.allCases.filter { value($0) != nil }.count }
    var missingRequired: [LabelField] { required.filter { value($0) == nil } }
    var isComplete: Bool { missingRequired.isEmpty }

    var confirmedFields: Set<LabelField> {
        Set(LabelField.allCases.filter { value($0) != nil })
    }

    var canFinishEarly: Bool { mandatory.allSatisfy { value($0) != nil } }

    var progress: Double {
        Double(required.count - missingRequired.count) / Double(required.count)
    }

    /// `allowUnconfirmed` is used by the Done button: fall back to single reads for
    /// anything not confirmed yet. The user checks these on the results screen.
    func makeScannedLabel(allowUnconfirmed: Bool = false) -> ScannedLabel? {
        func get(_ field: LabelField) -> String? {
            allowUnconfirmed ? (value(field) ?? bestGuess(field)) : value(field)
        }

        // The name and the key always have to be confirmed, even when skipping.
        guard let drug = value(.drugName) else { return nil }
        let isSupplement = kind == .supplement
        let key: String
        if isSupplement {
            guard let list = value(.listNumber) else { return nil }
            key = "LIST-\(list)"
        } else {
            guard let rx = value(.rxNumber) else { return nil }
            key = rx
        }

        return ScannedLabel(
            rxNumber: key,
            drugName: drug,
            dosage: get(.dosage),
            quantity: get(.quantity).flatMap { Int($0) },
            pharmacyName: get(.pharmacy) ?? (isSupplement ? "Nature Made" : nil),
            pharmacyAddress: isSupplement ? nil : get(.pharmacyAddress),
            prescriber: isSupplement ? nil : get(.prescriber),
            expirationDate: get(.expiration).flatMap { LabelParser.parseDate($0) },
            instructions: get(.instructions).map { directions in
                // Supplement directions are stored in short form; add "with food" back if the label said so.
                isSupplement && get(.withFood) == "yes" && !directions.contains("FOOD")
                    ? directions + " WITH FOOD" : directions
            },
            takeWithFood: get(.withFood).map { $0 == "yes" },
            timesOfDay: get(.schedule)?.split(separator: ",").map(String.init) ?? [],
            sideEffects: sideEffectVotes.filter { $0.value >= confirmationsNeeded }.map(\.key).sorted(),
            manufacturer: get(.manufacturer),
            isSupplement: isSupplement
        )
    }
}
