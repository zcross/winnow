/// Splits a scan into what to keep and what's left over, for the Apply step.
public struct Outcome<ID: Hashable>: Equatable {
    /// Reviewed keepers, plus (optionally) one-offs and everything in unreviewed groups.
    public var keepers: [ID]
    /// Reviewed rejects only: nothing becomes a leftover without a decision.
    public var rejects: [ID]
    /// Photos from groups nobody has looked at; included in keepers as-is.
    public var unreviewed: [ID]
    /// Photos that never had a near-duplicate.
    public var unique: [ID]

    /// `order` is every scanned photo (time order); `groups` the multi-photo clusters.
    public init(order: [ID], groups: [[ID]], decisions: [ID: Bool], includeUnique: Bool) {
        let grouped = Set(groups.joined())
        var keepers: [ID] = [], rejects: [ID] = [], unreviewed: [ID] = [], unique: [ID] = []
        var groupReviewed: [ID: Bool] = [:]
        for g in groups {
            let done = g.allSatisfy { decisions[$0] != nil }
            for id in g { groupReviewed[id] = done }
        }
        for id in order {
            if !grouped.contains(id) {
                unique.append(id)
                if includeUnique { keepers.append(id) }
            } else if groupReviewed[id] == true {
                if decisions[id] == true { keepers.append(id) } else { rejects.append(id) }
            } else {
                // Part-reviewed groups count as unreviewed: their explicit rejects still stay out.
                if decisions[id] == false { rejects.append(id) } else { unreviewed.append(id); keepers.append(id) }
            }
        }
        (self.keepers, self.rejects, self.unreviewed, self.unique) = (keepers, rejects, unreviewed, unique)
    }
}
