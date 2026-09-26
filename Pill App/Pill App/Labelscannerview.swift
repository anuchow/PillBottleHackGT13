//
//  LabelScannerView.swift
//  Face ID–style scan screen: circular window, tick ring that fills as fields
//  are found, arrow hints, and a drawn checkmark when the scan is done.
//

import SwiftUI
import SwiftData
import AVFoundation

struct LabelScannerView: View {
    @StateObject private var scanner = LabelScannerModel()
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var showReview = false

    var onSaved: (Prescription) -> Void = { _ in }

    var body: some View {
        GeometryReader { geo in
            let diameter = min(geo.size.width * 0.68, geo.size.height * 0.32)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height * 0.27)
            let done = scanner.result != nil

            ZStack {
                CameraPreview(session: scanner.session)

                // Dim everything outside the circle.
                Rectangle()
                    .fill(.black.opacity(0.7))
                    .overlay(
                        Circle()
                            .frame(width: diameter, height: diameter)
                            .position(center)
                            .blendMode(.destinationOut)
                    )
                    .compositingGroup()

                if done {
                    CompletionCheck()
                        .frame(width: diameter + 36, height: diameter + 36)
                        .position(center)
                        .transition(.opacity)
                } else {
                    TickRing(progress: scanner.progress)
                        .frame(width: diameter + 44, height: diameter + 44)
                        .position(center)

                    HintArrow(hint: scanner.hint)
                        .position(x: center.x + scanner.hint.direction.width * (diameter / 2 - 44),
                                  y: center.y + scanner.hint.direction.height * (diameter / 2 - 44))
                }

                // Hint, checklist, Done
                VStack(spacing: 16) {
                    Color.clear.frame(height: center.y + diameter / 2 + 16)

                    Text(done ? "Label scanned" : scanner.hint.message)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .animation(.easeInOut, value: scanner.hint)

                    if !done {
                        ScanChecklist(fields: LabelAccumulator.required, found: scanner.confirmed)
                        skipControls
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, geo.safeAreaInsets.bottom + 12)
            }
            .animation(.easeInOut(duration: 0.3), value: done)
        }
        .ignoresSafeArea()
        // Outside the full-screen layer so it respects the safe area and sits
        // below the Dynamic Island. The results page (overlay below) covers it.
        .overlay(alignment: .topLeading) {
            closeButton
                .padding(.leading, 20)
                .padding(.top, 8)
        }
        .onAppear { scanner.start() }
        .onDisappear { scanner.stop() }
        .onChange(of: scanner.result != nil) { _, done in
            guard done else { return }
            // Let the checkmark play, then slide in the results.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                withAnimation(.easeInOut(duration: 0.35)) { showReview = true }
            }
        }
        .overlay {
            if showReview, let label = scanner.result {
                ScanResultView(label: label,
                               onAdd: { save(label) },
                               onScanAnother: {
                                   withAnimation(.easeInOut(duration: 0.3)) { showReview = false }
                                   scanner.reset()
                               })
                .transition(.move(edge: .bottom))
            }
        }
    }

    // MARK: Pieces

    private var closeButton: some View {
        Button {
            scanner.stop()
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(.white.opacity(0.18)))
                .contentShape(Circle())
        }
        .accessibilityLabel("Close scanner")
    }

    /// Done lets the user stop early when the label is missing info.
    /// It only unlocks once the drug name and Rx number are confirmed.
    private var skipControls: some View {
        VStack(spacing: 8) {
            Button { scanner.finishEarly() } label: {
                Text("Done")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Capsule().fill(Color.white.opacity(scanner.canFinishEarly ? 1 : 0.2)))
                    .foregroundStyle(scanner.canFinishEarly ? Color.ink : Color.white.opacity(0.5))
            }
            .disabled(!scanner.canFinishEarly)

            Text(scanner.canFinishEarly
                 ? "Can't find the rest on the label? Tap Done to skip it. Anything missing stays blank."
                 : "Done unlocks once the drug name and Rx number are found.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
        }
    }

    private func save(_ label: ScannedLabel) {
        do {
            let prescription = try Prescription.upsert(label, in: modelContext)
            onSaved(prescription)
            dismiss()
        } catch {
            print("Save failed: \(error)")   // TODO: show an error to the user
        }
    }
}

// MARK: - "Looking for" checklist

struct ScanChecklist: View {
    let fields: [LabelField]
    let found: Set<LabelField>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Looking for:")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.ink)

            ForEach(fields, id: \.self) { field in
                let isFound = found.contains(field)
                HStack(spacing: 12) {
                    Image(systemName: isFound ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isFound ? Color.takenGreen : Color.secondary)
                        .contentTransition(.symbolEffect(.replace))
                    Text(field.title)
                        .foregroundStyle(isFound ? Color.secondary : Color.ink)
                    Spacer()
                    if !isFound && LabelAccumulator.mandatory.contains(field) {
                        Text("Required")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                }
                .font(.subheadline)
                .accessibilityElement(children: .combine)
                .accessibilityValue(isFound ? "Found" : "Missing")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22).fill(.white.opacity(0.95)))
        .animation(.easeOut(duration: 0.2), value: found)
    }
}

// MARK: - Tick ring (Face ID style)

struct TickRing: View {
    var progress: Double          // 0...1
    var tickCount = 72

    var body: some View {
        GeometryReader { geo in
            let radius = min(geo.size.width, geo.size.height) / 2
            ZStack {
                ForEach(0..<tickCount, id: \.self) { i in
                    let lit = Double(i) / Double(tickCount) < progress
                    Capsule()
                        .fill(lit ? Color.green : Color.white.opacity(0.35))
                        .frame(width: 3, height: lit ? 16 : 10)
                        .offset(y: -radius)
                        .rotationEffect(.degrees(Double(i) / Double(tickCount) * 360))
                        .animation(.easeOut(duration: 0.25).delay(Double(i % 12) * 0.01), value: lit)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

// MARK: - Completion checkmark

struct CompletionCheck: View {
    @State private var circleTrim: CGFloat = 0
    @State private var checkTrim: CGFloat = 0

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: circleTrim)
                .stroke(Color.green, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))

            CheckmarkShape()
                .trim(from: 0, to: checkTrim)
                .stroke(Color.green, style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
                .padding(70)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.45)) { circleTrim = 1 }
            withAnimation(.easeOut(duration: 0.3).delay(0.4)) { checkTrim = 1 }
        }
    }
}

struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.42, y: rect.maxY - rect.height * 0.22))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.16, y: rect.minY + rect.height * 0.24))
        return path
    }
}

// MARK: - Hint arrow

struct HintArrow: View {
    let hint: ScanHint
    @State private var nudge = false

    var body: some View {
        Image(systemName: hint.symbol)
            .font(.system(size: 44, weight: .bold))
            .foregroundStyle(.white)
            .shadow(radius: 4)
            .offset(x: nudge ? hint.direction.width * 12 : 0,
                    y: nudge ? hint.direction.height * 12 : 0)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: nudge)
            .onAppear { nudge = true }
            .id(hint)          // new hint -> fresh view -> animation restarts
            .transition(.opacity)
    }
}

// MARK: - Camera preview

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
