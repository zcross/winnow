import Foundation
import WinnowCore

/// Fast logic checks; returns the failure count.
func runUnitChecks() -> Int {
    var failures = 0
    func check(_ cond: Bool, _ msg: String, line: Int = #line) {
        if !cond { failures += 1; print("FAIL line \(line): \(msg)") }
    }

    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    func item(_ sec: Double, _ v: [Float]) -> ClusterInput {
        ClusterInput(date: t0.addingTimeInterval(sec), vector: Clustering.normalized(v))
    }
    let a: [Float] = [1, 0, 0], a2: [Float] = [0.95, 0.1, 0], b: [Float] = [0, 1, 0]
    let p = ClusterParams(maxGap: 60, threshold: 0.3)

    // Similar + close in time cluster; dissimilar or far-apart do not.
    var g = Clustering.groups([item(0, a), item(5, a2), item(10, b), item(500, a)], p)
    check(g == [[0, 1], [2], [3]], "basic grouping: \(g)")

    // Interleaved bursts (A B A B) still link across the gap.
    g = Clustering.groups([item(0, a), item(1, b), item(2, a2), item(3, b)], p)
    check(g == [[0, 2], [1, 3]], "interleaved: \(g)")

    // Chaining: each step within maxGap links the whole run.
    g = Clustering.groups((0..<5).map { item(Double($0) * 50, a) }, p)
    check(g == [[0, 1, 2, 3, 4]], "chain: \(g)")

    // Missing vectors stay singletons.
    g = Clustering.groups([item(0, a), ClusterInput(date: t0, vector: []), item(1, a)], p)
    check(g == [[0, 2], [1]], "empty vector: \(g)")

    check(abs(Clustering.distance(Clustering.normalized(a), Clustering.normalized(b)) - Float(2).squareRoot()) < 1e-5, "distance")

    // Coarse signature links a far-looking retake only when it's close in time.
    // All share a coarse signature; feature prints all differ. Only the pair 5s apart links.
    let fpFar = [item(0, a), item(5, b), item(500, [0, 0, 1])].map {
        ClusterInput(date: $0.date, vector: $0.vector, coarse: Clustering.normalized(a))
    }
    g = Clustering.groups(fpFar, ClusterParams(maxGap: 600, threshold: 0.3))
    check(g == [[0, 1], [2]], "coarse link: \(g)")
    check(ClusterParams(maxGap: 30, threshold: 0.5).coarseGap == 30, "coarse gap capped by maxGap")

    // Feature-print match vetoed when layouts are opposite (blurry shots of different scenes).
    let vetoed = [ClusterInput(date: t0, vector: Clustering.normalized(a), coarse: Clustering.normalized([1, 0])),
                  ClusterInput(date: t0.addingTimeInterval(5), vector: Clustering.normalized(a), coarse: Clustering.normalized([-1, 0]))]
    g = Clustering.groups(vetoed, ClusterParams(maxGap: 60, threshold: 0.3))
    check(g == [[0], [1]], "coarse veto: \(g)")

    // Ranking: a much softer sibling is flagged and ranked below a slightly less pretty sharp one.
    func an(_ score: Float, sharp: Float, luma: Float = 0.5) -> Analysis {
        Analysis(vector: [], coarse: [], score: score, sharpness: sharp, clipped: 0, luma: luma, noise: 4, isUtility: false)
    }
    let assessed = Ranking.assess([an(0.6, sharp: 5), an(0.5, sharp: 900), an(0.55, sharp: 800, luma: 0.2)])
    check(assessed[0].flaws == [.blurry] && assessed[1].flaws.isEmpty && assessed[2].flaws == [.dark], "flaws \(assessed.map(\.flaws))")
    check(Ranking.order(assessed.indices.map { _ in nil as Analysis? }, preferred: [false, true, false])[0] == 1, "favourite leads")
    let orderIdx = Ranking.order([an(0.6, sharp: 5), an(0.5, sharp: 900)], preferred: [false, false])
    check(orderIdx == [1, 0], "sharp beats soft: \(orderIdx)")
    check(Ranking.chosen(favorites: [false, false, true], albums: [["Best"], [], []]) == [true, false, true],
          "album pick within a burst counts")
    check(Ranking.chosen(favorites: [false, true, false], albums: [["Trip"], ["Trip"], ["Trip"]]) == [false, true, false],
          "album holding the whole burst is ignored")
    check(Ranking.chosen(favorites: [false, false, false], albums: [["Trip", "Best"], ["Trip"], ["Trip"]]) == [true, false, false],
          "best-of album still counts alongside a dump-everything trip album")

    // Pick rules: ranked best-first [2, 0, 3, 1] with scores by index.
    let sc: [Float] = [0.50, 0.10, 0.60, 0.45]
    check(Ranking.suggested(ranked: [2, 0, 3, 1], scores: sc, chosen: [], rules: PickRules()) == [2], "keep best")
    check(Ranking.suggested(ranked: [2, 0, 3, 1], scores: sc, chosen: [1], rules: PickRules(min: 2)) == [2, 0, 1],
          "keep 2 plus chosen")
    check(PickRules(fraction: 0.2).keepCount(groupSize: 3) == 1 && PickRules(fraction: 0.2).keepCount(groupSize: 30) == 6,
          "20% rounds up, at least 1")
    check(PickRules(fraction: 0.2, min: 2, max: 4).keepCount(groupSize: 5) == 2 &&
          PickRules(fraction: 0.2, min: 2, max: 4).keepCount(groupSize: 40) == 4, "clamped percentage")
    check(PickRules(min: 3).keepCount(groupSize: 2) == 2, "never more than the group")
    check(Ranking.suggested(ranked: [2, 0, 3, 1], scores: sc, chosen: [], rules: PickRules(max: 2, tieMargin: 0.16)) == [2, 0],
          "near-ties stop at the cap")
    check(Ranking.suggested(ranked: [2, 0, 3, 1], scores: sc, chosen: [], rules: PickRules(tieMargin: 0.16)) == [2, 0, 3],
          "near-ties within 0.16 of best")
    check(Ranking.margin([an(0.6, sharp: 900), an(0.5, sharp: 900), an(0.1, sharp: 900)], keepCount: 2) > 0.35,
          "margin after keeping 2")

    // Manual grouping edits
    let pos = Dictionary(uniqueKeysWithValues: ["a", "b", "c", "d", "e", "f"].enumerated().map { ($1, $0) })
    let auto = [["a", "b", "c", "d"], ["e"], ["f"]]
    var ed = GroupEdits()
    ed.split(auto[0], before: "c")
    check(ed.apply(to: auto, position: pos) == [["a", "b"], ["c", "d"], ["e"], ["f"]], "split \(ed.apply(to: auto, position: pos))")
    ed.merge(["c", "d"], ["f"])
    check(ed.apply(to: auto, position: pos) == [["a", "b"], ["c", "d", "f"], ["e"]], "merge across a one-off")
    ed.split(["c", "d", "f"], before: "f")
    check(ed.apply(to: auto, position: pos) == [["a", "b"], ["c", "d"], ["e"], ["f"]], "split drops the crossing merge")
    var det = GroupEdits()
    det.detach(auto[0], "b")
    check(det.apply(to: auto, position: pos) == [["a", "c", "d"], ["b"], ["e"], ["f"]],
          "detach one photo, the rest stays together: \(det.apply(to: auto, position: pos))")
    det.reset(["b", "c"])
    check(det.isEmpty, "reset clears edits on those photos")
    // Survives regrouping: same cut applied to a different automatic grouping.
    var cut = GroupEdits()
    cut.split(["a", "b", "c"], before: "c")
    check(cut.apply(to: [["a", "b", "c", "d", "e"], ["f"]], position: pos) == [["a", "b"], ["c", "d", "e"], ["f"]],
          "cut survives regrouping")

    // RAW+JPEG pairing
    let u = { (name: String) in URL(fileURLWithPath: "/roll/" + name) }
    let bundled = ImageFiles.bundle([
        u("IMG_1.CR3"), u("IMG_1.JPG"), u("IMG_1.CR3.xmp"),     // pair + RAW-named sidecar
        u("IMG_2.ARW"), u("IMG_2.xmp"),                          // RAW only + sidecar
        u("IMG_3.HEIC"), u("IMG_3.AAE"),                         // phone edit sidecar
        u("IMG_4.jpg"), u("IMG_4.heic"), u("IMG_4.dng"),         // two rendered: HEIC wins, JPG stands alone
        u("IMG_5.xmp"),                                          // stray sidecar dropped
        URL(fileURLWithPath: "/other/IMG_1.CR3"),                // same name, other folder: separate
    ])
    let byName = Dictionary(uniqueKeysWithValues: bundled.map { ($0.primary.path, $0) })
    check(bundled.count == 6, "bundle count \(bundled.count): \(bundled.map(\.primary.lastPathComponent))")
    check(byName["/roll/IMG_1.JPG"]?.companions.map(\.lastPathComponent) == ["IMG_1.CR3", "IMG_1.CR3.xmp"],
          "pair companions \(byName["/roll/IMG_1.JPG"]?.companions ?? [])")
    check(byName["/roll/IMG_1.JPG"]?.formatLabel == "RAW+JPEG", "pair label")
    check(byName["/roll/IMG_2.ARW"]?.companions.map(\.lastPathComponent) == ["IMG_2.xmp"] &&
          byName["/roll/IMG_2.ARW"]?.formatLabel == "RAW", "raw-only keeps sidecar")
    check(byName["/roll/IMG_3.HEIC"]?.companions.map(\.lastPathComponent) == ["IMG_3.AAE"] &&
          byName["/roll/IMG_3.HEIC"]?.formatLabel == nil, "heic + aae")
    check(byName["/roll/IMG_4.heic"]?.formatLabel == "RAW+HEIC" && byName["/roll/IMG_4.jpg"]?.companions == [],
          "extra rendered sibling stands alone")
    check(byName["/other/IMG_1.CR3"] != nil, "same name in another folder isn't paired")

    // Collisions in the rejects folder rename the whole set the same way.
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("winnow-check-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: tmp.appendingPathComponent("IMG_1.CR3").path, contents: Data())
    let dests = ImageFiles.destinations(for: [u("IMG_1.JPG"), u("IMG_1.CR3"), u("IMG_1.CR3.xmp")], in: tmp)
    check(dests.map(\.lastPathComponent) == ["IMG_1 2.JPG", "IMG_1 2.CR3", "IMG_1 2.CR3.xmp"], "collision rename \(dests.map(\.lastPathComponent))")
    try? FileManager.default.removeItem(at: tmp)

    // Apply outcome: a, b reviewed (keep a); c, d unreviewed; e unique; f, g part-reviewed after regrouping.
    let decided: [String: Bool] = ["a": true, "b": false, "f": false]
    let o = Outcome(order: ["a", "b", "c", "d", "e", "f", "g"], groups: [["a", "b"], ["c", "d"], ["f", "g"]],
                    decisions: decided, includeUnique: true)
    check(o.keepers == ["a", "c", "d", "e", "g"] && o.rejects == ["b", "f"] && o.unreviewed == ["c", "d", "g"] && o.unique == ["e"],
          "outcome \(o)")
    let noUnique = Outcome(order: ["a", "b", "e"], groups: [["a", "b"]], decisions: decided, includeUnique: false)
    check(noUnique.keepers == ["a"] && noUnique.unique == ["e"], "outcome without uniques")

    // Duel
    var d = Duel(ranked: ["p1", "p2", "p3", "p4"])!
    check(d.challenger == "p2", "first challenger")
    d.championWins()                       // p2 out
    d.challengerWins()                     // p3 beats p1
    check(d.champion == "p3" && d.challenger == "p4", "after two")
    d.keepBoth()                           // keep p3, p4 carries on
    check(d.isFinished && d.finalKeepers == ["p3", "p4"], "keepers \(d.finalKeepers)")
    d.undo()
    check(!d.isFinished && d.champion == "p3" && d.decided == 2, "undo")
    check(Duel<String>(ranked: []) == nil, "empty duel")
    var solo = Duel(ranked: ["only"])!
    check(solo.isFinished && solo.finalKeepers == ["only"], "single")
    solo.championWins()
    return failures
}
