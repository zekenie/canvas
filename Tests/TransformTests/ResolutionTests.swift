@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import TestKit
import Transform

// What a shape can be turned into, headless: the kinds, the shapes that can't turn, what the container
// channel hands a target, and a channel's source saying no.

private let area = CGRect(x: 0, y: 0, width: 100, height: 60)

@MainActor let transformResolutionTests = Suite("Transform resolution", [
    test("a shape can be turned into each target whose channel its kind offers; not into its own kind, nor a target of a channel it doesn't offer") {
        let h = try transformHarness([boxesTurnIntoDiscs()])
        let transforms = try require(h.editor.transforms)
        let corral = h.add(Corral(area)), pocket = h.add(Pocket(area)), box = h.add(Box(area)), disc = h.add(Disc(area))
        expectEqual(transforms.targets(of: corral), [Pocket.kind])
        expectEqual(transforms.targets(of: box), [Disc.kind])
        expectEqual(transforms.targets(of: pocket), [], "it takes a channel and offers none")
        expectEqual(transforms.targets(of: disc), [])
        expect(transforms.canTurn(corral, into: Pocket.kind))
        expect(transforms.canTurn(box, into: Disc.kind))
        expect(!transforms.canTurn(pocket, into: Pocket.kind), "already of the kind")
        expect(!transforms.canTurn(disc, into: Disc.kind))
        expect(!transforms.canTurn(corral, into: Disc.kind), "a corral offers the container channel; a disc takes the box channel")
        expect(!transforms.canTurn(box, into: Pocket.kind), "and a pocket the container channel")
        expect(!transforms.canTurn(pocket, into: Disc.kind) && !transforms.canTurn(disc, into: Pocket.kind), "a kind that offers nothing")
        expect(!transforms.canTurn(corral, into: Corral.kind) && !transforms.canTurn(corral, into: "no-such-kind"))
    },

    test("not a shape that isn't there, isn't on the board shown, or is kept aside; a read-only one can, and turning it is refused") {
        let h = try transformHarness()
        let transforms = try require(h.editor.transforms)
        let corral = h.add(Corral(area))
        let pocket = h.add(Pocket(CGRect(x: 300, y: 0, width: 100, height: 60)))
        expect(transforms.canTurn(corral, into: Pocket.kind))
        expect(!transforms.canTurn(ShapeID(), into: Pocket.kind), "no such shape")
        expectEqual(transforms.targets(of: ShapeID()), [])
        expect(h.enter(pocket))
        expect(!transforms.canTurn(corral, into: Pocket.kind), "on the root, while the pocket's board is shown")
        let inside = h.add(Corral(area))
        expect(transforms.canTurn(inside, into: Pocket.kind))
        expect(h.editor.showBoard(.root))
        expect(!transforms.canTurn(inside, into: Pocket.kind), "on the pocket's board, while the root is shown")
        expect(transforms.canTurn(corral, into: Pocket.kind))

        h.editor.freeze([corral])
        expect(transforms.canTurn(corral, into: Pocket.kind), "a frozen shape can; turning it is refused")
        h.editor.freeze([corral], false)
        h.editor.transact { $0.delete([corral]) }
        expect(!transforms.canTurn(corral, into: Pocket.kind), "deleted")

        let aside = try keptAside(Corral.kind, id: ShapeID(), in: h.editor.registry)
        h.editor.replaceDocument(with: CanvasDocument(shapes: h.editor.document.shapes + [aside]))
        expect(!transforms.canTurn(aside.id, into: Pocket.kind), "kept aside")
        expectEqual(transforms.targets(of: aside.id), [])
        expect(!transforms.turn([aside.id], into: Pocket.kind))
        expectEqual(h.editor.document[aside.id]?.kind, Corral.kind, "left as it is")
        expect(h.editor.document[aside.id]?.isOpaque == true)
    },

    test("the container channel hands over the container's id and frame, and what it holds at any depth; the arrows bound only to those go with them in the move") {
        let z = ShapeID(), k = ShapeID(), a = ShapeID(), l = ShapeID(), b = ShapeID(), c = ShapeID(), i = ShapeID(), o = ShapeID(), n = ShapeID(), m = ShapeID()
        let frame = CGRect(x: 100, y: 100, width: 400, height: 300)
        let h = try transformHarness(file: CanvasFile(root: board(box(z, x: 900), corral(k, frame), box(a, x: 120, y: 120, in: k),
                                                                  corral(l, CGRect(x: 200, y: 200, width: 200, height: 150), in: k), box(b, x: 220, y: 220, in: l),
                                                                  box(c, x: 600), link(i, a, b), link(o, a, c), link(n, nil, nil), link(m, b, k))))
        let source = h.editor.transact { ContainerChannel.source(of: k, in: $0) }
        expectEqual(source?.id, k)
        expectEqual(source?.frame, frame)
        expectEqual(source?.inside, [a, l, b], "the shapes in it at any depth, no link (the move takes the one between two of them along)")
        expectEqual(h.editor.transact { ContainerChannel.source(of: l, in: $0) }?.inside, [b], "an inner container's own")
        expect(h.editor.transact { ContainerChannel.source(of: z, in: $0) } == nil, "a box holds nothing, and isn't a container")
        expect(h.editor.transact { ContainerChannel.source(of: ShapeID(), in: $0) } == nil, "no such shape")
        expectEqual(h.editor.transact { ContainerChannel.source(of: l, in: $0) }?.frame, CGRect(x: 200, y: 200, width: 200, height: 150))
        let empty = h.add(Corral(CGRect(x: 700, y: 700, width: 50, height: 50)))
        expectEqual(h.editor.transact { ContainerChannel.source(of: empty, in: $0) }?.inside, [], "an empty container")
    },

    test("a channel's source can say no: the shape isn't turned, its target doesn't run, and no step is made") {
        let h = try transformHarness([boxesTurnIntoDiscs()])
        let transforms = try require(h.editor.transforms)
        let narrow = h.add(Box(CGRect(x: 0, y: 0, width: 40, height: 30)))
        let wide = h.add(Box(CGRect(x: 200, y: 0, width: 140, height: 30)))
        expect(transforms.canTurn(wide, into: Disc.kind), "its kind offers the channel; only its source says no")
        let before = h.file, revision = h.editor.revision
        expect(!transforms.turn([wide], into: Disc.kind))
        expectEqual(h.file, before)
        expectEqual(h.editor.revision, revision, "nothing committed")
        expect(transforms.turn([wide, narrow], into: Disc.kind), "the one it can turn turns")
        expectEqual(h.editor.document[narrow]?.kind, Disc.kind)
        expectEqual(h.editor.document[wide]?.kind, Box.kind, "the other is as it was")
        expectEqual(h.editor.undoHistory.undoName, "Turn into Disc", "the step is named for what it turned into")
    },

    test("a shape is turned only through a channel its kind offers: one of another kind is left as it is, whatever the channel's source would say of it") {
        let h = try transformHarness([boxesTurnIntoDiscs()])
        let transforms = try require(h.editor.transforms)
        // Each is narrow enough for the box channel to hand it over, if it were asked.
        let corral = h.add(Corral(CGRect(x: 0, y: 0, width: 50, height: 50)))
        let disc = h.add(Disc(CGRect(x: 100, y: 0, width: 50, height: 50)))
        let box = h.add(Box(CGRect(x: 200, y: 0, width: 50, height: 50)))
        let before = h.file
        expect(!transforms.turn([corral, disc], into: Disc.kind), "a corral offers the container channel, and a disc offers none")
        expectEqual(h.file, before)
        expect(!transforms.turn([box], into: Pocket.kind), "a box offers the box channel, and a pocket takes the container channel")
        expectEqual(h.file, before)
        expect(transforms.turn([corral, disc, box], into: Disc.kind), "the one that can turns")
        expectEqual(h.editor.document[corral]?.kind, Corral.kind)
        expectEqual(h.editor.document[disc]?.kind, Disc.kind)
        expectEqual(h.editor.document[box]?.kind, Disc.kind)
    },

    test("each shape is turned once, the deepest in containers first and the rest back to front, whatever order they're given in") {
        let calls = CallLog()
        let o = ShapeID(), i = ShapeID(), s1 = ShapeID(), s2 = ShapeID(), s3 = ShapeID()
        let h = try transformHarness([plugin("logging") { r in
            r.turnable(Corral.self, through: LooseChannel.self)
            r.turnable(into: Tag.self, through: LooseChannel.self) { id, transaction in
                calls.ids.append(id)
                transaction.turn(id, into: Tag(target: nil))
            }
        }], file: CanvasFile(root: board(corral(s1, CGRect(x: 1000, y: 0, width: 100, height: 100)), corral(o, CGRect(x: 0, y: 0, width: 600, height: 400)),
                                         corral(i, CGRect(x: 100, y: 100, width: 300, height: 200), in: o),
                                         corral(s2, CGRect(x: 1200, y: 0, width: 100, height: 100)), corral(s3, CGRect(x: 1400, y: 0, width: 100, height: 100)))))
        expect(h.editor.transforms?.turn([s3, i, o, s2, s1, s3, o], into: Tag.kind) == true)
        expectEqual(calls.ids, [i, s1, o, s2, s3], "the inner corral, then the rest as they stand on the board")
        expectEqual(ids(h.editor.document), [s1, o, i, s2, s3], "all of them still here, as tags, in their places")
    },
])
