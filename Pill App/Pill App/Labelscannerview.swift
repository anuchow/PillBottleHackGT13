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
    @State private var showReview = false

    var onSaved: (Prescription) -> Void = { _ in }

    var body: some View {
        GeometryReader { geo in
            let diameter = min(geo.size.width, geo.size.height) * 0.78

            ZStack {
                CameraPreview(session: scanner.session)
                    .ignoresSafeArea()

                // Dim everything outside the circle.
                Rectangle()
                    .fill(.black.opacity(0.65))
                    .overlay(
                        Circle()
                            .frame(width: diameter, height: diameter)
                            .blendMode(.destinationOut)
                    )
                    .compositingGroup()
                    .ignoresSafeArea()

                if scanner.result != nil {
                    CompletionCheck()
                        .frame(width: diameter + 36, height: diameter + 36)
                        .transition(.opacity)
                } else {
                    TickRing(progress: scanner.progress)
                        .frame(width: diameter + 44, height: diameter + 44)

                    HintArrow(hint: scanner.hint)
                        .offset(x: scanner.hint.direction.width * (diameter / 2 - 44),
                                y: scanner.hint.direction.height * (diameter / 2 - 44))
                }

                VStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Text(scanner.result == nil ? scanner.hint.message : "Label scanned")
                            .font(.title3.weight(.semibold))
                        if scanner.result == nil, !scanner.missing.isEmpty {
                            Text("Still looking for " + scanner.missing.map(\.displayName).joined(separator: ", "))
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        if scanner.result == nil, scanner.canFinishEarly {
                            Button("Done") { scanner.finishEarly() }
                                .buttonStyle(.borderedProminent)
                                .tint(.green)
                                .padding(.top, 10)
                        }
                    }
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 48)
                    .animation(.easeInOut, value: scanner.hint)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: scanner.result != nil)
        }
        .onAppear { scanner.start() }
        .onDisappear { scanner.stop() }
        .onChange(of: scanner.result != nil) { _, done in
            guard done else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { showReview = true }
        }
        .sheet(isPresented: $showReview) {
            if let label = scanner.result {
                LabelReviewView(label: label,
                                onSave: { save(label) },
                                onRescan: { showReview = false; scanner.reset() })
            }
        }
    }

    private func save(_ label: ScannedLabel) {
        do {
            let prescription = try Prescription.upsert(label, in: modelContext)
            showReview = false
            onSaved(prescription)
        } catch {
            print("Save failed: \(error)")   // TODO: show an error to the user
        }
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

// MARK: - Review before saving

struct LabelReviewView: View {
    let label: ScannedLabel
    var onSave: () -> Void
    var onRescan: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Medication") {
                    row("Drug", label.drugName.capitalized)
                    row("Strength", label.dosage)
                    row("Quantity", label.quantity.map(String.init))
                    row("Expires", label.expirationDate?.formatted(date: .abbreviated, time: .omitted))
                }
                Section("Directions") {
                    row("Instructions", label.instructions?.capitalized)
                    row("With food", label.takeWithFood.map { $0 ? "Yes" : "No" })
                    row("When", label.timesOfDay.isEmpty ? nil : ListFormatter.localizedString(byJoining: label.timesOfDay))
                }
                Section("Pharmacy") {
                    row("Pharmacy", label.pharmacyName)
                    row("Address", label.pharmacyAddress?.capitalized)
                    row("Prescriber", label.prescriber?.capitalized)
                }
                if !label.sideEffects.isEmpty {
                    Section("Warnings") {
                        ForEach(label.sideEffects, id: \.self) { Text($0.capitalized) }
                    }
                }
            }
            // TODO: make these rows editable so users can fix OCR mistakes before saving.
            .navigationTitle("Check the details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Scan again", action: onRescan) }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: onSave) }
            }
        }
    }

    private func row(_ title: String, _ value: String?) -> some View {
        LabeledContent(title, value: value ?? "Not found")
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
