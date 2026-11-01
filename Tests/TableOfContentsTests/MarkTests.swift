import AppKit
import Canvas
import CanvasTesting
import CoreGraphics
import Keyboard
import Selection
import SwiftUI
import TableOfContents
import TestKit

/// The shapes flagged, which `flags` marks: state kept outside the shapes, as a service's is.
@MainActor var flagged: Set<ShapeID> = []
/// The shapes flagged or unflagged since the last commit, which `flags` says that commit affects,
/// as another plugin names the shapes a commit may change the marks of.
@MainActor var reflagged: Set<ShapeID> = []
/// How often `flags` has made a mark.
@MainActor var marksMade = 0

/// An orange mark on each flagged shape's row, read through a service, as another plugin reads an engine.
let flags = Contributor(id: "flags") { r in
    r.forEveryShape { scope in
        scope.contentsMark(affected: { _, _ in
            defer { reflagged = [] }
            return reflagged
        }) { shape, context in
            marksMade += 1
            return context.service(ContentsState.self) != nil && flagged.contains(shape.id) ? ContentsMark(color: .orange, help: "Flagged") : nil
        }
    }
}

/// Flags `ids`, alone, from the next commit on.
@MainActor func flag(_ ids: Set<ShapeID>) {
    reflagged = flagged.symmetricDifference(ids)
    flagged = ids
}

extension Array where Element == ContentsEntry {
    /// Each row's marks' help, nested rows' after theirs.
    @MainActor var marks: [[String]] { flatMap { entry -> [[String]] in [entry.marks.map(\.help)] + (entry.children ?? []).marks } }
}

@MainActor let markTests = Suite("Table of contents: marks", [
    test("a row's marks: the kind's, then every kind's, each in plugin order; nil is none") {
        let editor = try contentsEditor([
            Contributor(id: "a") { r in r.forEveryShape { scope in
                scope.contentsMark { _, _ in ContentsMark(color: .red, help: "a") }
            } },
            Contributor(id: "b") { r in
                r.contribute(ContentsMarkContribution { _, _ in ContentsMark(color: .blue, help: "widget b") }, to: ContentsMarks.self, for: .kind(Widget.kind))
                r.forEveryShape { scope in
                    scope.contentsMark { shape, _ in shape.kind == Gizmo.kind ? nil : ContentsMark(color: .green, help: "b") }
                }
            },
        ])
        editor.add(Widget(name: "W"))
        editor.add(Gizmo())
        expectEqual(editor.contents.entries.marks, [["widget b", "a", "b"], ["a"]])
    },
    test("a scoped mark goes only on the kinds its scope reaches, its capability asked once per kind; a mark may be a symbol") {
        @MainActor final class Asked { var kinds: [ShapeKind] = [] }
        let asked = Asked()
        let editor = try contentsEditor([Contributor(id: "stars") { r in
            r.forShapes(adopting: ShapeCapability("that is a widget") { kind in
                asked.kinds.append(kind.kind)
                return kind.kind == Widget.kind
            }) { scope in
                scope.contentsMark { _, _ in ContentsMark(symbol: "star.fill", color: .secondary, help: "Starred") }
            }
        }])
        editor.add(Widget(name: "W"))
        editor.add(Gizmo())
        editor.add(Widget(name: "V"))
        expectEqual(editor.contents.entries.marks, [["Starred"], [], ["Starred"]])
        expectEqual(editor.contents.entries.first?.marks.first?.symbol, "star.fill")
        expectEqual(asked.kinds.sorted { $0.rawValue < $1.rawValue }, editor.registry.kinds.sorted { $0.rawValue < $1.rawValue },
                    "once per kind, as the registry is built")
        expectEqual(ContentsMark(color: .red, help: "a").symbol, nil, "a dot, by default")
    },
    test("a mark is made with its row; after a commit, marks are read again only for the shapes it changed and those its contributor says it may") {
        flag([])
        let editor = try contentsEditor([flags])
        let (a, b, c) = threeWidgets(editor)
        _ = editor.contents.entries
        marksMade = 0
        let rowsMade = widgetRowsMade
        flag([a])
        expectEqual(editor.contents.entries.marks, [[], [], []], "until a commit")
        editor.transact { $0.update(c, as: Widget.self) { $0.props.count = 1 } }
        expectEqual(editor.contents.entries.marks, [["Flagged"], [], []])
        expectEqual(marksMade, 2, "A's, which the commit may change, and C's, which it changed; not B's")
        expectEqual(widgetRowsMade, rowsMade + 1, "only C's row is made again; A's keeps its view, with its new mark")
        editor.transact { $0.update(b, as: Widget.self) { $0.props.count = 1 } }
        expectEqual(editor.contents.entries.marks, [["Flagged"], [], []])
        expectEqual(marksMade, 3, "B's")
    },
    test("a shape whose marks a commit may change, but doesn't, keeps its row: only its marks are read again") {
        flag([])
        let editor = try contentsEditor([flags])
        let (_, b, c) = threeWidgets(editor)
        _ = editor.contents.entries
        marksMade = 0
        let rowsMade = widgetRowsMade
        reflagged = [b]                     // named as affected, still unflagged
        editor.transact { $0.update(c, as: Widget.self) { $0.props.count = 1 } }
        expectEqual(editor.contents.entries.marks, [[], [], []])
        expectEqual(marksMade, 2, "B's read again, and C's made with its row")
        expectEqual(widgetRowsMade, rowsMade + 1, "C's row alone")
    },
    test("read by a service that hears of a commit first, a row whose mark the commit may change is right all the same") {
        flag([])
        let editor = CanvasEditor(registry: try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), WidgetsPlugin(), flags,
                                                                   Contributor(id: "early-reader") { $0.service { _ in EarlyReader() } },
                                                                   TableOfContentsPlugin()]),
                                  scheduler: ManualScheduler())
        let reader = try require(editor.service(EarlyReader.self))
        let (a, _, c) = threeWidgets(editor)
        _ = editor.contents.entries
        reader.reads = true
        flag([a])
        editor.transact { $0.update(c, as: Widget.self) { $0.props.count = 1 } }
        expectEqual(reader.heard, ["A", "B", "C"])
        expectEqual(reader.heardMarks, [["Flagged"], [], []], "as the reader read them, before the table of contents heard")
        expectEqual(editor.contents.entries.marks, [["Flagged"], [], []])
    },
    test("marks need the table of contents installed") {
        expectThrows(RegistryError.ownerNotInstalled(point: "ContentsMarks", owner: .tableOfContents, contributor: "flags")) {
            _ = try Registry(plugins: [FixturesPlugin(), flags])
        }
    },
    test("a mark is a small dot in its color at the row's trailing end, and nothing else changes") {
        // The same board twice, one with A flagged. No badges: a row's badge moves over for its marks.
        let ids = (ShapeID(), ShapeID())
        @MainActor func window() throws -> ContentsWindow {
            let editor = try contentsEditor([flags], scheduler: TaskScheduler())
            editor.add(Widget(CGRect(x: 0, y: 0, width: 100, height: 60), name: "A"), id: ids.0)
            editor.add(Widget(CGRect(x: 200, y: 0, width: 100, height: 60), name: "B"), id: ids.1)
            let w = ContentsWindow(editor)
            w.window.spin { w.rows == 2 }
            return w
        }
        flag([])
        let plain = try window()
        let before = snapshot(plain.hosting)
        flag([ids.0])
        let marked = try window()
        let after = snapshot(marked.hosting)
        let rowA = try marked.rect(ofRow: 1)                   // front to back: B, A
        expectEqual(changedPixels(before, after, in: marked.hosting.bounds) - changedPixels(before, after, in: rowA), 0, "only A's row changes")
        let dot = try require(differingBounds(before, after, in: rowA))
        expect((4...9).contains(dot.width) && (4...9).contains(dot.height), "about 6 points across: \(dot)")
        expect(dot.maxX > rowA.maxX - 40, "at the trailing end: \(dot) in \(rowA)")
        let center = pixel(after, at: CGPoint(x: dot.midX, y: dot.midY))
        expect(center[0] > 200 && (100...200).contains(center[1]) && center[2] < 100, "orange: \(center)")
    },
])

/// Where, in view points, `a` differs from `b` within `rect`: the smallest rect around every point
/// that does. Nil when none does.
@MainActor func differingBounds(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, in rect: CGRect) -> CGRect? {
    var bounds = CGRect.null
    for y in Int(rect.minY)..<Int(rect.maxY) {
        for x in Int(rect.minX)..<Int(rect.maxX) where pixel(a, at: CGPoint(x: x, y: y)) != pixel(b, at: CGPoint(x: x, y: y)) {
            bounds = bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
        }
    }
    return bounds.isNull ? nil : bounds
}
