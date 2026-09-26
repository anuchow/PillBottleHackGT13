//
//  ScanGuidance.swift
//  Decides which arrow to show, based on where the text sits in the frame.
//
//  Idea: if lines of text are cut off at an edge of the scan circle, the label
//  continues past that edge, so we ask the user to bring that part into view.
//

import CoreGraphics
import Vision

enum ScanHint: Hashable {
    case findLabel, moveCloser, moveBack, rotateLeft, rotateRight, tiltUp, tiltDown, holdStill

    var message: String {
        switch self {
        case .findLabel:                return "Point the camera at the pharmacy label"
        case .moveCloser:               return "Move the bottle closer"
        case .moveBack:                 return "Move the bottle a little farther away"
        case .rotateLeft, .rotateRight: return "Slowly turn the bottle"
        case .tiltUp:                   return "Move the bottle up"
        case .tiltDown:                 return "Move the bottle down"
        case .holdStill:                return "Hold still"
        }
    }

    var symbol: String {
        switch self {
        case .findLabel:   return "doc.text.viewfinder"
        case .moveCloser:  return "plus.magnifyingglass"
        case .moveBack:    return "minus.magnifyingglass"
        case .rotateLeft:  return "arrow.left"
        case .rotateRight: return "arrow.right"
        case .tiltUp:      return "arrow.up"
        case .tiltDown:    return "arrow.down"
        case .holdStill:   return "hand.raised"
        }
    }

    /// Where the arrow sits relative to the circle's center (SwiftUI coords, y points down).
    var direction: CGSize {
        switch self {
        case .rotateLeft:  return CGSize(width: -1, height: 0)
        case .rotateRight: return CGSize(width: 1, height: 0)
        case .tiltUp:      return CGSize(width: 0, height: -1)
        case .tiltDown:    return CGSize(width: 0, height: 1)
        default:           return .zero
        }
    }
}

enum ScanGuidance {

    /// Part of the camera frame that OCR looks at, roughly matching the on-screen circle.
    /// Normalized, lower-left origin, for a portrait frame.
    /// TODO: compute this from the preview layer with
    /// `previewLayer.metadataOutputRectConverted(fromLayerRect:)` so it matches exactly.
    static let regionOfInterest = CGRect(x: 0.12, y: 0.28, width: 0.76, height: 0.44)

    /// `boxes` are Vision bounding boxes, normalized to the region of interest.
    static func hint(for boxes: [CGRect],
                     stillMissing: Bool,
                     rotationPreference: inout ScanHint) -> ScanHint {
        guard !boxes.isEmpty else { return .findLabel }

        // Text size tells us distance.
        let averageHeight = boxes.map(\.height).reduce(0, +) / CGFloat(boxes.count)
        if averageHeight < 0.018 { return .moveCloser }
        if averageHeight > 0.09 { return .moveBack }

        guard stillMissing else { return .holdStill }

        // Count lines clipped by each edge.
        let edge: CGFloat = 0.03
        let clippedTop    = boxes.filter { $0.maxY > 1 - edge }.count
        let clippedBottom = boxes.filter { $0.minY < edge }.count
        let clippedLeft   = boxes.filter { $0.minX < edge }.count
        let clippedRight  = boxes.filter { $0.maxX > 1 - edge }.count

        // Vertical: text cut off at the top means the bottle should move down, and vice versa.
        if clippedTop > clippedBottom, clippedTop >= 2 { return .tiltDown }
        if clippedBottom > clippedTop, clippedBottom >= 2 { return .tiltUp }

        // Horizontal: text cut off on the right means the label continues around
        // the curve that way, so turn the bottle so that side comes toward the camera.
        if clippedRight > clippedLeft {
            rotationPreference = .rotateLeft
        } else if clippedLeft > clippedRight {
            rotationPreference = .rotateRight
        }

        // Nothing clipped but fields are still missing: keep turning the same way,
        // like panning, until the rest of the label comes around.
        return rotationPreference
    }

    /// Sort observations top-to-bottom, then left-to-right, so multi-line directions stay in order.
    static func readingOrder(_ a: VNRecognizedTextObservation, _ b: VNRecognizedTextObservation) -> Bool {
        let ay = a.boundingBox.midY, by = b.boundingBox.midY
        if abs(ay - by) > 0.015 { return ay > by }
        return a.boundingBox.minX < b.boundingBox.minX
    }
}
