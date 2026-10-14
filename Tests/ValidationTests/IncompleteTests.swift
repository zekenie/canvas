import Canvas
import CanvasTesting
import CoreGraphics
import DetailPanel
import Geometry
import SwiftUI
import TableOfContents
import TestKit
import Validation

// The third level: a shape still needs something. A rule of any plugin says it; the engine keeps it like any issue; and
// it shows nowhere on the board (no ring, no dot, no line of the Issues tab), and the shape stays valid.

/// A box with no width still needs one (the third level); one with no height has a warning; both have both.
private let needRules = Contributor(id: "rules") { r in
    r.validate(Box.self) { box, _ in
        (box.frame.width == 0 ? [.incomplete("Needs a width.", field: "frame")] : [])
            + (box.frame.height == 0 ? [.warning("No height.")] : [])
    }
}

/// The board of `incompleteTests`' ring test, drawn with no rules at all.
@MainActor private func renderBitmapWithoutIssues(_ size: CGSize) -> Data? {
    guard let h = try? EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin()]) else { return nil }
    h.add(Box(CGRect(x: 40, y: 40, width: 0, height: 0)))
    h.editor.camera = Camera(origin: .zero, zoom: 1)
    return renderBitmap(h.editor, size: size).tiffRepresentation
}

@MainActor let incompleteTests = Suite("Validation: what a shape still needs", [
    test("the level is under a warning, and a shape with only that is valid, with nothing worst to show") {
        expect(Severity.incomplete < .warning && Severity.warning < .error)
        let needs = ValidationResult(issues: [.incomplete("n")])
        expectEqual(needs.isValid, true)
        expectEqual(needs.worst, nil, "nothing shows")
        expectEqual(needs.worstFirst, [], "no line of any list")
        expectEqual(needs.issues.map(\.severity), [.incomplete], "but it is kept")
        expect(!Severity.incomplete.shows && Severity.warning.shows && Severity.error.shows)
    },
    test("beside others it is left out of what shows: worst and the lists are theirs") {
        let result = ValidationResult(issues: [.incomplete("n1"), .warning("w"), .incomplete("n2"), .error("e")])
        expectEqual(result.isValid, false)
        expectEqual(result.worst, .error)
        expectEqual(result.worstFirst.map(\.message), ["e", "w"])
        expectEqual(ValidationResult(issues: [.incomplete("n"), .warning("w")]).worst, .warning)
    },
    test("its maker keeps the field and the place in it") {
        let issue = ValidationIssue.incomplete("Needs one.", field: "lineItems", path: "/0/quantity")
        expectEqual(issue.severity, .incomplete)
        expectEqual(issue.field, "lineItems")
        expectEqual(issue.path, "/0/quantity")
        expect(issue != .warning("Needs one.", field: "lineItems", path: "/0/quantity"), "a different level is a different issue")
    },
    test("the engine keeps it, checks it again with a change and lets it go, as any issue; it is valid throughout") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), needRules])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 0, height: 40)))
        let fine = h.add(Box(CGRect(x: 0, y: 0, width: 40, height: 40)))
        let engine = try require(h.editor.validation)
        expectEqual(engine.results[box]?.issues, [.incomplete("Needs a width.", field: "frame")])
        expectEqual(engine.results[box]?.isValid, true)
        expectEqual(engine.results[fine], nil)
        expectEqual(engine.cachedResult(for: box), .current(ValidationResult(issues: [.incomplete("Needs a width.", field: "frame")])))
        h.editor.transact { $0.update(box, as: Box.self) { $0.frame.size.width = 40 } }
        expectEqual(engine.results[box], nil, "let go")
        h.editor.transact { $0.update(fine, as: Box.self) { $0.frame.size.width = 0 } }
        expectEqual(engine.results[fine]?.issues.map(\.message), ["Needs a width."], "and back for another shape")
        h.editor.undo()
        expectEqual(engine.results[fine], nil, "an undo lets it go")
    },
    test("it is found with no engine, as a run's check does: every rule for the kind, the level kept") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), needRules])
        let box = h.add(Box(.zero))
        let record = try require(h.editor.document[box])
        let found = h.editor.registry.validationIssues(of: record, in: h.editor.shapeContext)
        expectEqual(found.map(\.severity), [.incomplete, .warning])
    },
    test("the overlay draws no ring for it, in full or zoomed out: the board is pixel for pixel the board without the rule") {
        @MainActor func render(_ rules: [any CanvasPlugin], zoom: CGFloat) throws -> Data? {
            let h = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin()] + rules)
            h.add(Box(CGRect(x: 40, y: 40, width: 0, height: 40)))
            h.add(Box(CGRect(x: 140, y: 40, width: 40, height: 40)))
            h.editor.camera = Camera(origin: .zero, zoom: zoom)
            return renderBitmap(h.editor, size: CGSize(width: 600, height: 200)).tiffRepresentation
        }
        for zoom in [2, 0.2] as [CGFloat] {
            let with = try render([needRules], zoom: zoom), without = try render([], zoom: zoom)
            expect(with != nil && with == without, "nothing is drawn for it at \(zoom * 100)%")
        }
    },
    test("the ring of a shape with a warning too is the warning's, and goes with it") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), needRules])
        let both = h.add(Box(CGRect(x: 40, y: 40, width: 0, height: 0)))
        h.editor.camera = Camera(origin: .zero, zoom: 1)
        let engine = try require(h.editor.validation)
        let size = CGSize(width: 300, height: 220)
        let before = renderBitmap(h.editor, size: size)
        expect(before.tiffRepresentation != renderBitmapWithoutIssues(size), "the warning's ring is there")
        #if DEBUG
        expectEqual(engine.ringsKept, 1, "and kept")
        #endif
        h.editor.transact { $0.update(both, as: Box.self) { $0.frame.size.height = 40 } }
        expectEqual(engine.results[both]?.worst, nil, "only what it needs is left")
        _ = renderBitmap(h.editor, size: size)
        #if DEBUG
        expectEqual(engine.ringsKept, 0, "its ring is let go with the warning")
        #endif
    },
    test("the Issues tab has no line for it and is not there while it is all a shape has; beside a warning it lists the warning alone") {
        let h = try harness([ValidationPlugin(), DetailPanelPlugin(), ValidationDetailsPlugin(), needRules, boxSections])
        let needs = h.add(Box(CGRect(x: 0, y: 0, width: 0, height: 40)))
        let both = h.add(Box(.zero))
        expectEqual(try h.layout(needs).tabs.map(\.title), ["Box"], "no Issues tab")
        expectEqual(try h.issues(needs), [])
        expectEqual(try h.layout(both).tabs.map(\.title), ["Box", "Issues"])
        expectEqual(try h.issues(both), [DetailStatus("No height.", tone: .warning)])
        expectEqual(try h.footer(needs), [])
    },
    test("the table of contents marks it no row, and a warning's mark lists the warning alone") {
        let editor = try editor([ValidationPlugin(), TableOfContentsPlugin(), ValidationContentsPlugin(), needRules])
        let needs = editor.add(Box(CGRect(x: 0, y: 0, width: 0, height: 40)))
        let both = editor.add(Box(.zero))
        expectEqual(try editor.marks(needs), [])
        expectEqual(try editor.marks(both).map(\.help), ["No height."])
        expectEqual(try editor.marks(both).map(\.color), [Color(nsColor: Severity.warning.color)])
    },
])
