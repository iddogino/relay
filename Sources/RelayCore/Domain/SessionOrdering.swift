import Foundation

/// Applies the user's drag-to-reorder arrangement to a remote-reconciled
/// session list. Session lists come back from the provider in its order, so
/// the user's ordering lives as an overlay: a flat list of session IDs whose
/// relative order is what the sidebar shows. The list is app-global — only
/// relative order within one project ever matters, which keeps the overlay a
/// simple array instead of a per-project table.
public enum SessionOrdering {
    /// Sorts `sessions` by their position in `order`. Sessions the overlay
    /// doesn't know (created outside the app, or adopted) keep their
    /// provider-reported relative order after the known ones.
    public static func apply(order: [SessionID], to sessions: [RemoteSession]) -> [RemoteSession] {
        guard !order.isEmpty else { return sessions }
        var rank: [SessionID: Int] = [:]
        for (index, id) in order.enumerated() where rank[id] == nil { rank[id] = index }
        return sessions.enumerated()
            .sorted { a, b in
                let ra = rank[a.element.id] ?? Int.max
                let rb = rank[b.element.id] ?? Int.max
                return ra != rb ? ra < rb : a.offset < b.offset
            }
            .map(\.element)
    }
}
