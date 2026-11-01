import Foundation

/// Picks the best of a group of near-duplicates. Apple's aesthetics score does most of
/// the work; on top of it, frames that are technically worse *than their siblings*
/// (much softer, more clipped, much darker) are nudged down. Sharpness and brightness
/// only mean something relative to the same scene, hence per-group.
public enum Ranking {
    /// Why a frame lost points against its siblings.
    public enum Flaw: String, CaseIterable, Sendable {
        case blurry, blown, dark, grainy
    }

    public struct Assessment: Sendable {
        public var score: Float
        public var flaws: [Flaw]
    }

    public static func assess(_ group: [Analysis]) -> [Assessment] {
        guard group.count > 1 else { return group.map { Assessment(score: $0.score, flaws: []) } }
        let maxSharp = max(group.map(\.sharpness).max()!, 1e-6)
        let minClip = group.map(\.clipped).min()!
        let medianLuma = group.map(\.luma).sorted()[group.count / 2]
        // Median, not min: a blurred sibling has almost no edge response and would make every sharp frame look grainy.
        let medianNoise = max(group.map(\.noise).sorted()[group.count / 2], 1)
        return group.map { a in
            // Synthetic bursts: blur/shake frames sit at 1-7% of the group's sharpest, good ones above ~13%.
            let ratio = max(a.sharpness / maxSharp, 1e-4)
            let soft = Float(0.25 * min(max(log10(0.15 / ratio), 0), 1))
            // Blown frames clip ~38% of pixels; good ones under ~6%.
            let clip = 0.5 * max(a.clipped - minClip - 0.05, 0)
            // Underexposed relative to the group (a deliberately darker exposure is mild).
            let lumaRatio = medianLuma > 0.05 ? a.luma / medianLuma : 1
            let dark = 0.3 * min(max((0.6 - lumaRatio) / 0.3, 0), 1)
            // Much brighter than siblings: blown even when nothing hits pure white (dark scenes).
            let bright = 0.3 * min(max((lumaRatio - 1.2) / 0.25, 0), 1)
            // Grain lifts the median edge response everywhere; real detail only at edges.
            let grain = 0.3 * min(max((a.noise / medianNoise - 2.5) / 2.5, 0), 1)

            var flaws: [Flaw] = []
            if soft >= 0.1 { flaws.append(.blurry) }
            if clip + bright >= 0.1 { flaws.append(.blown) }
            if dark >= 0.1 { flaws.append(.dark) }
            if grain >= 0.1 { flaws.append(.grainy) }
            return Assessment(score: a.score - soft - clip - dark - bright - grain, flaws: flaws)
        }
    }

    public static func adjustedScores(_ group: [Analysis]) -> [Float] { assess(group).map(\.score) }

    /// Frames the user has already singled out: favourites always, plus members of any album that
    /// took some frames of the burst but not others. An album holding the whole burst (the usual
    /// dump-the-trip album) says nothing; a "best of" album alongside it does.
    public static func chosen(favorites: [Bool], albums: [Set<String>]) -> [Bool] {
        let all = albums.reduce(into: Set<String>()) { $0.formUnion($1) }
        let picky = all.filter { a in albums.contains { !$0.contains(a) } }
        return zip(favorites, albums).map { $0 || !$1.isDisjoint(with: picky) }
    }

    /// Indices best-first. Chosen frames (see `chosen`) always lead.
    public static func order(_ group: [Analysis?], preferred: [Bool]) -> [Int] {
        let known = group.compactMap { $0 }
        let adjusted = adjustedScores(known)
        var scores = [Float](repeating: -.infinity, count: group.count)
        var k = 0
        for i in group.indices where group[i] != nil { scores[i] = adjusted[k]; k += 1 }
        return group.indices.sorted {
            preferred[$0] != preferred[$1] ? preferred[$0] : scores[$0] > scores[$1]
        }
    }
}

/// How many frames to suggest keeping per group: a percentage of the group, clamped to a range.
/// Fixed N is `fraction: 0, min: N`; plain percentage is `max: nil`.
public struct PickRules: Equatable, Sendable {
    /// Share of the group to keep, rounded up (0 = just `min`).
    public var fraction: Float
    public var min: Int
    /// nil = no cap.
    public var max: Int?
    /// Also keep anything scoring within this of the last kept frame (0 = off), up to `max`.
    public var tieMargin: Float

    public init(fraction: Float = 0, min: Int = 1, max: Int? = nil, tieMargin: Float = 0) {
        self.fraction = Swift.min(Swift.max(fraction, 0), 1)
        self.min = Swift.max(1, min)
        self.max = max.map { Swift.max($0, Swift.max(1, min)) }
        self.tieMargin = Swift.max(0, tieMargin)
    }

    public func keepCount(groupSize n: Int) -> Int {
        var k = Swift.max(self.min, Int((fraction * Float(n)).rounded(.up)))
        if let max { k = Swift.min(k, max) }
        return Swift.min(k, n)
    }
}

extension Ranking {
    /// Indices to suggest keeping: the best `rules.keepCount` of `ranked` (best-first), near-ties up
    /// to `rules.max`, and every `chosen` frame (favourites, picky-album picks) regardless of the cap.
    public static func suggested(ranked: [Int], scores: [Float], chosen: Set<Int>, rules: PickRules) -> Set<Int> {
        guard !ranked.isEmpty else { return chosen }
        let top = ranked.prefix(rules.keepCount(groupSize: ranked.count))
        var keep = Set(top)
        if rules.tieMargin > 0, let last = top.last, scores[last].isFinite {
            let cutoff = scores[last] - rules.tieMargin
            let cap = rules.max ?? ranked.count
            for i in ranked.dropFirst(top.count) where scores[i] >= cutoff && keep.count < cap { keep.insert(i) }
        }
        return keep.union(chosen)
    }

    /// How clearly the kept frames beat the first one left out, after adjustment. Large
    /// margins mean the suggestion is safe to accept without looking.
    public static func margin(_ group: [Analysis], keepCount: Int = 1) -> Float {
        let s = adjustedScores(group).sorted(by: >)
        return s.count > keepCount ? s[keepCount - 1] - s[keepCount] : .infinity
    }

    public static let easyMargin: Float = 0.15
}
