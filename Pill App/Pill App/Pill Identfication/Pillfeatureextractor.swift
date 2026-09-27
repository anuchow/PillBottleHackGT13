//
//  PillFeatureExtractor.swift
//  One camera frame -> the pill's shape, color(s), and imprint text.
//
//  1. Vision's foreground mask (iOS 17+) cuts the pill out from the background.
//  2. The mask's outline gives the aspect ratio (shape) and the long-axis angle.
//  3. The cut-out is rotated so the long axis is horizontal, then:
//       color   = average of each half (two halves catch two-tone capsules)
//       imprint = OCR on a high-contrast grayscale copy, tried at a few rotations
//
//  Needs a real device (the foreground mask doesn't run in the Simulator).
//

import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

struct FramePillFeatures {
    var shape: String            // ROUND / OVAL / CAPSULE
    var colors: [String]         // Pillbox color words
    var imprints: [String]       // normalized OCR candidates
    var image: CGImage?          // cut-out of the pill, for the results screen
    var sizeInView: CGFloat      // pill length as a fraction of the visible circle
}

enum PillFeatureExtractor {
    private static let context = CIContext()

    static func extract(from pixelBuffer: CVPixelBuffer,
                        orientation: CGImagePropertyOrientation = .right) -> FramePillFeatures? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        do { try handler.perform([request]) } catch { return nil }

        guard let observation = request.results?.first,
              let blob = pickPillBlob(in: observation.instanceMask),
              let masked = try? observation.generateMaskedImage(ofInstances: IndexSet(integer: blob.label),
                                                                from: handler,
                                                                croppedToInstancesExtent: true) else { return nil }

        // Rotate so the long axis is horizontal. The angle was measured with y pointing
        // down (pixel rows); Core Image has y pointing up, so rotating by +angle levels it.
        var pill = CIImage(cvPixelBuffer: masked).transformed(by: CGAffineTransform(rotationAngle: blob.angle))
        pill = pill.transformed(by: CGAffineTransform(translationX: -pill.extent.minX, y: -pill.extent.minY))

        let shape = shapeName(aspectRatio: blob.aspectRatio)
        return FramePillFeatures(
            shape: shape,
            colors: dominantColors(of: pill, elongated: blob.aspectRatio > 1.6),
            imprints: readImprint(on: pill, isRound: shape == "ROUND"),
            image: context.createCGImage(pill, from: pill.extent),
            sizeInView: blob.longSide
        )
    }

    // MARK: Mask analysis

    private struct Blob {
        let label: Int
        let aspectRatio: Double
        let angle: CGFloat
        let longSide: CGFloat
    }

    /// Picks the foreground object nearest the center of the visible circle,
    /// skipping anything huge (a hand or the table) or tiny (noise).
    private static func pickPillBlob(in mask: CVPixelBuffer) -> Blob? {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return nil }

        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        let rowBytes = CVPixelBufferGetBytesPerRow(mask)
        let pixels = base.assumingMemoryBound(to: UInt8.self)

        // Running sums per instance label, sampling every other pixel for speed.
        var n = [Double](repeating: 0, count: 256)
        var sx = n, sy = n, sxx = n, syy = n, sxy = n
        for y in stride(from: 0, to: height, by: 2) {
            let row = pixels + y * rowBytes
            for x in stride(from: 0, to: width, by: 2) {
                let label = Int(row[x])
                guard label != 0 else { continue }
                let fx = Double(x), fy = Double(y)
                n[label] += 1
                sx[label] += fx;  sy[label] += fy
                sxx[label] += fx * fx;  syy[label] += fy * fy;  sxy[label] += fx * fy
            }
        }

        // The on-screen circle shows the center square of the frame.
        let side = Double(min(width, height))
        let centerX = Double(width) / 2, centerY = Double(height) / 2

        var best: Blob?
        var bestDistance = Double.infinity

        for label in 1..<256 where n[label] > 0 {
            let count = n[label]
            let mx = sx[label] / count, my = sy[label] / count
            guard abs(mx - centerX) < side / 2, abs(my - centerY) < side / 2 else { continue }

            let areaFraction = count * 4 / (side * side)          // * 4 because of the stride
            guard areaFraction > 0.002, areaFraction < 0.45 else { continue }

            // Principal axes of the blob: ratio of spreads = aspect ratio, direction = angle.
            let cxx = sxx[label] / count - mx * mx
            let cyy = syy[label] / count - my * my
            let cxy = sxy[label] / count - mx * my
            let trace = cxx + cyy
            let root = max(0, trace * trace / 4 - (cxx * cyy - cxy * cxy)).squareRoot()
            let major = trace / 2 + root
            let minor = max(trace / 2 - root, 1e-6)

            let distance = hypot(mx - centerX, my - centerY)
            if distance < bestDistance {
                bestDistance = distance
                best = Blob(label: label,
                            aspectRatio: (major / minor).squareRoot(),
                            angle: CGFloat(0.5 * atan2(2 * cxy, cxx - cyy)),
                            longSide: CGFloat(4 * major.squareRoot() / side))
            }
        }
        return best
    }

    /// Pillbox calls caplets (capsule-shaped tablets) "CAPSULE" too, so elongated = CAPSULE.
    private static func shapeName(aspectRatio: Double) -> String {
        if aspectRatio < 1.15 { return "ROUND" }
        if aspectRatio < 1.85 { return "OVAL" }
        return "CAPSULE"
    }

    // MARK: Color

    private static func dominantColors(of pill: CIImage, elongated: Bool) -> [String] {
        let inner = pill.extent.insetBy(dx: pill.extent.width * 0.15, dy: pill.extent.height * 0.2)
        guard elongated else {
            return averageColorName(of: pill, in: inner).map { [$0] } ?? []
        }
        // Two halves along the long axis, for two-tone capsules.
        let (left, right) = inner.divided(atDistance: inner.width / 2, from: .minXEdge)
        let names = [averageColorName(of: pill, in: left), averageColorName(of: pill, in: right)].compactMap { $0 }
        return Array(Set(names)).sorted()
    }

    private static func averageColorName(of image: CIImage, in rect: CGRect) -> String? {
        let filter = CIFilter.areaAverage()
        filter.inputImage = image
        filter.extent = rect
        guard let output = filter.outputImage else { return nil }

        var pixel = [Float](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 16,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: CGColorSpaceCreateDeviceRGB())

        // The cut-out has a transparent background, so undo the alpha weighting.
        let alpha = pixel[3]
        guard alpha > 0.05 else { return nil }
        return PillColors.name(red: pixel[0] / alpha, green: pixel[1] / alpha, blue: pixel[2] / alpha)
    }

    // MARK: Imprint

    private static func readImprint(on pill: CIImage, isRound: Bool) -> [String] {
        // Gray background, grayscale, extra contrast and sharpening: imprints are
        // often debossed (pressed in) with no ink, so they only show as shading.
        let background = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: pill.extent)
        var image = pill.composited(over: background)

        if image.extent.width < 700 {
            let scale = 700 / image.extent.width
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        let controls = CIFilter.colorControls()
        controls.inputImage = image
        controls.saturation = 0
        controls.contrast = 1.6
        image = controls.outputImage ?? image

        let sharpen = CIFilter.unsharpMask()
        sharpen.inputImage = image
        sharpen.radius = 3
        sharpen.intensity = 0.9
        image = sharpen.outputImage ?? image

        guard let cgImage = context.createCGImage(image, from: image.extent) else { return [] }

        // Long pills are already level, so only upright or upside down.
        // Round pills can be at any angle.
        let orientations: [CGImagePropertyOrientation] = isRound ? [.up, .right, .down, .left] : [.up, .down]
        var found = Set<String>()

        for orientation in orientations {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try? VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:]).perform([request])

            let lines = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first }
                .filter { $0.confidence > 0.3 }
                .map { PillText.normalize($0.string) }
                .filter { (1...12).contains($0.count) }

            found.formUnion(lines)
            if lines.count > 1 { found.insert(lines.joined()) }   // two-line imprints
        }
        return Array(found)
    }
}

// MARK: - Colors

enum PillColors {
    /// Maps RGB to Pillbox's color words. Tune with real photos: warm indoor light
    /// can make white pills read as yellow, which is why saturation must be fairly high
    /// before a color counts.
    static func name(red: Float, green: Float, blue: Float) -> String {
        let color = UIColor(red: CGFloat(min(max(red, 0), 1)),
                            green: CGFloat(min(max(green, 0), 1)),
                            blue: CGFloat(min(max(blue, 0), 1)), alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)

        if b < 0.22 { return "BLACK" }
        if s < 0.18 { return b > 0.68 ? "WHITE" : "GRAY" }

        switch h * 360 {
        case ..<12, 345...: return "RED"
        case 12..<40:       return b < 0.55 ? "BROWN" : "ORANGE"
        case 40..<68:       return "YELLOW"
        case 68..<160:      return "GREEN"
        case 160..<195:     return "TURQUOISE"
        case 195..<255:     return "BLUE"
        case 255..<290:     return "PURPLE"
        default:            return "PINK"
        }
    }

    /// Pillbox sometimes uses other words; fold them into the ones above.
    static func family(_ color: String) -> String {
        let c = color.uppercased()
        if c.contains("WHITE") || c.contains("CLEAR") { return "WHITE" }
        if c.contains("TAN") || c.contains("BEIGE") { return "BROWN" }
        if c.contains("GREY") { return "GRAY" }
        return c
    }

    /// Colors that lighting or camera white balance often mix up.
    static func areNeighbors(_ a: String, _ b: String) -> Bool {
        let pairs: Set<Set<String>> = [
            ["WHITE", "GRAY"], ["WHITE", "YELLOW"], ["YELLOW", "ORANGE"], ["ORANGE", "BROWN"],
            ["ORANGE", "RED"], ["RED", "PINK"], ["PINK", "PURPLE"], ["BLUE", "TURQUOISE"],
            ["GREEN", "TURQUOISE"], ["GRAY", "BLACK"]
        ]
        return pairs.contains([a, b])
    }
}

// MARK: - Text

enum PillText {
    /// Uppercase letters and digits only.
    static func normalize(_ s: String) -> String {
        s.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Same as normalize, but folds characters OCR confuses (O/0, I/1, S/5, ...),
    /// so "M 3O7" and "M307" compare equal.
    static func canonical(_ s: String) -> String {
        let swaps: [Character: Character] = ["O": "0", "Q": "0", "D": "0", "I": "1", "L": "1",
                                             "S": "5", "B": "8", "Z": "2", "G": "6"]
        return String(normalize(s).map { swaps[$0] ?? $0 })
    }

    /// Normalized Levenshtein similarity in 0...1.
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let a = Array(lhs), b = Array(rhs)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1,
                                 current[j - 1] + 1,
                                 previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return 1 - Double(previous[b.count]) / Double(max(a.count, b.count))
    }
}
