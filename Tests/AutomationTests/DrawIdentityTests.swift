import Automation
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Draw
import TestKit

// An edge is its pair and, for an edge kind that has identity keys, what a statement writes of
// them (`DrawEdgeIdentities`, named by whoever owns the property). A fixture edge kind, the tie, has
// two: `bond` (text) and `tags` (a list of text); `memo` is another property of it, no identity.

/// What a tie is bound by.
enum Bond {}

extension Bond: ShapeProperty {
    static let key: PropertyKey = "bond"
    static var defaultValue: String? { nil }
}

/// What a tie is tagged with: a set.
enum Tags {}

extension Tags: ShapeProperty {
    static let key: PropertyKey = "tags"
    static var defaultValue: [String]? { nil }
}

/// A note on a tie, no identity.
enum Memo {}

extension Memo: ShapeProperty {
    static let key: PropertyKey = "memo"
    static var defaultValue: String? { nil }
}

/// Makes ties (links) whose identity is `bond` and `tags`.
@MainActor func tieEdgesPlugin(identity: [String] = [Bond.key.rawValue, Tags.key.rawValue], log: EdgeLog? = nil) -> Contributor {
    Contributor(id: "tie-edges") { registrar in
        registrar.declare(Bond.self)
        registrar.optIn(Link.self, to: Bond.self)
        registrar.declare(Tags.self)
        registrar.optIn(Link.self, to: Tags.self)
        registrar.declare(Memo.self)
        registrar.optIn(Link.self, to: Memo.self)
        for key in identity { registrar.drawEdgeIdentity(PropertyKey(rawValue: key)) }
        registrar.drawEdges(kind: { _ in Link.kind }, sides: { _, _ in [:] }, ends: { record, _ in
            guard let link = record.typed(as: Link.self), let from = link.props.from, let to = link.props.to else { return nil }
            return (from, to)
        }, make: { request, existing, _ throws(DrawError) in
            log?.requests.append(request)
            return existing ?? AnyShapeRecord(ShapeRecord(Link(from: request.from, to: request.to)))
        })
    }
}

@MainActor private func tieEditor() throws -> CanvasEditor {
    let editor = try makeEditor([namesPlugin(), tieEdgesPlugin()])
    _ = try drawn(threeShapes, on: editor)
    return editor
}

/// The ties on the board, by their bond (nil: none).
@MainActor private func bonds(in editor: CanvasEditor) -> [String?] {
    editor.document.shapes.filter { $0.kind == Link.kind }.map { $0[Bond.self] }.sorted { ($0 ?? "") < ($1 ?? "") }
}

private func dids(_ result: JSON) -> [JSON?] { rows(result).map { $0["did"] } }

@MainActor let drawPairTests = Suite("draw: the arrows of one pair", [
    test("a run tells the maker which connections already join each pair, either way, counting its own as it makes them") {
        let log = EdgeLog()
        let editor = try makeEditor([namesPlugin(), tieEdgesPlugin(log: log)])
        _ = try drawn(threeShapes, on: editor)
        _ = try drawn(#"edge "Hub" -> "East" bond: "x""#, on: editor)
        log.requests = []
        let result = try drawn(#"""
        edge "Hub" -> "East" bond: "y"
        edge "East" -> "Hub" bond: "z"
        edge "Hub" -> "AB"
        edge "Hub" -> "East" bond: "w"
        """#, on: editor)
        expectEqual(dids(result), ["connected", "connected", "connected", "connected"])
        // An edge with attributes is made twice (the second asks the maker to hold what was set): the same count each time.
        var told: [Int?] = []
        for request in log.requests where told.last.map({ $0 != request.beside?.count }) ?? true { told.append(request.beside?.count) }
        expectEqual(told, [1, 2, 0, 3])
        // The same script again changes nothing, whatever it is told: each is found, not made again.
        let revision = editor.revision
        let again = try drawn(#"""
        edge "Hub" -> "East" bond: "y"
        edge "East" -> "Hub" bond: "z"
        edge "Hub" -> "AB"
        edge "Hub" -> "East" bond: "w"
        """#, on: editor)
        expectEqual(dids(again), ["unchanged", "unchanged", "unchanged", "unchanged"])
        expectEqual(editor.revision, revision)
    },
])

@MainActor let drawIdentityTests = Suite("draw: edge identity", [
    test("a pair with one plain tie takes a typed statement, another bond is a second tie, and a run again is unchanged for both") {
        let editor = try tieEditor()
        expectEqual(dids(try drawn(#"edge "Hub" -> "East""#, on: editor)), ["connected"])
        expectEqual(dids(try drawn(#"edge "Hub" -> "East" bond: "x""#, on: editor)), ["reconnected"], "the plain one takes the identity")
        expectEqual(bonds(in: editor), ["x"])
        expectEqual(dids(try drawn(#"edge "Hub" -> "East" bond: "y""#, on: editor)), ["connected"], "another bond is another tie")
        expectEqual(bonds(in: editor), ["x", "y"])
        let revision = editor.revision
        let again = try drawn(#"""
        edge "Hub" -> "East" bond: "x"
        edge "Hub" -> "East" bond: "y"
        """#, on: editor)
        expectEqual(dids(again), ["unchanged", "unchanged"])
        expectEqual(editor.revision, revision, "a run that changes nothing opens no step")
    },
    test("a statement that writes no bond over two ties is ambiguous_edge and says to write one; over one it updates") {
        let editor = try tieEditor()
        _ = try drawn(#"""
        edge "Hub" -> "East" bond: "x"
        edge "Hub" -> "East" bond: "y"
        """#, on: editor)
        let ambiguous = try refused(#"edge "Hub" -> "East" memo: "m""#, on: editor)
        expectEqual(ambiguous.reason, "ambiguous_edge")
        expectEqual(ambiguous.message, #""Hub" -> "East" is drawn 2 times"#)
        expectEqual(ambiguous.hint, #"write bond: or tags: to say which, or delete edge "Hub" -> "East" above this line to replace them"#)
        _ = try drawn(#"delete edge "Hub" -> "East" bond: "y""#, on: editor)
        expectEqual(dids(try drawn(#"edge "Hub" -> "East" memo: "m""#, on: editor)), ["reconnected"], "over one, an update")
        expectEqual(bonds(in: editor), ["x"])
    },
    test("two ties of one bond are ambiguous_edge, and the hint names the bond to delete") {
        let editor = try tieEditor()
        let hub = try require(shape("Hub", in: editor)), east = try require(shape("East", in: editor))
        for _ in 0..<2 {
            var record = link(hub, east, in: editor)
            record[Bond.self] = "x"
            editor.transact { $0.update(record.id) { $0 = record } }
        }
        let ambiguous = try refused(#"edge "Hub" -> "East" bond: "x""#, on: editor)
        expectEqual(ambiguous.reason, "ambiguous_edge")
        expectEqual(ambiguous.hint, #"write delete edge "Hub" -> "East" bond: "x" above this line to replace them"#)
    },
    test("bond: null addresses the plain tie alone") {
        let editor = try tieEditor()
        _ = try drawn(#"edge "Hub" -> "East" bond: "x""#, on: editor)
        expectEqual(dids(try drawn(#"edge "Hub" -> "East" bond: null"#, on: editor)), ["connected"], "a plain one beside the typed one, not a retyping")
        expectEqual(bonds(in: editor), [nil, "x"])
        expectEqual(dids(try drawn(#"edge "Hub" -> "East" bond: null memo: "m""#, on: editor)), ["reconnected"])
        expectEqual(dids(try drawn(#"edge "Hub" -> "East" bond: "x""#, on: editor)), ["unchanged"])
        expectEqual(bonds(in: editor), [nil, "x"])
    },
    test("tags are the same tags in any order, and none, null and an empty list are one") {
        let editor = try tieEditor()
        _ = try drawn(#"edge "Hub" -> "East" tags: ["a", "b"]"#, on: editor)
        expectEqual(dids(try drawn(#"edge "Hub" -> "East" tags: ["b", "a"]"#, on: editor)), ["unchanged"])
        expectEqual(dids(try drawn(#"edge "Hub" -> "East" tags: ["b"]"#, on: editor)), ["connected"], "other tags are another tie")
        expectEqual(dids(try drawn(#"edge "Hub" -> "East" tags: []"#, on: editor)), ["connected"], "an empty list is none: the plain tie")
        expectEqual(dids(try drawn(#"edge "Hub" -> "East" tags: null"#, on: editor)), ["unchanged"])
        expectEqual(links(in: editor).count, 3)
    },
    test("delete edge with a bond removes that tie, without one every tie of the pair, and no other attribute is taken") {
        let editor = try tieEditor()
        let two = #"""
        edge "Hub" -> "East" bond: "x"
        edge "Hub" -> "East" bond: "y"
        """#
        _ = try drawn(two, on: editor)
        expectEqual(dids(try drawn(#"delete edge "Hub" -> "East" bond: "x""#, on: editor)), ["deleted"])
        expectEqual(bonds(in: editor), ["y"])
        let memo = try refused(#"delete edge "Hub" -> "East" memo: "m""#, on: editor)
        expectEqual(memo.reason, "unknown_attribute")
        expectEqual(memo.message, "delete edge takes bond:, tags: and no other attribute, not memo:")
        let missing = try refused(#"delete edge "Hub" -> "East" bond: "z""#, on: editor)
        expectEqual(missing.reason, "nothing_to_delete")
        _ = try drawn(two, on: editor)
        expectEqual(dids(try drawn(#"delete edge "Hub" -> "East""#, on: editor)), ["deleted", "deleted"])
        expectEqual(links(in: editor), [])
        _ = try drawn(#"edge "Hub" -> "East" bond: "x""#, on: editor)
        _ = try drawn(#"edge "Hub" -> "East" bond: null"#, on: editor)
        expectEqual(dids(try drawn(#"delete edge "Hub" -> "East" bond: null"#, on: editor)), ["deleted"], "the plain one")
        expectEqual(bonds(in: editor), ["x"])
    },
    test("an edge kind with no identity takes no attribute on delete edge") {
        let editor = try drawEditor()
        _ = try drawn(threeShapes, on: editor)
        _ = try drawn(#"edge "Hub" -> "East""#, on: editor)
        let json = try refused(#"delete edge "Hub" -> "East" tone: warm"#, on: editor)
        expectEqual(json.reason, "unknown_attribute")
        expectEqual(json.message, "delete edge takes no attribute, not tone:")
        expectEqual(links(in: editor), ["Hub -> East"])
    },
    test("two statements of one pair in one script are a duplicate unless both write a bond, and differently") {
        let editor = try tieEditor()
        let both_script = #"""
        edge "Hub" -> "East" bond: "x"
        edge "Hub" -> "East" bond: "y"
        """#
        let both = try drawn(both_script, on: editor)
        expectEqual(dids(both), ["connected", "connected"])
        for script in [#"""
            edge "Hub" -> "East"
            edge "Hub" -> "East" bond: "x"
            """#, #"""
            edge "Hub" -> "East" bond: "x"
            edge "Hub" -> "East" bond: "x"
            """#, #"""
            edge "Hub" -> "East" bond: "x"
            edge "East" <- "Hub" memo: "m"
            """#] {
            expectEqual(try refused(script, on: editor).reason, "duplicate", script)
        }
        let deletes = try drawn(#"""
        delete edge "Hub" -> "East" bond: "x"
        delete edge "Hub" -> "East" bond: "y"
        """#, on: editor)
        expectEqual(dids(deletes), ["deleted", "deleted"])
        _ = try drawn(both_script, on: editor)
        expectEqual(try refused(#"""
        delete edge "Hub" -> "East" bond: "x"
        delete edge "Hub" -> "East"
        """#, on: editor).reason, "duplicate")
    },
    test("a delete above an edge of the same bond replaces the tie in one run") {
        let editor = try tieEditor()
        _ = try drawn(#"edge "Hub" -> "East" bond: "x""#, on: editor)
        _ = try drawn(#"edge "Hub" -> "East" bond: "y""#, on: editor)
        let result = try drawn(#"""
        delete edge "Hub" -> "East" bond: "x"
        edge "Hub" -> "East" bond: "x" memo: "again"
        """#, on: editor)
        expectEqual(dids(result), ["deleted", "connected"])
        expectEqual(bonds(in: editor), ["x", "y"])
    },
    test("an identity key must be a word, once, no language key and no attribute of the maker") {
        @MainActor func identityRefusal(_ identity: [String], attributes: [String] = []) -> String? {
            refusal { registrar in
                for key in identity { registrar.drawEdgeIdentity(PropertyKey(rawValue: key)) }
                registrar.drawEdges(kind: { _ in nil }, attributes: attributes, sides: { _, _ in [:] }, ends: { _, _ in nil },
                                    make: { _, _, _ throws(DrawError) in throw DrawError("no", reason: "no") })
            }
        }
        expectEqual(identityRefusal(["from"]), "DrawEdgeIdentities: identity from: the language keeps from: for itself")
        expectEqual(identityRefusal([""]), "DrawEdgeIdentities: identity : a key is a word a script can write before a colon")
        expectEqual(identityRefusal(["is", "is"]), "more and more both claim draw edge identity is in DrawEdgeIdentities")
        expectEqual(identityRefusal(["bond"], attributes: ["bond"]),
                    "DrawEdgeIdentities: identity bond: it's one of the maker's attributes, and an identity key is a property of the kind's schema")
        expectEqual(identityRefusal(["is", "bond"]), nil)
    },
    test("an identity key the edge kind has no property for tells nothing apart: the pair is the edge") {
        let editor = try makeEditor([namesPlugin(), tieEdgesPlugin(identity: ["nothing"])])
        _ = try drawn(threeShapes, on: editor)
        _ = try drawn(#"edge "Hub" -> "East""#, on: editor)
        expectEqual(dids(try drawn(#"edge "Hub" -> "East" bond: "x""#, on: editor)), ["reconnected"], "the one tie, updated")
        let hub = try require(shape("Hub", in: editor)), east = try require(shape("East", in: editor))
        link(hub, east, in: editor)
        let ambiguous = try refused(#"edge "Hub" -> "East""#, on: editor)
        expectEqual(ambiguous.hint, #"write delete edge "Hub" -> "East" above this line to replace them"#, "no key to write")
        let delete = try refused(#"delete edge "Hub" -> "East" bond: "x""#, on: editor)
        expectEqual(delete.message, "delete edge takes no attribute, not bond:")
    },
    test("two typed statements over a pair with one plain arrow: the first types it, the second draws its own") {
        let editor = try makeEditor([namesPlugin(), tieEdgesPlugin()])
        _ = try drawn(threeShapes, on: editor)
        _ = try drawn(#"edge "Hub" -> "East""#, on: editor)
        let script = "edge \"Hub\" -> \"East\" bond: \"x\"\nedge \"Hub\" -> \"East\" bond: \"y\""
        expectEqual(dids(try drawn(script, on: editor)), ["reconnected", "connected"])
        @MainActor func bonds() -> [String?] { editor.document.shapes.filter { $0.kind == Link.kind }.map { $0[Bond.self] }.sorted { ($0 ?? "") < ($1 ?? "") } }
        expectEqual(bonds(), ["x", "y"], "both ties, each its own")
        expectEqual(dids(try drawn(script, on: editor)), ["unchanged", "unchanged"], "a run again changes nothing")
        expectEqual(bonds(), ["x", "y"])
    },
    test("the same in a run that draws a shape too, which is laid out with its arrows first: the same rows and the same ties, and again unchanged") {
        let editor = try makeEditor([namesPlugin(), tieEdgesPlugin()])
        _ = try drawn(threeShapes, on: editor)
        _ = try drawn(#"edge "Hub" -> "East""#, on: editor)
        // A shape in the script makes the run lay its arrows out first. (That the arrow laid out is the arrow drawn
        // is held where a second arrow of a pair differs from the first: CompositionTests, on the shipped arrows.)
        let script = "tile \"North\" above \"Hub\"\nedge \"Hub\" -> \"East\" bond: \"x\"\nedge \"Hub\" -> \"East\" bond: \"y\"\nedge \"North\" -> \"Hub\" bond: \"x\""
        expectEqual(dids(try drawn(script, on: editor)), ["created", "reconnected", "connected", "connected"])
        expectEqual(bonds(in: editor), ["x", "x", "y"])
        expectEqual(dids(try drawn(script, on: editor)), ["unchanged", "unchanged", "unchanged", "unchanged"], "a run again changes nothing")
        expectEqual(bonds(in: editor), ["x", "x", "y"])
    },
    test("a typed statement and bond: null over a pair with one plain arrow: the arrow is typed and the plain one drawn") {
        let editor = try makeEditor([namesPlugin(), tieEdgesPlugin()])
        _ = try drawn(threeShapes, on: editor)
        _ = try drawn(#"edge "Hub" -> "East""#, on: editor)
        let script = "edge \"Hub\" -> \"East\" bond: \"x\"\nedge \"Hub\" -> \"East\" bond: null"
        expectEqual(dids(try drawn(script, on: editor)), ["reconnected", "connected"])
        let bonds = editor.document.shapes.filter { $0.kind == Link.kind }.map { $0[Bond.self] }.sorted { ($0 ?? "") < ($1 ?? "") }
        expectEqual(bonds, [nil, "x"])
    },
    test("drawEdgesIdentity: 400 plain edges among 1,000 shapes cost the same with identity keys as without, and 400 that write a key cost a reading of their own pair's arrows more, never of the board's") {
        @MainActor func ran(identity: [String], writing: String) throws -> Duration {
            let editor = try makeEditor([namesPlugin(), tieEdgesPlugin(identity: identity)])
            editor.transact { transaction in
                for index in 0..<1_000 {
                    transaction.insert(AnyShapeRecord(ShapeRecord(Tile(CGRect(x: Double(index % 50) * 120, y: Double(index / 50) * 90, width: 100, height: 60), label: "T\(index)"))))
                }
            }
            let script = (0..<400).map { #"edge "T\#($0)" -> "T\#($0 + 400)""# + writing }.joined(separator: "\n")
            var result: JSON?
            // The run again is the restatement of 400 arrows: each looks for its pair among those drawn.
            let first = threadCPUTime { result = try? drawn(script, on: editor) }
            expectEqual(rows(result ?? .null).count, 400)
            let again = threadCPUTime { result = try? drawn(script, on: editor) }
            expectEqual(rows(result ?? .null).map { $0["did"] }, Array(repeating: "unchanged", count: 400))
            return first + again
        }
        let keys = [Bond.key.rawValue, Tags.key.rawValue]
        // A statement that writes no key is the pair's, as it was before a kind could name keys: the same code.
        let without = try ran(identity: [], writing: ""), with = try ran(identity: keys, writing: "")
        expect(with < without * 3 / 2 + .milliseconds(50), "400 plain edges, drawn and drawn again, took \(with) with identity keys and \(without) without")
        // One that writes a key reads the arrows of its own pair (one here) for what they hold: a cost an edge, so
        // a bound of several times and not of half as much again, and the same whatever else the board holds.
        let plain = try ran(identity: [], writing: #" bond: "x""#), keyed = try ran(identity: keys, writing: #" bond: "x""#)
        expect(keyed < plain * 3 + .milliseconds(100), "400 edges that write a bond, drawn and drawn again, took \(keyed) with identity keys and \(plain) without")
    },
])
