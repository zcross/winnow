import Foundation
import WinnowCore

/// Scores the real pipeline against a Synth dataset.
enum Eval {
    struct Item {
        let group: String
        let variant: String
        let date: Date
        let analysis: Analysis
    }

    /// Same shape as the app's scan: a wide task group feeding the bounded Vision queue.
    static func analyzeAll(_ files: [URL]) async -> [Item] {
        await withTaskGroup(of: Item?.self) { group in
            for url in files {
                group.addTask {
                    let parts = url.deletingPathExtension().lastPathComponent.split(separator: "_")
                    guard parts.count == 3, let cg = ImageFiles.thumbnail(url, maxPixels: ImageAnalyzer.thumbnailPixels),
                          let a = await ImageAnalyzer.analyzeQueued(cg) else { return nil }
                    return Item(group: String(parts[0]), variant: String(parts[2]), date: ImageFiles.captureDate(url), analysis: a)
                }
            }
            var out: [Item] = []
            for await i in group { if let i { out.append(i) } }
            return out
        }
    }

    static func run(_ dir: URL) async {
        let files = ImageFiles.list(in: dir)
        var items: [Item] = []
        for width in [1, 2, 4, 8] {
            ImageAnalyzer.maxConcurrent = width
            let t0 = Date()
            items = await analyzeAll(files)
            let elapsed = Date().timeIntervalSince(t0)
            print(String(format: "Vision width %d: %d images in %.2fs (%.1f ms/image)",
                         width, items.count, elapsed, elapsed * 1000 / Double(max(items.count, 1))))
        }
        items.sort { $0.date < $1.date }

        distanceReport(items)

        let inputs = items.map { ClusterInput(date: $0.date, vector: $0.analysis.vector, coarse: $0.analysis.coarse) }
        for (label, coarseGap) in [("feature print only", 0.0), ("feature print + coarse", 60.0)] {
            print("\n\(label)\nthreshold  precision  recall   F1     exact-groups")
            for t in stride(from: Float(0.35), through: 0.85, by: 0.05) {
                let groups = Clustering.groups(inputs, ClusterParams(maxGap: 180, threshold: t, coarseGap: coarseGap))
                let (p, r, exact) = score(groups, items)
                let f1 = 2 * p * r / max(p + r, 1e-9)
                print(String(format: "  %.2f      %.3f      %.3f   %.3f   %d/%d", t, p, r, f1, exact, Set(items.map(\.group)).count))
            }
        }

        print("\nfalse links at 0.65 (different scenes, would link):")
        for i in items.indices {
            for j in (i + 1)..<min(items.count, i + 41) {
                let dt = items[j].date.timeIntervalSince(items[i].date)
                guard dt <= 180, items[i].group != items[j].group else { continue }
                let d = Clustering.distance(items[i].analysis.vector, items[j].analysis.vector)
                let dc = Clustering.distance(items[i].analysis.coarse, items[j].analysis.coarse)
                if d <= 0.65 || (dt <= 60 && dc <= 0.585) {
                    print(String(format: "  %@ %@ ~ %@ %@  dt %.0fs  fp %.2f  coarse %.2f", items[i].group, items[i].variant,
                                 items[j].group, items[j].variant, dt, d, dc))
                }
            }
        }

        print("\ncoarse window @0.65   precision  recall   exact-groups")
        for cg in [10.0, 15.0, 20.0, 30.0, 60.0] {
            let groups = Clustering.groups(inputs, ClusterParams(maxGap: 180, threshold: 0.65, coarseGap: cg))
            let (p, r, exact) = score(groups, items)
            print(String(format: "  %3.0fs                %.3f      %.3f   %d", cg, p, r, exact))
        }

        // Does the top aesthetics score land on a decent frame?
        var byGroup: [String: [Item]] = [:]
        for i in items { byGroup[i.group, default: []].append(i) }
        let mixed = byGroup.values.filter { g in g.contains { Synth.isGood($0.variant) } && g.contains { !Synth.isGood($0.variant) } }
        for (label, adjusted) in [("aesthetics only", false), ("aesthetics + technical", true)] {
            var misses: [[Item]] = []
            for g in mixed {
                let best = adjusted ? g[Ranking.order(g.map(\.analysis), preferred: g.map { _ in false })[0]]
                    : g.max { $0.analysis.score < $1.analysis.score }!
                if !Synth.isGood(best.variant) { misses.append(g) }
            }
            print("\n\(label): best pick is a good frame in \(mixed.count - misses.count)/\(mixed.count) mixed groups")
            for g in misses {
                let adj = Ranking.adjustedScores(g.map(\.analysis))
                print("  miss \(g[0].group): " + zip(g, adj).sorted { $0.1 > $1.1 }
                    .map { String(format: "%@ %+.2f", $0.0.variant, $0.1) }.joined(separator: ", "))
            }
        }

        // Auto-accept: how many groups clear the margin, and how often their pick is a good frame.
        let multi = byGroup.values.filter { $0.count > 1 && $0.contains { Synth.isGood($0.variant) } }
        print("\nauto-accept margin   easy groups   pick is good")
        for m: Float in [0.05, 0.10, 0.15, 0.20, 0.30] {
            let easy = multi.filter { Ranking.margin($0.map(\.analysis)) >= m }
            let good = easy.filter { g in Synth.isGood(g[Ranking.order(g.map(\.analysis), preferred: g.map { _ in false })[0]].variant) }
            print(String(format: "  %.2f%@           %3d/%d (%2.0f%%)   %d/%d", m, m == Ranking.easyMargin ? "*" : " ",
                         easy.count, multi.count, 100 * Double(easy.count) / Double(max(multi.count, 1)), good.count, easy.count))
        }

        print("\nwithin-group technical stats by variant (a = sharpness ratio | noise ratio to group min (ranking uses median); b = clipped | luma ratio to median):")
        var tech: [String: [(Float, Float)]] = [:]
        for g in byGroup.values where g.count > 1 {
            let maxSharp = g.map(\.analysis.sharpness).max()!
            let minNoise = max(g.map(\.analysis.noise).min()!, 1)
            let medLuma = g.map(\.analysis.luma).sorted()[g.count / 2]
            for i in g {
                tech[i.variant, default: []].append((i.analysis.sharpness / max(maxSharp, 1e-6), i.analysis.clipped))
                tech[i.variant + " noise×", default: []].append((i.analysis.noise / minNoise, i.analysis.luma / max(medLuma, 0.05)))
            }
        }
        for (v, xs) in tech.sorted(by: { $0.key < $1.key }) {
            let r = xs.map(\.0).sorted(), c = xs.map(\.1).sorted()
            print(String(format: "  %-15@ a p10 %.2f p50 %.2f p90 %.2f   b p50 %.3f p90 %.3f",
                         v, r[r.count / 10], r[r.count / 2], r[r.count * 9 / 10], c[c.count / 2], c[c.count * 9 / 10]))
        }

        print("\nmean aesthetics score by variant:")
        var byVariant: [String: [Float]] = [:]
        for i in items { byVariant[i.variant, default: []].append(i.analysis.score) }
        let means: [String: Float] = byVariant.mapValues { $0.reduce(0, +) / Float($0.count) }
        for (v, mean) in means.sorted(by: { $0.value > $1.value }) {
            print(String(format: "  %-9@ %+.3f  (n=%d)%@", v, mean, byVariant[v]!.count, Synth.isGood(v) ? "" : "  flawed"))
        }
    }

    /// How far apart same-scene retakes are, versus different scenes shot close together.
    static func distanceReport(_ items: [Item]) {
        var buckets: [String: [Float]] = [:], coarse: [String: [Float]] = [:]
        for i in items.indices {
            for j in (i + 1)..<items.count {
                let (a, b) = (items[i], items[j])
                let dt = abs(b.date.timeIntervalSince(a.date))
                let d = Clustering.distance(a.analysis.vector, b.analysis.vector)
                let dc = Clustering.distance(a.analysis.coarse, b.analysis.coarse)
                func add(_ k: String) { buckets[k, default: []].append(d); coarse[k, default: []].append(dc) }
                if a.group == b.group {
                    let kind = Synth.isGood(a.variant) && Synth.isGood(b.variant) ? "same scene, good-good"
                        : Synth.isGood(a.variant) || Synth.isGood(b.variant) ? "same scene, good-flawed" : "same scene, flawed-flawed"
                    add(kind)
                    if Synth.isGood(a.variant) != Synth.isGood(b.variant) {
                        add("  good vs " + (Synth.isGood(a.variant) ? b.variant : a.variant))
                    }
                } else if dt <= 180 {
                    add("different scenes <=3min apart")
                } else {
                    add("different scenes, any time")
                }
            }
        }
        func q(_ a: [Float], _ p: Double) -> Float { let s = a.sorted(); return s[min(s.count - 1, Int(Double(s.count) * p))] }
        for (title, b) in [("feature print", buckets), ("coarse signature", coarse)] {
            print("\n\(title) distance quantiles".padding(toLength: 33, withPad: " ", startingAt: 0) + "n     min    p10    p50    p90    max")
            for (k, v) in b.sorted(by: { $0.key < $1.key }) {
                print(String(format: "  %-29@ %5d   %.2f   %.2f   %.2f   %.2f   %.2f", k, v.count, v.min()!, q(v, 0.1), q(v, 0.5), q(v, 0.9), v.max()!))
            }
        }
    }

    /// Pairwise precision/recall plus how many true groups came out exactly right.
    static func score(_ groups: [[Int]], _ items: [Item]) -> (Double, Double, Int) {
        var label = [Int](repeating: 0, count: items.count)
        for (c, g) in groups.enumerated() { for i in g { label[i] = c } }
        var tp = 0, fp = 0, fn = 0
        for i in items.indices {
            for j in (i + 1)..<items.count {
                let same = items[i].group == items[j].group, pred = label[i] == label[j]
                if same && pred { tp += 1 } else if pred { fp += 1 } else if same { fn += 1 }
            }
        }
        let truth = Dictionary(grouping: items.indices, by: { items[$0].group }).values.map { Set($0) }
        let predicted = Set(groups.map { Set($0) })
        let exact = truth.filter { predicted.contains($0) }.count
        return (Double(tp) / Double(max(tp + fp, 1)), Double(tp) / Double(max(tp + fn, 1)), exact)
    }
}
