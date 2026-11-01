import AppKit
import SwiftUI
import WinnowCore

/// Drives the real views off-screen against a folder of images: scans, sends keystrokes
/// through the same handler the app uses, checks the resulting state and writes PNGs.
/// Works without a logged-in GUI session. Set WINNOW_DATA_DIR to keep its decisions separate.
@MainActor
enum Snapshot {
    static func run(folder: URL, out: URL, applyMoves: Bool = false) -> Bool {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var failures = 0
        func expect(_ cond: Bool, _ msg: String) {
            print((cond ? "ok   " : "FAIL ") + msg)
            if !cond { failures += 1 }
        }

        let model = AppModel()
        model.source = .folder(folder)
        let t0 = Date()
        Task { await model.scan() }
        spin(until: { model.phase == .ready }, timeout: 120)
        expect(model.phase == .ready, String(format: "scan finished in %.1fs: %d photos, %d groups, %d unique",
                                             Date().timeIntervalSince(t0), model.photos.count, model.clusters.count, model.singletonCount))
        guard let first = model.current else { print("no groups"); return false }

        // NavigationSplitView lays out around a toolbar that off-screen windows don't have,
        // so render the two columns separately and paste them side by side.
        let height: CGFloat = 820
        func host<V: View>(_ v: V, width: CGFloat) -> NSView {
            let h = NSHostingView(rootView: v.environmentObject(model).frame(width: width, height: height)
                .background(Color(nsColor: .windowBackgroundColor)))
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless],
                             backing: .buffered, defer: false)
            w.contentView = h
            windows.append(w)
            return h
        }
        var windows: [NSWindow] = []
        let columns = [host(Sidebar(), width: 310), host(ReviewView(), width: 970)]

        func render(_ v: NSView) -> NSBitmapImageRep? {
            v.layoutSubtreeIfNeeded()
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
            v.cacheDisplay(in: v.bounds, to: rep)
            return rep
        }
        func shot(_ name: String, view: NSView? = nil) {
            spin(seconds: 1.2)   // let async thumbnails land
            let parts = (view.map { [$0] } ?? columns).compactMap(render)
            let size = NSSize(width: parts.map(\.size.width).reduce(0, +), height: parts.map(\.size.height).max() ?? 0)
            let image = NSImage(size: size)
            image.lockFocus()
            var x: CGFloat = 0
            for p in parts { p.draw(in: NSRect(x: x, y: 0, width: p.size.width, height: p.size.height)); x += p.size.width }
            image.unlockFocus()
            guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            else { return }
            try? png.write(to: out.appendingPathComponent("\(name).png"))
        }
        func press(_ chars: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = []) {
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                     context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                     isARepeat: false, keyCode: keyCode)!
            _ = model.handleKey(e)
            spin(seconds: 0.05)
        }

        // Grid: the suggestion keeps exactly the ranked best.
        shot("1-grid")
        let kept = first.members.filter { model.draft[$0] == true }
        expect(kept == [model.best(first)], "grid pre-keeps only the best of \(first.members.count)")

        press("", 124); press("x", 7)
        expect(model.focus == 1 && model.draft[first.members[1]] == !(first.members[1] == model.best(first)),
               "→ then X toggles the second photo")
        shot("2-grid-toggled")

        press("\r", 36)
        expect(first.members.allSatisfy { model.decisions[$0] != nil }, "Return commits every photo in the group")
        expect(model.current?.id != first.id, "Return advances to the next group")
        press("z", 6, .command)
        expect(model.current?.id == first.id && first.members.allSatisfy { model.decisions[$0] == nil },
               "⌘Z reopens the group and clears its decisions")
        press("\r", 36)

        // Bulk accept is one undo step.
        let before = model.reviewedCount, obvious = model.obviousClusters.count
        if obvious > 0 {
            model.acceptObvious()
            expect(model.reviewedCount == before + obvious, "Accept obvious reviews \(obvious) groups at once")
            press("z", 6, .command)
            expect(model.reviewedCount == before && model.autoAccepted.isEmpty, "⌘Z undoes the whole bulk accept")
            model.acceptObvious()
        }
        model.hideDone = true
        expect(model.days.flatMap(\.clusters).allSatisfy { !model.isReviewed($0) || $0.id == model.selectedID }, "Hide done hides reviewed groups")
        model.hideDone = false

        // Duel on the next group: keep picking the right-hand challenger, one "keep both".
        press("d", 2)
        guard let dc = model.current, model.duel != nil else { expect(false, "D starts a duel"); return false }
        shot("3-duel")
        press("z", 6)
        model.zoomCenter = UnitPoint(x: 0.3, y: 0.6)
        expect(model.zoom == 3, "Z zooms both duel photos")
        shot("3b-duel-zoom")
        press("z", 6)
        expect(model.zoom == 1, "Z again zooms out")
        press("", 125)   // keep both
        while model.duel?.isFinished == false { press("", 124) }
        let duelKeep = Set(dc.members.filter { model.draft[$0] == true })
        expect(duelKeep == model.duel!.finalKeepers && (dc.members.count == 1 || duelKeep.count == 2),
               "duel with one keep-both leaves 2 keepers (\(duelKeep.count) of \(dc.members.count))")
        shot("4-duel-done")
        press("u", 32)
        expect(model.duel?.isFinished == false, "U undoes the last duel step")
        press("", 123)
        press("\r", 36)
        expect(dc.members.allSatisfy { model.decisions[$0] != nil }, "finished duel commits on Return")

        press("g", 5)
        press(" ", 49)
        expect(model.zoomID != nil, "Space zooms in grid")
        shot("5-zoom")
        press(" ", 49)
        expect(model.zoomID == nil, "Space closes zoom")

        // Pick rules re-suggest an undecided group: 50% of it, then capped at 2.
        if let c = model.current, !c.members.contains(where: { model.decisions[$0] != nil }), c.members.count >= 4 {
            let n = c.members.count
            model.keepPercent = 50
            let half = c.members.filter { model.draft[$0] == true }.count
            model.keepMax = 2
            let capped = c.members.filter { model.draft[$0] == true }.count
            expect(half == (n + 1) / 2 && capped == 2,
                   "pick rules: 50% of \(n) keeps \(half), capped at 2 keeps \(capped)")
            model.keepPercent = 0
            model.keepMax = 0
        }

        // Grouping edits: split, undo, detach, merge back; all survive a regroup.
        if let c = model.current, c.members.count >= 4 {
            let n = c.members.count, groupsBefore = model.clusters.count
            model.focus = 2
            press("\\", 42)
            expect(model.current?.members == Array(c.members[2...]) && model.clusters.count == groupsBefore + 1,
                   "\\ splits \(n) photos into 2 + \(n - 2), opening the second part")
            model.recluster()
            expect(model.clusters.contains { $0.members == Array(c.members[..<2]) }, "split survives regrouping")
            press("z", 6, .command)
            expect(model.current?.members == c.members, "⌘Z undoes the split")
            model.focus = 1
            press("-", 27)
            expect(model.clusters.first { $0.members.contains(c.members[0]) }?.members == c.members.filter { $0 != c.members[1] }
                   && !model.clusters.contains { $0.members.contains(c.members[1]) }, "- takes one photo out as a one-off")
            press("z", 6, .command)
            if let i = model.clusters.firstIndex(where: { $0.id == c.id }), i + 1 < model.clusters.count {
                let next = model.clusters[i + 1]
                press("m", 46)
                expect(model.current?.members.count == n + next.members.count, "M merges with the next group")
                press("z", 6, .command)
            }
            expect(model.edits.isEmpty && model.current?.members == c.members, "everything undone, edits empty")
        }

        press("?", 44)
        expect(model.showHelp, "? shows all shortcuts")
        let help = host(ShortcutsOverlay(), width: 700)
        shot("5b-shortcuts", view: help)
        let draftBefore = model.draft
        press("x", 7)
        expect(model.showHelp && model.draft == draftBefore, "keys are ignored while the shortcuts card is up")
        press("", 53)
        expect(!model.showHelp, "Esc closes it")

        // Loosest grouping should merge more; strictest should merge less.
        let base = model.clusters.count
        model.threshold = 1.1; model.recluster()
        let loose = model.clusters.count
        model.threshold = 0.2; model.recluster()
        let strict = model.clusters.count
        model.threshold = 0.65; model.recluster()
        expect(model.clusters.count == base, "regrouping is repeatable (\(strict) strict / \(base) default / \(loose) loose groups)")
        shot("6-sidebar-progress")

        // Rescan hits the analysis cache and lands on the same grouping.
        let groupsBefore = model.clusters.count
        let t1 = Date()
        model.startScan()
        spin(seconds: 0.05)
        spin(until: { model.phase == .ready }, timeout: 120)
        let rescan = Date().timeIntervalSince(t1)
        expect(model.clusters.count == groupsBefore && rescan < 2,
               String(format: "rescan from cache in %.2fs, same %d groups", rescan, model.clusters.count))

        model.openApply()
        let sheet = NSHostingView(rootView: ApplySheet().environmentObject(model).background(Color(nsColor: .windowBackgroundColor)))
        sheet.frame = NSRect(origin: .zero, size: sheet.fittingSize)
        let sheetWindow = NSWindow(contentRect: sheet.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        sheetWindow.contentView = sheet
        windows.append(sheetWindow)
        shot("7-apply", view: sheet)
        model.showApply = false

        // Files on disk vs photos shown: RAW+JPEG pairs and sidecars must collapse into one photo.
        let bundles = ImageFiles.files(in: folder)
        let paired = bundles.filter { !$0.companions.isEmpty }
        expect(model.photos.count == bundles.count,
               "\(ImageFiles.list(in: folder).count) files show as \(model.photos.count) photos (\(paired.count) with RAW/sidecar companions)")
        for rawOnly in bundles where rawOnly.formatLabel == "RAW" {
            expect(model.photos[rawOnly.primary.path]?.analysis != nil, "RAW-only \(rawOnly.primary.lastPathComponent) analysed via its preview")
        }
        if let p = paired.first(where: { $0.formatLabel != nil }) {
            expect(model.formatLabel(p.primary.path) == p.formatLabel, "format tag \(p.formatLabel ?? "-") on \(p.primary.lastPathComponent)")
        }

        if applyMoves {
            let rejected = model.rejects
            let expectedGone = Set(rejected.flatMap { id in [id] + (bundles.first { $0.primary.path == id }?.companions.map(\.path) ?? []) })
            model.keepersToCollection = true
            model.includeUnique = true
            model.leftovers = .collect
            let plannedKeepers = model.outcome.keepers
            let dest = folder.appendingPathComponent(ImageFiles.rejectsFolderName)
            let namesBefore = Set((try? FileManager.default.contentsOfDirectory(atPath: dest.path)) ?? [])
            Task { await model.applyPlan() }
            spin(seconds: 0.05)
            spin(until: { !model.busy }, timeout: 30)
            // Compare against what was already there: re-applying adds to the same folders.
            let movedNames = Set((try? FileManager.default.contentsOfDirectory(atPath: dest.path)) ?? []).subtracting(namesBefore)
            let leftBehind = expectedGone.filter { FileManager.default.fileExists(atPath: $0) }
            expect(leftBehind.isEmpty && movedNames.count == expectedGone.count,
                   "moved \(rejected.count) rejects as \(movedNames.count) files, \(leftBehind.count) left behind")
            expect(model.errorMessage == nil, "no move errors \(model.errorMessage ?? "")")
            let keepersDir = folder.appendingPathComponent(ImageFiles.keepersFolderName)
            let keptFiles = ImageFiles.files(in: keepersDir)
            // Keepers sit at their own subfolder path, so same-named files from different subfolders both land.
            let missing = plannedKeepers.filter {
                !FileManager.default.fileExists(atPath: keepersDir.path + $0.dropFirst(folder.path.count))
            }
            expect(missing.isEmpty, "all \(plannedKeepers.count) keepers are in “\(ImageFiles.keepersFolderName)”, "
                   + "\(keptFiles.filter { !$0.companions.isEmpty }.count) with RAW/sidecar companions")
            expect(ImageFiles.files(in: folder).count == bundles.count - rejected.count, "rescan skips both Winnow subfolders")
            print("     " + (model.lastResult ?? "no result"))
        }

        // Photos-library controls with stand-in albums (no library access needed to draw them).
        model.source = .photos
        model.albums = [.init(id: "a1", title: "Summer Vacation", count: 1840), .init(id: "a2", title: "Summer favorites", count: 62)]
        model.useAlbum = true
        model.albumID = "a1"
        shot("8-photos-album-scope")
        expect(model.albums.count == 2, "album scope renders without loading the library")
        model.openApply()
        model.leftovers = .removeFromAlbum
        expect(model.keepersAlbumName == "Summer Vacation · Keepers" && model.availableLeftovers.contains(.removeFromAlbum),
               "album scan offers “\(model.keepersAlbumName)” and remove-from-album")
        spin(seconds: 0.2)
        sheet.frame = NSRect(origin: .zero, size: sheet.fittingSize)
        sheetWindow.setContentSize(sheet.fittingSize)
        shot("9-apply-photos-album", view: sheet)
        model.showApply = false

        print(failures == 0 ? "snapshot checks passed; PNGs in \(out.path)" : "\(failures) snapshot check(s) failed")
        return failures == 0
    }

    private static func spin(seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static func spin(until done: () -> Bool, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
}
