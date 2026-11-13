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

    /// What a fresh read of a project's sessions means for its sidebar rows.
    public struct Reconciliation: Equatable, Sendable {
        /// The rows to show, in sidebar order.
        public let sessions: [RemoteSession]
        /// Rows shown before that the host no longer has, apart from a kept
        /// on-screen one.
        public let vanished: [SessionID]
    }

    /// Merges a fresh read from the host into the rows already shown. The
    /// read wins: names, titles, and sessions created or ended elsewhere
    /// (another device, a terminal on the host). The exception is the session
    /// on screen, `keeping`: once it's gone from the host its row stays as
    /// last known, in place, so its "session ended" overlay can explain what
    /// happened rather than the terminal vanishing under the user.
    public static func reconcile(
        previous: [RemoteSession],
        fresh: [RemoteSession],
        order: [SessionID],
        keeping onScreen: SessionID?
    ) -> Reconciliation {
        let liveIDs = Set(fresh.map(\.id))
        var rows = apply(order: order, to: fresh)
        var kept: SessionID?
        if let onScreen, !liveIDs.contains(onScreen),
           let index = previous.firstIndex(where: { $0.id == onScreen }) {
            // After the nearest surviving row above it, so it doesn't jump.
            let anchor = previous[..<index].last { liveIDs.contains($0.id) }?.id
            let position = anchor.flatMap { id in rows.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
            rows.insert(previous[index], at: position)
            kept = onScreen
        }
        let vanished = previous.map(\.id).filter { !liveIDs.contains($0) && $0 != kept }
        return Reconciliation(sessions: rows, vanished: vanished)
    }
}
