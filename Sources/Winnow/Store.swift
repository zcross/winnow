import Foundation
import WinnowCore

/// Files under ~/Library/Application Support/Winnow, or $WINNOW_DATA_DIR when set
/// (keeps dev and snapshot runs away from real decisions).
enum Store {
    static let dir: URL = {
        let d = ProcessInfo.processInfo.environment["WINNOW_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Winnow", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private static let analysesURL = dir.appendingPathComponent("analyses.plist")
    private static let decisionsURL = dir.appendingPathComponent("decisions.json")
    private static let editsURL = dir.appendingPathComponent("group-edits.json")

    static func loadEdits() -> GroupEdits {
        guard let data = try? Data(contentsOf: editsURL) else { return GroupEdits() }
        return (try? JSONDecoder().decode(GroupEdits.self, from: data)) ?? GroupEdits()
    }

    static func saveEdits(_ e: GroupEdits) {
        if let data = try? JSONEncoder().encode(e) { try? data.write(to: editsURL, options: .atomic) }
    }

    static func loadAnalyses() -> [String: Analysis] {
        guard let data = try? Data(contentsOf: analysesURL) else { return [:] }
        return (try? PropertyListDecoder().decode([String: Analysis].self, from: data)) ?? [:]
    }

    /// One serial queue so an older checkpoint can never land after a newer save.
    private static let saveQueue = DispatchQueue(label: "Winnow.Store.save", qos: .utility)

    static func saveAnalysesInBackground(_ a: [String: Analysis]) {
        saveQueue.async { saveAnalyses(a) }
    }

    static func saveAnalyses(_ a: [String: Analysis]) {
        let enc = PropertyListEncoder()
        enc.outputFormat = .binary
        if let data = try? enc.encode(a) { try? data.write(to: analysesURL, options: .atomic) }
    }

    /// localIdentifier -> keep (true) / reject (false)
    static func loadDecisions() -> [String: Bool] {
        guard let data = try? Data(contentsOf: decisionsURL) else { return [:] }
        return (try? JSONDecoder().decode([String: Bool].self, from: data)) ?? [:]
    }

    static func saveDecisions(_ d: [String: Bool]) {
        if let data = try? JSONEncoder().encode(d) { try? data.write(to: decisionsURL, options: .atomic) }
    }
}
