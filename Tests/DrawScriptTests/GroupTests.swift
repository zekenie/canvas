import DrawScript
import TestKit

// `group "A" and "B"` and `ungroup "A"`: shapes a script puts in one group, or takes out of every group. The language knows
// only the names: two or more for a group, one or more for an ungroup, each a title in quotes or an id, joined by `and` (or
// commas, as a placement's targets are). What a group is, and the board the shapes are on, are the caller's.

private let one = "7C1E2A04-4B9E-4E0C-9D8C-5B0E7F3A2C11"
private let two = "b3d9f0e1-6a52-4c8d-a7e4-1f2b9c3d5e60"

/// The group a line says, or nil if it isn't one.
@MainActor private func group(_ source: String) throws -> GroupStatement {
    guard case .group(let group) = try parse(source) else {
        expect(false, "\(source) isn't a group")
        throw RequireFailed()
    }
    return group
}

/// The ungroup a line says.
@MainActor private func ungroup(_ source: String) throws -> GroupStatement {
    guard case .ungroup(let group) = try parse(source) else {
        expect(false, "\(source) isn't an ungroup")
        throw RequireFailed()
    }
    return group
}

@MainActor let groupTests = Suite("Groups and ungroups", [
    test("group names two shapes or more joined by and, ungroup one or more; the statement is the shapes in the order written") {
        expectEqual(try group(#"group "A" and "B""#), GroupStatement(shapes: ["A", "B"]))
        expectEqual(try group(#"group "A" and "B" and "C""#).shapes, ["A", "B", "C"])
        expectEqual(try ungroup(#"ungroup "A""#), GroupStatement(shapes: ["A"]))
        expectEqual(try ungroup(#"ungroup "B" and "A""#).shapes, ["B", "A"])
        expectEqual(try group(#"group "A" and "B""#).written, #""A" and "B""#)
        expectEqual(try group(#"group "A" and "B" and "C""#).written, #""A", "B" and "C""#)
        let script = try Script(parsing: """
            card "A"
            card "B" right of "A"
              group "A" and "B"   // together
            ungroup "A"
            """)
        expectEqual(script.statements.map(\.line), [1, 2, 3, 4])
        expectEqual(script.statements[2].text, #"group "A" and "B""#, "its comment stripped")
        expectEqual(script.statements[2].body, .group(GroupStatement(shapes: ["A", "B"])))
        expectEqual(script.statements[3].body, .ungroup(GroupStatement(shapes: ["A"])))
    },
    test("a comma joins as and does, as the targets of a placement are joined, and the two together") {
        expectEqual(try group(#"group "A", "B" and "C""#).shapes, ["A", "B", "C"])
        expectEqual(try group(#"group "A", "B", "C""#).shapes, ["A", "B", "C"])
        expectEqual(try group(#"group "A", and "B""#).shapes, ["A", "B"])
        expectEqual(try group(#"group "A","B""#).shapes, ["A", "B"])
        expectEqual(try ungroup(#"ungroup "A", "B""#).shapes, ["A", "B"])
    },
    test("a title is read as everywhere: folded by the caller, its escapes undone, whatever it holds") {
        expectEqual(try group(#"group "say \"hi\"" and "a // b""#).shapes, [.title("say \"hi\""), .title("a // b")])
        expectEqual(try group(##"group "#1" and "and""##).shapes, [.title("#1"), .title("and")], "a quoted word is a title")
        expectEqual(try group(#"group "A" and "B""#).shapes.map(\.written), [#""A""#, #""B""#])
    },
    test("a shape with no title is named by its id, in either case, among titles") {
        expectEqual(try group("group #\(one) and \"B\"").shapes, [.id(one), .title("B")])
        expectEqual(try group("group \"A\" and #\(two)").shapes, [.title("A"), .id(two)])
        expectEqual(try ungroup("ungroup #\(one) and #\(two)").shapes, [.id(one), .id(two)])
        expectEqual(try group("group #\(one), #\(two)").written, "#\(one) and #\(two)", "written round-trips")
    },
    test("a group of fewer than two shapes is refused, the fix being another shape joined with and") {
        let single = parseError(#"group "A""#)
        expectEqual(single?.reason, .syntax)
        expectEqual(single?.message, #"group "A": a group is two shapes or more, and this names one"#)
        expectEqual(single?.hint, #"join another with and: group "A" and "B""#)
        expectEqual(single?.line, 1)
        expectEqual(single?.statement, #"group "A""#)
        expectEqual(parseError("group #\(one)")?.message, "group #\(one): a group is two shapes or more, and this names one")
        // An ungroup of one is what it is for.
        expectEqual(parseError(#"ungroup "A""#), nil)
    },
    test("a statement that names no shape says what it names") {
        let group = parseError("group")
        expectEqual(group?.reason, .syntax)
        expectEqual(group?.message, "group names the shapes it puts in one group")
        expectEqual(group?.hint, #"write group "A" and "B""#)
        let ungroup = parseError("ungroup")
        expectEqual(ungroup?.message, "ungroup names the shapes it takes out of their groups")
        expectEqual(ungroup?.hint, #"write ungroup "A""#)
    },
    test("shapes are joined by and: two titles side by side are refused, with the fix") {
        let group = parseError(#"group "A" "B""#)
        expectEqual(group?.reason, .syntax)
        expectEqual(group?.message, #"group "A": "B" is a title where none goes"#)
        expectEqual(group?.hint, #"join the shapes with and: "A" and "B""#)
        let ungroup = parseError(#"ungroup "A" "B" "C""#)
        expectEqual(ungroup?.message, #"ungroup "A": "B" is a title where none goes"#)
        expectEqual(ungroup?.hint, #"join the shapes with and: "A" and "B""#)
        expectEqual(parseError(#"group "A" and "B" "C""#)?.hint, #"join the shapes with and: "B" and "C""#)
        let id = parseError("group \"A\" #\(one)")
        expectEqual(id?.message, "group \"A\": #\(one) is an id where none goes")
        expectEqual(id?.hint, "join the shapes with and: \"A\" and #\(one)")
    },
    test("an and or comma that joins nothing is refused") {
        expectEqual(parseError(#"group "A" and"#)?.message, #"group "A": and joins a shape, and none follows it"#)
        expectEqual(parseError(#"group "A" and"#)?.hint, #"write group "A" and "B""#)
        expectEqual(parseError(#"ungroup "A" and"#)?.hint, #"write ungroup "A""#)
        expectEqual(parseError(#"group "A","#)?.message, #"group "A": a comma joins a shape, and none follows it"#)
        let leading = parseError(#"group and "A""#)
        expectEqual(leading?.reason, .syntax)
        expectEqual(leading?.message, "and is out of place: group names shapes by their titles")
        expectEqual(parseError(#"group "A" and and "B""#)?.message, #"group "A": and is out of place: group names shapes by their titles"#)
        expectEqual(parseError(#"group , "A""#)?.message, ", is out of place: group names shapes by their titles")
    },
    test("a title is quoted: a bare word is refused, with every bare name quoted in the fix") {
        let first = parseError("group A and B")
        expectEqual(first?.reason, .syntax)
        expectEqual(first?.message, "A isn't quoted, and titles are in double quotes")
        expectEqual(first?.hint, #"write group "A" and "B""#)
        let later = parseError(#"group "A" and B"#)
        expectEqual(later?.message, #"group "A": B isn't quoted, and titles are in double quotes"#)
        expectEqual(later?.hint, #"write group "A" and "B""#)
        expectEqual(parseError("ungroup Web")?.hint, #"write ungroup "Web""#)
        expectEqual(parseError(#"group "A", B, "C""#)?.hint, #"write group "A", "B" and "C""#)
        expectEqual(parseError("group 12 and \"A\"")?.hint, #"write group "12" and "A""#, "a number is a word")
    },
    test("a title can't be blank, and an id that isn't one is not_an_id") {
        let blank = parseError(#"group "A" and " ""#)
        expectEqual(blank?.reason, .syntax)
        expectEqual(blank?.message, #"group "A": a title can't be blank"#)
        for source in ["group #nope and \"B\"", "group \"A\" and #7C1E2A04", "ungroup #Services", "ungroup \"A\" and #12"] {
            let error = parseError(source)
            expectEqual(error?.reason, .notAnID, source)
            expectEqual(error?.line, 1, source)
        }
    },
    test("nothing follows the shapes: a group has no attributes or placements, which go on a shape's own line") {
        let placement = parseError(#"group "A" and "B" right of "C""#)
        expectEqual(placement?.reason, .syntax)
        expectEqual(placement?.message, #"group "A" and "B": group takes the shapes and nothing after them (right)"#)
        expectEqual(placement?.hint, #"a placement or an attribute goes on a shape's own line; write group "A" and "B""#)
        expectEqual(parseError(#"group "A" and "B" text: "x""#)?.message, #"group "A" and "B": group takes the shapes and nothing after them (text:)"#)
        expectEqual(parseError(#"ungroup "A" -> "B""#)?.message, #"ungroup "A": ungroup takes the shapes and nothing after them (->)"#)
        expectEqual(parseError("group text: \"x\"")?.message, "text: is out of place: group names shapes by their titles")
    },
    test("every line that can't be read is reported with the rest of the script, in line order") {
        let errors = parseErrors("""
            group "A"
            ungroup
            card "B"
            group "C" and
            """)
        expectEqual(errors.map(\.line), [1, 2, 4])
        expectEqual(errors.map(\.reason), [.syntax, .syntax, .syntax])
        expectEqual(errors.map(\.statement), [#"group "A""#, "ungroup", #"group "C" and"#])
    },
    test("group and ungroup are statements of the language's own, never a kind: read so, and a shape may be called either") {
        expectEqual(try parse(#"group "A" and "B""#), .group(GroupStatement(shapes: ["A", "B"])))
        expectEqual(try parse(#"ungroup "A""#), .ungroup(GroupStatement(shapes: ["A"])))
        expectEqual(try shape(#"card "group" right of "ungroup""#).title, "group")
        expectEqual(parseError(#"group "A" right of "B""#)?.reason, .syntax, "not a shape of a kind called group")
    },
])
