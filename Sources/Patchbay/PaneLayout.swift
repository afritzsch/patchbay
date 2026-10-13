import Foundation

enum SplitAxis: String, Codable {
    /// Children side by side.
    case horizontal
    /// Children stacked top to bottom.
    case vertical
}

/// Where something was dropped on a pane.
enum DropZone: Equatable {
    case left, right, top, bottom, center

    var axis: SplitAxis? {
        switch self {
        case .left, .right: .horizontal
        case .top, .bottom: .vertical
        case .center: nil
        }
    }

    /// The new pane goes before (left of / above) the target.
    var insertsBefore: Bool { self == .left || self == .top }
}

/// The panes shown in the main area: a tree of splits whose leaves are sessions. Each session appears at
/// most once; sessions not in the tree are only in the sidebar.
enum PaneLayout: Codable, Equatable {
    case pane(UUID)
    case split(id: UUID, axis: SplitAxis, children: [PaneLayout], fractions: [Double])

    var sessionIDs: [UUID] {
        switch self {
        case .pane(let id): [id]
        case .split(_, _, let children, _): children.flatMap(\.sessionIDs)
        }
    }

    func contains(_ id: UUID) -> Bool { sessionIDs.contains(id) }

    /// The tree without `id`'s pane; a split left with one child is replaced by that child.
    func removing(_ id: UUID) -> PaneLayout? {
        switch self {
        case .pane(let leaf):
            return leaf == id ? nil : self
        case .split(let splitID, let axis, let children, let fractions):
            var kept: [PaneLayout] = []
            var keptFractions: [Double] = []
            for (child, fraction) in zip(children, fractions) {
                if let child = child.removing(id) {
                    kept.append(child)
                    keptFractions.append(fraction)
                }
            }
            if kept.isEmpty { return nil }
            if kept.count == 1 { return kept[0] }
            return .split(id: splitID, axis: axis, children: kept, fractions: Self.normalized(keptFractions))
        }
    }

    /// Puts `new` in `target`'s pane, which leaves the layout.
    func replacing(_ target: UUID, with new: UUID) -> PaneLayout {
        mapLeaves { $0 == target ? new : $0 }
    }

    /// Exchanges the panes of two sessions.
    func swapping(_ a: UUID, _ b: UUID) -> PaneLayout {
        mapLeaves { $0 == a ? b : $0 == b ? a : $0 }
    }

    /// Splits `target`'s pane and puts `new` on the given side. Joins the parent split when it already
    /// runs along the same axis, so three side-by-side panes share one row instead of nesting.
    func inserting(_ new: UUID, at target: UUID, zone: DropZone) -> PaneLayout {
        guard let axis = zone.axis else { return replacing(target, with: new) }
        switch self {
        case .pane(let leaf):
            guard leaf == target else { return self }
            let children: [PaneLayout] = zone.insertsBefore ? [.pane(new), self] : [self, .pane(new)]
            return .split(id: UUID(), axis: axis, children: children, fractions: [0.5, 0.5])
        case .split(let splitID, let splitAxis, var children, var fractions):
            if splitAxis == axis, let index = children.firstIndex(of: .pane(target)) {
                let half = fractions[index] / 2
                fractions[index] = half
                let at = zone.insertsBefore ? index : index + 1
                children.insert(.pane(new), at: at)
                fractions.insert(half, at: at)
                return .split(id: splitID, axis: splitAxis, children: children, fractions: fractions)
            }
            return .split(id: splitID, axis: splitAxis,
                          children: children.map { $0.inserting(new, at: target, zone: zone) }, fractions: fractions)
        }
    }

    func settingFractions(_ new: [Double], forSplit id: UUID) -> PaneLayout {
        switch self {
        case .pane:
            return self
        case .split(let splitID, let axis, let children, let fractions):
            if splitID == id { return .split(id: splitID, axis: axis, children: children, fractions: new) }
            return .split(id: splitID, axis: axis,
                          children: children.map { $0.settingFractions(new, forSplit: id) }, fractions: fractions)
        }
    }

    func equalized() -> PaneLayout {
        switch self {
        case .pane:
            return self
        case .split(let id, let axis, let children, _):
            return .split(id: id, axis: axis, children: children.map { $0.equalized() },
                          fractions: Array(repeating: 1 / Double(children.count), count: children.count))
        }
    }

    /// Drops panes whose sessions no longer exist, e.g. in a layout restored from disk.
    func keeping(_ ids: Set<UUID>) -> PaneLayout? {
        sessionIDs.filter { !ids.contains($0) }.reduce(Optional(self)) { $0?.removing($1) }
    }

    private func mapLeaves(_ transform: (UUID) -> UUID) -> PaneLayout {
        switch self {
        case .pane(let id):
            return .pane(transform(id))
        case .split(let id, let axis, let children, let fractions):
            return .split(id: id, axis: axis, children: children.map { $0.mapLeaves(transform) }, fractions: fractions)
        }
    }

    private static func normalized(_ fractions: [Double]) -> [Double] {
        let total = fractions.reduce(0, +)
        return total > 0 ? fractions.map { $0 / total } : fractions
    }
}
