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
        let fractions: [Double] = split(layout)?.fractions ?? []
        #expect(fractions.count == 3 && fractions.allSatisfy { abs($0 - 1.0 / 3) < 1e-9 }) // the new pane gets an equal share
    }

    @Test func removingMergesARowLeftInsideARow() {
        let d = UUID()
        // a | (b over (c | d)); without b, c and d join a's row.
        let layout = PaneLayout.pane(a).inserting(b, at: a, zone: .right).inserting(c, at: b, zone: .bottom)
            .inserting(d, at: c, zone: .right)
        let removed = layout.removing(b)
        #expect(split(removed)?.children == [.pane(a), .pane(c), .pane(d)])
        #expect(split(removed)?.fractions == [0.5, 0.25, 0.25])
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
        #expect(fractions.count == 2 && fractions.allSatisfy { abs($0 - 0.5) < 1e-9 })
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

    @Test func grid() {
        let d = UUID(), e = UUID()
        #expect(PaneLayout.grid([a]) == .pane(a))
        #expect(split(.grid([a, b]))?.axis == .horizontal)
        let five = PaneLayout.grid([a, b, c, d, e])
        #expect(five.sessionIDs == [a, b, c, d, e])
        #expect(split(five)?.axis == .vertical)
        #expect(split(five)?.children.map(\.sessionIDs) == [[a, b, c], [d, e]])
    }

    @Test func resizingKeepsBothNeighboursAboveTheMinimum() {
        let fractions = resized([0.5, 0.5], at: 0, by: 0.4, minimum: 0.2)
        #expect(fractions[0] == 0.8)
        #expect(abs(fractions[1] - 0.2) < 1e-9)
        #expect(resized([0.5, 0.5], at: 1, by: 0.1, minimum: 0.2) == [0.5, 0.5]) // no boundary after the last
    }
}
