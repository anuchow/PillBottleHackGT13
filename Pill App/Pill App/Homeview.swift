//
//  HomeView.swift
//  Home: greeting, next dose, today's medications, quick scan actions.
//

import SwiftUI
import SwiftData

struct HomeView: View {
    @Binding var selectedTab: AppTab

    @Query(sort: \Prescription.drugName) private var prescriptions: [Prescription]
    @Environment(\.modelContext) private var modelContext
    @AppStorage("userName") private var userName = "Prathithi"   // TODO: set this from the Profile tab

    @State private var showBottleScanner = false
    @State private var showPillScanner = false
    @State private var activeWarning: DoseWarning?
    @State private var bottleCheckFor: Prescription?     // Take Now -> AR bottle check

    var body: some View {
        let doses = ScheduledDose.today(for: prescriptions)
        let next = doses.first { !$0.isTaken }

        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                if let next {
                    NextDoseCard(dose: next) { attemptLog(next) }
                } else {
                    emptyCard(hasDosesToday: !doses.isEmpty)
                }

                todaySection(doses, next: next)
                quickActions
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(Color.appBackground.ignoresSafeArea())
        .fullScreenCover(isPresented: $showBottleScanner) {
            LabelScannerView()
        }
        .fullScreenCover(isPresented: $showPillScanner) {
            PillScanView()
        }
        .fullScreenCover(item: $bottleCheckFor) { prescription in
            ARDoseCheckView(target: prescription, all: prescriptions)
        }
        .fullScreenCover(item: $activeWarning) { warning in
            DoseWarningView(warning: warning)
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting + (userName.isEmpty ? "." : ","))
                    .font(.system(size: 32))
                if !userName.isEmpty {
                    Text(userName + ".")
                        .font(.system(size: 32, weight: .bold))
                }
            }
            .foregroundStyle(Color.ink)

            Spacer()

            Button { selectedTab = .profile } label: {
                Image(systemName: "person")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.ink)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.white).shadow(color: .black.opacity(0.06), radius: 6, y: 2))
            }
            .accessibilityLabel("Profile")
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        if hour < 12 { return "Good morning" }
        if hour < 17 { return "Good afternoon" }
        return "Good evening"
    }

    private func emptyCard(hasDosesToday: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(prescriptions.isEmpty ? "No medications yet"
                 : hasDosesToday ? "All done for today" : "Nothing scheduled today")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.ink)
            Text(prescriptions.isEmpty ? "Scan a pill bottle to add your first medication."
                 : hasDosesToday ? "You've logged every scheduled dose." : "Doses you need to take today will show up here.")
                .foregroundStyle(.secondary)

            if prescriptions.isEmpty {
                Button { showBottleScanner = true } label: {
                    Text("Scan a bottle")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Capsule().fill(Color.ink))
                        .foregroundStyle(.white)
                }
                .padding(.top, 12)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 24).fill(Color.doseCream))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.doseBorder, lineWidth: 1))
    }

    private func todaySection(_ doses: [ScheduledDose], next: ScheduledDose?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Today's Medications")
                    .font(.headline)
                    .foregroundStyle(Color.ink)
                Spacer()
                Button("View All") { selectedTab = .meds }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !doses.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(doses.enumerated()), id: \.element.id) { index, dose in
                        DoseRow(dose: dose, isNext: dose.id == next?.id) {
                            dose.isTaken ? undoDose(dose) : attemptLog(dose)
                        }
                        if index < doses.count - 1 {
                            Divider().padding(.leading, 70)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 20).fill(.white))
            }
        }
    }

    /// Scan Bottle / Scan Pill now live behind the center scan button.
    /// Only the test-only reset is left here.
    @ViewBuilder private var quickActions: some View {
        #if DEBUG
        Button("Reset today's doses", action: resetTodaysDoses)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
        #endif
    }

    // MARK: Logging

    /// Take Now or tapping a dose: check the bottle in AR first, then log from there.
    private func attemptLog(_ dose: ScheduledDose) {
        bottleCheckFor = dose.prescription
    }

    /// Logs without the camera check (kept for reference / other entry points).
    private func logWithoutCheck(_ dose: ScheduledDose) {
        let check = dose.prescription.checkDose()
        if check != .ok {
            activeWarning = DoseWarning(prescription: dose.prescription, check: check)
        } else {
            dose.prescription.logDose(in: modelContext)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    /// Tapping a green check: removes the most recent dose logged today for that medication.
    private func undoDose(_ dose: ScheduledDose) {
        let calendar = Calendar.current
        guard let latest = dose.prescription.doses
            .filter({ calendar.isDateInToday($0.takenAt) })
            .max(by: { $0.takenAt < $1.takenAt }) else { return }
        modelContext.delete(latest)
        try? modelContext.save()
    }

    #if DEBUG
    private func resetTodaysDoses() {
        let startOfDay = Calendar.current.startOfDay(for: .now)
        let descriptor = FetchDescriptor<DoseLog>(predicate: #Predicate { $0.takenAt >= startOfDay })
        if let logs = try? modelContext.fetch(descriptor) {
            for log in logs { modelContext.delete(log) }
            try? modelContext.save()
        }
    }
    #endif
}

// MARK: - Next dose card

struct NextDoseCard: View {
    let dose: ScheduledDose
    var onTake: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(dose.isOverdue ? "Overdue" : "Next dose")
                        .font(.footnote.weight(.medium))
                        .textCase(.uppercase)
                        .tracking(0.8)
                        .foregroundStyle(dose.isOverdue ? Color.orange : Color.secondary)
                    Text(dose.time.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(Color.ink)
                    Text(dose.prescription.displayName)
                        .foregroundStyle(Color.ink)
                    Text(dose.prescription.doseSummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                PillBadge()
            }

            Button(action: onTake) {
                Text("Take Now")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Capsule().fill(Color.ink))
                    .foregroundStyle(.white)
            }
        }
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 24).fill(Color.doseCream))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.doseBorder, lineWidth: 1))
    }
}

struct PillBadge: View {
    var body: some View {
        ZStack {
            Circle().fill(Color.doseAmber.opacity(0.15))
            Circle().stroke(Color.doseAmber.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [2, 5]))
            Circle().fill(Color.doseAmber).padding(16)
            Image(systemName: "pill.fill")
                .font(.system(size: 26))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(-45))
        }
        .frame(width: 100, height: 100)
        .accessibilityHidden(true)
    }
}

// MARK: - Dose row

struct DoseRow: View {
    let dose: ScheduledDose
    let isNext: Bool
    var onTap: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Button(action: onTap) { statusIcon }
                .buttonStyle(.plain)
                .accessibilityLabel(dose.isTaken ? "Taken. Tap to undo" : "Log dose")

            VStack(alignment: .leading, spacing: 3) {
                Text(dose.prescription.displayName)
                    .foregroundStyle(Color.ink)
                Text(dose.prescription.doseSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(dose.time.formatted(date: .omitted, time: .shortened))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder private var statusIcon: some View {
        if dose.isTaken {
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.takenGreen))
        } else if isNext {
            Circle()
                .fill(Color.doseAmber)
                .frame(width: 34, height: 34)
                .overlay(Circle().fill(.white.opacity(0.85)).frame(width: 12, height: 12))
        } else {
            Circle()
                .stroke(Color.secondary.opacity(0.35), lineWidth: 1.5)
                .frame(width: 34, height: 34)
        }
    }
}

// MARK: - Quick action card

struct ActionCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 20))
                    .foregroundStyle(Color.ink)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(.white))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).foregroundStyle(Color.ink)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 22).fill(Color.cardGray))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Today's schedule

struct ScheduledDose: Identifiable {
    let prescription: Prescription
    let time: Date
    let isTaken: Bool

    var id: String { "\(prescription.key)-\(time.timeIntervalSince1970)" }
    var isOverdue: Bool { !isTaken && time < .now }

    /// Lays out today's doses. Doses logged today fill the earliest slots first,
    /// so logging a dose checks off the next unchecked slot.
    static func today(for prescriptions: [Prescription], now: Date = .now) -> [ScheduledDose] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: now)

        return prescriptions.flatMap { prescription -> [ScheduledDose] in
            let times = prescription.scheduledHours
                .map { startOfDay.addingTimeInterval($0 * 3600) }
                .sorted()
            let takenToday = prescription.doses.filter { calendar.isDate($0.takenAt, inSameDayAs: now) }.count
            return times.enumerated().map { index, time in
                ScheduledDose(prescription: prescription, time: time, isTaken: index < takenToday)
            }
        }
        .sorted { $0.time < $1.time }
    }
}

// MARK: - Display helpers

extension Prescription {
    var displayName: String { drugName.capitalized }

    /// "500 mg · 1 tablet"
    var doseSummary: String {
        [DoseFormat.strength(from: dosage), perDose].compactMap { $0 }.joined(separator: " · ")
    }

    var perDose: String? { DoseFormat.perDose(from: instructions) }

    var scheduledHours: [Double] {
        DoseFormat.hours(timesOfDay: timesOfDay, maxDosesPerDay: maxDosesPerDay, asNeeded: asNeeded)
    }
}
