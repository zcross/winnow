import Foundation
import WinnowCore

// WinnowCheck            run logic checks
// WinnowCheck gen <stock-dir> <out-dir> [rounds]   build a synthetic burst dataset
// WinnowCheck eval <dir>                  analyse + cluster it and score against ground truth
let args = CommandLine.arguments
switch args.dropFirst().first {
case "gen" where args.count == 4 || args.count == 5:
    let rounds = args.count == 5 ? Int(args[4]) ?? 1 : 1
    exit(Synth.generate(stock: URL(fileURLWithPath: args[2]), out: URL(fileURLWithPath: args[3]), rounds: rounds) ? 0 : 1)
case "eval" where args.count == 3:
    await Eval.run(URL(fileURLWithPath: args[2]))
case "bench":
    // Clustering cost at library scale, with random unit vectors at burst-like spacing.
    var rng = SplitMix(state: 7)
    for n in [10_000, 50_000] {
        var t = Date(timeIntervalSince1970: 0)
        let inputs = (0..<n).map { _ -> ClusterInput in
            t += Double.random(in: 1...3, using: &rng)   // worst case: all bursts, full 40-neighbour window
            return ClusterInput(date: t, vector: Clustering.normalized((0..<768).map { _ in Float.random(in: -1...1, using: &rng) }),
                                coarse: Clustering.normalized((0..<768).map { _ in Float.random(in: -1...1, using: &rng) }))
        }
        let t0 = Date()
        let groups = Clustering.groups(inputs, ClusterParams(maxGap: 180, threshold: 0.65))
        print(String(format: "%6d photos: clustered in %.3fs (%d groups)", n, Date().timeIntervalSince(t0), groups.count))
    }
case nil:
    let failures = runUnitChecks()
    print(failures == 0 ? "all checks passed" : "\(failures) failure(s)")
    exit(failures == 0 ? 0 : 1)
default:
    print("usage: WinnowCheck [gen <stock> <out> | eval <dir>]")
    exit(2)
}
