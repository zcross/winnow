import CoreImage
import Foundation
import WinnowCore

/// Deterministic RNG so datasets are reproducible.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Fakes a camera roll: each stock photo becomes a burst of retakes (good and
/// flawed variants a few seconds apart), with sessions separated by minutes to
/// hours. Filenames carry ground truth: g<group>_<n>_<variant>.jpg.
enum Synth {
    static let good = ["orig", "reframe", "brighter", "tilt", "zoom"]
    static let bad = ["blur", "shake", "dark", "noise", "blown"]
    static func isGood(_ variant: String) -> Bool { good.contains(variant) }

    /// `rounds` > 1 reuses each base photo for more sessions (different variants, hours apart),
    /// to fake a large trip backlog.
    static func generate(stock: URL, out: URL, rounds: Int = 1) -> Bool {
        var rng = SplitMix(state: 42)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        // picsum can hand out the same photo for different seeds; drop exact repeats.
        var seen = Set<Data>()
        let bases = ImageFiles.list(in: stock).sorted { $0.path < $1.path }.filter { url in
            guard let d = try? Data(contentsOf: url) else { return false }
            return seen.insert(d).inserted
        }

        let ctx = CIContext()
        var clock = Date(timeIntervalSince1970: 1_780_300_800) // 2026-06-01
        var written = 0
        let sessions = (0..<rounds).flatMap { _ in bases.shuffled(using: &rng) }
        for (gid, url) in sessions.enumerated() {
            guard let base = CIImage(contentsOf: url) else { continue }
            // Mostly hours-apart sessions, but sometimes a different scene only seconds later.
            clock += Double.random(in: 0..<1, using: &rng) < 0.2
                ? .random(in: 10...40, using: &rng) : .random(in: 180...14_400, using: &rng)

            let variants: [String]
            if Double.random(in: 0..<1, using: &rng) < 0.25 {
                variants = ["orig"]
            } else {
                let size = Int.random(in: 2...7, using: &rng)
                var pool = (good.dropFirst() + bad).shuffled(using: &rng)
                // Always one decent frame; the "orig" itself isn't guaranteed.
                var v = [Double.random(in: 0..<1, using: &rng) < 0.5 ? "orig" : good.randomElement(using: &rng)!]
                while v.count < size, let next = pool.popLast() { if !v.contains(next) { v.append(next) } }
                variants = v.shuffled(using: &rng)
            }

            for (k, variant) in variants.enumerated() {
                let img = apply(variant, to: base, rng: &rng)
                guard let cg = ctx.createCGImage(img, from: base.extent) else { continue }
                let name = String(format: "g%04d_%d_%@.jpg", gid, k, variant)
                if ImageFiles.writeJPEG(cg, to: out.appendingPathComponent(name), captureDate: clock) { written += 1 }
                clock += .random(in: 1...12, using: &rng)
            }
        }
        print("wrote \(written) images from \(bases.count) distinct bases to \(out.path)")
        return written > 0
    }

    /// Returns an image covering `base.extent`.
    static func apply(_ variant: String, to base: CIImage, rng: inout SplitMix) -> CIImage {
        let e = base.extent
        func cropScaled(_ frac: CGFloat, dx: CGFloat = 0, dy: CGFloat = 0) -> CIImage {
            let r = CGRect(x: e.midX - e.width * frac / 2 + dx * e.width, y: e.midY - e.height * frac / 2 + dy * e.height,
                           width: e.width * frac, height: e.height * frac)
            return base.cropped(to: r)
                .transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY).concatenating(.init(scaleX: 1 / frac, y: 1 / frac)))
        }
        func ev(_ v: Double) -> CIImage { base.applyingFilter("CIExposureAdjust", parameters: ["inputEV": v]) }

        switch variant {
        case "reframe": return cropScaled(0.88, dx: .random(in: -0.05...0.05, using: &rng), dy: .random(in: -0.05...0.05, using: &rng))
        case "zoom": return cropScaled(0.75)
        case "brighter": return ev(0.35)
        case "tilt":
            let a = CGFloat.random(in: 0.03...0.05, using: &rng) * (Bool.random(using: &rng) ? 1 : -1)
            let rotated = base.transformed(by: CGAffineTransform(translationX: -e.midX, y: -e.midY)
                .concatenating(.init(rotationAngle: a)).concatenating(.init(translationX: e.midX, y: e.midY)))
            return rotated.cropped(to: e.insetBy(dx: e.width * 0.06, dy: e.height * 0.06))
                .transformed(by: CGAffineTransform(translationX: -e.width * 0.06, y: -e.height * 0.06)
                    .concatenating(.init(scaleX: 1 / 0.88, y: 1 / 0.88)))
        case "blur": return base.clampedToExtent().applyingGaussianBlur(sigma: 7).cropped(to: e)
        case "shake":
            return base.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [
                "inputRadius": 18, "inputAngle": Double.random(in: 0...Double.pi, using: &rng),
            ]).cropped(to: e)
        case "dark": return ev(-1.8)
        case "blown": return ev(1.9)
        case "noise":
            let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: e)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0.35, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0.35, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0.35, w: 0), "inputBiasVector": CIVector(x: -0.17, y: -0.17, z: -0.17, w: 0),
                ])
            return noise.applyingFilter("CIAdditionCompositing", parameters: ["inputBackgroundImage": ev(-0.6)]).cropped(to: e)
        default: return base
        }
    }
}
