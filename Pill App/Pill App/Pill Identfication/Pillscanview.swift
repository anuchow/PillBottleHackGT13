//
//  PillScanView.swift
//  "Scan Pill" screen: camera in a circle, dotted ring, and the Analyzing checklist.
//  Shows PillResultView when the scan finishes.
//

import SwiftUI
import SwiftData

struct PillScanView: View {
    @StateObject private var scanner = PillScannerModel()
    @Query private var prescriptions: [Prescription]
    @Environment(\.dismiss) private var dismiss

    @State private var isLoading = true
    @State private var profiles: [LoggedPillProfile] = []

    private var hasReferenceData: Bool { profiles.contains { !$0.appearances.isEmpty } }

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            if let outcome = scanner.outcome {
                PillResultView(outcome: outcome,
                               onScanAgain: { scanner.reset() },
                               onClose: { dismiss() })
                    .transition(.move(edge: .bottom))
            } else {
                scanScreen
            }
        }
        .animation(.easeInOut(duration: 0.35), value: scanner.outcome != nil)
        .task { await prepare() }
        .onDisappear { scanner.stop() }
    }

    private func prepare() async {
        await PillboxIndex.shared.preload()
        profiles = PillboxIndex.shared.profiles(for: prescriptions)
        isLoading = false
        if hasReferenceData { scanner.start(profiles: profiles) }
    }

    // MARK: Scan screen

    private var scanScreen: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Close")

                Spacer()

                Button { scanner.toggleTorch() } label: {
                    Image(systemName: scanner.torchOn ? "bolt.fill" : "bolt")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(scanner.torchOn ? "Turn flashlight off" : "Turn flashlight on")
            }
            .foregroundStyle(Color.ink)
            .padding(.horizontal, 12)

            Text("Scan Pill")
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.ink)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.top, 4)
                .animation(.easeInOut, value: scanner.hint)

            Spacer(minLength: 16)

            if isLoading {
                ProgressView("Loading pill database")
                    .frame(width: 300, height: 300)
            } else if !hasReferenceData {
                emptyState
            } else {
                cameraCircle
            }

            Spacer(minLength: 16)

            if !isLoading && hasReferenceData {
                analyzingCard
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
        }
    }

    private var subtitle: String {
        if isLoading || !hasReferenceData { return "Point the camera at the pill" }
        return scanner.hint
    }

    private var cameraCircle: some View {
        ZStack {
            PillScanRing()
                .frame(width: 300, height: 300)
            CameraPreview(session: scanner.session)
                .frame(width: 250, height: 250)
                .clipShape(Circle())
                .accessibilityLabel("Camera view")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "pills")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(prescriptions.isEmpty ? "Add a medication first" : "No pill descriptions found")
                .font(.headline)
                .foregroundStyle(Color.ink)
            Text(prescriptions.isEmpty
                 ? "Pill scanning compares the pill with the medications you've logged. Scan a bottle to add one."
                 : "The pill database doesn't have descriptions for your medications, so there's nothing to compare against yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
        .frame(height: 300)
    }

    private var analyzingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Analyzing:")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.ink)
            analyzingRow("Shape", scanner.shape?.capitalized)
            analyzingRow("Color", scanner.colors.isEmpty ? nil : scanner.colors.map(\.capitalized).joined(separator: " & "))
            analyzingRow("Imprint", scanner.imprint)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22).fill(Color.appBackground))
    }

    private func analyzingRow(_ title: String, _ value: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: value != nil ? "checkmark" : "circle.dotted")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(value != nil ? Color.takenGreen : Color.secondary)
                .frame(width: 20)
                .contentTransition(.symbolEffect(.replace))
            Text(title)
                .foregroundStyle(Color.ink)
            Spacer()
            Text(value ?? "")
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
        .accessibilityValue(value ?? "Not found yet")
    }
}

/// Dotted ring around the camera circle. Turns slowly unless Reduce Motion is on.
struct PillScanRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.ink.opacity(0.15), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [0.1, 9]))
            Circle()
                .stroke(Color.ink.opacity(0.35), style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [0.1, 10]))
                .padding(12)
                .rotationEffect(.degrees(spin ? 360 : 0))
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 30).repeatForever(autoreverses: false)) { spin = true }
        }
        .accessibilityHidden(true)
    }
}
