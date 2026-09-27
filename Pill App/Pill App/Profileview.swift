//
//  Profileview.swift
//  Pill App
//
//  Created by Prathithi Nellaiappan on 9/26/26.
//

import SwiftUI
import SwiftData

// MARK: - Adherence math
//
// A "scheduled" medication is any Prescription where asNeeded == false.
// It's expected scheduledHours.count doses per day (minimum 1), the same count
// Home uses, so "twice daily" means 2 even when the label had no dose-time grid.
// A medication starts counting on the day of its first logged dose
// (swap startDay(for:) to use an `addedAt` field if you add one).
// A day is "complete" when every scheduled med active that day got all its doses.
// As-needed meds show up on the calendar but never break a streak.

enum DayStatus {
    case complete, partial, missed, empty, future
}

struct AdherenceCalculator {
    let prescriptions: [Prescription]
    private let cal = Calendar.current

    init(prescriptions: [Prescription]) {
        self.prescriptions = prescriptions
    }

    private var today: Date { cal.startOfDay(for: .now) }

    func expectedDoses(for p: Prescription) -> Int {
        max(p.scheduledHours.count, 1)
    }

    private func startDay(for p: Prescription) -> Date? {
        p.doses.map(\.takenAt).min().map { cal.startOfDay(for: $0) }
    }

    func takenCount(_ p: Prescription, on day: Date) -> Int {
        p.doses.filter { cal.isDate($0.takenAt, inSameDayAs: day) }.count
    }

    /// Scheduled meds that were being tracked on this day.
    func activeScheduled(on day: Date) -> [Prescription] {
        let d = cal.startOfDay(for: day)
        return prescriptions.filter { p in
            guard !p.asNeeded, let start = startDay(for: p) else { return false }
            return start <= d
        }
    }

    func status(on day: Date) -> DayStatus {
        let d = cal.startOfDay(for: day)
        if d > today { return .future }
        let active = activeScheduled(on: d)
        if active.isEmpty { return .empty }

        let completeCount = active.filter { takenCount($0, on: d) >= expectedDoses(for: $0) }.count
        if completeCount == active.count { return .complete }
        return active.contains { takenCount($0, on: d) > 0 } ? .partial : .missed
    }

    /// Every dose logged on a day, oldest first, with its medication.
    func doses(on day: Date) -> [(med: Prescription, log: DoseLog)] {
        prescriptions
            .flatMap { p in p.doses.map { (med: p, log: $0) } }
            .filter { cal.isDate($0.log.takenAt, inSameDayAs: day) }
            .sorted { $0.log.takenAt < $1.log.takenAt }
    }

    /// Consecutive complete days ending today. If today isn't finished yet,
    /// it counts back from yesterday so the streak doesn't "break" at 8 AM.
    var currentStreak: Int {
        var day = today
        if status(on: day) != .complete {
            day = cal.date(byAdding: .day, value: -1, to: day)!
        }
        var count = 0
        while status(on: day) == .complete {
            count += 1
            day = cal.date(byAdding: .day, value: -1, to: day)!
        }
        return count
    }

    var bestStreak: Int {
        guard let first = prescriptions.compactMap({ startDay(for: $0) }).min() else { return 0 }
        var best = 0, run = 0
        var day = first
        while day <= today {
            if status(on: day) == .complete {
                run += 1
                best = max(best, run)
            } else if day != today {   // an unfinished today shouldn't reset the run
                run = 0
            }
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        return best
    }

    /// Share of expected doses taken over the last `n` days.
    /// Today only counts once it's complete. Returns nil if nothing was expected.
    func adherence(lastDays n: Int) -> Double? {
        var expected = 0, taken = 0
        for offset in 0..<n {
            let day = cal.date(byAdding: .day, value: -offset, to: today)!
            if offset == 0 && status(on: day) != .complete { continue }
            for p in activeScheduled(on: day) {
                let e = expectedDoses(for: p)
                expected += e
                taken += min(takenCount(p, on: day), e)
            }
        }
        return expected == 0 ? nil : Double(taken) / Double(expected)
    }

    // Stable color per medication for calendar dots.
    private static let palette: [Color] = [
        .takenGreen, .doseAmber, .blue, .purple, .pink, .teal, .orange, .indigo
    ]

    func color(for p: Prescription) -> Color {
        let keys = prescriptions.map(\.key).sorted()
        let i = keys.firstIndex(of: p.key) ?? 0
        return Self.palette[i % Self.palette.count]
    }
}

// MARK: - Profile screen

struct ProfileView: View {
    @AppStorage("userName") private var userName = "Prathithi"
    @Query(sort: \Prescription.drugName) private var prescriptions: [Prescription]
    @Environment(\.modelContext) private var modelContext

    @State private var selectedDay = Calendar.current.startOfDay(for: .now)
    @State private var isEditingName = false
    @State private var draftName = ""

    var body: some View {
        let calc = AdherenceCalculator(prescriptions: prescriptions)

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                StreakCard(calc: calc)
                MedicationCalendarView(calc: calc, selectedDay: $selectedDay)
                DayDetailCard(calc: calc, day: selectedDay)

                #if DEBUG
                debugTools
                #endif
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 24)   // the tab bar reserves its own space
        }
        .background(Color.appBackground.ignoresSafeArea())
        .alert("Your name", isPresented: $isEditingName) {
            TextField("Name", text: $draftName)
            Button("Save") {
                let trimmed = draftName.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { userName = trimmed }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(Color.ink)
                Text(initials)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 64, height: 64)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(userName)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Color.ink)
                Text("\(prescriptions.count) medication\(prescriptions.count == 1 ? "" : "s") tracked")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                draftName = userName
                isEditingName = true
            } label: {
                Image(systemName: "pencil")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.ink)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.cardGray))
            }
            .accessibilityLabel("Edit name")
        }
    }

    private var initials: String {
        let parts = userName.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    #if DEBUG
    /// Fills the last 20 days with doses (leaving day 6 blank) so the
    /// streak and calendar have something to show in a demo.
    private var debugTools: some View {
        HStack {
            Button("Seed 20 days of doses") {
                let cal = Calendar.current
                for p in prescriptions where !p.asNeeded {
                    for offset in 1...20 where offset != 6 {
                        let day = cal.date(byAdding: .day, value: -offset, to: .now)!
                        for i in 0..<max(p.scheduledHours.count, 1) {
                            let t = cal.date(bySettingHour: 8 + i * 6, minute: 0, second: 0, of: day)!
                            let log = DoseLog(takenAt: t, overrodeWarning: false)
                            log.prescription = p
                            modelContext.insert(log)
                        }
                    }
                }
                try? modelContext.save()
            }
            Spacer()
            Button("Clear all doses", role: .destructive) {
                // Delete the logs themselves; removing them from `doses` would leave orphans behind.
                for p in prescriptions {
                    for log in p.doses { modelContext.delete(log) }
                }
                try? modelContext.save()
            }
        }
        .font(.footnote)
        .padding(.top, 8)
    }
    #endif
}

// MARK: - Streak card

private struct StreakCard: View {
    let calc: AdherenceCalculator

    var body: some View {
        let streak = calc.currentStreak
        let week = calc.adherence(lastDays: 7)

        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "flame.fill")
                    .font(.title2)
                    .foregroundStyle(streak > 0 ? Color.doseAmber : .secondary)
                Text("\(streak)")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(Color.ink)
                Text("day streak")
                    .font(.headline)
                    .foregroundStyle(Color.ink)
                Spacer()
            }
            .accessibilityElement(children: .combine)

            Text(streakMessage(streak))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            LastSevenDays(calc: calc)

            Divider()

            HStack {
                stat(title: "Best streak", value: "\(calc.bestStreak) day\(calc.bestStreak == 1 ? "" : "s")")
                Spacer()
                stat(title: "Doses taken, last 7 days",
                     value: week.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 24).fill(Color.doseCream))
    }

    private func streakMessage(_ s: Int) -> String {
        switch s {
        case 0: "Take all of today's doses to start a streak."
        case 1: "One full day on track. Keep it going tomorrow."
        default: "You've taken every scheduled dose for \(s) days in a row."
        }
    }

    private func stat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.headline).foregroundStyle(Color.ink)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct LastSevenDays: View {
    let calc: AdherenceCalculator
    private let cal = Calendar.current

    var body: some View {
        let days = (0..<7).reversed().map {
            cal.date(byAdding: .day, value: -$0, to: cal.startOfDay(for: .now))!
        }
        HStack {
            ForEach(days, id: \.self) { day in
                VStack(spacing: 6) {
                    Text(day.formatted(.dateTime.weekday(.narrow)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    StatusDot(status: calc.status(on: day), size: 28)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct StatusDot: View {
    let status: DayStatus
    let size: CGFloat

    var body: some View {
        ZStack {
            switch status {
            case .complete:
                Circle().fill(Color.takenGreen)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.4, weight: .bold))
                    .foregroundStyle(.white)
            case .partial:
                Circle().fill(Color.doseAmber.opacity(0.35))
                Circle().stroke(Color.doseAmber, lineWidth: 2)
            case .missed:
                Circle().fill(Color.warningRed.opacity(0.15))
            case .empty, .future:
                Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Calendar

struct MedicationCalendarView: View {
    let calc: AdherenceCalculator
    @Binding var selectedDay: Date
    @State private var month = Calendar.current.startOfDay(for: .now)

    private let cal = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(month.formatted(.dateTime.month(.wide).year()))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.ink)
                Spacer()
                monthButton("chevron.left", by: -1, label: "Previous month")
                monthButton("chevron.right", by: 1, label: "Next month")
                    .disabled(cal.isDate(month, equalTo: .now, toGranularity: .month))
            }

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, s in
                    Text(s).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(daysInMonth.enumerated()), id: \.offset) { _, day in
                    if let day {
                        DayCell(
                            day: day,
                            status: calc.status(on: day),
                            dotColors: dotColors(for: day),
                            isSelected: cal.isDate(day, inSameDayAs: selectedDay),
                            isToday: cal.isDateInToday(day)
                        )
                        .onTapGesture {
                            if day <= .now { selectedDay = day }
                        }
                    } else {
                        Color.clear.frame(height: 48)
                    }
                }
            }

            legend
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 24).fill(.white))
    }

    private func monthButton(_ symbol: String, by value: Int, label: String) -> some View {
        Button {
            withAnimation(.snappy) {
                month = cal.date(byAdding: .month, value: value, to: month)!
            }
        } label: {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.ink)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.cardGray))
        }
        .accessibilityLabel(label)
    }

    private var weekdaySymbols: [String] {
        let s = cal.veryShortWeekdaySymbols
        let shift = cal.firstWeekday - 1
        return Array(s[shift...] + s[..<shift])
    }

    private var daysInMonth: [Date?] {
        guard let interval = cal.dateInterval(of: .month, for: month),
              let range = cal.range(of: .day, in: .month, for: month) else { return [] }
        let first = interval.start
        let lead = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        let days = range.map { cal.date(byAdding: .day, value: $0 - 1, to: first)! }
        return Array(repeating: nil, count: lead) + days
    }

    /// One dot per distinct medication taken that day (max 4).
    private func dotColors(for day: Date) -> [Color] {
        var seen = Set<String>()
        return calc.doses(on: day)
            .filter { seen.insert($0.med.key).inserted }
            .prefix(4)
            .map { calc.color(for: $0.med) }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(.complete, "All taken")
            legendItem(.partial, "Some")
            legendItem(.missed, "Missed")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func legendItem(_ s: DayStatus, _ label: String) -> some View {
        HStack(spacing: 6) {
            StatusDot(status: s, size: 12)
            Text(label)
        }
    }
}

private struct DayCell: View {
    let day: Date
    let status: DayStatus
    let dotColors: [Color]
    let isSelected: Bool
    let isToday: Bool

    var body: some View {
        VStack(spacing: 3) {
            Text("\(Calendar.current.component(.day, from: day))")
                .font(.subheadline.weight(isToday ? .bold : .regular))
                .foregroundStyle(textColor)
                .frame(width: 32, height: 32)
                .background(Circle().fill(fill))
                .overlay(Circle().stroke(Color.ink, lineWidth: isSelected ? 2 : 0))

            HStack(spacing: 2) {
                ForEach(Array(dotColors.enumerated()), id: \.offset) { _, c in
                    Circle().fill(c).frame(width: 5, height: 5)
                }
            }
            .frame(height: 5)
        }
        .frame(height: 48)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted) + ", " + statusText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var fill: Color {
        switch status {
        case .complete: .takenGreen
        case .partial: .doseAmber.opacity(0.35)
        case .missed: .warningRed.opacity(0.15)
        case .empty, .future: .clear
        }
    }

    private var textColor: Color {
        switch status {
        case .complete: .white
        case .future: .secondary.opacity(0.5)
        default: .ink
        }
    }

    private var statusText: String {
        switch status {
        case .complete: "all doses taken"
        case .partial: "some doses taken"
        case .missed: "doses missed"
        case .empty: "nothing scheduled"
        case .future: "upcoming"
        }
    }
}

// MARK: - Selected day detail

private struct DayDetailCard: View {
    let calc: AdherenceCalculator
    let day: Date

    var body: some View {
        let taken = calc.doses(on: day)
        let missing = calc.activeScheduled(on: day).filter {
            calc.takenCount($0, on: day) < calc.expectedDoses(for: $0)
        }

        VStack(alignment: .leading, spacing: 14) {
            Text(Calendar.current.isDateInToday(day)
                 ? "Today"
                 : day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.ink)

            if taken.isEmpty && missing.isEmpty {
                Text("No doses logged this day.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(taken.enumerated()), id: \.offset) { _, entry in
                HStack(spacing: 12) {
                    Circle().fill(calc.color(for: entry.med)).frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.med.displayName)
                            .font(.body.weight(.medium))
                            .foregroundStyle(Color.ink)
                        if entry.log.overrodeWarning {
                            Text("Logged despite a dose warning")
                                .font(.caption)
                                .foregroundStyle(Color.warningRed)
                        }
                    }
                    Spacer()
                    Text(entry.log.takenAt.formatted(date: .omitted, time: .shortened))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }

            // Don't call today's not-yet-taken doses "missed".
            if !Calendar.current.isDateInToday(day) {
                ForEach(missing, id: \.key) { p in
                    HStack(spacing: 12) {
                        Circle().stroke(Color.warningRed, lineWidth: 1.5).frame(width: 10, height: 10)
                        Text(p.displayName).foregroundStyle(.secondary)
                        Spacer()
                        Text("Missed \(calc.expectedDoses(for: p) - calc.takenCount(p, on: day))")
                            .font(.subheadline)
                            .foregroundStyle(Color.warningRed)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 24).fill(.white))
    }
}

#Preview {
    ProfileView()
        .modelContainer(for: [Prescription.self, DoseLog.self], inMemory: true)
}
