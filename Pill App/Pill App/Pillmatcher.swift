//
//  PillMatcher.swift
//  Votes across frames, then scores the scanned pill against each logged
//  medication's Pillbox appearances.
//

import Foundation
import CoreGraphics

// MARK: - Multi-frame voting

struct ScannedPillSummary: Sendable {
    var shape: String?
    var colors: [String]
    var imprints: [String]       // confirmed OCR reads, most-seen first
}

struct PillFeatureAccumulator {
    private var shapeVotes: [String: Int] = [:]
    private var colorVotes: [String: Int] = [:]
    private var imprintVotes: [String: Int] = [:]
    private(set) var frames = 0

    mutating func add(_ frame: FramePillFeatures) {
        frames += 1
        shapeVotes[frame.shape, default: 0] += 1
        if !frame.colors.isEmpty {
            colorVotes[frame.colors.joined(separator: ";"), default: 0] += 1
        }
        for imprint in frame.imprints {
            imprintVotes[imprint, default: 0] += 1
        }
    }

    /// Shape and color need 3 matching frames; an imprint needs 2.
    var summary: ScannedPillSummary {
        ScannedPillSummary(
            shape: top(shapeVotes, minimum: 3),
            colors: top(colorVotes, minimum: 3)?.split(separator: ";").map(String.init) ?? [],
            imprints: imprintVotes.filter { $0.value >= 2 }.sorted { $0.value > $1.value }.map(\.key)
        )
    }

    private func top(_ votes: [String: Int], minimum: Int) -> String? {
        guard let best = votes.max(by: { $0.value < $1.value }), best.value >= minimum else { return nil }
        return best.key
    }
}

// MARK: - Results

struct PillMatchResult: Identifiable, Sendable {
    let profile: LoggedPillProfile
    let appearance: PillAppearance?      // nil when Pillbox has nothing for this medication
    let score: Double                    // 0...1
    var id: String { profile.id }
    var percent: Int { Int((score * 100).rounded()) }
}

enum MatchConfidence {
    case strong, possible, none
}

struct PillScanOutcome {
    let summary: ScannedPillSummary
    let matches: [PillMatchResult]       // best first
    let image: CGImage?

    var best: PillMatchResult? { matches.first }
    var runnerUp: PillMatchResult? { matches.dropFirst().first }
    var imprintWasRead: Bool { !summary.imprints.isEmpty }

    /// "Strong" needs a high score, a clear gap to the next medication, and a readable
    /// imprint (unless the pill has none). Otherwise the user is asked to double-check.
    var confidence: MatchConfidence {
        guard let best, best.appearance != nil else { return .none }
        let gap = best.score - (runnerUp?.score ?? 0)
        let imprintOK = imprintWasRead || best.appearance?.imprint.isEmpty == true
        if best.score >= 0.8, gap >= 0.15, imprintOK { return .strong }
        if best.score >= 0.55 { return .possible }
        return .none
    }

    /// Another medication scored close enough to be confused with the best one.
    var closeRunnerUp: PillMatchResult? {
        guard let best, let runnerUp, runnerUp.appearance != nil, best.score - runnerUp.score < 0.15 else { return nil }
        return runnerUp
    }
}

// MARK: - Scoring

enum PillMatcher {

    static func rank(_ scan: ScannedPillSummary, against profiles: [LoggedPillProfile]) -> [PillMatchResult] {
        profiles.map { profile in
            let scored = profile.appearances.map { appearance in
                PillMatchResult(profile: profile, appearance: appearance, score: score(scan, appearance))
            }
            return scored.max(by: { $0.score < $1.score })
                ?? PillMatchResult(profile: profile, appearance: nil, score: 0)
        }
        .sorted { $0.score > $1.score }
    }

    /// Weighted: imprint 60%, color 25%, shape 15%. Only signals we have count.
    static func score(_ scan: ScannedPillSummary, _ appearance: PillAppearance) -> Double {
        var total = 0.0, weight = 0.0

        let pillHasImprint = !appearance.imprint.isEmpty
        if pillHasImprint, !scan.imprints.isEmpty {
            total += 0.60 * imprintSimilarity(scan.imprints, expected: appearance.imprint)
            weight += 0.60
        }
        if !appearance.colors.isEmpty, !scan.colors.isEmpty {
            total += 0.25 * colorSimilarity(scan.colors, appearance.colors)
            weight += 0.25
        }
        if let shape = scan.shape, !appearance.shape.isEmpty {
            total += 0.15 * shapeSimilarity(shape, appearance.shape)
            weight += 0.15
        }
        guard weight > 0 else { return 0 }

        var score = total / weight
        // Couldn't read an imprint the pill should have: color + shape alone can't be sure.
        if pillHasImprint && scan.imprints.isEmpty { score *= 0.7 }
        return score
    }

    /// Pillbox imprints list each side/line separated by ";". Seeing either the whole
    /// imprint or each part of it counts (you may only see one side at a time).
    static func imprintSimilarity(_ scanned: [String], expected: String) -> Double {
        let parts = expected.uppercased()
            .split(whereSeparator: { $0 == ";" || $0 == " " || $0 == "," })
            .map { PillText.canonical(String($0)) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty, !scanned.isEmpty else { return 0 }

        let reads = scanned.map(PillText.canonical)
        let whole = parts.joined()
        let wholeScore = reads.map { PillText.similarity($0, whole) }.max() ?? 0

        let partsFound = parts.filter { part in
            reads.contains { read in
                // Single characters must match exactly; longer parts can be inside a longer read.
                part.count >= 2 ? (read.contains(part) || PillText.similarity(read, part) >= 0.8) : read == part
            }
        }.count
        return max(wholeScore, Double(partsFound) / Double(parts.count))
    }

    static func colorSimilarity(_ scanned: [String], _ expected: [String]) -> Double {
        let seen = scanned.map(PillColors.family)
        let wanted = expected.map(PillColors.family)
        let scores = wanted.map { color -> Double in
            if seen.contains(color) { return 1 }
            if seen.contains(where: { PillColors.areNeighbors($0, color) }) { return 0.5 }
            return 0
        }
        return scores.reduce(0, +) / Double(max(scores.count, 1))
    }

    static func shapeSimilarity(_ scanned: String, _ expected: String) -> Double {
        let a = shapeFamily(scanned), b = shapeFamily(expected)
        if a == b { return 1 }
        if Set([a, b]) == ["OVAL", "CAPSULE"] { return 0.5 }
        if a == "OTHER" || b == "OTHER" || Set([a, b]) == ["ROUND", "OVAL"] { return 0.3 }
        return 0
    }

    /// The camera can only tell round / oval / long apart, so fold Pillbox's shapes into those.
    static func shapeFamily(_ shape: String) -> String {
        let s = shape.uppercased()
        if s.contains("ROUND") { return "ROUND" }
        if s.contains("OVAL") || s.contains("ELLIP") || s.contains("EGG") { return "OVAL" }
        if s.contains("CAPSULE") || s.contains("OBLONG") || s.contains("RECTANGLE") { return "CAPSULE" }
        return "OTHER"
    }
}
