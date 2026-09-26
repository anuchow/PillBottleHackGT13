//
//  ScanResultView.swift
//  "Medication Found" screen shown after a label scan, before saving.
//

import SwiftUI

struct ScanResultView: View {
    let label: ScannedLabel
    var onAdd: () -> Void
    var onScanAnother: () -> Void

    // Derived from the scan
    private var schedule: DoseSchedule { ScheduleParser.parse(label.instructions) }
    private var timesOfDay: [String] { label.timesOfDay.isEmpty ? schedule.timesOfDay : label.timesOfDay }
    private var perDose: String? { DoseFormat.perDose(from: label.instructions) }
    private var strength: String? { DoseFormat.strength(from: label.dosage) }

    private var quantityText: String? {
        guard let quantity = label.quantity else { return nil }
        let unit = DoseFormat.unit(perDose: perDose, dosage: label.dosage)
        return unit.map { "\(quantity) \($0)\(quantity == 1 ? "" : "s")" } ?? "Qty \(quantity)"
    }

    private var nextDose: Date? {
        let hours = DoseFormat.hours(timesOfDay: timesOfDay,
                                     maxDosesPerDay: schedule.maxDosesPerDay,
                                     asNeeded: schedule.asNeeded).sorted()
        let startOfDay = Calendar.current.startOfDay(for: .now)
        let today = hours.map { startOfDay.addingTimeInterval($0 * 3600) }
        return today.first { $0 > .now } ?? today.first?.addingTimeInterval(24 * 3600)
    }

    private var frequency: String? {
        DoseFormat.frequency(instructions: label.instructions,
                             maxDosesPerDay: schedule.maxDosesPerDay,
                             asNeeded: schedule.asNeeded)
    }

    private var rows: [DetailRow] {
        var rows: [DetailRow] = []
        if let nextDose {
            rows.append(DetailRow(symbol: "clock", title: "Next dose",
                                  value: nextDose.formatted(date: .omitted, time: .shortened),
                                  detail: Calendar.current.isDateInToday(nextDose) ? "Today" : "Tomorrow",
                                  emphasized: true))
        }
        if let perDose {
            rows.append(DetailRow(symbol: "pill", title: "Take", value: perDose))
        }
        if let frequency {
            rows.append(DetailRow(symbol: "arrow.triangle.2.circlepath", title: "How often", value: frequency))
        }
        if let expires = label.expirationDate {
            rows.append(DetailRow(symbol: "calendar", title: "Expires",
                                  value: expires.formatted(date: .abbreviated, time: .omitted)))
        }
        return rows
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(Color.takenGreen.opacity(0.12)).frame(width: 96, height: 96)
                    Circle().fill(Color.takenGreen).frame(width: 60, height: 60)
                    Image(systemName: "checkmark")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                }
                .padding(.top, 40)
                .accessibilityHidden(true)

                Text("Medication Found")
                    .font(.title2.weight(.semibold))
                    .padding(.top, 24)

                Text(label.drugName.capitalized)
                    .font(.system(size: 30, weight: .bold))
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)

                if let line = joined([strength, perDose]) {
                    Text(line)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }

                if let line = joined(["Rx \(label.rxNumber)", quantityText]) {
                    Text(line)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }

                if !rows.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            detailRow(row)
                            if index < rows.count - 1 { Divider() }
                        }
                    }
                    .padding(.horizontal, 18)
                    .background(RoundedRectangle(cornerRadius: 22).fill(Color.appBackground))
                    .padding(.top, 32)
                }
            }
            .foregroundStyle(Color.ink)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                Button(action: onAdd) {
                    Text("Add to My Medications")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 17)
                        .background(RoundedRectangle(cornerRadius: 18).fill(Color.ink))
                        .foregroundStyle(.white)
                }
                Button(action: onScanAnother) {
                    Text("Scan Another")
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 17)
                        .background(RoundedRectangle(cornerRadius: 18).fill(Color.appBackground))
                        .foregroundStyle(Color.ink)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(Color.white)
        }
        .background(Color.white.ignoresSafeArea())
    }

    private func detailRow(_ row: DetailRow) -> some View {
        HStack(alignment: .top) {
            Label(row.title, systemImage: row.symbol)
                .foregroundStyle(.secondary)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.value)
                    .fontWeight(row.emphasized ? .semibold : .regular)
                if let detail = row.detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.subheadline)
        .padding(.vertical, 16)
        .accessibilityElement(children: .combine)
    }

    private func joined(_ parts: [String?]) -> String? {
        let present = parts.compactMap { $0 }.filter { !$0.isEmpty }
        return present.isEmpty ? nil : present.joined(separator: " • ")
    }
}

private struct DetailRow: Identifiable {
    let symbol: String
    let title: String
    let value: String
    var detail: String? = nil
    var emphasized = false
    var id: String { title }
}

// MARK: - Shared formatting (used here and on Home)

enum DoseFormat {

    /// "Every 8 hours", "Twice a day", "As needed"
    static func frequency(instructions: String?, maxDosesPerDay: Int?, asNeeded: Bool) -> String? {
        if asNeeded { return "As needed" }
        if let text = instructions?.uppercased(),
           let m = text.firstMatch(of: /EVERY\s+(\d+)(?:\s*(?:TO|-)\s*(\d+))?\s*HOURS?/) {
            if let upper = m.2 { return "Every \(m.1)–\(upper) hours" }
            return "Every \(m.1) hours"
        }
        switch maxDosesPerDay {
        case 1:  return "Once a day"
        case 2:  return "Twice a day"
        case 3:  return "3 times a day"
        case 4:  return "4 times a day"
        default: return nil
        }
    }

    /// "500 MG TABLET" -> "500 mg"
    static func strength(from dosage: String?) -> String? {
        guard let dosage,
              let m = dosage.uppercased().firstMatch(of: /(\d+(?:\.\d+)?)\s?(MG|MCG|ML|G|%|UNITS?)/) else { return nil }
        return "\(m.1) \(m.2.lowercased())"
    }

    /// "TAKE ONE TABLET BY MOUTH..." -> "1 tablet"
    static func perDose(from instructions: String?) -> String? {
        guard let text = instructions?.uppercased(),
              let m = text.firstMatch(of: /TAKE\s+(\d+|ONE|TWO|THREE|HALF|1\/2)\s+(TABLET|CAPSULE|PILL)S?/) else { return nil }
        let numbers = ["ONE": "1", "TWO": "2", "THREE": "3", "HALF": "½", "1/2": "½"]
        let count = numbers[String(m.1)] ?? String(m.1)
        let unit = m.2.lowercased() + (count == "1" || count == "½" ? "" : "s")
        return "\(count) \(unit)"
    }

    /// Singular unit for quantities: "capsule", "tablet".
    static func unit(perDose: String?, dosage: String?) -> String? {
        let source = (perDose ?? "") + " " + (dosage ?? "")
        let upper = source.uppercased()
        if upper.contains("CAP") { return "capsule" }
        if upper.contains("TAB") { return "tablet" }
        if upper.contains("PILL") { return "pill" }
        return nil
    }

    /// Hours after midnight for each dose.
    /// TODO: let users set their own times; these are defaults.
    static func hours(timesOfDay: [String], maxDosesPerDay: Int?, asNeeded: Bool) -> [Double] {
        let slotHours: [String: Double] = [
            "morning": 8, "midday": 12, "afternoon": 14, "evening": 18, "bedtime": 21
        ]
        let fromLabel = timesOfDay.compactMap { slotHours[$0] }
        if !fromLabel.isEmpty { return fromLabel }
        if asNeeded { return [] }

        switch maxDosesPerDay {
        case 1:  return [9]
        case 2:  return [9, 21]
        case 3:  return [8, 14, 20]
        case 4:  return [8, 12, 16, 20]
        default: return []
        }
    }
}
