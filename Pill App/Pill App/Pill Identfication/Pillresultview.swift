//
//  PillResultView.swift
//  "Pill Identified" screen. Also handles "possible match" and "not sure",
//  since a wrong answer here could mean taking the wrong medication.
//

import SwiftUI
import SwiftData

struct PillResultView: View {
    let outcome: PillScanOutcome
    var onScanAgain: () -> Void
    var onClose: () -> Void

    @Query private var prescriptions: [Prescription]
    @Environment(\.modelContext) private var modelContext

    @State private var userChoice: PillMatchResult?     // picked from "Not My Medication"
    @State private var showAlternatives = false
    @State private var activeWarning: DoseWarning?

    private var match: PillMatchResult? { userChoice ?? outcome.best }
    private var confidence: MatchConfidence { outcome.confidence }
    private var canLog: Bool { userChoice != nil || confidence != .none }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                statusIcon
                    .padding(.top, 40)

                Text(title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.center)
                    .padding(.top, 20)

                if let match, canLog, userChoice == nil {
                    Text("\(match.percent)% match")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }

                pillPhoto
                    .padding(.top, 24)

                if let match, canLog {
                    Text(match.profile.name)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Color.ink)
                        .padding(.top, 20)
                    if let strength = match.profile.strength {
                        Text(strength)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                }

                detailsCard
                    .padding(.top, 24)

                note
                    .padding(.top, 16)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom) { buttons }
        .background(Color.white.ignoresSafeArea())
        .sheet(isPresented: $showAlternatives) {
            PillAlternativesSheet(matches: outcome.matches,
                                  onPick: { choice in
                                      userChoice = choice
                                      showAlternatives = false
                                  },
                                  onScanAgain: {
                                      showAlternatives = false
                                      onScanAgain()
                                  })
        }
        .fullScreenCover(item: $activeWarning) { warning in
            DoseWarningView(warning: warning)
        }
    }

    // MARK: Header

    private var title: String {
        if userChoice != nil { return "Selected Medication" }
        switch confidence {
        case .strong:   return "Pill Identified"
        case .possible: return "Possible Match"
        case .none:     return "Not Sure Which Pill This Is"
        }
    }

    @ViewBuilder private var statusIcon: some View {
        let (symbol, color): (String, Color) = {
            if userChoice != nil { return ("checkmark", Color.takenGreen) }
            switch confidence {
            case .strong:   return ("checkmark", Color.takenGreen)
            case .possible: return ("questionmark", Color.orange)
            case .none:     return ("xmark", Color.secondary)
            }
        }()
        ZStack {
            Circle().fill(color.opacity(0.12)).frame(width: 72, height: 72)
            Circle().fill(color).frame(width: 48, height: 48)
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var pillPhoto: some View {
        RoundedRectangle(cornerRadius: 24)
            .fill(Color.appBackground)
            .frame(width: 150, height: 110)
            .overlay {
                if let image = outcome.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .padding(14)
                } else {
                    Image(systemName: "pill.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel("Photo of the scanned pill")
    }

    // MARK: Details

    private var detailsCard: some View {
        let appearance = match?.appearance
        let scan = outcome.summary

        let shapeValue = scan.shape?.capitalized ?? "Not detected"
        let colorValue = scan.colors.isEmpty ? "Not detected" : scan.colors.map(\.capitalized).joined(separator: " & ")
        let imprintValue: String = {
            // Show Pillbox's version of the imprint when it matched (reads cleaner than OCR).
            if let appearance, !appearance.imprint.isEmpty,
               PillMatcher.imprintSimilarity(scan.imprints, expected: appearance.imprint) >= 0.8 {
                return appearance.imprintDisplay
            }
            return scan.imprints.first ?? "Couldn't read"
        }()

        let shapeOK = shapeMatches(scan, appearance)
        let colorOK = colorMatches(scan, appearance)
        let imprintOK = imprintMatches(scan, appearance)

        return VStack(spacing: 0) {
            detailRow("circle.square", "Shape", shapeValue, matches: shapeOK)
            Divider()
            detailRow("paintpalette", "Color", colorValue, matches: colorOK)
            Divider()
            detailRow("textformat.abc", "Imprint", imprintValue, matches: imprintOK)
        }
        .padding(.horizontal, 18)
        .background(RoundedRectangle(cornerRadius: 22).fill(Color.appBackground))
    }

    private func shapeMatches(_ scan: ScannedPillSummary, _ appearance: PillAppearance?) -> Bool? {
        guard let appearance, let shape = scan.shape, !appearance.shape.isEmpty else { return nil }
        return PillMatcher.shapeSimilarity(shape, appearance.shape) >= 1
    }

    private func colorMatches(_ scan: ScannedPillSummary, _ appearance: PillAppearance?) -> Bool? {
        guard let appearance, !scan.colors.isEmpty, !appearance.colors.isEmpty else { return nil }
        return PillMatcher.colorSimilarity(scan.colors, appearance.colors) >= 1
    }

    private func imprintMatches(_ scan: ScannedPillSummary, _ appearance: PillAppearance?) -> Bool? {
        guard let appearance, !appearance.imprint.isEmpty, !scan.imprints.isEmpty else { return nil }
        return PillMatcher.imprintSimilarity(scan.imprints, expected: appearance.imprint) >= 0.8
    }

    /// `matches`: true = agrees with the medication's description, false = differs, nil = unknown.
    private func detailRow(_ symbol: String, _ title: String, _ value: String, matches: Bool?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(title)
                .foregroundStyle(Color.ink)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
            if let matches {
                Image(systemName: matches ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(matches ? Color.takenGreen : Color.orange)
                    .accessibilityLabel(matches ? "Matches" : "Doesn't match")
            }
        }
        .font(.subheadline)
        .padding(.vertical, 15)
        .accessibilityElement(children: .combine)
    }

    // MARK: Note

    @ViewBuilder private var note: some View {
        if userChoice != nil {
            noteText("You picked this medication. Compare the pill with the bottle before taking it.", color: .secondary)
        } else {
            switch confidence {
            case .strong:
                noteText("Matches your logged medication", color: .blue)
            case .possible:
                VStack(spacing: 8) {
                    if !outcome.imprintWasRead {
                        noteText("Couldn't read the imprint, so this is based on color and shape only.", color: .orange)
                    }
                    if let other = outcome.closeRunnerUp {
                        noteText("Could also be \(other.profile.name). Compare the imprint with both bottles.", color: .orange)
                    } else {
                        noteText("Compare the imprint with the bottle before taking it.", color: .orange)
                    }
                }
            case .none:
                noteText("This doesn't clearly match any medication you've logged. Check your bottles or ask a pharmacist before taking it.", color: .secondary)
            }
        }
    }

    private func noteText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .background(RoundedRectangle(cornerRadius: 18).fill(Color.appBackground))
    }

    // MARK: Buttons

    private var buttons: some View {
        VStack(spacing: 12) {
            if canLog {
                primaryButton("Log Dose", action: logDose)
                secondaryButton("Not My Medication") { showAlternatives = true }
            } else {
                primaryButton("Scan Again", action: onScanAgain)
                secondaryButton("Choose Medication") { showAlternatives = true }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Color.white)
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 17)
                .background(RoundedRectangle(cornerRadius: 18).fill(Color.ink))
                .foregroundStyle(.white)
        }
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 17)
                .background(RoundedRectangle(cornerRadius: 18).fill(Color.appBackground))
                .foregroundStyle(Color.ink)
        }
    }

    /// Same overdose check as Home: warning screen if it's too soon.
    private func logDose() {
        guard let match,
              let prescription = prescriptions.first(where: { $0.key == match.profile.id }) else { return }
        let check = prescription.checkDose()
        if check != .ok {
            activeWarning = DoseWarning(prescription: prescription, check: check)
        } else {
            prescription.logDose(in: modelContext)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onClose()
        }
    }
}

// MARK: - Not My Medication

struct PillAlternativesSheet: View {
    let matches: [PillMatchResult]
    var onPick: (PillMatchResult) -> Void
    var onScanAgain: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(matches) { match in
                        Button { onPick(match) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(match.profile.name).foregroundStyle(Color.ink)
                                    if let strength = match.profile.strength {
                                        Text(strength).font(.subheadline).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text(match.appearance == nil ? "No description" : "\(match.percent)%")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Which medication is it?")
                } footer: {
                    Text("Only pick one if you're sure. Otherwise, scan again with better light or ask a pharmacist.")
                }

                Section {
                    Button("Scan Again", action: onScanAgain)
                }
            }
            .navigationTitle("Your Medications")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
