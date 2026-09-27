//
//  DoseWarningView.swift
//  Full-screen "Dose may be too soon" warning, shown instead of logging
//  when DoseGuard flags a dose.
//

import SwiftUI
import SwiftData
import UserNotifications

/// What the warning screen needs. Presented with `.fullScreenCover(item:)`.
struct DoseWarning: Identifiable {
    let id = UUID()
    let prescription: Prescription
    let check: DoseCheck
}

struct DoseWarningView: View {
    let warning: DoseWarning

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var showDetails = false

    private var prescription: Prescription { warning.prescription }

    private var nameWithStrength: String {
        [prescription.displayName, DoseFormat.strength(from: prescription.dosage)]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    /// Earliest time the next dose is OK by the label's directions.
    private var nextAllowed: Date? {
        switch warning.check {
        case .tooSoon(_, let next):
            return next
        case .dailyLimitReached:
            let windowStart = Date.now.addingTimeInterval(-24 * 3600)
            return prescription.doses.map(\.takenAt)
                .filter { $0 > windowStart }
                .min()?
                .addingTimeInterval(24 * 3600)
        case .ok:
            return nil
        }
    }

    private var title: String {
        switch warning.check {
        case .dailyLimitReached: return "Daily limit reached"
        default:                 return "Dose may be too soon"
        }
    }

    private var paragraphs: [String] {
        var lines: [String] = []

        switch warning.check {
        case .tooSoon(let last, _):
            lines.append("You logged \(nameWithStrength) at \(timeText(last)).")
            if let frequency = prescription.frequencyText {
                lines.append(frequency.hasPrefix("Every")
                             ? "Your prescribed interval is \(frequency.lowercased())."
                             : "Your label says to take it \(frequency.lowercased()).")
            }
        case .dailyLimitReached(let limit):
            lines.append("You've already logged \(limit) dose\(limit == 1 ? "" : "s") of \(nameWithStrength) in the last 24 hours.")
            lines.append("That's the most your label's directions allow.")
        case .ok:
            break
        }

        if let nextAllowed {
            lines.append("The next recommended dose is at \(timeText(nextAllowed)).")
        }
        return lines
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    Circle().fill(Color.warningRed.opacity(0.1)).frame(width: 88, height: 88)
                    Circle().fill(Color.warningRed).frame(width: 56, height: 56)
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 16)
                .accessibilityHidden(true)

                Text(title)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Color.warningRed)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)

                VStack(alignment: .leading, spacing: 18) {
                    ForEach(paragraphs, id: \.self) { Text($0) }
                }
                .foregroundStyle(Color.ink)
                .padding(.top, 28)

                Spacer()

                buttons
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .background(Color.white.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left").foregroundStyle(Color.ink)
                    }
                    .accessibilityLabel("Back")
                }
            }
            .navigationDestination(isPresented: $showDetails) {
                MedicationDetailView(prescription: prescription)
            }
        }
    }

    private var buttons: some View {
        VStack(spacing: 12) {
            if let nextAllowed {
                Button {
                    DoseReminder.schedule(at: nextAllowed)
                    dismiss()
                } label: {
                    Text("Wait Until \(nextAllowed.formatted(date: .omitted, time: .shortened))")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 17)
                        .background(RoundedRectangle(cornerRadius: 18).fill(Color.ink))
                        .foregroundStyle(.white)
                }
                .accessibilityHint("Sends you a reminder at that time")
            }

            Button { showDetails = true } label: {
                Text("Review Medication")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 17)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Color.appBackground))
                    .foregroundStyle(Color.ink)
            }

            Button {
                prescription.logDose(overrodeWarning: true, in: modelContext)
                dismiss()
            } label: {
                Text("Log Anyway")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.ink)
                    .padding(.vertical, 10)
            }
        }
    }

    private func timeText(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return time }
        if calendar.isDateInYesterday(date) { return "\(time) yesterday" }
        if calendar.isDateInTomorrow(date) { return "\(time) tomorrow" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - Reminder

enum DoseReminder {
    /// Local notification for when the next dose is OK.
    /// The text leaves out the drug name on purpose, since notifications show on the lock screen.
    static func schedule(at date: Date) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = "Time for your next dose"
            content.body = "Open the app to log it."
            content.sound = .default

            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            let request = UNNotificationRequest(
                identifier: "dose-\(date.timeIntervalSince1970)",
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )
            center.add(request)
        }
    }
}
