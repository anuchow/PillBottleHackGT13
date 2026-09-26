//
//  PillboxIndex.swift
//  Offline copy of the Pillbox archived data (built by tools/build_pillbox_index.py),
//  and the lookup that links each logged prescription to the pill appearances
//  Pillbox has for that drug + strength (+ manufacturer when the label has it).
//

import Foundation

/// One way a pill can look, from Pillbox.
struct PillAppearance: Hashable, Sendable {
    let name: String
    let strength: String
    let rxString: String
    let manufacturer: String
    let imprint: String          // Pillbox format: sides/lines separated by ";", e.g. "A;500"
    let colors: [String]         // ["WHITE"], ["BLUE", "WHITE"]
    let shape: String            // "OVAL", "ROUND", "CAPSULE", ...
    let sizeMM: Double?
    let imageID: String
    let searchText: String       // uppercased name + strength, for lookups

    init(name: String, strength: String, rxString: String, manufacturer: String,
         imprint: String, colors: [String], shape: String, sizeMM: Double?, imageID: String) {
        self.name = name
        self.strength = strength
        self.rxString = rxString
        self.manufacturer = manufacturer
        self.imprint = imprint
        self.colors = colors
        self.shape = shape
        self.sizeMM = sizeMM
        self.imageID = imageID
        self.searchText = "\(name) \(strength) \(rxString)".uppercased()
    }

    /// "A;500" -> "A 500"
    var imprintDisplay: String { imprint.replacingOccurrences(of: ";", with: " ") }
}

/// A logged prescription plus the Pillbox appearances that could be it.
/// Plain struct so it can be handed to the camera's background queue.
struct LoggedPillProfile: Identifiable, Sendable {
    let id: String               // Prescription.key
    let name: String
    let strength: String?
    let appearances: [PillAppearance]
}

private struct PillboxIndexFile: Decodable {
    let fields: [String]
    let rows: [[String]]
}

@MainActor
final class PillboxIndex {
    static let shared = PillboxIndex()

    private(set) var rows: [PillAppearance] = []
    private(set) var isLoaded = false
    private var cache: [String: [PillAppearance]] = [:]

    /// Loads the bundled JSON off the main thread. Safe to call repeatedly.
    func preload() async {
        guard !isLoaded else { return }
        rows = await Task.detached(priority: .userInitiated) { PillboxIndex.decodeBundledIndex() }.value
        isLoaded = true
    }

    func profiles(for prescriptions: [Prescription]) -> [LoggedPillProfile] {
        prescriptions.map { prescription in
            LoggedPillProfile(
                id: prescription.key,
                name: prescription.displayName,
                strength: DoseFormat.strength(from: prescription.dosage),
                appearances: appearances(drugName: prescription.drugName,
                                         dosage: prescription.dosage,
                                         manufacturer: prescription.manufacturer,
                                         cacheKey: prescription.key)
            )
        }
    }

    /// Pillbox rows for a drug, narrowed by strength and then manufacturer when possible.
    func appearances(drugName: String, dosage: String?, manufacturer: String?, cacheKey: String) -> [PillAppearance] {
        if let cached = cache[cacheKey] { return cached }

        // "METFORMIN HCL ER" -> search on "METFORMIN"
        let words = drugName.uppercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .filter { $0.count >= 4 }
        guard let primary = words.first else { return [] }

        var matches = rows.filter { $0.searchText.contains(primary) }

        // Strength: whole-number match so "500 MG" doesn't match "1500 MG".
        if let parts = Self.strengthParts(dosage),
           let pattern = try? Regex("\\b\(parts.number.replacingOccurrences(of: ".", with: "\\."))\\s?\(parts.unit)\\b") {
            let sameStrength = matches.filter { $0.searchText.contains(pattern) }
            if !sameStrength.isEmpty { matches = sameStrength }
        }

        // Manufacturer from the label ("MFR: AUROBINDO") narrows generics a lot.
        if let maker = manufacturer?.uppercased().split(separator: " ").first.map(String.init), maker.count >= 3 {
            let sameMaker = matches.filter { $0.manufacturer.uppercased().contains(maker) }
            if !sameMaker.isEmpty { matches = sameMaker }
        }

        // Many listings share one look; keep one of each.
        var seen = Set<String>()
        matches = matches.filter { seen.insert("\($0.imprint)|\($0.colors)|\($0.shape)").inserted }

        cache[cacheKey] = matches
        return matches
    }

    // MARK: Helpers

    nonisolated static func strengthParts(_ dosage: String?) -> (number: String, unit: String)? {
        guard let text = dosage?.uppercased(),
              let m = text.firstMatch(of: /(\d+(?:\.\d+)?)\s?(MG|MCG|G|ML)\b/) else { return nil }
        return (String(m.1), String(m.2))
    }

    nonisolated private static func decodeBundledIndex() -> [PillAppearance] {
        guard let url = Bundle.main.url(forResource: "pillbox_index", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(PillboxIndexFile.self, from: data) else {
            print("pillbox_index.json is missing or unreadable. Did you add it to the app target?")
            return []
        }

        var column: [String: Int] = [:]
        for (index, field) in file.fields.enumerated() { column[field] = index }

        func value(_ row: [String], _ key: String) -> String {
            guard let index = column[key], index < row.count else { return "" }
            return row[index]
        }

        return file.rows.map { row in
            PillAppearance(
                name: value(row, "name"),
                strength: value(row, "strength"),
                rxString: value(row, "rxstring"),
                manufacturer: value(row, "manufacturer"),
                imprint: value(row, "imprint"),
                colors: value(row, "colors").split(separator: ";")
                    .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
                    .filter { !$0.isEmpty },
                shape: value(row, "shape"),
                sizeMM: Double(value(row, "size")),
                imageID: value(row, "image")
            )
        }
    }
}
