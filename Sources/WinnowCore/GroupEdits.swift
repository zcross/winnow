/// Your manual fixes to automatic grouping. Stored as constraints on photos rather than on
/// groups, so they survive regrouping (slider changes, rescans).
public struct GroupEdits: Codable, Equatable, Sendable {
    /// A group never continues into one of these photos: it starts a new group.
    public var cuts: Set<String> = []
    /// Pairs of photos that belong together; applied after cuts, so an explicit merge wins.
    public var links: [[String]] = []

    public init() {}

    public var isEmpty: Bool { cuts.isEmpty && links.isEmpty }

    /// Splits `group` (time order) before `photo`, dropping merges that would rejoin the halves.
    public mutating func split(_ group: [String], before photo: String) {
        guard let i = group.firstIndex(of: photo), i > 0 else { return }
        cuts.insert(photo)
        let before = Set(group[..<i]), after = Set(group[i...])
        links.removeAll { l in (before.contains(l[0]) && after.contains(l[1])) || (after.contains(l[0]) && before.contains(l[1])) }
    }

    /// Takes `photo` out of `group` on its own; the photos either side stay together.
    public mutating func detach(_ group: [String], _ photo: String) {
        guard let i = group.firstIndex(of: photo) else { return }
        split(group, before: photo)
        if i + 1 < group.count { split(Array(group[i...]), before: group[i + 1]) }
        if i > 0, i + 1 < group.count { links.append([group[i - 1], group[i + 1]]) }
    }

    public mutating func merge(_ a: [String], _ b: [String]) {
        guard let x = a.last, let y = b.first else { return }
        links.append([x, y])
    }

    /// Forgets edits touching these photos.
    public mutating func reset(_ photos: Set<String>) {
        cuts.subtract(photos)
        links.removeAll { photos.contains($0[0]) || photos.contains($0[1]) }
    }

    /// `groups` are automatic groups (singletons included) in time order, members in time order;
    /// `position` gives each photo's time rank.
    public func apply(to groups: [[String]], position: [String: Int]) -> [[String]] {
        guard !isEmpty else { return groups }
        var pieces: [[String]] = []
        for g in groups {
            var current: [String] = []
            for id in g {
                if cuts.contains(id), !current.isEmpty { pieces.append(current); current = [] }
                current.append(id)
            }
            if !current.isEmpty { pieces.append(current) }
        }

        var owner: [String: Int] = [:]
        for (i, p) in pieces.enumerated() { for id in p { owner[id] = i } }
        var parent = Array(pieces.indices)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        for l in links where l.count == 2 {
            guard let a = owner[l[0]], let b = owner[l[1]] else { continue }
            let (ra, rb) = (find(a), find(b))
            if ra != rb { parent[Swift.max(ra, rb)] = Swift.min(ra, rb) }
        }
        var merged: [Int: [String]] = [:]
        for (i, p) in pieces.enumerated() { merged[find(i), default: []].append(contentsOf: p) }
        let rank = { (id: String) in position[id] ?? Int.max }
        return merged.values
            .map { $0.sorted { rank($0) < rank($1) } }
            .sorted { rank($0[0]) < rank($1[0]) }
    }
}
