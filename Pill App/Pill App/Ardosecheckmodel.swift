//
//  ARDoseCheckModel.swift
//  "Is this the right bottle?" check before logging a dose.
//
//  Every ~0.35 s the camera frame is OCR'd. Any logged medication whose name,
//  Rx number, or list number shows up in the frame is located on screen, then
//  placed in 3D and marked with a pin. Each display frame, the pin is projected
//  back to the screen so the card floats just above the bottle.
//
//    green card + big check = the medication you tapped Take Now for
//    red card               = one of your other medications (the wrong bottle)
//
//  Cards only stay while the bottle keeps being seen. If a bottle is moved away
//  (or out of the frame), its card and pin are removed within about a second.
//

import ARKit
import RealityKit
import Vision
import SwiftUI
import Combine

/// What identifies a bottle, copied out of SwiftData so it can be used off the main thread.
struct BottleIdentity: Sendable {
    let key: String
    let name: String            // "Lisinopril"
    let strength: String?       // "10 mg"
    let strengthNumber: String? // "10", to tell apart two strengths of the same drug
    let tokens: [String]        // uppercased text to look for on the label, most distinctive first

    @MainActor
    init(_ p: Prescription) {
        key = p.key
        name = p.displayName
        strength = DoseFormat.strength(from: p.dosage)
        strengthNumber = strength?.split(separator: " ").first.map(String.init)

        var tokens: [String] = []
        let words = p.drugName.uppercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0 != "VITAMIN" && $0.count >= 2 }
        if let longest = words.max(by: { $0.count < $1.count }) { tokens.append(longest) }
        if p.rxNumber.hasPrefix("LIST-") {
            tokens.append(String(p.rxNumber.dropFirst(5)))
        } else if p.rxNumber.count >= 5 {
            tokens.append(p.rxNumber)
        }
        self.tokens = tokens
    }
}

@MainActor
final class ARDoseCheckModel: NSObject, ObservableObject {

    /// A card floating over one bottle.
    struct Tag: Identifiable {
        let id: String              // prescription key
        let isTarget: Bool
        let title: String
        let detail: String
        let cardPoint: CGPoint      // where the card sits (above the bottle)
        let pinPoint: CGPoint       // the spot on the label it points to
    }

    @Published private(set) var tags: [Tag] = []
    /// The right bottle is in view right now.
    @Published private(set) var targetVisible = false
    /// A wrong bottle is in view right now.
    @Published private(set) var wrongVisible = false
    /// Log Medication is allowed: the right bottle is in view, or was just confirmed
    /// and no wrong bottle has shown up since.
    @Published private(set) var canLog = false
    /// Goes up by one each time the right bottle is (re)confirmed, to play the big check.
    @Published private(set) var confirmations = 0
    @Published private(set) var hint = "Point the camera at the bottle you picked up"
    @Published private(set) var arUnavailable = false

    let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)

    private let target: BottleIdentity
    private let targetDetail: String
    private let identities: [BottleIdentity]

    private struct Tracked {
        var position: SIMD3<Float>
        var seen: Int               // total reads
        var lastSeen: Date
        var missesInView: Int       // OCR passes in a row where its spot was on screen but it wasn't read
        var anchor: AnchorEntity
    }
    private var tracked: [String: Tracked] = [:]
    private var lastTargetConfirmed: Date?

    private let ocrQueue = DispatchQueue(label: "ar.dosecheck.ocr")
    private var ocrBusy = false
    private var lastOCR = Date.distantPast
    private var displayLink: CADisplayLink?

    /// Reads needed before a bottle gets a card (avoids flicker from one misread).
    private let readsToConfirm = 2
    /// A card disappears if its bottle hasn't been read for this long.
    private let visibleFor: TimeInterval = 1.2
    /// The pin is deleted after this long, or after this many misses while its spot is on screen.
    private let forgetAfter: TimeInterval = 3
    private let missesToForget = 3
    /// After confirming the right bottle, Log stays available this long (so you can lower the phone to tap).
    private let confirmationLasts: TimeInterval = 6
    /// How far above the label the card floats, in meters.
    private let cardLift: Float = 0.07

    init(target: Prescription, all prescriptions: [Prescription]) {
        self.target = BottleIdentity(target)
        self.targetDetail = [
            DoseFormat.perDose(from: target.instructions).map { "Take \($0)" },
            target.takeWithFood.map { $0 ? "With food" : "Empty stomach" },
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
        self.identities = prescriptions.map { BottleIdentity($0) }
        super.init()
    }

    // MARK: Lifecycle

    func start() {
        guard ARWorldTrackingConfiguration.isSupported else {
            arUnavailable = true
            hint = "AR isn't available on this device."
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        // LiDAR phones: build a live 3D mesh so pins land on the bottle itself, not the wall behind it.
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
            arView.environment.sceneUnderstanding.options.insert(.collision)
        }
        arView.session.delegate = self
        arView.session.run(config)

        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        arView.session.pause()
    }

    // MARK: Reading labels

    private func handle(_ frame: ARFrame) {
        guard !ocrBusy, Date().timeIntervalSince(lastOCR) > 0.35, arView.bounds.width > 0 else { return }
        ocrBusy = true
        lastOCR = Date()

        let buffer = frame.capturedImage
        let viewSize = arView.bounds.size
        let transform = frame.displayTransform(for: .portrait, viewportSize: viewSize)
        let identities = identities

        ocrQueue.async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try? VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .right, options: [:]).perform([request])

            let lines = (request.results ?? []).compactMap { observation in
                observation.topCandidates(1).first.map { (text: $0.string.uppercased(), box: observation.boundingBox) }
            }
            let found = Self.match(lines, identities).map { match in
                (key: match.key, point: Self.viewPoint(for: match.box, transform: transform, viewSize: viewSize))
            }

            Task { @MainActor in
                self.ocrBusy = false
                self.update(with: found, sawText: !lines.isEmpty)
            }
        }
    }

    /// For each medication, the tallest line of text containing one of its tokens (the drug
    /// name is usually the biggest text). If two medications land on the same line (same drug,
    /// different strengths), keep the one whose strength is printed in the frame.
    nonisolated private static func match(_ lines: [(text: String, box: CGRect)],
                                          _ identities: [BottleIdentity]) -> [(key: String, box: CGRect)] {
        let allWords = Set(lines.flatMap { $0.text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) })

        let hits: [(identity: BottleIdentity, box: CGRect)] = identities.compactMap { identity in
            let matching = lines.filter { line in
                let words = Set(line.text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
                return identity.tokens.contains { token in
                    // Names must match a whole word; long numbers can be part of "RX# 1234567".
                    words.contains(token) || (token.allSatisfy(\.isNumber) && token.count >= 5 && line.text.contains(token))
                }
            }
            guard let best = matching.max(by: { $0.box.height < $1.box.height }) else { return nil }
            return (identity, best.box)
        }

        var result: [(key: String, box: CGRect)] = []
        for group in Dictionary(grouping: hits, by: { "\($0.box)" }).values {
            if group.count == 1 {
                result.append((group[0].identity.key, group[0].box))
                continue
            }
            let withStrength = group.filter { hit in
                hit.identity.strengthNumber.map { allWords.contains($0) } ?? false
            }
            for hit in (withStrength.isEmpty ? group : withStrength) {
                result.append((hit.identity.key, hit.box))
            }
        }
        return result
    }

    /// Vision box (normalized, portrait, origin bottom-left) -> point in the AR view.
    nonisolated private static func viewPoint(for box: CGRect, transform: CGAffineTransform, viewSize: CGSize) -> CGPoint {
        // The camera image is landscape with a top-left origin. A portrait point (x, yDown)
        // is image point (yDown, 1 - x). displayTransform then maps image -> view.
        let yDown = 1 - box.midY
        let imagePoint = CGPoint(x: yDown, y: 1 - box.midX)
        let normalized = imagePoint.applying(transform)
        return CGPoint(x: normalized.x * viewSize.width, y: normalized.y * viewSize.height)
    }

    // MARK: Tracking

    private func update(with found: [(key: String, point: CGPoint)], sawText: Bool) {
        let now = Date()
        let foundKeys = Set(found.map(\.key))

        // 1. Bottles read this pass: place or move their pins.
        for item in found {
            guard let world = worldPosition(at: item.point) else { continue }
            if var bottle = tracked[item.key] {
                // Moved a lot: jump there. Otherwise smooth out jitter.
                bottle.position = simd_distance(bottle.position, world) > 0.12
                    ? world
                    : simd_mix(bottle.position, world, SIMD3<Float>(repeating: 0.5))
                bottle.anchor.position = bottle.position
                bottle.seen += 1
                bottle.lastSeen = now
                bottle.missesInView = 0
                tracked[item.key] = bottle
                if bottle.seen == readsToConfirm && item.key != target.key {
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                }
            } else {
                let anchor = AnchorEntity(world: world)
                anchor.addChild(Self.pin(isTarget: item.key == target.key))
                arView.scene.addAnchor(anchor)
                tracked[item.key] = Tracked(position: world, seen: 1, lastSeen: now, missesInView: 0, anchor: anchor)
            }
        }

        // 2. Bottles not read this pass: if their spot is on screen and they're still not
        //    there, they've been moved away. Forget them so the card doesn't point at empty space.
        for (key, var bottle) in tracked where !foundKeys.contains(key) {
            if isOnScreen(bottle.position) { bottle.missesInView += 1 }
            if bottle.missesInView >= missesToForget || now.timeIntervalSince(bottle.lastSeen) > forgetAfter {
                arView.scene.removeAnchor(bottle.anchor)
                tracked[key] = nil
            } else {
                tracked[key] = bottle
            }
        }

        // 3. What's in view now.
        let wasVisible = targetVisible
        targetVisible = isShowing(target.key, at: now)
        wrongVisible = tracked.keys.contains { $0 != target.key && isShowing($0, at: now) }

        if targetVisible {
            lastTargetConfirmed = now
            if !wasVisible {
                confirmations += 1
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
        if wrongVisible && !targetVisible {
            lastTargetConfirmed = nil        // switched to a wrong bottle: confirm again
        }
        let recentlyConfirmed = lastTargetConfirmed.map { now.timeIntervalSince($0) < confirmationLasts } ?? false
        canLog = targetVisible || (recentlyConfirmed && !wrongVisible)

        if targetVisible {
            hint = "That's the right bottle."
        } else if wrongVisible {
            hint = "That's not \(target.name). Look for the bottle with the green check."
        } else if recentlyConfirmed {
            hint = "Right bottle checked. Tap Log Medication."
        } else if sawText {
            hint = "Hold the label steady so the name is in view."
        } else {
            hint = "Point the camera at the bottle you picked up"
        }
    }

    /// Confirmed and read recently enough to still be in view.
    private func isShowing(_ key: String, at now: Date) -> Bool {
        guard let bottle = tracked[key] else { return false }
        return bottle.seen >= readsToConfirm && now.timeIntervalSince(bottle.lastSeen) < visibleFor
    }

    private func isOnScreen(_ position: SIMD3<Float>) -> Bool {
        guard let point = arView.project(position) else { return false }
        return arView.bounds.insetBy(dx: 20, dy: 20).contains(point)
    }

    /// The 3D point behind a screen point, most accurate first:
    ///   1. the LiDAR mesh (the bottle's actual surface)
    ///   2. a surface ARKit detected (the label, or the table right behind it)
    ///   3. ~35 cm out along that line of sight, about where a held bottle is
    private func worldPosition(at point: CGPoint) -> SIMD3<Float>? {
        guard let ray = arView.ray(through: point) else { return nil }

        if arView.environment.sceneUnderstanding.options.contains(.collision),
           let hit = arView.scene.raycast(origin: ray.origin, direction: ray.direction, length: 1.5,
                                          query: .nearest, mask: .sceneUnderstanding).first {
            return hit.position
        }

        if let hit = arView.raycast(from: point, allowing: .estimatedPlane, alignment: .any).first {
            let c = hit.worldTransform.columns.3
            let position = SIMD3<Float>(c.x, c.y, c.z)
            if simd_distance(position, ray.origin) < 1.2 { return position }
        }

        return ray.origin + ray.direction * 0.35
    }

    /// A small glowing dot on the label, rendered in the 3D scene.
    private static func pin(isTarget: Bool) -> ModelEntity {
        let color = isTarget ? UIColor(Color.takenGreen) : UIColor(Color.warningRed)
        return ModelEntity(mesh: .generateSphere(radius: 0.008), materials: [UnlitMaterial(color: color)])
    }

    // MARK: Cards (every display frame)

    @objc private func tick() {
        let now = Date()
        var next: [Tag] = []
        for identity in identities {
            guard isShowing(identity.key, at: now),
                  let bottle = tracked[identity.key],
                  let pinPoint = arView.project(bottle.position),
                  let cardPoint = arView.project(bottle.position + SIMD3<Float>(0, cardLift, 0)) else { continue }

            let isTarget = identity.key == target.key
            next.append(Tag(
                id: identity.key,
                isTarget: isTarget,
                title: isTarget
                    ? [identity.name, identity.strength].compactMap { $0 }.joined(separator: " ")
                    : "This is \(identity.name)",
                detail: isTarget
                    ? (targetDetail.isEmpty ? "Right bottle" : targetDetail)
                    : "Not \(target.name)",
                cardPoint: cardPoint,
                pinPoint: pinPoint
            ))
        }
        tags = next
    }
}

extension ARDoseCheckModel: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // ARKit calls this on the main queue.
        MainActor.assumeIsolated { handle(frame) }
    }
}
