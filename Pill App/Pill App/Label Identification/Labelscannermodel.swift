//
//  LabelScannerModel.swift
//  Runs the camera, OCRs ~3 frames per second, and publishes progress + hints.
//
//  Add NSCameraUsageDescription to Info.plist.
//

import AVFoundation
import Vision
import UIKit
import Combine

final class LabelScannerModel: NSObject, ObservableObject {

    @Published private(set) var hint: ScanHint = .findLabel
    @Published private(set) var progress: Double = 0
    @Published private(set) var missing: [LabelField] = LabelAccumulator.pharmacyRequired
    @Published private(set) var requiredFields: [LabelField] = LabelAccumulator.pharmacyRequired
    @Published private(set) var mandatoryFields: Set<LabelField> = [.rxNumber, .drugName]
    @Published private(set) var isSupplement = false
    @Published private(set) var result: ScannedLabel?
    @Published private(set) var canFinishEarly = false
    @Published private(set) var confirmed: Set<LabelField> = []

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "pillbottle.scanner")

    // Everything below is only touched on `queue`.
    private var accumulator = LabelAccumulator()
    private var lastFrameTime = Date.distantPast
    private var recentHints: [ScanHint] = []
    private var rotationPreference: ScanHint = .rotateLeft
    private var finished = false
    private var frameCount = 0

    // MARK: Lifecycle

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.session.inputs.isEmpty { self.configure() }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        queue.async { [weak self] in self?.session.stopRunning() }
    }

    func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            self.accumulator = LabelAccumulator()
            self.recentHints = []
            self.finished = false
            DispatchQueue.main.async {
                self.result = nil
                self.canFinishEarly = false
                self.confirmed = []
                self.progress = 0
                self.hint = .findLabel
                self.missing = LabelAccumulator.pharmacyRequired
                self.requiredFields = LabelAccumulator.pharmacyRequired
                self.mandatoryFields = [.rxNumber, .drugName]
                self.isSupplement = false
            }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    /// "Done" button: stop scanning and use whatever has been found so far.
    func finishEarly() {
        queue.async { [weak self] in
            guard let self, !self.finished, self.accumulator.canFinishEarly,
                  let label = self.accumulator.makeScannedLabel(allowUnconfirmed: true) else { return }
            self.finished = true
            self.session.stopRunning()
            DispatchQueue.main.async {
                self.result = label
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }

    private func configure() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .hd1920x1080

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)

        // Labels are read up close.
        if (try? device.lockForConfiguration()) != nil {
            if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
            device.unlockForConfiguration()
        }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
    }
}

// MARK: - Frame processing

extension LabelScannerModel: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard !finished,
              Date().timeIntervalSince(lastFrameTime) > 0.35,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrameTime = Date()
        frameCount += 1

        // Supplement Lot/Exp is printed sideways. Every third frame, read the whole
        // frame turned 90° (alternating directions) and keep only the expiration date.
        if accumulator.kind == .supplement && frameCount % 3 == 0 {
            let sideways = VNRecognizeTextRequest()
            sideways.recognitionLevel = .accurate
            sideways.usesLanguageCorrection = false
            let orientation: CGImagePropertyOrientation = frameCount % 6 == 0 ? .up : .down
            try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
                .perform([sideways])
            let lines = (sideways.results ?? []).compactMap { obs in
                obs.topCandidates(1).first.map { TextLine(text: $0.string, box: obs.boundingBox) }
            }
            var parsed = LabelParser.parse(lines)
            parsed.fields = parsed.fields.filter { $0.key == .expiration }
            parsed.sideEffects = []
            parsed.kind = nil
            accumulator.ingest(parsed)
            return
        }

        // 1. OCR
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false        // drug names and Rx numbers aren't dictionary words
        request.regionOfInterest = ScanGuidance.regionOfInterest
        try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
            .perform([request])

        let observations = (request.results ?? []).sorted(by: ScanGuidance.readingOrder)
        let textLines = observations.compactMap { obs in
            obs.topCandidates(1).first.map { TextLine(text: $0.string, box: obs.boundingBox) }
        }
        // print(textLines.map(\.text))   // uncomment to see what the OCR reads

        // 2. Parse + vote
        let foundBefore = accumulator.foundCount
        accumulator.ingest(LabelParser.parse(textLines))
        let foundSomethingNew = accumulator.foundCount > foundBefore

        // 3. Guidance, debounced so the arrow doesn't flicker
        let rawHint = ScanGuidance.hint(for: observations.map(\.boundingBox),
                                        stillMissing: !accumulator.isComplete,
                                        rotationPreference: &rotationPreference)
        recentHints = Array((recentHints + [rawHint]).suffix(3))
        let stableHint: ScanHint? = (recentHints.count == 3 && Set(recentHints).count == 1) ? rawHint : nil

        // 4. Done?
        let label = accumulator.isComplete ? accumulator.makeScannedLabel() : nil
        if label != nil {
            finished = true
            queue.async { [weak self] in self?.session.stopRunning() }
        }

        let progress = accumulator.progress
        let missing = accumulator.missingRequired
        let canFinish = accumulator.canFinishEarly
        let confirmed = accumulator.confirmedFields
        let requiredFields = accumulator.required
        let mandatoryFields = accumulator.mandatory
        let isSupplement = accumulator.kind == .supplement

        DispatchQueue.main.async {
            self.progress = progress
            self.missing = missing
            self.canFinishEarly = canFinish
            self.confirmed = confirmed
            self.requiredFields = requiredFields
            self.mandatoryFields = mandatoryFields
            self.isSupplement = isSupplement
            if let stableHint { self.hint = stableHint }
            if foundSomethingNew { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            if let label {
                self.result = label
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }
}
