/// King-of-the-hill picker: the current favourite faces each remaining
/// challenger in turn. n photos take n-1 quick decisions to find the best,
/// and "keep both" lets extra keepers out along the way.
public struct Duel<ID: Hashable> {
    public private(set) var champion: ID
    public private(set) var queue: [ID]
    public private(set) var keepers: [ID] = []
    public private(set) var total: Int
    private var history: [(ID, [ID], [ID])] = []

    /// `ranked` best-first; the top item starts as champion.
    public init?(ranked: [ID]) {
        guard let first = ranked.first else { return nil }
        champion = first
        queue = Array(ranked.dropFirst())
        total = ranked.count
    }

    public var challenger: ID? { queue.first }
    public var isFinished: Bool { queue.isEmpty }
    public var decided: Int { total - 1 - queue.count }
    public var canUndo: Bool { !history.isEmpty }
    public var finalKeepers: Set<ID> { Set(keepers + [champion]) }
    /// Next few challengers, for prefetching.
    public var upcoming: ArraySlice<ID> { queue.prefix(3) }

    public mutating func championWins() {
        guard !queue.isEmpty else { return }
        save()
        queue.removeFirst()
    }

    public mutating func challengerWins() {
        guard !queue.isEmpty else { return }
        save()
        champion = queue.removeFirst()
    }

    /// Both are keepers; the challenger carries on as the one to beat.
    public mutating func keepBoth() {
        guard !queue.isEmpty else { return }
        save()
        keepers.append(champion)
        champion = queue.removeFirst()
    }

    public mutating func undo() {
        guard let (c, q, k) = history.popLast() else { return }
        (champion, queue, keepers) = (c, q, k)
    }

    private mutating func save() { history.append((champion, queue, keepers)) }
}
