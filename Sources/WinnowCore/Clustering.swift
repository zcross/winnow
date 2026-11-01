import Accelerate
import Foundation

public struct ClusterInput {
    public var date: Date
    /// Unit-length embedding; empty means "never similar to anything".
    public var vector: [Float]
    /// Unit-length blur/exposure-tolerant signature; may be empty.
    public var coarse: [Float]

    public init(date: Date, vector: [Float], coarse: [Float] = []) {
        (self.date, self.vector, self.coarse) = (date, vector, coarse)
    }
}

public struct ClusterParams: Equatable {
    /// Two photos can only link if taken within this many seconds of each other.
    public var maxGap: TimeInterval
    /// Max euclidean distance between unit embeddings (0 = identical, 2 = opposite).
    public var threshold: Float
    /// How many time-ordered neighbours each photo is compared against.
    public var window: Int
    /// Botched retakes (blurred, shaken, mis-exposed) look unlike their good sibling to the
    /// feature print, so shots this close in time may also link on the coarse signature.
    public var coarseGap: TimeInterval
    public var coarseThreshold: Float
    /// Two heavily blurred shots of different scenes can look alike to the feature print;
    /// their layouts still differ wildly. Same-scene pairs measured <= 1.18 on the coarse signature.
    public var coarseVeto: Float = 1.35

    /// Measured on synthetic bursts: good retakes sit <= 0.53 apart on feature prints and
    /// different scenes >= 0.83; on coarse signatures flawed retakes sit <= 0.48 from a
    /// sibling and different scenes shot within minutes >= 0.77.
    public init(maxGap: TimeInterval, threshold: Float, window: Int = 40,
                coarseGap: TimeInterval = 60, coarseThreshold: Float? = nil) {
        self.maxGap = maxGap
        self.threshold = threshold
        self.window = window
        self.coarseGap = min(coarseGap, maxGap)
        self.coarseThreshold = coarseThreshold ?? threshold * 0.9
    }
}

public enum Clustering {
    public static func normalized(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        norm = norm.squareRoot()
        guard norm > 0 else { return v }
        return vDSP.divide(v, norm)
    }

    public static func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        return vDSP.distanceSquared(a, b).squareRoot()
    }

    /// Groups time-sorted items by single linkage over edges that are both
    /// temporally close and visually similar. Returns every group, singletons
    /// included, as index lists ordered by their first member.
    public static func groups(_ items: [ClusterInput], _ p: ClusterParams) -> [[Int]] {
        var parent = Array(items.indices)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }

        for i in items.indices where !items[i].vector.isEmpty {
            var j = i + 1
            while j < items.count, j <= i + p.window {
                let dt = items[j].date.timeIntervalSince(items[i].date)
                if dt > p.maxGap { break }
                let coarse = items[i].coarse.isEmpty || items[j].coarse.isEmpty ? nil : distance(items[i].coarse, items[j].coarse)
                let similar = distance(items[i].vector, items[j].vector) <= p.threshold && (coarse ?? 0) <= p.coarseVeto
                if similar || (dt <= p.coarseGap && (coarse ?? .infinity) <= p.coarseThreshold) {
                    let (ri, rj) = (find(i), find(j))
                    if ri != rj { parent[max(ri, rj)] = min(ri, rj) }
                }
                j += 1
            }
        }

        var byRoot: [Int: [Int]] = [:]
        for i in items.indices { byRoot[find(i), default: []].append(i) }
        return byRoot.values.sorted { $0[0] < $1[0] }
    }
}
