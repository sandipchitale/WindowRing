import Foundation

/// A pluggable policy for the order windows appear in the ring.
///
/// Only `MRUOrdering` is implemented in v1, per the product brief's
/// instruction not to over-engineer this. Future policies (alphabetical,
/// grouped-by-application, manually pinned positions) can be added later by
/// creating more conformers — nothing else in the app needs to change.
protocol WindowOrderingPolicy {
    func order(_ windows: [WindowInfo]) -> [WindowInfo]
}

/// Orders windows most-recently-focused first, mirroring the conceptual feel
/// of ⌘Tab but at the window level rather than the application level.
/// Windows with no focus history yet (e.g. opened after launch but never
/// focused) are appended at the end, in WindowDiscovery's original order.
struct MRUOrdering: WindowOrderingPolicy {
    let history: [WindowIdentity]

    func order(_ windows: [WindowInfo]) -> [WindowInfo] {
        var rank: [WindowIdentity: Int] = [:]
        for (index, id) in history.enumerated() {
            rank[id] = index
        }
        return windows.enumerated()
            .sorted { lhs, rhs in
                let lhsRank = rank[lhs.element.id] ?? Int.max
                let rhsRank = rank[rhs.element.id] ?? Int.max
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
