import AppKit

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        // Winnow --snapshot <folder> <out-dir> [--apply-moves]: headless UI run for development
        // (see Snapshot.swift). --apply-moves really moves rejects, so only use it on a scratch copy.
        if let i = args.firstIndex(of: "--snapshot"), args.count > i + 2 {
            let ok = MainActor.assumeIsolated {
                Snapshot.run(folder: URL(fileURLWithPath: args[i + 1]), out: URL(fileURLWithPath: args[i + 2]),
                             applyMoves: args.contains("--apply-moves"))
            }
            exit(ok ? 0 : 1)
        }
        WinnowApp.main()
    }
}
