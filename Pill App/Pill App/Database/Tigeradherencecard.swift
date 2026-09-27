//
//  TigerAdherenceCard.swift
//  Profile card showing the last 7 days of doses, read back from Tiger Data
//  (the daily_doses continuous aggregate) through the Vultr API.
//

import SwiftUI
import Charts

struct TigerAdherenceCard: View {
    /// Changes whenever a dose is logged or undone, so the card reloads.
    var refreshKey: Int

    @State private var summary: CloudAdherence?
    @State private var state = LoadState.loading

    private enum LoadState { case loading, loaded, unavailable, off }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Last 7 days")
                    .font(.headline)
                    .foregroundStyle(Color.ink)
                Spacer()
                Label("Tiger Data", systemImage: "icloud")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            switch state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 80)

            case .off:
                Text("Cloud sync isn't set up yet, so this history is only on your phone.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

            case .unavailable:
                Text("Couldn't reach the cloud right now. Your doses are saved on this phone and will sync.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

            case .loaded:
                if let summary, summary.expected > 0 {
                    loaded(summary)
                } else {
                    Text("Your dose history will show up here once you log a few doses.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 24).fill(.white))
        .task(id: refreshKey) { await load() }
    }

    @ViewBuilder
    private func loaded(_ summary: CloudAdherence) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(summary.taken) of \(summary.expected) doses taken")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.ink)
            if summary.overrides > 0 {
                Text("\(summary.overrides) logged after a too-soon warning")
                    .font(.caption)
                    .foregroundStyle(Color.warningRed)
            }
        }

        Chart(summary.days) { day in
            BarMark(x: .value("Day", day.date, unit: .day),
                    y: .value("Doses", day.taken))
                .foregroundStyle(Color.takenGreen)
            BarMark(x: .value("Day", day.date, unit: .day),
                    y: .value("Doses", day.missed))
                .foregroundStyle(Color.cardGray)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.narrow))
            }
        }
        .chartYAxis(.hidden)
        .frame(height: 110)
        .accessibilityElement()
        .accessibilityLabel("Last 7 days: \(summary.taken) of \(summary.expected) doses taken")

        HStack(spacing: 14) {
            legend(Color.takenGreen, "Taken")
            legend(Color.cardGray, "Missed")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(label)
        }
    }

    private func load() async {
        guard CloudSync.shared.isEnabled else {
            state = .off
            return
        }
        if summary == nil { state = .loading }
        if let result = await CloudSync.shared.fetchAdherence(days: 7) {
            summary = result
            state = .loaded
        } else if summary == nil {
            state = .unavailable
        }
    }
}
