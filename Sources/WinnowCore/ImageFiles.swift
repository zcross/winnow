import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One photo as the camera produced it: the file we show and analyse, plus files that
/// belong to it and travel with it (the RAW half of a RAW+JPEG pair, .xmp/.aae sidecars).
public struct ImageFile: Equatable, Sendable {
    public var primary: URL
    public var companions: [URL] = []

    public init(primary: URL, companions: [URL] = []) {
        self.primary = primary
        self.companions = companions
    }

    /// "RAW+JPEG", "RAW", or nil for a plain rendered image.
    public var formatLabel: String? {
        let raw = ImageFiles.kind(primary) == .raw || companions.contains { ImageFiles.kind($0) == .raw }
        guard raw else { return nil }
        return ImageFiles.kind(primary) == .raw ? "RAW" : "RAW+\(ImageFiles.shortName(primary))"
    }
}

/// Plain image files on disk, for folder sources.
public enum ImageFiles {
    /// Where folder-mode rejects get moved and keepers get copied; both skipped when listing.
    public static let rejectsFolderName = "Winnow Rejects"
    public static let keepersFolderName = "Winnow Keepers"

    static let sidecarExtensions: Set<String> = ["xmp", "aae"]

    enum Kind { case rendered, raw, sidecar, other }

    static func kind(_ url: URL) -> Kind {
        let ext = url.pathExtension.lowercased()
        if sidecarExtensions.contains(ext) { return .sidecar }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .rawImage) { return .raw }
        return type.conforms(to: .image) ? .rendered : .other
    }

    static func shortName(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": "JPEG"
        default: url.pathExtension.uppercased()
        }
    }

    public static func files(in dir: URL) -> [ImageFile] { bundle(list(in: dir)) }

    /// Every image and sidecar file under `dir`, skipping the rejects folder.
    public static func list(in dir: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var out: [URL] = []
        for case let url as URL in e {
            if url.lastPathComponent == rejectsFolderName || url.lastPathComponent == keepersFolderName {
                e.skipDescendants()
                continue
            }
            guard (try? url.resourceValues(forKeys: Set(keys)))?.isRegularFile == true else { continue }
            if kind(url) != .other { out.append(url) }
        }
        return out
    }

    /// Pairs files that share a folder and base name: IMG_1.JPG + IMG_1.CR3 + IMG_1.xmp (or
    /// IMG_1.CR3.xmp) become one photo shown via the JPEG. A RAW with no rendered sibling stands
    /// alone; stray sidecars are dropped; extra rendered siblings (IMG_1.JPG + IMG_1.HEIC) stay separate.
    public static func bundle(_ urls: [URL]) -> [ImageFile] {
        func key(_ url: URL) -> String {
            var name = url.lastPathComponent
            if kind(url) == .sidecar { name = (name as NSString).deletingPathExtension }
            if kind(URL(fileURLWithPath: name)) != .other { name = (name as NSString).deletingPathExtension }
            return url.deletingLastPathComponent().path + "/" + name.lowercased()
        }
        // Prefer what a camera or phone would show: HEIC/JPEG over other rendered formats.
        func rank(_ url: URL) -> Int {
            ["heic": 0, "heif": 0, "jpg": 1, "jpeg": 1][url.pathExtension.lowercased()] ?? 2
        }

        var out: [ImageFile] = []
        for (_, group) in Dictionary(grouping: urls, by: key).sorted(by: { $0.key < $1.key }) {
            let sorted = group.sorted { $0.lastPathComponent < $1.lastPathComponent }
            let rendered = sorted.filter { kind($0) == .rendered }.sorted { rank($0) < rank($1) }
            let raws = sorted.filter { kind($0) == .raw }
            let sidecars = sorted.filter { kind($0) == .sidecar }
            if let first = rendered.first {
                out.append(ImageFile(primary: first, companions: raws + sidecars))
                out += rendered.dropFirst().map { ImageFile(primary: $0) }
            } else if let first = raws.first {
                out.append(ImageFile(primary: first, companions: sidecars))
                out += raws.dropFirst().map { ImageFile(primary: $0) }
            }
        }
        return out
    }

    /// Where to move a photo's files so they stay paired: if any name is taken, the shared stem
    /// gets the same suffix on all of them (IMG_1 2.JPG, IMG_1 2.CR3, IMG_1 2.CR3.xmp).
    public static func destinations(for files: [URL], in dir: URL) -> [URL] {
        let stem = files[0].deletingPathExtension().lastPathComponent
        func names(_ suffix: String) -> [URL] {
            files.map { f in
                let name = f.lastPathComponent
                let renamed = name.lowercased().hasPrefix(stem.lowercased())
                    ? String(name.prefix(stem.count)) + suffix + name.dropFirst(stem.count) : name
                return dir.appendingPathComponent(renamed)
            }
        }
        var n = 1
        var candidate = names("")
        while candidate.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            n += 1
            candidate = names(" \(n)")
        }
        return candidate
    }

    public static func thumbnail(_ url: URL, maxPixels: CGFloat) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        func make(fromImage key: CFString) -> CGImage? {
            let opts: [CFString: Any] = [
                key: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            ]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }
        // RAWs carry a camera-rendered preview, often full size: a 6000px CR3 gives 1600px in
        // ~28ms from it versus ~250ms decoding the RAW. Old cameras embed tiny ones, so check.
        if kind(url) == .raw, let preview = make(fromImage: kCGImageSourceCreateThumbnailFromImageIfAbsent),
           CGFloat(max(preview.width, preview.height)) >= maxPixels * 0.75 {
            return preview
        }
        return make(fromImage: kCGImageSourceCreateThumbnailFromImageAlways)
    }

    static let exifFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    /// EXIF capture time, falling back to the file's modification date.
    public static func captureDate(_ url: URL) -> Date {
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
           let d = exifFormatter.date(from: s) {
            return d
        }
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    public static func modificationStamp(_ url: URL) -> String {
        let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return String(Int(d.timeIntervalSince1970))
    }

    public static func writeJPEG(_ image: CGImage, to url: URL, captureDate: Date, quality: Double = 0.85) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: exifFormatter.string(from: captureDate)],
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }
}
