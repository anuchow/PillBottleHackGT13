//
//  PillScannerModel.swift
//  Camera + per-frame pill analysis for the Scan Pill screen.
//

import AVFoundation
import UIKit
import Combine

final class PillScannerModel: NSObject, ObservableObject {

    @Published private(set) var shape: String?
    @Published private(set) var colors: [String] = []
    @Published private(set) var imprint: String?
    @Published private(set) var hint = "Point the camera at the pill"
    @Published private(set) var outcome: PillScanOutcome?
    @Published private(set) var torchOn = false

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "pill.scanner")
    private var device: AVCaptureDevice?

    // Only touched on `queue`.
    private var profiles: [LoggedPillProfile] = []
    private var accumulator = PillFeatureAccumulator()
    private var lastFrame = Date.distantPast
    private var firstSeen: Date?
    private var bestImage: CGImage?
    private var bestImageSize: CGFloat = 0
    private var missedFrames = 0
    private var finished = false

    // MARK: Lifecycle

    func start(profiles: [LoggedPillProfile]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.profiles = profiles
            if self.session.inputs.isEmpty { self.configure() }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.setTorch(false)
            self.session.stopRunning()
        }
    }

    func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            self.accumulator = PillFeatureAccumulator()
            self.firstSeen = nil
            self.bestImage = nil
            self.bestImageSize = 0
            self.missedFrames = 0
            self.finished = false
            DispatchQueue.main.async {
                self.outcome = nil
                self.shape = nil
                self.colors = []
                self.imprint = nil
                self.hint = "Point the camera at the pill"
            }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func toggleTorch() {
        queue.async { [weak self] in
            guard let self else { return }
            self.setTorch(self.device?.torchMode != .on)
        }
    }

    private func setTorch(_ on: Bool) {
        guard let device, device.hasTorch, (try? device.lockForConfiguration()) != nil else { return }
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
        DispatchQueue.main.async { self.torchOn = on }
    }

    private func configure() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .hd1920x1080

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else { return }
        session.addInput(input)
        device = camera

        if (try? camera.lockForConfiguration()) != nil {
            if camera.isAutoFocusRangeRestrictionSupported { camera.autoFocusRangeRestriction = .near }
            camera.unlockForConfiguration()
        }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
    }
}

// MARK: - Frames

extension PillScannerModel: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Each frame runs a mask + several OCR passes, so ~2 frames a second.
        guard !finished,
              Date().timeIntervalSince(lastFrame) > 0.5,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrame = Date()

        guard let frame = PillFeatureExtractor.extract(from: pixelBuffer) else {
            missedFrames += 1
            if missedFrames >= 3 { publishHint("Point the camera at the pill") }
            return
        }
        missedFrames = 0

        if frame.sizeInView < 0.12 {
            publishHint("Move closer to the pill")
            return
        }

        if firstSeen == nil { firstSeen = Date() }
        accumulator.add(frame)
        if frame.sizeInView > bestImageSize, let image = frame.image {
            bestImage = image
            bestImageSize = frame.sizeInView
        }

        let summary = accumulator.summary
        let elapsed = Date().timeIntervalSince(firstSeen ?? Date())
        let hasLook = summary.shape != nil && !summary.colors.isEmpty

        let hint: String
        if hasLook && summary.imprints.isEmpty && elapsed > 3 {
            hint = "Turn or flip the pill so the writing faces the camera"
        } else {
            hint = "Hold still"
        }

        // Done when shape, color and imprint are confirmed, or after ~9 seconds
        // with shape and color (some pills have no imprint, or it can't be read).
        let ready = hasLook && ((!summary.imprints.isEmpty && accumulator.frames >= 4) || elapsed > 9)

        var outcome: PillScanOutcome?
        if ready {
            finished = true
            outcome = PillScanOutcome(summary: summary,
                                      matches: PillMatcher.rank(summary, against: profiles),
                                      image: bestImage)
            queue.async { [weak self] in
                self?.setTorch(false)
                self?.session.stopRunning()
            }
        }

        DispatchQueue.main.async {
            self.shape = summary.shape
            self.colors = summary.colors
            self.imprint = summary.imprints.first
            self.hint = hint
            if let outcome {
                self.outcome = outcome
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }

    private func publishHint(_ text: String) {
        DispatchQueue.main.async { self.hint = text }
    }
}
