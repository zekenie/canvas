@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Find
import Geometry
import TestKit

// The fields hit: which of a shape's texts hold hits (a row's id, for a kind found a text a row), for a plugin that hides
// some of a shape's texts and shows them while Find is open (LineRows' folds); and the listener told as results change.

@MainActor let fieldsTests = Suite("Find's fields hit", [
    test("fieldsHit names the fields whose texts hold hits, only while Find is open; whenResultsChange is told of each answer, a patch and a close") {
        let shapes = memos(["apple pie", "plum", "apple"])
        let h = try findHarness(CanvasFile(root: CanvasDocument(shapes: shapes)))
        let find = try require(h.editor.find)
        var told = 0
        find.whenResultsChange { told += 1 }
        expectEqual(find.fieldsHit(of: shapes[0].id), [], "nothing before Find opens")
        _ = try search("apple", in: h)
        expectEqual(find.fieldsHit(of: shapes[0].id), ["body"])
        expectEqual(find.fieldsHit(of: shapes[1].id), [], "a shape with no hit")
        let afterSearch = told
        expect(afterSearch >= 1, "told of the answer")
        h.editor.transact("Edit") { $0.update(shapes[1].id, as: Memo.self) { $0.props.body = "apple tart" } }
        try settle(find, h)
        expect(told > afterSearch, "told of the commit's change to the results")
        expectEqual(find.fieldsHit(of: shapes[1].id), ["body"])
        let beforeClose = told
        find.close()
        expectEqual(told, beforeClose + 1, "told as it closes")
        expectEqual(find.fieldsHit(of: shapes[0].id), [], "none while closed")
    },
])
