//
//  RootView.swift
//  App shell: custom tab bar with the black scan button in the middle.
//
//  In your App file:
//      WindowGroup { RootView() }
//          .modelContainer(for: [Prescription.self, DoseLog.self])
//

import SwiftUI
import SwiftData

enum AppTab: Hashable {
    case home, meds, scan, chat, profile
}

struct RootView: View {
    @State private var tab: AppTab = .home

    var body: some View {
        ZStack {
            switch tab {
            case .home:    HomeView(selectedTab: $tab)
            case .meds:    MedsView()
            case .scan:    ScanChooserView(selectedTab: $tab)
            case .chat:    PlaceholderView(title: "Chat", symbol: "message")
            case .profile: PlaceholderView(title: "Profile", symbol: "person")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AppTabBar(selection: $tab)
        }
        .preferredColorScheme(.light)   // mockups are light-only for now
    }
}

// MARK: - Tab bar

struct AppTabBar: View {
    @Binding var selection: AppTab

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            item(.home, "Home", "house.fill")
            item(.meds, "Meds", "pill")
            scanButton
            item(.chat, "Chat", "message.fill")
            item(.profile, "Profile", "person.fill")
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .background(
            Color.white
                .shadow(color: .black.opacity(0.06), radius: 12, y: -2)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func item(_ tab: AppTab, _ title: String, _ symbol: String) -> some View {
        Button { selection = tab } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .medium))
                    .frame(height: 24)
                Text(title)
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(selection == tab ? Color.ink : Color.secondary.opacity(0.6))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == tab ? .isSelected : [])
    }

    private var scanButton: some View {
        Button { selection = .scan } label: {
            ZStack {
                Circle()
                    .fill(Color.ink)
                    .frame(width: 64, height: 64)
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                Image(systemName: selection == .scan ? "viewfinder" : "circle.dashed")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .offset(y: -18)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Scan medication")
    }
}

// MARK: - Meds tab

struct MedsView: View {
    @Query(sort: \Prescription.drugName) private var prescriptions: [Prescription]
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationStack {
            List {
                ForEach(prescriptions) { prescription in
                    NavigationLink {
                        MedicationDetailView(prescription: prescription)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(prescription.displayName)
                            Text(prescription.doseSummary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets { modelContext.delete(prescriptions[index]) }
                }
            }
            .overlay {
                if prescriptions.isEmpty {
                    ContentUnavailableView("No medications",
                                           systemImage: "pill",
                                           description: Text("Scan a bottle to add one."))
                }
            }
            .navigationTitle("Meds")
        }
    }
}

// MARK: - Placeholder tabs

struct PlaceholderView: View {
    let title: String
    let symbol: String

    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text("Coming soon."))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.appBackground.ignoresSafeArea())
    }
}
