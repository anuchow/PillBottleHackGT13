//
//  ScanChooserView.swift
//  "Scan Medication" screen from the middle tab button.
//

import SwiftUI

struct ScanChooserView: View {
    @Binding var selectedTab: AppTab
    @State private var showBottleScanner = false
    @State private var showPillScanner = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Scan Medication")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(Color.ink)
            Text("What are you scanning?")
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            HStack(spacing: 16) {
                ScanTypeCard(title: "Scan Pill", subtitle: "Identify & match", symbol: "pill") {
                    showPillScanner = true
                }
                ScanTypeCard(title: "Scan Bottle", subtitle: "Read label & log", symbol: "cross.vial") {
                    showBottleScanner = true
                }
            }
            .padding(.top, 32)

            Spacer()
            ScanOrb().frame(maxWidth: .infinity)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.appBackground.ignoresSafeArea())
        .fullScreenCover(isPresented: $showBottleScanner) {
            LabelScannerView { _ in selectedTab = .home }
        }
        .fullScreenCover(isPresented: $showPillScanner) {
            PillScanView()
        }
    }
}

struct ScanTypeCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 16) {
                Image(systemName: symbol)
                    .font(.system(size: 34))
                    .foregroundStyle(Color.blue)
                    .frame(width: 96, height: 96)
                    .background(Circle().fill(Color.blue.opacity(0.08)))
                VStack(spacing: 4) {
                    Text(title).font(.headline).foregroundStyle(Color.ink)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(.white)
                    .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Decorative dotted-ring circle from the mockup. Slowly turns unless Reduce Motion is on.
struct ScanOrb: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.ink.opacity(0.15), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [0.1, 9]))
                .frame(width: 300, height: 300)
            Circle()
                .stroke(Color.ink.opacity(0.35), style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [0.1, 10]))
                .frame(width: 262, height: 262)
                .rotationEffect(.degrees(spin ? 360 : 0))
            Circle()
                .fill(Color(white: 0.66))
                .frame(width: 222, height: 222)
            Image(systemName: "barcode.viewfinder")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.white)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 40).repeatForever(autoreverses: false)) { spin = true }
        }
        .accessibilityHidden(true)
    }
}

struct PillScanComingSoonView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ContentUnavailableView("Pill scanning is coming soon",
                                   systemImage: "pill",
                                   description: Text("For now, scan the bottle's label to add a medication."))
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Close") { dismiss() }
                    }
                }
        }
    }
}
