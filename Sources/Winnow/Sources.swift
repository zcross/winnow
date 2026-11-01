import AppKit
import Photos
import WinnowCore

/// Where a photo lives: the Photos library, or a plain file in a chosen folder.
enum PhotoRef {
    case asset(PHAsset)
    case file(URL)

    var asset: PHAsset? { if case let .asset(a) = self { a } else { nil } }
    var file: URL? { if case let .file(u) = self { u } else { nil } }
}

enum Analyzer {
    static func analyze(_ ref: PhotoRef) async -> Analysis? {
        guard let cg = await ImageLoader.shared.cgImage(for: ref, pixels: ImageAnalyzer.thumbnailPixels) else { return nil }
        return await ImageAnalyzer.analyzeQueued(cg)
    }
}

final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()
    private let manager = PHCachingImageManager()
    /// Folder images are decoded by us, so keep recent ones around for snappy scrolling.
    private let fileCache = NSCache<NSString, NSImage>()

    init() { fileCache.countLimit = 300 }

    private func options() -> PHImageRequestOptions {
        let o = PHImageRequestOptions()
        o.deliveryMode = .highQualityFormat
        o.resizeMode = .fast
        o.isNetworkAccessAllowed = true
        return o
    }

    func image(for ref: PhotoRef, pixels: CGFloat) async -> NSImage? {
        switch ref {
        case let .asset(asset):
            return await withCheckedContinuation { cont in
                let once = Once()
                manager.requestImage(for: asset, targetSize: CGSize(width: pixels, height: pixels),
                                     contentMode: .aspectFit, options: options()) { image, _ in
                    if once.claim() { cont.resume(returning: image) }
                }
            }
        case let .file(url):
            let key = "\(url.path)@\(Int(pixels))" as NSString
            if let hit = fileCache.object(forKey: key) { return hit }
            let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                guard let cg = ImageFiles.thumbnail(url, maxPixels: pixels) else { return nil }
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }.value
            if let image { fileCache.setObject(image, forKey: key) }
            return image
        }
    }

    func cgImage(for ref: PhotoRef, pixels: CGFloat) async -> CGImage? {
        switch ref {
        case .asset:
            return await image(for: ref, pixels: pixels)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        case let .file(url):
            return await Task.detached { ImageFiles.thumbnail(url, maxPixels: pixels) }.value
        }
    }

    func prefetch(_ refs: [PhotoRef], pixels: CGFloat) {
        let assets = refs.compactMap(\.asset)
        if !assets.isEmpty {
            manager.startCachingImages(for: assets, targetSize: CGSize(width: pixels, height: pixels),
                                       contentMode: .aspectFit, options: options())
        }
        for ref in refs where ref.file != nil { Task { _ = await image(for: ref, pixels: pixels) } }
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Photos library reads and writes, kept off the main actor: PhotoKit runs change blocks on its
/// own queue, and a closure written inside a @MainActor type would be treated as main-isolated.
enum PhotosLibrary {
    struct Item {
        let asset: PHAsset
        let date: Date
    }

    struct Album: Identifiable, Hashable {
        let id: String      // PHAssetCollection localIdentifier
        let title: String
        let count: Int      // photos (not videos)
    }

    private static func imageOptions(_ predicate: NSPredicate? = nil) -> PHFetchOptions {
        let opts = PHFetchOptions()
        let images = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        opts.predicate = predicate.map { NSCompoundPredicate(andPredicateWithSubpredicates: [images, $0]) } ?? images
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        return opts
    }

    private static func items(_ result: PHFetchResult<PHAsset>, includeScreenshots: Bool) -> [Item] {
        var out: [Item] = []
        result.enumerateObjects { a, _, _ in
            if !includeScreenshots && a.mediaSubtypes.contains(.photoScreenshot) { return }
            out.append(Item(asset: a, date: a.creationDate ?? .distantPast))
        }
        return out
    }

    static func images(from start: Date, to end: Date, includeScreenshots: Bool) async -> [Item] {
        await Task.detached(priority: .userInitiated) {
            let range = NSPredicate(format: "creationDate >= %@ AND creationDate < %@", start as NSDate, end as NSDate)
            return items(PHAsset.fetchAssets(with: imageOptions(range)), includeScreenshots: includeScreenshots)
        }.value
    }

    static func images(inAlbum id: String, includeScreenshots: Bool) async -> [Item] {
        await Task.detached(priority: .userInitiated) {
            guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
            else { return [] }
            return items(PHAsset.fetchAssets(in: album, options: imageOptions()), includeScreenshots: includeScreenshots)
        }.value
    }

    /// Albums you made (including ones inside folders), with photos in them, by title.
    static func albums() async -> [Album] {
        await Task.detached(priority: .userInitiated) {
            var out: [Album] = []
            PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil).enumerateObjects { c, _, _ in
                let n = PHAsset.fetchAssets(in: c, options: imageOptions()).count
                if n > 0 { out.append(Album(id: c.localIdentifier, title: c.localizedTitle ?? "Untitled", count: n)) }
            }
            return out.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }.value
    }

    static let rejectsAlbumTitle = "Winnow Rejects"

    /// Which of `assetIDs` sit in which of your albums (titles), ignoring `excluding` and Winnow's own
    /// rejects album (being in that is the opposite of a vote to keep).
    /// One pass per album rather than one query per photo.
    static func membership(of assetIDs: Set<String>, excluding: String?) async -> [String: [String]] {
        await Task.detached(priority: .utility) {
            var out: [String: [String]] = [:]
            PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil).enumerateObjects { c, _, _ in
                guard c.localIdentifier != excluding, c.localizedTitle != rejectsAlbumTitle else { return }
                let title = c.localizedTitle ?? "Untitled"
                PHAsset.fetchAssets(in: c, options: imageOptions()).enumerateObjects { a, _, _ in
                    if assetIDs.contains(a.localIdentifier) { out[a.localIdentifier, default: []].append(title) }
                }
            }
            return out
        }.value
    }

    /// Adds to the album with this title, creating it if needed.
    static func addToAlbum(_ assets: [PHAsset], title: String) async throws {
        guard !assets.isEmpty else { return }
        var album: PHAssetCollection?
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil).enumerateObjects { c, _, stop in
            if c.localizedTitle == title { album = c; stop.pointee = true }
        }
        let existing = album
        try await PHPhotoLibrary.shared().performChanges {
            let req = existing.map { PHAssetCollectionChangeRequest(for: $0) }
                ?? PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            req?.addAssets(assets as NSArray)
        }
    }

    /// Takes photos out of one album; they stay in the library and any other albums.
    static func remove(_ assets: [PHAsset], fromAlbum id: String) async throws {
        guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
        else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: album)?.removeAssets(assets as NSArray)
        }
    }

    static func favorite(_ assets: [PHAsset]) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            for a in assets { PHAssetChangeRequest(for: a).isFavorite = true }
        }
    }

    /// Photos asks the user to confirm; throws userCancelled if they decline.
    static func delete(_ assets: [PHAsset]) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
    }
}
