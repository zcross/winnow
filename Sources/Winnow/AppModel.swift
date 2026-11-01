import AppKit
import Photos
import SwiftUI
import UniformTypeIdentifiers
import WinnowCore

struct Photo {
    let id: String
    let date: Date
    let isFavorite: Bool
    let analysis: Analysis?
}

struct Cluster: Identifiable, Hashable {
    let members: [String]   // time order
    var id: String { members[0] }
}

enum Source: Equatable {
    case photos
    case folder(URL)

    var isPhotos: Bool { self == .photos }
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable { case idle, scanning(done: Int, total: Int), ready }
    enum Mode: String, CaseIterable { case grid = "Grid", duel = "Duel" }

    // Scan setup
    @Published var source: Source = .photos
    @Published var startDate = Calendar.current.date(byAdding: .month, value: -1, to: .now)!
    @Published var endDate = Date.now
    @Published var includeScreenshots = false
    /// Your Photos albums; loaded on demand (needs library access).
    @Published var albums: [PhotosLibrary.Album] = []
    /// Scan one album instead of a date range.
    @Published var useAlbum = false {
        didSet { if useAlbum && albums.isEmpty { Task { await loadAlbums() } } }
    }
    @Published var albumID: String?
    @Published private(set) var phase: Phase = .idle
    @Published var errorMessage: String?

    // Grouping knobs (applied on slider release). Defaults sit mid-plateau of WinnowCheck eval.
    @Published var maxGapMinutes = UserDefaults.standard.object(forKey: "maxGapMinutes") as? Double ?? 3 {
        didSet { UserDefaults.standard.set(maxGapMinutes, forKey: "maxGapMinutes") }
    }
    @Published var threshold = UserDefaults.standard.object(forKey: "threshold") as? Double ?? 0.65 {
        didSet { UserDefaults.standard.set(threshold, forKey: "threshold") }
    }

    // Pick rules: keep clamp(⌈percent × group⌉, keepMin, keepMax) per group.
    @Published var keepPercent = UserDefaults.standard.double(forKey: "keepPercent") {
        didSet { UserDefaults.standard.set(keepPercent, forKey: "keepPercent"); pickRulesChanged() }
    }
    @Published var keepMin = max(1, UserDefaults.standard.integer(forKey: "keepMin")) {
        didSet {
            if keepMax > 0 && keepMax < keepMin { keepMax = keepMin }
            UserDefaults.standard.set(keepMin, forKey: "keepMin"); pickRulesChanged()
        }
    }
    /// 0 = no cap.
    @Published var keepMax = UserDefaults.standard.integer(forKey: "keepMax") {
        didSet {
            if keepMax > 0 && keepMax < keepMin { keepMin = keepMax }
            UserDefaults.standard.set(keepMax, forKey: "keepMax"); pickRulesChanged()
        }
    }
    @Published var tieMargin = UserDefaults.standard.double(forKey: "tieMargin") {
        didSet { UserDefaults.standard.set(tieMargin, forKey: "tieMargin"); pickRulesChanged() }
    }

    @Published private(set) var photos: [String: Photo] = [:]
    @Published private(set) var clusters: [Cluster] = []
    @Published private(set) var singletonCount = 0
    @Published private(set) var decisions: [String: Bool] = Store.loadDecisions()

    // Review state for the selected cluster
    @Published var selectedID: Cluster.ID? { didSet { if selectedID != oldValue { prepareReview() } } }
    @Published var mode: Mode = .grid { didSet { if mode != oldValue { prepareReview() } } }
    @Published var draft: [String: Bool] = [:]
    @Published var focus = 0
    @Published var duel: Duel<String>?
    @Published var zoomID: String? { didSet { if zoomID == nil { zoom = 1 } } }
    /// Magnification for duel and the Space viewer (Z toggles); `zoomCenter` follows the pointer.
    @Published var zoom: CGFloat = 1
    @Published var zoomCenter = UnitPoint.center
    @Published var showApply = false
    @Published var confirmForget = false
    @Published var showHelp = false
    @Published var hideDone = false
    /// F toggles a sidebar-free focus view.
    @Published var columns: NavigationSplitViewVisibility = .all
    @Published private(set) var busy = false
    /// Photos whose decision came from "Accept obvious" rather than a look.
    @Published private(set) var autoAccepted: Set<String> = []
    @Published private(set) var canUndo = false

    private(set) var refs: [String: PhotoRef] = [:]
    /// Folder photos: the RAW half of a pair and sidecars, moved along with the primary.
    private var companions: [String: [URL]] = [:]
    /// Library photo id -> titles of your albums it's in (other than the one being scanned).
    private var albumsOf: [String: [String]] = [:]
    /// "RAW+JPEG" / "RAW" tags; folder ones known at scan, library ones looked up on first view.
    private var formats: [String: String?] = [:]
    private var order: [String] = []
    private var analyses: [String: Analysis]?
    private var bestCache: [Cluster.ID: [String]] = [:]
    private var marginCache: [Cluster.ID: Float] = [:]
    private var assessCache: [Cluster.ID: [String: Ranking.Assessment]] = [:]

    /// Each entry restores the previous decision (nil = undecided) of every photo it touched.
    private struct UndoStep {
        var previous: [String: Bool?] = [:]
        var selected: Cluster.ID?
        var auto: Set<String> = []
        /// Set when the step was a grouping edit.
        var edits: GroupEdits?
    }

    /// Manual splits and merges; applied on top of automatic grouping every time it runs.
    @Published private(set) var edits = Store.loadEdits()
    private var undoStack: [UndoStep] = [] { didSet { canUndo = !undoStack.isEmpty } }
    private var commitTimes: [Date] = []

    // MARK: Scan

    private struct Candidate {
        let id: String
        let cacheKey: String
        let ref: PhotoRef
        let date: Date
        let isFavorite: Bool
        var companions: [URL] = []
        var format: String?
    }

    private var scanTask: Task<Void, Never>?

    func startScan() {
        guard scanTask == nil else { return }
        scanTask = Task {
            await scan()
            scanTask = nil
        }
    }

    /// Stops after in-flight photos finish; everything analysed so far stays cached.
    func cancelScan() { scanTask?.cancel() }

    func scan() async {
        let previousPhase = phase == .ready ? Phase.ready : .idle
        guard let candidates = await gatherCandidates() else { phase = previousPhase; return }

        // Album membership is independent of analysis; look it up meanwhile.
        let membership: Task<[String: [String]], Never>? = source.isPhotos
            ? Task { [scanned = useAlbum ? albumID : nil] in
                await PhotosLibrary.membership(of: Set(candidates.map(\.id)), excluding: scanned)
            }
            : nil

        phase = .scanning(done: 0, total: candidates.count)
        if analyses == nil { analyses = await Task.detached { Store.loadAnalyses() }.value }
        var cache = analyses!
        let todo = candidates.filter { cache[$0.cacheKey] == nil }
        var done = candidates.count - todo.count
        phase = .scanning(done: done, total: candidates.count)

        // Thumbnail decode overlaps with Vision; ImageAnalyzer bounds the Vision side itself.
        await withTaskGroup(of: (String, Analysis?).self) { group in
            var it = todo.makeIterator()
            func enqueue() {
                guard let c = it.next() else { return }
                group.addTask { (c.cacheKey, await Analyzer.analyze(c.ref)) }
            }
            for _ in 0..<16 { enqueue() }
            for await (key, result) in group {
                if let result { cache[key] = result }
                done += 1
                if done % 16 == 0 { phase = .scanning(done: done, total: candidates.count) }
                if done % 500 == 0 { Store.saveAnalysesInBackground(cache) }
                if !Task.isCancelled { enqueue() }
            }
        }
        analyses = cache
        if !todo.isEmpty { Store.saveAnalysesInBackground(cache) }
        if Task.isCancelled { membership?.cancel(); phase = previousPhase; return }
        albumsOf = await membership?.value ?? [:]

        refs = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0.ref) })
        companions = Dictionary(uniqueKeysWithValues: candidates.filter { !$0.companions.isEmpty }.map { ($0.id, $0.companions) })
        formats = source.isPhotos ? [:] : Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0.format) })
        order = candidates.map(\.id)
        photos = Dictionary(uniqueKeysWithValues: candidates.map {
            ($0.id, Photo(id: $0.id, date: $0.date, isFavorite: $0.isFavorite, analysis: cache[$0.cacheKey]))
        })
        phase = .ready
        selectedID = nil
        recluster()
    }

    /// Time-ordered photos to consider, or nil if the source can't be read.
    private func gatherCandidates() async -> [Candidate]? {
        switch source {
        case .photos:
            guard await ensurePhotosAccess() else { return nil }
            phase = .scanning(done: 0, total: 0)
            let items: [PhotosLibrary.Item]
            if useAlbum {
                guard let albumID else { errorMessage = "Pick an album to scan."; return nil }
                items = await PhotosLibrary.images(inAlbum: albumID, includeScreenshots: includeScreenshots)
            } else {
                let cal = Calendar.current
                let start = cal.startOfDay(for: startDate)
                let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: endDate))!
                items = await PhotosLibrary.images(from: start, to: end, includeScreenshots: includeScreenshots)
            }
            return items.map {
                Candidate(id: $0.asset.localIdentifier, cacheKey: $0.asset.localIdentifier, ref: .asset($0.asset),
                          date: $0.date, isFavorite: $0.asset.isFavorite)
            }

        case let .folder(dir):
            phase = .scanning(done: 0, total: 0)
            return await Task.detached {
                ImageFiles.files(in: dir).map { f in
                    Candidate(id: f.primary.path, cacheKey: "file:\(f.primary.path)@\(ImageFiles.modificationStamp(f.primary))",
                              ref: .file(f.primary), date: ImageFiles.captureDate(f.primary), isFavorite: false,
                              companions: f.companions, format: f.formatLabel)
                }
                .sorted { $0.date < $1.date }
            }.value
        }
    }

    private func ensurePhotosAccess() async -> Bool {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        guard status == .authorized || status == .limited else {
            errorMessage = "Winnow needs Photos access. Enable it in System Settings › Privacy & Security › Photos."
            return false
        }
        return true
    }

    func loadAlbums() async {
        guard await ensurePhotosAccess() else { return }
        albums = await PhotosLibrary.albums()
        if !albums.contains(where: { $0.id == albumID }) { albumID = albums.first?.id }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url { source = .folder(url) }
    }

    func recluster() {
        let inputs = order.map { id in
            ClusterInput(date: photos[id]!.date, vector: photos[id]!.analysis?.vector ?? [],
                         coarse: photos[id]!.analysis?.coarse ?? [])
        }
        let params = ClusterParams(maxGap: maxGapMinutes * 60, threshold: Float(threshold))
        let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        let groups = edits.apply(to: Clustering.groups(inputs, params).map { $0.map { order[$0] } }, position: position)
        clusters = groups.filter { $0.count > 1 }.map { Cluster(members: $0) }
        singletonCount = groups.count - clusters.count
        bestCache = [:]
        marginCache = [:]
        assessCache = [:]
        if selectedID == nil || !clusters.contains(where: { $0.id == selectedID }) {
            selectedID = clusters.first(where: { !isReviewed($0) })?.id ?? clusters.first?.id
        }
    }

    // MARK: Review

    var current: Cluster? { clusters.first { $0.id == selectedID } }

    func isReviewed(_ c: Cluster) -> Bool { c.members.allSatisfy { decisions[$0] != nil } }

    var reviewedCount: Int { clusters.filter(isReviewed).count }

    /// Best-first: favourites, then aesthetics adjusted for softness/clipping relative to siblings.
    func ranked(_ c: Cluster) -> [String] {
        if let hit = bestCache[c.id] { return hit }
        let keep = chosen(c)
        let idx = Ranking.order(c.members.map { photos[$0]?.analysis }, preferred: c.members.map(keep.contains))
        let r = idx.map { c.members[$0] }
        bestCache[c.id] = r
        return r
    }

    func best(_ c: Cluster) -> String { ranked(c)[0] }

    /// Adjusted score and flaws of each analysed member, relative to its siblings.
    private func assessment(_ c: Cluster) -> [String: Ranking.Assessment] {
        if let hit = assessCache[c.id] { return hit }
        let known = c.members.filter { photos[$0]?.analysis != nil }
        let a = Dictionary(uniqueKeysWithValues: zip(known, Ranking.assess(known.map { photos[$0]!.analysis! })))
        assessCache[c.id] = a
        return a
    }

    /// What makes each photo worse than its siblings (blurry, blown, ...).
    func flaws(_ id: String, in c: Cluster) -> [Ranking.Flaw] { assessment(c)[id]?.flaws ?? [] }

    /// Frames you've already singled out: favourites, and album picks when the album took only some of the burst.
    func chosen(_ c: Cluster) -> Set<String> {
        let flags = Ranking.chosen(favorites: c.members.map { photos[$0]?.isFavorite ?? false },
                                   albums: c.members.map { Set(albumsOf[$0] ?? []) })
        return Set(zip(c.members, flags).filter(\.1).map(\.0))
    }

    func albumTitles(_ id: String) -> [String] { albumsOf[id] ?? [] }

    var pickRules: PickRules {
        PickRules(fraction: Float(keepPercent / 100), min: keepMin, max: keepMax > 0 ? keepMax : nil, tieMargin: Float(tieMargin))
    }

    /// e.g. "1", "20%, at least 1", "20%, 2–4".
    var pickRulesSummary: String {
        let cap = keepMax > 0 ? keepMax : nil
        if keepPercent < 0.5 { return "best \(keepMin)" }
        let pct = "\(Int(keepPercent.rounded()))%"
        if let cap { return "\(pct), \(keepMin)–\(cap)" }
        return "\(pct), at least \(keepMin)"
    }

    private func suggestion(_ c: Cluster) -> [String: Bool] {
        let index = Dictionary(uniqueKeysWithValues: c.members.enumerated().map { ($1, $0) })
        let scores = c.members.map { assessment(c)[$0]?.score ?? -.infinity }
        let keep = Ranking.suggested(ranked: ranked(c).map { index[$0]! }, scores: scores,
                                     chosen: Set(chosen(c).map { index[$0]! }), rules: pickRules)
        return Dictionary(uniqueKeysWithValues: c.members.enumerated().map { ($1, keep.contains($0)) })
    }

    /// New rules re-suggest the open group (if you haven't decided it) and change what counts as obvious.
    private func pickRulesChanged() {
        marginCache = [:]
        if let c = current, duel == nil, !c.members.contains(where: { decisions[$0] != nil }) {
            draft = suggestion(c)
        }
    }

    private func prepareReview() {
        zoomID = nil
        zoom = 1
        focus = 0
        guard let c = current else { draft = [:]; duel = nil; return }
        let suggested = suggestion(c)
        draft = Dictionary(uniqueKeysWithValues: c.members.map { ($0, decisions[$0] ?? suggested[$0]!) })
        duel = mode == .duel ? Duel(ranked: ranked(c)) : nil
        prefetchDuel()
    }

    func toggle(_ id: String) { draft[id]?.toggle() }

    func keepOnlyBest() { if let c = current { draft = suggestion(c) } }

    func keepAll() { for k in draft.keys { draft[k] = true } }

    func commit() {
        guard let c = current else { return }
        record(c.members)
        for id in c.members {
            decisions[id] = draft[id] ?? false
            autoAccepted.remove(id)
        }
        Store.saveDecisions(decisions)
        commitTimes.append(.now)
        advance()
    }

    private func record(_ ids: [String], auto: Set<String> = []) {
        undoStack.append(UndoStep(previous: Dictionary(uniqueKeysWithValues: ids.map { ($0, decisions[$0]) }),
                                  selected: selectedID, auto: auto))
        if undoStack.count > 200 { undoStack.removeFirst() }
    }

    /// Reverts the last commit or bulk accept and goes back to where it happened.
    func undo() {
        guard let step = undoStack.popLast() else { return }
        if let old = step.edits {
            changeEdits(to: old, focusOn: step.selected)
            return
        }
        for (id, old) in step.previous { decisions[id] = old }
        autoAccepted.subtract(step.auto)
        Store.saveDecisions(decisions)
        if !commitTimes.isEmpty, step.auto.isEmpty { commitTimes.removeLast() }
        if let sel = step.selected, clusters.contains(where: { $0.id == sel }) {
            if selectedID == sel { prepareReview() } else { selectedID = sel }
        }
    }

    // MARK: Grouping edits

    /// Splits the open group just before the focused photo (`\`).
    func splitAtFocus() {
        guard let c = current, focus > 0, focus < c.members.count else { return }
        var e = edits
        e.split(c.members, before: c.members[focus])
        recordEdit(e, focusOn: c.members[focus])
    }

    /// Takes the focused photo out of the group on its own (`-`).
    func detachFocused() {
        guard let c = current, focus < c.members.count else { return }
        let photo = c.members[focus]
        var e = edits
        e.detach(c.members, photo)
        recordEdit(e, focusOn: c.members.first { $0 != photo })
    }

    /// Joins the open group with the next one (`M`).
    func mergeWithNext() {
        guard let i = clusters.firstIndex(where: { $0.id == selectedID }), i + 1 < clusters.count else { return }
        var e = edits
        e.merge(clusters[i].members, clusters[i + 1].members)
        recordEdit(e, focusOn: clusters[i].id)
    }

    func resetEditsForCurrent() {
        guard let c = current else { return }
        var e = edits
        e.reset(Set(c.members))
        recordEdit(e, focusOn: c.id)
    }

    func resetAllEdits() { recordEdit(GroupEdits(), focusOn: selectedID) }

    private func recordEdit(_ new: GroupEdits, focusOn photo: String?) {
        guard new != edits else { return }
        undoStack.append(UndoStep(selected: selectedID, edits: edits))
        changeEdits(to: new, focusOn: photo)
    }

    /// Regroups with `new` edits and opens the group holding `photo`.
    private func changeEdits(to new: GroupEdits, focusOn photo: String?) {
        edits = new
        Store.saveEdits(new)
        let previous = selectedID
        recluster()
        let target = clusters.first { c in photo.map(c.members.contains) ?? false }?.id ?? previous
        if let target, clusters.contains(where: { $0.id == target }) { selectedID = target }
        prepareReview()
        if let photo, let c = current, let i = c.members.firstIndex(of: photo) { focus = i }
    }

    // MARK: Backlog

    /// How clearly the suggested pick beats the runner-up.
    func margin(_ c: Cluster) -> Float {
        if let hit = marginCache[c.id] { return hit }
        let m = Ranking.margin(c.members.compactMap { photos[$0]?.analysis },
                               keepCount: pickRules.keepCount(groupSize: c.members.count))
        marginCache[c.id] = m
        return m
    }

    var obviousClusters: [Cluster] {
        clusters.filter { !isReviewed($0) && margin($0) >= Ranking.easyMargin }
    }

    /// Accepts the suggestion for every unreviewed group with a clear winner, as one undo step.
    func acceptObvious() {
        let batch = obviousClusters
        guard !batch.isEmpty else { return }
        let ids = batch.flatMap(\.members)
        record(ids, auto: Set(ids))
        for c in batch {
            for (id, keep) in suggestion(c) { decisions[id] = keep }
        }
        autoAccepted.formUnion(ids)
        Store.saveDecisions(decisions)
        if let c = current, isReviewed(c) { advance() } else { prepareReview() }
    }

    struct DaySection {
        let day: Date
        var clusters: [Cluster] = []   // visible ones
        var total = 0
        var done = 0
    }

    /// Groups bucketed by the calendar day of their first shot, in one pass.
    var days: [DaySection] {
        let cal = Calendar.current
        var out: [DaySection] = []
        for c in clusters {
            let day = cal.startOfDay(for: photos[c.id]?.date ?? .distantPast)
            if out.last?.day != day { out.append(DaySection(day: day)) }
            let reviewed = isReviewed(c)
            out[out.count - 1].total += 1
            if reviewed { out[out.count - 1].done += 1 }
            if !hideDone || !reviewed || c.id == selectedID { out[out.count - 1].clusters.append(c) }
        }
        return out.filter { !$0.clusters.isEmpty }
    }

    var position: Int? { clusters.firstIndex { $0.id == selectedID }.map { $0 + 1 } }

    var rejectCount: Int { rejects.count }

    /// Time left at the recent pace; ignores breaks longer than a minute.
    var remainingEstimate: String? {
        let gaps = zip(commitTimes.suffix(21), commitTimes.suffix(20)).map { $1.timeIntervalSince($0) }.filter { $0 < 60 }
        guard gaps.count >= 3 else { return nil }
        let left = Double(clusters.count - reviewedCount) * gaps.reduce(0, +) / Double(gaps.count)
        if left < 60 { return "under a minute left" }
        return Duration.seconds(left).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)) + " left"
    }

    func advance() {
        guard let i = clusters.firstIndex(where: { $0.id == selectedID }) else { return }
        let rotated = clusters[(i + 1)...] + clusters[..<i]
        selectedID = rotated.first(where: { !isReviewed($0) })?.id ?? (isReviewed(clusters[i]) ? nil : selectedID)
        // Warm the group after this one so the next Return feels instant.
        if let j = clusters.firstIndex(where: { $0.id == selectedID }), j + 1 < clusters.count {
            ImageLoader.shared.prefetch(clusters[j + 1].members.compactMap { refs[$0] }, pixels: 640)
        }
    }

    func duelStep(_ step: (inout Duel<String>) -> Void) {
        guard var d = duel else { return }
        step(&d)
        duel = d
        if d.isFinished, let c = current {
            let keep = d.finalKeepers
            draft = Dictionary(uniqueKeysWithValues: c.members.map { ($0, keep.contains($0)) })
        }
        prefetchDuel()
    }

    static let duelPixels: CGFloat = 1600

    private func prefetchDuel() {
        guard let d = duel else { return }
        ImageLoader.shared.prefetch(d.upcoming.compactMap { refs[$0] }, pixels: Self.duelPixels)
    }

    // MARK: Keyboard

    func handleKey(_ e: NSEvent) -> Bool {
        guard !showApply else { return false }
        let cmd = e.modifierFlags.contains(.command)
        let chars = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if !cmd, chars == "?" || (showHelp && e.keyCode == 53) { showHelp.toggle(); return true }
        if showHelp { return false }
        if cmd, chars == "z" {
            if duel?.canUndo == true, duel?.isFinished == false { duelStep { $0.undo() } } else { undo() }
            return true
        }
        guard !cmd, current != nil else { return false }

        if zoomID != nil, e.keyCode == 49 || e.keyCode == 53 { zoomID = nil; return true }
        if chars == "z", zoomID != nil || (duel.map { !$0.isFinished } ?? false) {
            zoom = zoom > 1 ? 1 : 3
            return true
        }

        switch (e.keyCode, chars) {
        case (36, _), (76, _):                 // return / enter
            if duel == nil || duel!.isFinished { commit(); return true }
        case (48, _), (_, "s"): advance(); return true    // tab: skip
        case (_, "f"): columns = columns == .detailOnly ? .all : .detailOnly; return true
        case (_, "\\"): splitAtFocus(); return true
        case (_, "-"): detachFocused(); return true
        case (_, "m"): mergeWithNext(); return true
        case (_, "g"): mode = .grid; return true
        case (_, "d"): mode = .duel; return true
        default: break
        }

        if let d = duel, !d.isFinished {
            switch (e.keyCode, chars) {
            case (123, _): duelStep { $0.championWins() }; return true
            case (124, _): duelStep { $0.challengerWins() }; return true
            case (125, _), (_, "b"): duelStep { $0.keepBoth() }; return true
            case (_, "u"): duelStep { $0.undo() }; return true
            default: return false
            }
        }
        if duel != nil, chars == "u" { duelStep { $0.undo() }; return true }

        // Grid
        guard let c = current else { return false }
        switch (e.keyCode, chars) {
        case (123, _): focus = max(0, focus - 1); return true
        case (124, _): focus = min(c.members.count - 1, focus + 1); return true
        case (49, _): zoomID = c.members[focus]; return true
        case (_, "x"), (_, "k"): toggle(c.members[focus]); return true
        case (_, "1"...("9")):
            let i = Int(chars)! - 1
            if i < c.members.count { toggle(c.members[i]); focus = i }
            return true
        case (_, "o"): keepOnlyBest(); return true
        case (_, "a"): keepAll(); return true
        default: return false
        }
    }

    // MARK: Apply

    /// Decisions limited to photos in the current scan.
    var rejects: [String] { decisions.filter { !$0.value && refs[$0.key] != nil }.map(\.key) }
    /// Rejects you'd filed in an album: deleting them removes them from those albums too.
    var rejectsInAlbums: Int { rejects.filter { albumsOf[$0] != nil }.count }

    // The plan: what happens to keepers, and what happens to leftovers.
    enum Leftovers: String, CaseIterable {
        case leave, collect, removeFromAlbum, delete
    }

    // Plan choices persist between launches (the album name follows each scan instead).
    @Published var keepersToCollection = UserDefaults.standard.object(forKey: "keepersToCollection") as? Bool ?? true {
        didSet { UserDefaults.standard.set(keepersToCollection, forKey: "keepersToCollection") }
    }
    @Published var keepersAlbumName = ""
    @Published var includeUnique = UserDefaults.standard.object(forKey: "includeUnique") as? Bool ?? true {
        didSet { UserDefaults.standard.set(includeUnique, forKey: "includeUnique") }
    }
    @Published var favoritePicks = UserDefaults.standard.bool(forKey: "favoritePicks") {
        didSet { UserDefaults.standard.set(favoritePicks, forKey: "favoritePicks") }
    }
    @Published var leftovers = Leftovers(rawValue: UserDefaults.standard.string(forKey: "leftovers") ?? "") ?? .collect {
        didSet { UserDefaults.standard.set(leftovers.rawValue, forKey: "leftovers") }
    }
    @Published private(set) var lastResult: String?
    private var lastDefaultName = ""

    var scannedAlbum: PhotosLibrary.Album? {
        source.isPhotos && useAlbum ? albums.first { $0.id == albumID } : nil
    }

    var outcome: Outcome<String> {
        Outcome(order: order, groups: clusters.map(\.members), decisions: decisions, includeUnique: includeUnique)
    }

    /// Picks from reviewed groups (not one-offs or unreviewed): what "favourite the picks" touches.
    var picks: [String] {
        let o = outcome
        let passive = Set(o.unique + o.unreviewed)
        return o.keepers.filter { !passive.contains($0) }
    }

    func openApply() {
        lastResult = nil
        // Follow the scan (new album, new dates) unless you've typed your own name.
        if keepersAlbumName.isEmpty || keepersAlbumName == lastDefaultName || !source.isPhotos {
            keepersAlbumName = defaultKeepersName
        }
        lastDefaultName = defaultKeepersName
        if leftovers == .removeFromAlbum && scannedAlbum == nil { leftovers = .collect }
        showApply = true
    }

    private var defaultKeepersName: String {
        if !source.isPhotos { return ImageFiles.keepersFolderName }
        if let album = scannedAlbum { return "\(album.title) · Keepers" }
        let f = Date.FormatStyle.dateTime.month(.abbreviated).day().year()
        return "Keepers \(startDate.formatted(f)) – \(endDate.formatted(f))"
    }

    func leftoverLabel(_ l: Leftovers) -> String {
        switch (l, source.isPhotos) {
        case (.leave, _): "Leave them"
        case (.collect, true): "Collect in “\(PhotosLibrary.rejectsAlbumTitle)”"
        case (.collect, false): "Move into “\(ImageFiles.rejectsFolderName)” subfolder"
        case (.removeFromAlbum, _): "Remove from “\(scannedAlbum?.title ?? "album")” only"
        case (.delete, true): "Delete (Recently Deleted, 30 days)"
        case (.delete, false): "Move to the Trash"
        }
    }

    var availableLeftovers: [Leftovers] {
        Leftovers.allCases.filter { $0 != .removeFromAlbum || scannedAlbum != nil }
    }

    /// Plain-English preview of what Apply will do.
    var planSummary: [String] {
        let o = outcome
        var lines: [String] = []
        if keepersToCollection {
            var parts = ["\(o.keepers.count) keepers"]
            if includeUnique, !o.unique.isEmpty { parts.append("incl. \(o.unique.count) one-offs") }
            if !o.unreviewed.isEmpty { parts.append("\(o.unreviewed.count) from unreviewed groups as-is") }
            lines.append(parts.joined(separator: ", ") + (source.isPhotos
                ? " → album “\(keepersAlbumName)”" : " → copied into “\(ImageFiles.keepersFolderName)”"))
        }
        if favoritePicks, source.isPhotos { lines.append("\(picks.count) picks marked as Favourites") }
        let n = o.rejects.count
        switch leftovers {
        case .leave: lines.append("\(n) rejects left where they are")
        case .collect: lines.append("\(n) rejects → " + (source.isPhotos ? "album “\(PhotosLibrary.rejectsAlbumTitle)”" : "“\(ImageFiles.rejectsFolderName)” subfolder"))
        case .removeFromAlbum: lines.append("\(n) rejects removed from “\(scannedAlbum?.title ?? "")” (still in your library)")
        case .delete:
            lines.append(source.isPhotos
                ? "\(n) rejects deleted (Photos asks first; 30 days in Recently Deleted)"
                    + (rejectsInAlbums > 0 ? ", which also takes them out of their albums" : "")
                : "\(n) rejects (with RAW halves and sidecars) moved to the Trash")
        }
        return lines
    }

    func applyPlan() async {
        let o = outcome
        var done: [String] = []
        await perform("Couldn't apply") {
            let byDate = { (ids: [String]) in ids.sorted { (self.photos[$0]?.date ?? .distantPast) < (self.photos[$1]?.date ?? .distantPast) } }
            switch self.source {
            case .photos:
                if self.keepersToCollection {
                    try await PhotosLibrary.addToAlbum(byDate(o.keepers).compactMap { self.refs[$0]?.asset }, title: self.keepersAlbumName)
                    done.append("\(o.keepers.count) in “\(self.keepersAlbumName)”")
                }
                if self.favoritePicks {
                    try await PhotosLibrary.favorite(self.picks.compactMap { self.refs[$0]?.asset }.filter { !$0.isFavorite })
                    done.append("picks favourited")
                }
                let rejectAssets = o.rejects.compactMap { self.refs[$0]?.asset }
                switch self.leftovers {
                case .leave: break
                case .collect:
                    try await PhotosLibrary.addToAlbum(rejectAssets, title: PhotosLibrary.rejectsAlbumTitle)
                    done.append("\(o.rejects.count) in “\(PhotosLibrary.rejectsAlbumTitle)”")
                case .removeFromAlbum:
                    guard let album = self.scannedAlbum else { break }
                    try await PhotosLibrary.remove(rejectAssets, fromAlbum: album.id)
                    self.forget(o.rejects)   // a rescan of the album won't see them any more
                    done.append("\(o.rejects.count) removed from “\(album.title)”")
                case .delete:
                    try await PhotosLibrary.delete(rejectAssets)
                    self.forget(o.rejects)
                    done.append("\(o.rejects.count) deleted")
                }

            case let .folder(dir):
                if self.keepersToCollection {
                    let copied = try self.copyKeepers(o.keepers, into: dir.appendingPathComponent(ImageFiles.keepersFolderName))
                    done.append("\(copied) copied into “\(ImageFiles.keepersFolderName)”")
                }
                switch self.leftovers {
                case .leave, .removeFromAlbum: break
                case .collect:
                    try self.moveFiles(o.rejects, toTrash: false, dir: dir)
                    done.append("\(o.rejects.count) moved into “\(ImageFiles.rejectsFolderName)”")
                case .delete:
                    try self.moveFiles(o.rejects, toTrash: true, dir: dir)
                    done.append("\(o.rejects.count) moved to the Trash")
                }
            }
        }
        if !done.isEmpty { lastResult = "Done: " + done.joined(separator: "; ") + "." }
    }

    /// Clones (APFS copy-on-write, so no extra space) keepers and their companions into `dest`, at the
    /// same subfolder path they have under the scanned folder, so same-named files from different
    /// subfolders (DCIM/100CANON, 101CANON) can't collide. Files already there are left alone so
    /// re-applying doesn't duplicate. Returns photos copied.
    private func copyKeepers(_ ids: [String], into dest: URL) throws -> Int {
        let fm = FileManager.default
        let root = dest.deletingLastPathComponent().resolvingSymlinksInPath().pathComponents
        var copied = 0
        for id in ids {
            guard let url = refs[id]?.file else { continue }
            let parts = url.deletingLastPathComponent().resolvingSymlinksInPath().pathComponents
            let sub = parts.starts(with: root) ? parts.dropFirst(root.count) : []
            let dir = sub.reduce(dest) { $0.appendingPathComponent($1, isDirectory: true) }
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var any = false
            for f in [url] + (companions[id] ?? []) {
                let to = dir.appendingPathComponent(f.lastPathComponent)
                if fm.fileExists(atPath: to.path) { continue }
                try fm.copyItem(at: f, to: to)
                any = true
            }
            if any { copied += 1 }
        }
        return copied
    }

    /// Folder rejects into "<folder>/Winnow Rejects" (renamed as a set on collision), or to the Trash.
    private func moveFiles(_ ids: [String], toTrash: Bool, dir: URL) throws {
        let fm = FileManager.default
        let dest = dir.appendingPathComponent(ImageFiles.rejectsFolderName, isDirectory: true)
        if !toTrash { try fm.createDirectory(at: dest, withIntermediateDirectories: true) }
        var moved: [String] = []
        defer { forget(moved) }
        for id in ids {
            guard let url = refs[id]?.file else { continue }
            let files = [url] + (companions[id] ?? [])
            if toTrash {
                for f in files { try fm.trashItem(at: f, resultingItemURL: nil) }
            } else {
                for (from, to) in zip(files, ImageFiles.destinations(for: files, in: dest)) { try fm.moveItem(at: from, to: to) }
            }
            moved.append(id)
        }
    }

    /// "RAW+JPEG" / "RAW" / nil. Photos keeps a RAW+JPEG pair as one asset with two resources.
    func formatLabel(_ id: String) -> String? {
        if let known = formats[id] { return known }
        guard let asset = refs[id]?.asset else { return nil }
        let originals = PHAssetResource.assetResources(for: asset).filter { $0.type == .photo || $0.type == .alternatePhoto }
        let isRaw = { (r: PHAssetResource) in UTType(r.uniformTypeIdentifier)?.conforms(to: .rawImage) == true }
        var label: String?
        if let raw = originals.first(where: isRaw) {
            let other = originals.first { $0 !== raw && !isRaw($0) }
            label = other.map { "RAW+" + (UTType($0.uniformTypeIdentifier)?.preferredFilenameExtension?.uppercased()
                .replacingOccurrences(of: "JPG", with: "JPEG") ?? "JPEG") } ?? "RAW"
        }
        formats[id] = label
        return label
    }

    /// Drop photos that no longer exist in the source.
    private func forget(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let gone = Set(ids)
        for id in ids {
            refs[id] = nil
            photos[id] = nil
            decisions[id] = nil
            companions[id] = nil
            albumsOf[id] = nil
        }
        order.removeAll { gone.contains($0) }
        Store.saveDecisions(decisions)
        recluster()
    }

    func forgetDecisions() {
        for id in refs.keys { decisions[id] = nil }
        Store.saveDecisions(decisions)
        prepareReview()
    }

    private func perform(_ what: String, _ body: @MainActor () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do { try await body() } catch {
            let ns = error as NSError
            // User hitting "Don't Delete" in the system prompt isn't an error worth reporting.
            if ns.domain == PHPhotosErrorDomain, ns.code == PHPhotosError.userCancelled.rawValue { return }
            errorMessage = "\(what): \(error.localizedDescription)"
        }
    }
}
