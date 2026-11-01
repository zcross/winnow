import CoreGraphics
import Foundation
import Vision

/// Per-photo Vision results, cached on disk by photo identifier.
public struct Analysis: Codable, Sendable {
    public var vector: [Float]   // unit-length feature print
    public var coarse: [Float]   // unit-length blur/exposure-tolerant layout signature
    public var score: Float      // aesthetics overall score, roughly -1...1
    public var sharpness: Float  // variance of the Laplacian on a grey thumbnail; only comparable within a scene
    public var clipped: Float    // fraction of pixels crushed to black or blown to white
    public var luma: Float       // mean grey level, 0...1
    public var noise: Float      // median |Laplacian|: grain lifts it everywhere, real detail only at edges
    public var isUtility: Bool   // receipts, screenshots of text, documents

    public init(vector: [Float], coarse: [Float], score: Float, sharpness: Float = 0, clipped: Float = 0, luma: Float = 0.5, noise: Float = 0, isUtility: Bool) {
        (self.vector, self.coarse, self.score, self.isUtility) = (vector, coarse, score, isUtility)
        (self.sharpness, self.clipped, self.luma, self.noise) = (sharpness, clipped, luma, noise)
    }

    // Vectors go to disk as raw bytes; a plist array of 768 reals per photo is slow and bulky.
    private enum CodingKeys: String, CodingKey { case vector, coarse, score, sharpness, clipped, luma, noise, isUtility }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let data = try c.decode(Data.self, forKey: .vector)
        vector = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let coarseData = try c.decodeIfPresent(Data.self, forKey: .coarse) ?? Data()
        coarse = coarseData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        score = try c.decode(Float.self, forKey: .score)
        sharpness = try c.decodeIfPresent(Float.self, forKey: .sharpness) ?? 0
        clipped = try c.decodeIfPresent(Float.self, forKey: .clipped) ?? 0
        luma = try c.decodeIfPresent(Float.self, forKey: .luma) ?? 0.5
        noise = try c.decodeIfPresent(Float.self, forKey: .noise) ?? 0
        isUtility = try c.decode(Bool.self, forKey: .isUtility)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(vector.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: .vector)
        try c.encode(coarse.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: .coarse)
        try c.encode(score, forKey: .score)
        try c.encode(sharpness, forKey: .sharpness)
        try c.encode(clipped, forKey: .clipped)
        try c.encode(luma, forKey: .luma)
        try c.encode(noise, forKey: .noise)
        try c.encode(isUtility, forKey: .isUtility)
    }
}

public enum ImageAnalyzer {
    /// Small enough to be quick, large enough for Vision's ~360px models.
    public static let thumbnailPixels: CGFloat = 448

    /// Vision blocks its calling thread while it waits on internal queues. Calling it from
    /// many threads at once (a task group on the cooperative pool, concurrentPerform)
    /// starves those queues and deadlocks, so all callers funnel through here.
    private static let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "Winnow.Vision"
        q.qualityOfService = .userInitiated
        q.maxConcurrentOperationCount = 4
        return q
    }()

    public static var maxConcurrent: Int {
        get { queue.maxConcurrentOperationCount }
        set { queue.maxConcurrentOperationCount = newValue }
    }

    public static func analyzeQueued(_ cg: CGImage) async -> Analysis? {
        await withCheckedContinuation { cont in
            queue.addOperation { cont.resume(returning: try? analyze(cg)) }
        }
    }

    public static func analyze(_ cg: CGImage) throws -> Analysis? {
        let print = VNGenerateImageFeaturePrintRequest()
        let aesthetics = VNCalculateImageAestheticsScoresRequest()
        try VNImageRequestHandler(cgImage: cg).perform([print, aesthetics])
        guard let fp = print.results?.first else { return nil }
        let ae = aesthetics.results?.first
        let t = technical(cg)
        return Analysis(vector: Clustering.normalized(floats(fp)), coarse: coarseSignature(cg),
                        score: ae?.overallScore ?? 0, sharpness: t.sharpness, clipped: t.clipped, luma: t.luma, noise: t.noise,
                        isUtility: ae?.isUtility ?? false)
    }

    public struct Technical { public var sharpness, clipped, luma, noise: Float }

    /// Sharpness, clipping, brightness and grain from a grey copy at most 384px on the long side.
    public static func technical(_ cg: CGImage) -> Technical {
        let scale = min(1, 384 / CGFloat(max(cg.width, cg.height)))
        let w = max(3, Int(CGFloat(cg.width) * scale)), h = max(3, Int(CGFloat(cg.height) * scale))
        var g = [UInt8](repeating: 0, count: w * h)
        let drawn: Bool = g.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return Technical(sharpness: 0, clipped: 0, luma: 0.5, noise: 0) }
        var sum: Double = 0, sumSq: Double = 0
        var hist = [Int](repeating: 0, count: 1021)   // |Laplacian| ranges 0...1020
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let lap = Double(g[i - 1]) + Double(g[i + 1]) + Double(g[i - w]) + Double(g[i + w]) - 4 * Double(g[i])
                sum += lap
                sumSq += lap * lap
                hist[Int(abs(lap))] += 1
            }
        }
        let n = Double((w - 2) * (h - 2))
        let variance = sumSq / n - (sum / n) * (sum / n)
        let extremes = g.reduce(0) { $0 + ($1 <= 6 || $1 >= 249 ? 1 : 0) }
        let total = g.reduce(0) { $0 + Int($1) }
        var seen = 0, median = 0
        while median < hist.count - 1, seen + hist[median] < Int(n) / 2 { seen += hist[median]; median += 1 }
        return Technical(sharpness: Float(variance), clipped: Float(extremes) / Float(g.count),
                         luma: Float(total) / Float(g.count * 255), noise: Float(median))
    }

    static let coarseSide = 16

    /// A 16x16 colour thumbnail, each channel standardised to zero mean / unit variance.
    /// Downscaling washes out blur, shake and noise; standardising cancels exposure shifts.
    public static func coarseSignature(_ cg: CGImage) -> [Float] {
        let n = coarseSide
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard drawn else { return [] }
        var out = [Float](repeating: 0, count: n * n * 3)
        for ch in 0..<3 {
            let vals = (0..<(n * n)).map { Float(px[$0 * 4 + ch]) }
            let mean = vals.reduce(0, +) / Float(vals.count)
            let variance: Float = vals.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(vals.count)
            let sd = max(variance.squareRoot(), 4)
            for i in 0..<(n * n) { out[ch * n * n + i] = (vals[i] - mean) / sd }
        }
        return Clustering.normalized(out)
    }

    private static func floats(_ fp: VNFeaturePrintObservation) -> [Float] {
        fp.data.withUnsafeBytes { raw in
            switch fp.elementType {
            case .double: return raw.bindMemory(to: Double.self).map { Float($0) }
            default: return Array(raw.bindMemory(to: Float.self))
            }
        }
    }
}
