import Foundation
import Testing
@testable import Patchbay

struct PaneLayoutTests {
    let a = UUID(), b = UUID(), c = UUID()

    /// The children and fractions of a split, or nil for a single pane.
    func split(_ layout: PaneLayout?) -> (axis: SplitAxis, children: [PaneLayout], fractions: [Double])? {
        guard case .split(_, let axis, let children, let fractions) = layout else { return nil }
        return (axis, children, fractions)
    }

    @Test func splittingAPane() {
        let layout = PaneLayout.pane(a).inserting(b, at: a, zone: .right)
        #expect(layout.sessionIDs == [a, b])
        #expect(split(layout)?.axis == .horizontal)
        #expect(split(layout)?.fractions == [0.5, 0.5])

        let before = PaneLayout.pane(a).inserting(b, at: a, zone: .top)
        #expect(before.sessionIDs == [b, a])
        #expect(split(before)?.axis == .vertical)
    }

    @Test func splittingAlongTheSameAxisJoinsTheRow() {
        let layout = PaneLayout.pane(a).inserting(b, at: a, zone: .right).inserting(c, at: b, zone: .right)
        #expect(layout.sessionIDs == [a, b, c])
        #expect(split(layout)?.children.count == 3)
        #expect(split(layout)?.fractions == [0.5, 0.25, 0.25])
    }

    @Test func splittingAcrossNests() {
        let layout = PaneLayout.pane(a).inserting(b, at: a, zone: .right).inserting(c, at: b, zone: .bottom)
        #expect(layout.sessionIDs == [a, b, c])
        let inner = split(layout)?.children.last
        #expect(split(inner)?.axis == .vertical)
        #expect(inner?.sessionIDs == [b, c])
    }

    @Test func removingCollapsesSplits() {
        let layout = PaneLayout.pane(a).inserting(b, at: a, zone: .right).inserting(c, at: b, zone: .bottom)
        let removed = layout.removing(c)
        #expect(removed?.sessionIDs == [a, b])
        #expect(split(removed)?.children == [.pane(a), .pane(b)])
        #expect(removed?.removing(b) == .pane(a))
        #expect(PaneLayout.pane(a).removing(a) == nil)
    }

    @Test func fractionsStayWholeAfterRemoving() {
        let layout = PaneLayout.pane(a).inserting(b, at: a, zone: .right).inserting(c, at: b, zone: .right)
        let fractions = split(layout.removing(a))?.fractions ?? []
        #expect(fractions == [0.5, 0.5])
    }

    @Test func swappingReplacingKeeping() {
        let layout = PaneLayout.pane(a).inserting(b, at: a, zone: .right)
        #expect(layout.swapping(a, b).sessionIDs == [b, a])
        #expect(layout.replacing(a, with: c).sessionIDs == [c, b])
        #expect(layout.keeping([b]) == .pane(b))
        #expect(layout.keeping([]) == nil)
    }

    @Test func equalizing() {
        let layout = PaneLayout.pane(a).inserting(b, at: a, zone: .right).inserting(c, at: b, zone: .right)
        #expect(split(layout.equalized())?.fractions == Array(repeating: 1.0 / 3, count: 3))
    }

    @Test func resizingKeepsBothNeighboursAboveTheMinimum() {
        let fractions = resized([0.5, 0.5], at: 0, by: 0.4, minimum: 0.2)
        #expect(fractions[0] == 0.8)
        #expect(abs(fractions[1] - 0.2) < 1e-9)
        #expect(resized([0.5, 0.5], at: 1, by: 0.1, minimum: 0.2) == [0.5, 0.5]) // no boundary after the last
    }
}
