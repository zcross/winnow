import AppKit
import SwiftUI
import WinnowCore

struct WinnowApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Winnow") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .windowToolbarStyle(.unified)
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var keys = KeyMonitor()

    var body: some View {
        NavigationSplitView(columnVisibility: $model.columns) {
            Sidebar().navigationSplitViewColumnWidth(min: 280, ideal: 310)
        } detail: {
            ReviewView()
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: $model.mode) {
                    ForEach(AppModel.Mode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .disabled(model.current == nil)
                .help("G: grid, D: head-to-head duel")
            }
            ToolbarItem {
                Button { model.openApply() } label: {
                    Label("Apply…", systemImage: "checkmark.circle")
                }
                .disabled(model.phase != .ready)
            }
        }
        .overlay { if model.showHelp { ShortcutsOverlay() } }
        .sheet(isPresented: $model.showApply) { ApplySheet().environmentObject(model) }
        .alert("Winnow", isPresented: Binding(get: { model.errorMessage != nil },
                                             set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") {}
        } message: { Text(model.errorMessage ?? "") }
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            keys.install(model)
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        // A plain stack, not a Form: a grouped Form is a scroll view and collapses when sized to fit.
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Source", selection: sourceKind) {
                    Text("Photos Library").tag(true)
                    Text("Folder").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if model.source.isPhotos {
                    Picker("Scope", selection: $model.useAlbum) {
                        Text("Dates").tag(false)
                        Text("Album").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    if model.useAlbum {
                        if model.albums.isEmpty {
                            Text("Loading albums…").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Picker("Album", selection: $model.albumID) {
                                ForEach(model.albums) { a in Text("\(a.title)  \(a.count)").tag(Optional(a.id)) }
                            }
                            .labelsHidden()
                        }
                    } else {
                        Grid(alignment: .leading, verticalSpacing: 6) {
                            GridRow {
                                Text("From").foregroundStyle(.secondary)
                                DatePicker("From", selection: $model.startDate, displayedComponents: .date).labelsHidden()
                            }
                            GridRow {
                                Text("To").foregroundStyle(.secondary)
                                DatePicker("To", selection: $model.endDate, displayedComponents: .date).labelsHidden()
                            }
                        }
                        HStack {
                            ForEach([("Week", 7), ("Month", 31), ("Year", 365)], id: \.0) { name, days in
                                Button(name) {
                                    model.endDate = .now
                                    model.startDate = Calendar.current.date(byAdding: .day, value: -days, to: .now)!
                                }
                            }
                        }
                        .controlSize(.small)
                    }
                    Toggle("Include screenshots", isOn: $model.includeScreenshots)
                } else {
                    HStack {
                        Image(systemName: "folder")
                        Text(folderName).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { model.chooseFolder() }.controlSize(.small)
                    }
                }
                scanButton

                if model.phase == .ready {
                    Divider()
                    LabeledContent("Time window", value: gapLabel)
                    // Log scale: seconds-apart bursts and hour-long sessions both get room.
                    Slider(value: Binding(get: { log2(model.maxGapMinutes) },
                                          set: { model.maxGapMinutes = pow(2, $0) }),
                           in: -3...8) { editing in
                        if !editing { model.recluster() }
                    }
                    .labelsHidden()
                    LabeledContent("Similarity", value: String(format: "%.2f", model.threshold))
                    Slider(value: $model.threshold, in: 0.2...1.1) {
                        EmptyView()
                    } minimumValueLabel: {
                        Text("strict").font(.caption2)
                    } maximumValueLabel: {
                        Text("loose").font(.caption2)
                    } onEditingChanged: { editing in
                        if !editing { model.recluster() }
                    }
                    .labelsHidden()
                    Text("\(model.photos.count) photos → \(model.clusters.count) groups · \(model.singletonCount) unique")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    LabeledContent("Keep per group", value: model.pickRulesSummary)
                    HStack(spacing: 6) {
                        Slider(value: Binding(get: { model.keepPercent }, set: { model.keepPercent = ($0 / 5).rounded() * 5 }),
                               in: 0...100).labelsHidden()
                            .help("Share of each group to keep, rounded up (0% = just the minimum)")
                        Text(model.keepPercent < 0.5 ? "off" : "\(Int(model.keepPercent))%")
                            .monospacedDigit().frame(width: 34, alignment: .trailing)
                    }
                    HStack {
                        Text("at least").foregroundStyle(.secondary)
                        Stepper("\(model.keepMin)", value: $model.keepMin, in: 1...20).monospacedDigit()
                        Spacer()
                        Text("at most").foregroundStyle(.secondary)
                        Stepper(model.keepMax == 0 ? "∞" : "\(model.keepMax)", value: $model.keepMax, in: 0...50).monospacedDigit()
                    }
                    .controlSize(.small)
                    LabeledContent("Near-ties", value: model.tieMargin < 0.005 ? "off" : String(format: "within %.2f", model.tieMargin))
                    Slider(value: $model.tieMargin, in: 0...0.3).labelsHidden()
                        .help("Also keep frames that score almost as well as the ones kept")
                }
            }
            .padding(12)

            if model.phase == .ready && !model.clusters.isEmpty {
                Divider()
                BacklogStrip().padding(12)
            }

            Divider()

            List(selection: $model.selectedID) {
                ForEach(model.days, id: \.day) { day in
                    Section {
                        ForEach(day.clusters) { c in ClusterRow(cluster: c).tag(c.id) }
                    } header: {
                        HStack {
                            Text(day.day.formatted(.dateTime.weekday(.abbreviated).month().day()))
                            Spacer()
                            Text("\(day.done)/\(day.total)").monospacedDigit()
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var sourceKind: Binding<Bool> {
        Binding(get: { model.source.isPhotos }, set: { photos in
            if photos { model.source = .photos } else if model.source.isPhotos { model.chooseFolder() }
        })
    }

    private var folderName: String {
        if case let .folder(url) = model.source { url.lastPathComponent } else { "No folder" }
    }

    private var gapLabel: String {
        let m = model.maxGapMinutes
        return m < 1 ? "\(Int(m * 60)) s" : m < 60 ? "\(Int(m)) min" : String(format: "%.1f h", m / 60)
    }

    @ViewBuilder private var scanButton: some View {
        if case let .scanning(done, total) = model.phase {
            VStack(alignment: .leading) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                HStack {
                    Text(total == 0 ? "Finding photos…" : "Analysing \(done) / \(total)")
                    Spacer()
                    Button("Cancel") { model.cancelScan() }.controlSize(.small)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Button { model.startScan() } label: {
                Text(model.phase == .ready ? "Rescan" : "Scan").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("r", modifiers: .command)
        }
    }
}

/// Backlog progress plus the bulk shortcuts.
struct BacklogStrip: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let total = model.clusters.count, done = model.reviewedCount
        let obvious = model.obviousClusters.count
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: Double(done), total: Double(max(total, 1)))
            HStack {
                Text("\(done) of \(total) groups").monospacedDigit()
                Spacer()
                if let eta = model.remainingEstimate { Text(eta) }
            }
            .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button {
                    model.acceptObvious()
                } label: {
                    Label(obvious > 0 ? "Accept \(obvious) obvious" : "No obvious groups left", systemImage: "wand.and.stars")
                }
                .disabled(obvious == 0)
                .help("Accept the suggested pick wherever it clearly beats the rest. ⌘Z undoes.")
                Spacer()
                Toggle("Hide done", isOn: $model.hideDone).toggleStyle(.checkbox)
            }
            .controlSize(.small)
        }
    }
}

struct ClusterRow: View {
    @EnvironmentObject var model: AppModel
    let cluster: Cluster

    var body: some View {
        HStack {
            AssetImage(id: model.best(cluster), pixels: 120)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading) {
                Text("\(cluster.members.count) photos")
                Text(model.photos[cluster.id]?.date.formatted(date: .abbreviated, time: .shortened) ?? "")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isReviewed(cluster) {
                let kept = cluster.members.filter { model.decisions[$0] == true }.count
                let auto = cluster.members.allSatisfy(model.autoAccepted.contains)
                Text("\(kept) kept").font(.caption).foregroundStyle(.secondary)
                Image(systemName: auto ? "wand.and.stars" : "checkmark.circle.fill")
                    .foregroundStyle(auto ? Color.purple : Color.green)
                    .help(auto ? "Accepted automatically" : "Reviewed")
            }
        }
    }
}

// MARK: - Review

struct ReviewView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if let c = model.current {
                VStack(spacing: 0) {
                    GroupHeader(cluster: c)
                    Divider()
                    if let d = model.duel, !d.isFinished {
                        DuelView(duel: d)
                    } else {
                        if model.duel != nil {
                            Text("Duel done. Return to confirm, U to undo.")
                                .font(.headline).padding(.top, 10)
                        }
                        GridReview(cluster: c)
                    }
                    Divider()
                    HintBar()
                }
                .overlay { if let z = model.zoomID { ZoomView(id: z) } }
            } else if model.phase == .ready && !model.clusters.isEmpty {
                ContentUnavailableView {
                    Label("All groups reviewed", systemImage: "checkmark.seal")
                } description: {
                    Text("\(model.rejectCount) photos marked to remove. ⌘Z to go back.")
                } actions: {
                    Button("Apply…") { model.openApply() }
                }
            } else if model.phase == .ready {
                ContentUnavailableView("No similar groups", systemImage: "photo.stack",
                                       description: Text("Try a looser similarity or a wider time window."))
            } else {
                ContentUnavailableView("Pick a date range and Scan", systemImage: "photo.on.rectangle.angled",
                                       description: Text("Winnow groups near-duplicate shots so you can keep the best."))
            }
        }
    }
}

/// One quiet line: where you are, when it was shot, and a warning if nothing survives.
struct GroupHeader: View {
    @EnvironmentObject var model: AppModel
    let cluster: Cluster

    var body: some View {
        let kept = cluster.members.filter { model.draft[$0] == true }.count
        HStack(spacing: 10) {
            if let p = model.position { Text("Group \(p) of \(model.clusters.count)").monospacedDigit() }
            Text(model.photos[cluster.id]?.date.formatted(date: .abbreviated, time: .shortened) ?? "")
                .foregroundStyle(.secondary)
            Spacer()
            if kept == 0 {
                Label("Nothing kept: all \(cluster.members.count) will go", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                Text("keep \(kept) of \(cluster.members.count)").foregroundStyle(.secondary).monospacedDigit()
            }
            Menu {
                Button("Split before selected photo   \\") { model.splitAtFocus() }.disabled(model.focus == 0)
                Button("Take selected photo out   -") { model.detachFocused() }
                Button("Merge with next group   M") { model.mergeWithNext() }
                Divider()
                Button("Undo grouping edits for this group") { model.resetEditsForCurrent() }
                Button("Undo all grouping edits") { model.resetAllEdits() }.disabled(model.edits.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Fix this group: split, take a photo out, merge")
        }
        .font(.callout)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
}

struct GridReview: View {
    @EnvironmentObject var model: AppModel
    let cluster: Cluster

    var body: some View {
        let n = cluster.members.count
        let minSide: CGFloat = n <= 2 ? 420 : n <= 4 ? 320 : n <= 9 ? 240 : 180
        let best = model.best(cluster)
        let chosen = model.chosen(cluster)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: minSide), spacing: 12)], spacing: 12) {
                    ForEach(Array(cluster.members.enumerated()), id: \.element) { i, id in
                        GridCell(id: id, index: i, isBest: id == best, focused: model.focus == i,
                                 flaws: model.flaws(id, in: cluster),
                                 chosenByAlbum: chosen.contains(id) && model.photos[id]?.isFavorite != true)
                            .id(id)
                            .onTapGesture(count: 2) { model.zoomID = id }
                            .onTapGesture { model.focus = i; model.toggle(id) }
                    }
                }
                .padding(16)
            }
            .onChange(of: model.focus) { _, f in
                if f < n { withAnimation { proxy.scrollTo(cluster.members[f]) } }
            }
        }
    }
}

struct GridCell: View {
    @EnvironmentObject var model: AppModel
    let id: String
    let index: Int
    let isBest: Bool
    let focused: Bool
    let flaws: [Ranking.Flaw]
    var chosenByAlbum = false

    var body: some View {
        let keep = model.draft[id] ?? false
        let photo = model.photos[id]
        AssetImage(id: id, pixels: 640)
            .aspectRatio(4 / 3, contentMode: .fit)
            .opacity(keep ? 1 : 0.35)
            .overlay(alignment: .topLeading) {
                HStack(spacing: 4) {
                    if index < 9 { Text("\(index + 1)").monospacedDigit() }
                    if isBest { Image(systemName: "crown.fill").foregroundStyle(.yellow) }
                    if let format = model.formatLabel(id) { Text(format).font(.caption2.weight(.semibold)) }
                    if photo?.isFavorite == true { Image(systemName: "heart.fill").foregroundStyle(.pink) }
                    if chosenByAlbum {
                        Image(systemName: "rectangle.stack.fill").foregroundStyle(.blue)
                            .help("In " + model.albumTitles(id).joined(separator: ", "))
                    }
                }
                .font(.caption.bold())
                .padding(5).background(.ultraThinMaterial, in: Capsule()).padding(6)
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: keep ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.title2).symbolRenderingMode(.palette)
                    .foregroundStyle(.white, keep ? Color.green : Color.red)
                    .padding(6)
            }
            .overlay(alignment: .bottomLeading) {
                if !flaws.isEmpty {
                    Text(flaws.map(\.rawValue).joined(separator: " · "))
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(6)
                        .help("Worse than its siblings on this")
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(focused ? Color.accentColor : .clear, lineWidth: 3)
            }
            .contentShape(Rectangle())
    }
}

struct DuelView: View {
    @EnvironmentObject var model: AppModel
    let duel: Duel<String>

    var body: some View {
        VStack(spacing: 8) {
            Text("Which is better?  \(duel.decided + 1) of \(duel.total - 1)")
                .font(.headline).padding(.top, 10)
            HStack(spacing: 12) {
                side(duel.champion, key: "←") { model.duelStep { $0.championWins() } }
                if let ch = duel.challenger {
                    side(ch, key: "→") { model.duelStep { $0.challengerWins() } }
                }
            }
            .padding(.horizontal, 12)
            HStack {
                Button("Keep both  ↓") { model.duelStep { $0.keepBoth() } }
                Button("Undo  U") { model.duelStep { $0.undo() } }.disabled(!duel.canUndo)
            }
            .padding(.bottom, 8)
        }
    }

    private func side(_ id: String, key: String, action: @escaping () -> Void) -> some View {
        ZoomableImage(id: id, pixels: AppModel.duelPixels) {
            HStack(spacing: 6) {
                Text(key).font(.title3.bold())
                if model.photos[id]?.isFavorite == true { Image(systemName: "heart.fill").foregroundStyle(.pink) }
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

struct HintBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let duelActive = model.duel.map { !$0.isFinished } ?? false
        Text(duelActive
             ? "←/→ pick the better one   ↓ keep both   Z zoom both (point to pan)   U undo   G grid   ? all shortcuts"
             : "←/→ move   X or 1–9 toggle   O suggestion   A keep all   Space view   Return confirm & next   \\ split   - take out   M merge   ⌘Z undo   ? all shortcuts")
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity).padding(8)
    }
}

/// Every shortcut on one card (? toggles).
struct ShortcutsOverlay: View {
    @EnvironmentObject var model: AppModel

    private let sections: [(String, [(String, String)])] = [
        ("Review", [("Return", "Confirm group, go to next"), ("Tab / S", "Skip group"), ("⌘Z", "Undo (decisions, bulk accepts, grouping edits)"),
                    ("G / D", "Grid / Duel"), ("F", "Focus: hide sidebar")]),
        ("Grid", [("← →", "Move selection"), ("X or 1–9", "Keep / reject"), ("O", "Back to suggestion"), ("A", "Keep all"),
                  ("Space", "View large  (Z zooms, pointer pans)")]),
        ("Duel", [("← →", "Pick the better one"), ("↓ or B", "Keep both"), ("Z", "Zoom both together, pointer pans"), ("U", "Undo step")]),
        ("Grouping", [("\\", "Split before selected photo"), ("-", "Take selected photo out"), ("M", "Merge with next group")]),
    ]

    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.35)).onTapGesture { model.showHelp = false }
            VStack(alignment: .leading, spacing: 14) {
                Text("Shortcuts").font(.title3.bold())
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    ForEach(sections, id: \.0) { title, keys in
                        GridRow { Text(title).font(.headline).padding(.top, 6).gridCellColumns(2) }
                        ForEach(keys, id: \.0) { key, what in
                            GridRow {
                                Text(key).font(.body.monospaced().weight(.semibold)).gridColumnAlignment(.trailing)
                                Text(what).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Text("? or Esc to close").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(radius: 20)
        }
    }
}

struct ZoomView: View {
    @EnvironmentObject var model: AppModel
    let id: String

    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.85))
            ZoomableImage(id: id, pixels: 3000) { EmptyView() }.padding(20)
        }
        .onTapGesture { model.zoomID = nil }
    }
}

// MARK: - Shared

struct AssetImage<Badge: View>: View {
    @EnvironmentObject var model: AppModel
    let id: String
    let pixels: CGFloat
    /// Pinned to the bottom of the image itself (not the frame around it).
    var badge: () -> Badge
    // @State is a macro that needs Xcode's plugins; @StateObject works with just the CLT.
    @StateObject private var loader = ImageHolder()

    var body: some View {
        ZStack {
            if let image = loader.image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .overlay(alignment: .bottom) { badge() }
            } else {
                Rectangle().fill(.quaternary)
                ProgressView().controlSize(.small)
            }
        }
        .task(id: "\(id)@\(pixels)") {
            // Same photo at a new size (zooming): keep showing the old one until the sharper one lands.
            if loader.id != id { loader.image = nil }
            guard let ref = model.refs[id] else { return }
            let image = await ImageLoader.shared.image(for: ref, pixels: pixels)
            if !Task.isCancelled { (loader.image, loader.id) = (image, id) }
        }
    }

}

extension AssetImage where Badge == EmptyView {
    init(id: String, pixels: CGFloat) { self.init(id: id, pixels: pixels, badge: { EmptyView() }) }
}

@MainActor final class ImageHolder: ObservableObject {
    @Published var image: NSImage?
    var id: String?
}

/// A photo that magnifies around `model.zoomCenter` when `model.zoom > 1`; the pointer moves the
/// centre, so two of these side by side pan together.
struct ZoomableImage<Badge: View>: View {
    @EnvironmentObject var model: AppModel
    let id: String
    let pixels: CGFloat
    var badge: () -> Badge

    var body: some View {
        let zoomed = model.zoom > 1
        GeometryReader { geo in
            AssetImage(id: id, pixels: zoomed ? max(pixels, 3200) : pixels, badge: zoomed ? { AnyView(EmptyView()) } : { AnyView(badge()) })
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(model.zoom, anchor: model.zoomCenter)
                .clipped()
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    if zoomed, case let .active(p) = phase {
                        model.zoomCenter = UnitPoint(x: p.x / max(geo.size.width, 1), y: p.y / max(geo.size.height, 1))
                    }
                }
        }
    }
}

/// App-wide shortcuts, routed to the model unless the user is editing a field.
@MainActor
final class KeyMonitor: ObservableObject {
    private var token: Any?

    func install(_ model: AppModel) {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let r = NSApp.keyWindow?.firstResponder
            if r is NSText || r is NSDatePicker { return e }
            return model.handleKey(e) ? nil : e
        }
    }
}

struct ApplySheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Apply").font(.title2.bold())

            VStack(alignment: .leading, spacing: 8) {
                Text("Keepers").font(.headline)
                Toggle(model.source.isPhotos ? "Put them in an album" : "Copy them into “\(ImageFiles.keepersFolderName)”",
                       isOn: $model.keepersToCollection)
                if model.keepersToCollection {
                    Group {
                        if model.source.isPhotos {
                            TextField("Album name", text: $model.keepersAlbumName).textFieldStyle(.roundedBorder)
                        } else {
                            Text("A subfolder of copies; on APFS drives they take no extra space. Future scans skip it.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle("Include one-offs (photos with no near-duplicates)", isOn: $model.includeUnique)
                    }
                    .padding(.leading, 20)
                }
                if model.source.isPhotos {
                    Toggle("Mark picks from reviewed groups as Favourites", isOn: $model.favoritePicks)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Leftovers").font(.headline)
                Picker("Leftovers", selection: $model.leftovers) {
                    ForEach(model.availableLeftovers, id: \.self) { Text(model.leftoverLabel($0)).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.planSummary, id: \.self) { Label($0, systemImage: "arrow.right").font(.callout) }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            if let result = model.lastResult {
                Label(result, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }

            HStack {
                Button("Forget decisions in this scan", role: .destructive) { model.confirmForget = true }
                    .confirmationDialog("Forget every keep/reject decision in this scan?", isPresented: $model.confirmForget) {
                        Button("Forget decisions", role: .destructive) { model.forgetDecisions() }
                    } message: { Text("Your photos aren't touched, but this review work can't be undone.") }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(model.leftovers == .delete ? "Apply & Delete" : "Apply") { Task { await model.applyPlan() } }
                    // Return shouldn't delete: review muscle memory presses it a lot.
                    .keyboardShortcut(model.leftovers == .delete ? nil : .defaultAction)
                    .disabled(model.busy || (model.keepersToCollection && model.keepersAlbumName.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
