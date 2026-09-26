//
//  MedicationDetailView.swift
//  Per-medication page: Listen (reads everything aloud) and Translate.
//
//  Translation uses Apple's on-device Translation framework (iOS 18+).
//  The first time a language is used, iOS asks to download it.
//

import SwiftUI
import SwiftData
import Translation

struct MedicationDetailView: View {
    let prescription: Prescription

    @ObservedObject private var speaker = LabelSpeaker.shared
    @AppStorage("labelLanguage") private var languageCode = AppLanguage.english.rawValue

    @State private var showLanguagePicker = false
    @State private var translatedSummary: String?
    @State private var translationFailed = false
    @State private var translationConfig: TranslationSession.Configuration?

    private var language: AppLanguage { AppLanguage(rawValue: languageCode) ?? .english }
    private var isTranslating: Bool { language != .english && translatedSummary == nil && !translationFailed }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(prescription.displayName)
                        .font(.system(size: 30, weight: .bold))
                    Text(prescription.doseSummary.replacingOccurrences(of: " · ", with: " • "))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color.ink)

                HStack(spacing: 16) {
                    pillImage
                    listenButton
                }

                if language != .english { translationCard }

                nextDoseCard
                infoRow("Last Taken", lastTakenText)
                infoRow("Schedule", prescription.frequencyText ?? "Not on label")
                translateRow
                labelDetails
            }
            .padding(20)
        }
        .background(Color.appBackground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showLanguagePicker) {
            LanguagePickerView(selection: $languageCode)
        }
        .translationTask(translationConfig) { session in
            do {
                let response = try await session.translate(prescription.spokenSummary)
                await MainActor.run { translatedSummary = response.targetText }
            } catch {
                await MainActor.run { translationFailed = true }
            }
        }
        .onAppear { updateTranslation() }
        .onChange(of: languageCode) { _, _ in updateTranslation() }
        .onDisappear { speaker.stop() }
    }

    // MARK: Top row

    private var pillImage: some View {
        // TODO: show the user's own pill photo once pill scanning exists.
        RoundedRectangle(cornerRadius: 22)
            .fill(.white)
            .frame(width: 108, height: 108)
            .overlay(
                Image(systemName: "pill.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.doseAmber)
                    .rotationEffect(.degrees(-45))
            )
            .accessibilityHidden(true)
    }

    private var listenButton: some View {
        Button {
            if speaker.isSpeaking {
                speaker.stop()
            } else {
                speaker.speak(text: translatedSummary ?? prescription.spokenSummary,
                              languageCode: translatedSummary == nil ? AppLanguage.english.speechCode : language.speechCode)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: speaker.isSpeaking ? "stop.fill" : "speaker.wave.2.fill")
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(.white))
                Text(speaker.isSpeaking ? "Stop" : "Listen")
                    .font(.body.weight(.medium))
            }
            .foregroundStyle(Color.ink)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(Capsule().fill(Color.cardGray))
        }
        .disabled(isTranslating)
        .accessibilityHint("Reads this medication's details out loud")
    }

    // MARK: Translation

    private var translationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(language.nativeName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if let translatedSummary {
                Text(translatedSummary)
                    .foregroundStyle(Color.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.layoutDirection, language.isRightToLeft ? .rightToLeft : .leftToRight)
            } else if translationFailed {
                Text("Couldn't translate right now. Make sure the language is downloaded, then try again.")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }

            Text("Machine translated. Ask your pharmacist if anything is unclear.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20).fill(.white))
    }

    private var translateRow: some View {
        Button { showLanguagePicker = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "globe")
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.appBackground))
                Text("Translate")
                Spacer()
                Text(language.nativeName).foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(Color.ink)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 20).fill(.white))
        }
        .buttonStyle(.plain)
    }

    private func updateTranslation() {
        speaker.stop()
        translatedSummary = nil
        translationFailed = false
        guard language != .english else {
            translationConfig = nil
            return
        }
        translationConfig = TranslationSession.Configuration(source: AppLanguage.english.localeLanguage,
                                                             target: language.localeLanguage)
    }

    // MARK: Cards

    private var nextDoseCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Next Dose", systemImage: "clock")
                    .font(.headline)
                Spacer()
                Text(prescription.nextDoseTime?.formatted(date: .omitted, time: .shortened) ?? "Not scheduled")
                    .fontWeight(.semibold)
            }
            if let next = prescription.nextDoseTime {
                Text(Calendar.current.isDateInToday(next) ? "Today" : "Tomorrow")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            let detail = [prescription.perDose.map { "Take \($0)" }, prescription.frequencyText]
                .compactMap { $0 }
                .joined(separator: " • ")
            if !detail.isEmpty {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(Color.ink)
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 20).fill(.white))
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.body.weight(.semibold))
            Spacer()
            Text(value).font(.subheadline).foregroundStyle(.secondary)
        }
        .foregroundStyle(Color.ink)
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 20).fill(.white))
        .accessibilityElement(children: .combine)
    }

    /// Everything else from the label.
    private var labelDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("From the label")
                .font(.headline)
            if let instructions = prescription.instructions {
                detail("Directions", instructions.capitalized)
            }
            if let withFood = prescription.takeWithFood {
                detail("Food", withFood ? "Take with food" : "Take on an empty stomach")
            }
            if !prescription.sideEffects.isEmpty {
                detail("Warnings", prescription.sideEffects.map(\.capitalized).joined(separator: "\n"))
            }
            if let quantity = prescription.quantity {
                detail("Quantity", "\(quantity)")
            }
            if let expires = prescription.expirationDate {
                detail("Expires", expires.formatted(date: .abbreviated, time: .omitted))
            }
            if let pharmacy = prescription.pharmacyName {
                detail("Pharmacy", [pharmacy, prescription.pharmacyAddress?.capitalized].compactMap { $0 }.joined(separator: "\n"))
            }
            if let prescriber = prescription.prescriber {
                detail("Prescriber", prescriber.capitalized)
            }
        }
        .foregroundStyle(Color.ink)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20).fill(.white))
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.subheadline)
        }
        .accessibilityElement(children: .combine)
    }

    private var lastTakenText: String {
        guard let date = prescription.lastTaken else { return "Not yet" }
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today, \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday, \(time)" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - Language picker

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en", spanish = "es", chinese = "zh-Hans", hindi = "hi",
         french = "fr", korean = "ko", arabic = "ar"

    var id: String { rawValue }

    var nativeName: String {
        switch self {
        case .english: return "English"
        case .spanish: return "Español"
        case .chinese: return "中文 (简体)"
        case .hindi:   return "हिन्दी"
        case .french:  return "Français"
        case .korean:  return "한국어"
        case .arabic:  return "العربية"
        }
    }

    /// Voice to use for AVSpeechSynthesizer.
    var speechCode: String {
        switch self {
        case .english: return "en-US"
        case .spanish: return "es-MX"
        case .chinese: return "zh-CN"
        case .hindi:   return "hi-IN"
        case .french:  return "fr-FR"
        case .korean:  return "ko-KR"
        case .arabic:  return "ar-SA"
        }
    }

    var localeLanguage: Locale.Language { Locale.Language(identifier: rawValue) }
    var isRightToLeft: Bool { self == .arabic }
}

struct LanguagePickerView: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var draft = AppLanguage.english.rawValue
    @State private var unavailable: Set<AppLanguage> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Select Language")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.ink)
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 8)

            List(AppLanguage.allCases) { language in
                Button { draft = language.rawValue } label: {
                    HStack {
                        Text(language.nativeName)
                        if unavailable.contains(language) {
                            Text("Not available")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: draft == language.rawValue ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(draft == language.rawValue ? Color.ink : Color.secondary)
                    }
                    .foregroundStyle(Color.ink)
                    .padding(.vertical, 6)
                }
                .disabled(unavailable.contains(language))
                .accessibilityAddTraits(draft == language.rawValue ? .isSelected : [])
            }
            .listStyle(.plain)

            Button {
                selection = draft
                dismiss()
            } label: {
                Text("Done")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 17)
                    .background(Capsule().fill(Color.ink))
                    .foregroundStyle(.white)
            }
            .padding(24)
        }
        .onAppear { draft = selection }
        .task {
            let availability = LanguageAvailability()
            for language in AppLanguage.allCases where language != .english {
                let status = await availability.status(from: AppLanguage.english.localeLanguage,
                                                       to: language.localeLanguage)
                if status == .unsupported { unavailable.insert(language) }
            }
        }
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Prescription helpers

extension Prescription {
    var lastTaken: Date? { doses.map(\.takenAt).max() }

    var frequencyText: String? {
        DoseFormat.frequency(instructions: instructions, maxDosesPerDay: maxDosesPerDay, asNeeded: asNeeded)
    }

    /// Next unchecked slot today, otherwise the first slot tomorrow.
    var nextDoseTime: Date? {
        let hours = scheduledHours.sorted()
        guard let first = hours.first else { return nil }
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: .now)
        let takenToday = doses.filter { calendar.isDateInToday($0.takenAt) }.count
        if takenToday < hours.count {
            return startOfDay.addingTimeInterval(hours[takenToday] * 3600)
        }
        return startOfDay.addingTimeInterval((24 + first) * 3600)
    }
}
