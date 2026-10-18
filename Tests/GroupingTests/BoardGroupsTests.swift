import Canvas
import Grouping
import TestKit

/// Five shapes, back to front, for the pure tests: a, b, c, d, e.
private let a = ShapeID(), b = ShapeID(), c = ShapeID(), d = ShapeID(), e = ShapeID()

private func groups(_ paths: KeyValuePairs<ShapeID, [String]>) -> BoardGroups {
    let order = [a, b, c, d, e]
    let stored = Dictionary(uniqueKeysWithValues: paths.map { ($0.key, $0.value) })
    return BoardGroups(order.compactMap { id in stored[id].map { (id: id, path: $0) } })
}

@MainActor let boardGroupsTests = Suite("What groups count on a board, and what grouping writes", [
    test("a group counts while it holds two parts or more; a shape holding a group of one is in none") {
        let board = groups([a: ["g"], b: ["g"], c: ["lone"]])
        expectEqual(board.shapes["g"], [a, b])
        expectEqual(board.path(of: a), ["g"])
        expectEqual(board.shapes["lone"], nil)
        expectEqual(board.path(of: c), [])
        expectEqual(board.path(of: d), [])
    },
    test("groups in groups: each counts its parts, a group in it one of them; a group whose one part is a group is gone, and so is one of one shape") {
        let nested = groups([a: ["o", "i"], b: ["o", "i"], c: ["o"]])
        expectEqual(nested.shapes["o"], [a, b, c])
        expectEqual(nested.shapes["i"], [a, b])
        expectEqual(nested.path(of: a), ["o", "i"])
        let wrapped = groups([a: ["o", "i"], b: ["o", "i"]])
        expectEqual(wrapped.shapes["o"], nil, "its one part is i")
        expectEqual(wrapped.path(of: a), ["i"])
        let thin = groups([a: ["o", "i"], b: ["o"]])
        expectEqual(thin.shapes["i"], nil)
        expectEqual(thin.shapes["o"], [a, b], "a counts as a part of o itself")
        let chain = groups([a: ["x", "y", "z"], b: ["x", "y", "z"], c: ["x"]])
        expectEqual(chain.path(of: a), ["x", "z"], "y's one part is z")
        expectEqual(chain.shapes["x"], [a, b, c])
    },
    test("a path naming a group twice counts it once") {
        expectEqual(groups([a: ["g", "g"], b: ["g"]]).path(of: a), ["g"])
    },
    test("grouping two shapes puts them in a new group; one shape, or one group whole, isn't grouped") {
        let board = groups([c: ["g"], d: ["g"]])
        expectEqual(board.grouping([a, b], as: "new"), [a: ["new"], b: ["new"]])
        expectEqual(board.grouping([a], as: "new"), nil)
        expectEqual(board.grouping([c, d], as: "new"), nil, "a group whole is one part")
        expectEqual(board.grouping([], as: "new"), nil)
        expect(board.canGroup([a, c, d]))
        expect(!board.canGroup([c, d]))
    },
    test("grouping a group held whole with a shape keeps the group, in the new one; a group held in part is left") {
        let board = groups([a: ["g"], b: ["g"], c: ["h"], d: ["h"]])
        expectEqual(board.grouping([a, b, e], as: "new"), [a: ["new", "g"], b: ["new", "g"], e: ["new"]])
        expectEqual(board.grouping([a, c, d], as: "new"), [a: ["new"], c: ["new", "h"], d: ["new", "h"]], "a leaves g, which is then b alone")
    },
    test("grouping inside a group: the new group is in it") {
        let board = groups([a: ["o"], b: ["o"], c: ["o"]])
        expectEqual(board.grouping([a, b], as: "new"), [a: ["o", "new"], b: ["o", "new"]])
    },
    test("ungrouping takes apart the outermost groups held whole, a level; inside a group, those in it") {
        let nested = groups([a: ["o", "i"], b: ["o", "i"], c: ["o"], d: ["h"], e: ["h"]])
        expectEqual(nested.ungrouping([a, b, c]), [a: ["i"], b: ["i"], c: []])
        expectEqual(nested.ungrouping([a, b]), [a: ["o"], b: ["o"]], "inside o, i whole")
        expectEqual(nested.ungrouping([a, b, c, d, e]), [a: ["i"], b: ["i"], c: [], d: [], e: []], "both outermost")
        expectEqual(nested.ungrouping([a]), nil, "a part of a group holds none whole")
        expect(nested.canUngroup([d, e]))
        expect(!nested.canUngroup([a, d]))
        expectEqual(groups([:]).ungrouping([a, b]), nil)
    },
    test("copies keep the groups two or more of them share, under new ids, and drop those only one holds") {
        var minted = 0
        let copies = BoardGroups.copied([a: ["g", "i"], b: ["g", "i"], c: ["g"], d: ["h"]]) {
            minted += 1
            return "new\(minted)"
        }
        expectEqual(copies[a], copies[b])
        expectEqual(copies[a]?.count, 2)
        expectEqual(copies[c], copies[a].map { Array($0.prefix(1)) })
        expectEqual(copies[d], [], "h, held by one copy, is gone")
        expect(!(copies[a] ?? []).contains("g"), "never the original's id")
        expectEqual(minted, 2)
    },
])
