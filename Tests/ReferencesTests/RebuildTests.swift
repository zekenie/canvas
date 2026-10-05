import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Publishing
import Queries
import References
import TestKit
import Titles
import Topology

// What ReferenceState keeps as commits come equals what it works out afresh: seeded commits of every
// kind (boxes made, renamed, made public and private, moved into a pocket's board or deleted with the
// pocket, references direct and dynamic, made, re-asked, switched to All and back, wires into them,
// undo and redo), and after each, once the answers have settled, the graph in every view, what each
// reference stands for and how its query was answered are those of an editor opened on the same file
// and given every answer anew. A quiescent graph is a function of the records alone.

/// A reproducible stream of choices.
private struct Seeded: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The queries the run's dynamic references ask: kinds, titles, attributes, containment, edges in
/// the recorded view (wires, and wires forwarded through a direct reference), a title no shape may
/// have, and one that reads the person (refused).
private let queriesAsked = ["box", "tile", "\"A\"", "box[title^=\"B\"]", "box:edge-to(*)", ":connected-to(\"A\")", "box:not([title=\"C\"])",
                            "\"Nobody\"", ":inside(\"P\")", "box, tile", "tile:edge-to(box)"]

/// How a reference's query was answered, without when: the matches and their count, a refusal, a failure.
private func answerOf(_ status: ReferenceStatus?) -> String {
    switch status {
    case .answered(let matches)?: "\(matches.ids) of \(matches.count)"
    case let other?: "\(other)"
    case nil: "none"
    }
}

@MainActor private func compare(_ h: EditorHarness, seed: UInt64, step: Int, what: String) throws {
    let fresh = try EditorHarness(plugins: referencePlugins([PocketsPlugin(), pocketTitles]), file: h.editor.file)
    fresh.editor.viewportDidResize(to: CGSize(width: 1000, height: 800))
    fresh.answer()
    let kept = try require(h.editor.topology), anew = try require(fresh.editor.topology)
    let at = "seed \(seed), step \(step) (\(what))"
    for view in [EdgeView.resolved, .recorded, .literal] {
        let ours = Set(kept.edges(ofType: .all, view: view)), theirs = Set(anew.edges(ofType: .all, view: view))
        expectEqual(ours, theirs, "\(at): \(view) edges: \(ours.subtracting(theirs).count) more, \(theirs.subtracting(ours).count) fewer")
    }
    let state = try require(h.editor.references), freshState = try require(fresh.editor.references)
    expectEqual(state.dynamicReferences, freshState.dynamicReferences, "\(at): the dynamic references")
    for id in state.dynamicReferences {
        expectEqual(kept.forwards(of: id), anew.forwards(of: id), "\(at): what \(id) stands for")
        expectEqual(answerOf(state.status(of: id)), answerOf(freshState.status(of: id)), "\(at): how \(id) was answered")
    }
}

@MainActor let rebuildTests = Suite("Answers kept as commits come", [
    test("seeded commits, undo, redo and boards: once settled, the graph and every answer equal an editor's that works them out afresh") {
        let seeds: [UInt64] = [1, 2, 3, 5, 8, 13]
        for seed in seeds {
            var random = Seeded(state: seed)
            let h = try referenceHarness([PocketsPlugin(), pocketTitles])
            var pocketRecord = ShapeRecord(Pocket(CGRect(x: 800, y: 600, width: 100, height: 100)))
            pocketRecord[TitleProperty.self] = "P"
            h.editor.transact { $0.insert(pocketRecord) }
            let pocket = pocketRecord.id
            let titles = ["A", "B", "C", "Bee", "D"]
            func frame() -> CGRect {
                CGRect(x: CGFloat(Int.random(in: 0..<12, using: &random)) * 70, y: CGFloat(Int.random(in: 0..<8, using: &random)) * 70, width: 60, height: 40)
            }
            @MainActor func ids(of kind: ShapeKind) -> [ShapeID] {
                var found: [ShapeID] = []
                for document in [h.editor.file.root] + Array(h.editor.file.children.values) {
                    found += document.shapes.filter { $0.kind == kind }.map(\.id)
                }
                return found.sorted { $0.description < $1.description }
            }
            @MainActor func pick(_ kind: ShapeKind) -> ShapeID? { ids(of: kind).randomElement(using: &random) }
            for _ in 0..<3 { h.addBox(titles.randomElement(using: &random)!, public: Bool.random(using: &random), at: frame()) }
            h.addTile("T", at: frame())
            for step in 0..<36 {
                var what = ""
                switch Int.random(in: 0..<14, using: &random) {
                case 0, 1:
                    what = "a box"
                    h.addBox(titles.randomElement(using: &random)!, public: Bool.random(using: &random), at: frame())
                case 2:
                    what = "a tile"
                    h.addTile(titles.randomElement(using: &random)!, at: frame())
                case 3:
                    guard let box = pick(Box.kind), h.editor.document[box] != nil else { continue }
                    what = "public or not"
                    h.editor.transact { $0.update(box) { $0[PublicProperty.self] = $0[PublicProperty.self] == true ? nil : true } }
                case 4:
                    guard let box = pick(Box.kind), h.editor.document[box] != nil else { continue }
                    what = "a rename"
                    let title = titles.randomElement(using: &random)!
                    h.editor.transact { $0.update(box) { $0[TitleProperty.self] = title } }
                case 5:
                    what = "a box in the pocket"
                    var box = ShapeRecord(Box(frame()))
                    box[TitleProperty.self] = titles.randomElement(using: &random)!
                    box[PublicProperty.self] = true
                    h.editor.transact(on: BoardID(owner: pocket)) { $0.insert(box) }
                case 6:
                    guard let box = pick(Box.kind) else { continue }
                    what = "a direct reference"
                    h.addReference(to: box, label: "picked", at: frame().origin)
                case 7, 8:
                    what = "a dynamic reference"
                    h.addReference(query: queriesAsked.randomElement(using: &random)!, all: Bool.random(using: &random), at: frame().origin)
                case 9:
                    guard let reference = pick(Reference.kind), let props = h.reference(reference), props.mode == .dynamic else { continue }
                    if Bool.random(using: &random) {
                        what = "All switched"
                        h.editor.references?.setAll(!props.all, of: reference)
                    } else {
                        what = "asked again"
                        let query = queriesAsked.randomElement(using: &random)!
                        h.editor.transact("Edit Reference") { $0.update(reference, as: Reference.self) { ReferenceEdits.find(&$0.props, words: "", query: query) } }
                    }
                case 10:
                    let ends = ids(of: Box.kind) + ids(of: Tile.kind) + ids(of: Reference.kind)
                    guard let from = ends.randomElement(using: &random), let to = ends.randomElement(using: &random),
                          h.editor.document[from] != nil, h.editor.document[to] != nil else { continue }
                    what = "a wire"
                    h.connect(from, to)
                case 11:
                    let shapes = h.editor.document.shapes.filter { $0.kind != Pocket.kind || Int.random(in: 0..<4, using: &random) == 0 }
                    guard let gone = shapes.randomElement(using: &random) else { continue }
                    what = "a deletion of a \(gone.kind)"
                    h.editor.transact { $0.delete([gone.id]) }
                case 12:
                    what = "an undo"
                    h.editor.undo()
                default:
                    what = "a redo"
                    h.editor.redo()
                }
                h.answer(after: 250)
                try compare(h, seed: seed, step: step, what: what)
            }
        }
    },
])
