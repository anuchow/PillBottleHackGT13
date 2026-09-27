//
//  ARDoseCheckView.swift
//  Opens from Take Now: point the camera at a bottle, see a green card over the
//  right one and red cards over the wrong ones, then Log Medication.
//

import SwiftUI
import SwiftData
import RealityKit

struct ARDoseCheckView: View {
    let prescription: Prescription

    @StateObject private var model: ARDoseCheckModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var warning: DoseWarning?
    @State private var showBigCheck = false

    init(target: Prescription, all prescriptions: [Prescription]) {
        self.prescription = target
        _model = StateObject(wrappedValue: ARDoseCheckModel(target: target, all: prescriptions))
    }

    var body: some View {
        ZStack {
            ARViewContainer(arView: model.arView)
                .ignoresSafeArea()

            // Cards pinned over the bottles, with a line down to the spot on the label.
            ZStack {
                ForEach(model.tags) { tag in
                    Path { path in
                        path.move(to: CGPoint(x: tag.cardPoint.x, y: tag.cardPoint.y + 30))
                        path.addLine(to: tag.pinPoint)
                    }
                    .stroke(tag.isTarget ? Color.takenGreen : Color.warningRed, lineWidth: 3)

                    BottleTagCard(tag: tag)
                        .position(tag.cardPoint)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.15), value: model.tags.map(\.id))

            // Big check in the middle when the right bottle is confirmed.
            if showBigCheck {
                CompletionCheck()
                    .frame(width: 160, height: 160)
                    .background(Circle().fill(.black.opacity(0.35)))
                    .transition(.scale.combined(with: .opacity))
                    .allowsHitTesting(false)
                    .accessibilityLabel("Right bottle")
            }

            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomPanel
            }
        }
        .onChange(of: model.confirmations) { _, _ in
            withAnimation(.spring(duration: 0.3)) { showBigCheck = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.easeOut(duration: 0.3)) { showBigCheck = false }
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .fullScreenCover(item: $warning, onDismiss: { dismiss() }) { warning in
            DoseWarningView(warning: warning)
        }
    }

    // MARK: Top

    private var topBar: some View {
        HStack(alignment: .top) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.black.opacity(0.45)))
            }
            .accessibilityLabel("Close")

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("Taking now")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.8))
                Text([prescription.displayName, DoseFormat.strength(from: prescription.dosage)]
                        .compactMap { $0 }.joined(separator: " "))
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.45)))
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: Bottom

    private var bottomPanel: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: model.targetVisible ? "checkmark.circle.fill"
                      : model.wrongVisible ? "xmark.circle.fill" : "viewfinder")
                    .font(.title3)
                    .foregroundStyle(model.targetVisible ? Color.takenGreen
                                     : model.wrongVisible ? Color.warningRed : Color.ink)
                    .contentTransition(.symbolEffect(.replace))
                Text(model.hint)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.easeInOut, value: model.hint)
            }

            Button(action: logDose) {
                Text("Log Medication")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(RoundedRectangle(cornerRadius: 18)
                        .fill(model.canLog ? Color.ink : Color.secondary.opacity(0.35)))
                    .foregroundStyle(.white)
            }
            .disabled(!model.canLog)

            // Backup if the camera can't read the label (or AR isn't available).
            Button("Log without checking", action: logDose)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 28)
                .fill(.white)
                .shadow(color: .black.opacity(0.15), radius: 20, y: 4)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    /// Same dose-spacing check as everywhere else.
    private func logDose() {
        let check = prescription.checkDose()
        if check != .ok {
            warning = DoseWarning(prescription: prescription, check: check)
        } else {
            prescription.logDose(in: modelContext)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
        }
    }
}

// MARK: - Card over a bottle

private struct BottleTagCard: View {
    let tag: ARDoseCheckModel.Tag

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: tag.isTarget ? "checkmark" : "xmark")
                .font(.system(size: 16, weight: .heavy))
                .foregroundStyle(tag.isTarget ? Color.takenGreen : Color.warningRed)
                .frame(width: 30, height: 30)
                .background(Circle().fill(.white))
            VStack(alignment: .leading, spacing: 1) {
                Text(tag.title)
                    .font(.subheadline.weight(.bold))
                Text(tag.detail)
                    .font(.caption.weight(.medium))
                    .opacity(0.9)
            }
            .foregroundStyle(.white)
            .lineLimit(1)
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(tag.isTarget ? Color.takenGreen : Color.warningRed))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - ARView in SwiftUI

private struct ARViewContainer: UIViewRepresentable {
    let arView: ARView
    func makeUIView(context: Context) -> ARView { arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}
