@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import TestKit
import Validation

// What writes that have not committed touch: a rule's `touches`, the engine's kept lookups, and the one
// function of the registry that answers for both (`validationTouched(by:in:)`), asked inside a transaction
// that is then thrown away.

/// What a rule keeps outside the shapes, as a service would: each box's partner, anywhere in the file. A box
/// whose partner is empty has an issue, though nothing of the box says so.
@MainActor private final class Partners {
    var of: [ShapeID: ShapeID] = [:]
    var asked = 0

    func boxes(with partners: Set<ShapeID>) -> Set<ShapeID> {
        Set(of.filter { partners.contains($0.value) }.keys)
    }
}

private struct Thrown: Error {}

/// A box is warned of while its partner is empty or gone, read from the file as the checker has it; the rule
/// says which boxes a write of a partner reaches.
@MainActor private func partnerRules(_ partners: Partners) -> Rules {
    Rules { r in
        r.validate(Box.self, ignoringMoves: true, touches: { changes, _ in
            partners.asked += 1
            return partners.boxes(with: changes.shapeIDs.union(changes.elsewhere))
        }) { box, context in
            guard let partner = partners.of[box.id], let reading = context.reading else { return [] }
            guard let other = reading.shape(inFile: partner)?.typed(as: Box.self) else { return [.error("its partner is gone")] }
            return other.frame.isEmpty ? [.warning("its partner is empty")] : []
        }
    }
}

/// A tag is warned of while the box it names is empty: found by a lookup the engine notes. Not ignoring moves,
/// for a rule that reads where shapes are.
@MainActor private func tagRules(ignoringMoves: Bool = true) -> Rules {
    Rules("tag-rules") { r in
        r.validate(Tag.self, ignoringMoves: ignoringMoves) { tag, context in
            guard let target = tag.props.target, let box = context.shape(target)?.typed(as: Box.self) else { return [] }
            return box.frame.isEmpty ? [.warning("its box is empty")] : []
        }
    }
}

/// Runs `body` in a transaction that commits nothing.
@MainActor private func uncommitted<T>(_ editor: CanvasEditor, _ body: (inout Transaction) -> T) -> T? {
    var result: T?
    try? editor.transact { transaction in
        result = body(&transaction)
        throw Thrown()
    }
    return result
}

@MainActor private func messages(_ registry: Registry, _ record: AnyShapeRecord?, in shapes: ShapeContext) -> [String] {
    record.map { registry.validationIssues(of: $0, in: shapes).map(\.message) } ?? []
}

private let full = CGRect(x: 0, y: 0, width: 40, height: 40)

@MainActor let touchesTests = Suite("What uncommitted writes touch", [
    test("a rule names the other shapes a write reaches, the issue is there before the commit, and nothing is committed") {
        let partners = Partners()
        let h = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), partnerRules(partners)])
        let box = h.add(Box(full)), partner = h.add(Box(full)), bystander = h.add(Box(full))
        partners.of[box] = partner
        let revision = h.editor.revision
        let registry = h.editor.registry
        let found = uncommitted(h.editor) { transaction -> (touched: Set<ShapeID>, before: [String], after: [String]) in
            transaction.update(partner, as: Box.self) { $0.frame.size = .zero }
            let touched = registry.validationTouched(by: transaction.pending, in: transaction.shapes)
            return (touched, messages(registry, h.editor.document[box], in: h.editor.shapeContext),
                    messages(registry, transaction.shapes.document[box], in: transaction.shapes))
        }
        expectEqual(found?.touched, [box], "the box, and neither the partner written nor a box nothing joins to it")
        expectEqual(found?.before, [])
        expectEqual(found?.after, ["its partner is empty"])
        expectEqual(h.editor.revision, revision)
        expect(h.editor.document[bystander] != nil)
    },
    test("a write that reaches nothing names nothing, and neither does a list with no rule that answers") {
        let partners = Partners()
        let h = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), partnerRules(partners)])
        let box = h.add(Box(full)), partner = h.add(Box(full)), other = h.add(Box(full))
        partners.of[box] = partner
        let registry = h.editor.registry
        let touched = uncommitted(h.editor) { transaction -> Set<ShapeID> in
            transaction.update(other, as: Box.self) { $0.frame.size = .zero }
            transaction.insert(ShapeRecord(Box(full)))
            return registry.validationTouched(by: transaction.pending, in: transaction.shapes)
        }
        expectEqual(touched, [])

        let plain = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), tagRules()])
        let lone = plain.add(Box(full))
        let none = uncommitted(plain.editor) { transaction -> Set<ShapeID> in
            transaction.update(lone, as: Box.self) { $0.frame.size = .zero }
            return plain.editor.registry.validationTouched(by: transaction.pending, in: transaction.shapes)
        }
        expectEqual(none, [], "a rule with no touches and a board the engine has not read")
    },
    test("a written shape is never among those it touches, and a deleted one is told as removed") {
        let partners = Partners()
        let h = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), partnerRules(partners)])
        let a = h.add(Box(full)), b = h.add(Box(full)), c = h.add(Box(full))
        // Each is the other's partner, and `c` waits on `b`.
        partners.of = [a: b, b: a, c: b]
        let registry = h.editor.registry
        let found = uncommitted(h.editor) { transaction -> (touched: Set<ShapeID>, after: [String]) in
            transaction.update(a, as: Box.self) { $0.frame.size = .zero }
            transaction.delete([b])
            expectEqual(transaction.pending.removed, [b])
            expectEqual(transaction.pending.changed, [a])
            return (registry.validationTouched(by: transaction.pending, in: transaction.shapes), messages(registry, transaction.shapes.document[c], in: transaction.shapes))
        }
        expectEqual(found?.touched, [c], "`a` waits on `b` too, and was written")
        expectEqual(found?.after, ["its partner is gone"])
    },
    test("the engine's kept lookups answer for a rule that looks a shape up, once it has checked the board") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), tagRules()])
        let box = h.add(Box(full)), tag = h.add(Tag(target: box)), other = h.add(Box(full))
        let registry = h.editor.registry
        @MainActor func touched(_ body: (inout Transaction) -> Void) -> Set<ShapeID>? {
            uncommitted(h.editor) { transaction in
                body(&transaction)
                return registry.validationTouched(by: transaction.pending, in: transaction.shapes)
            }
        }
        expectEqual(touched { $0.update(box, as: Box.self) { $0.frame.size = .zero } }, [], "nothing was checked yet, so no lookup is kept")
        _ = h.editor.validation?.results
        expectEqual(touched { $0.update(box, as: Box.self) { $0.frame.size = .zero } }, [tag])
        // Deleting the box writes the tag bound to it too (the core lets go of it, or takes it along): a written
        // shape, which is the writer's own to look at.
        let deleting = uncommitted(h.editor) { transaction -> (written: Set<ShapeID>, touched: Set<ShapeID>) in
            transaction.delete([box])
            let pending = transaction.pending
            return (pending.shapeIDs, registry.validationTouched(by: pending, in: transaction.shapes))
        }
        expectEqual(deleting?.written, [box, tag])
        expectEqual(deleting?.touched, [])
        expectEqual(touched { $0.update(other, as: Box.self) { $0.frame.size = .zero } }, [])
        expectEqual(touched { $0.moveBox(box, to: CGPoint(x: 300, y: 0)) }, [], "the rule ignores moves, as a commit that only moved the box would")
        expectEqual(touched {
            $0.update(box, as: Box.self) { $0.frame.size = .zero }
            $0.update(tag, as: Tag.self) { $0.props.target = other }
        }, [], "the tag was written too")
    },
    test("a move reaches the shapes whose rules read where shapes are") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), tagRules(ignoringMoves: false)])
        let box = h.add(Box(full)), tag = h.add(Tag(target: box))
        _ = h.editor.validation?.results
        let touched = uncommitted(h.editor) { transaction -> Set<ShapeID> in
            transaction.moveBox(box, to: CGPoint(x: 300, y: 0))
            expectEqual(transaction.pending.moved, [box])
            return h.editor.registry.validationTouched(by: transaction.pending, in: transaction.shapes)
        }
        expectEqual(touched, [tag])
    },
    test("a shape on a board that is not shown is named, and checked over its own board as the transaction has it") {
        let partners = Partners()
        let pocket = ShapeRecord(Pocket(CGRect(x: 0, y: 200, width: 200, height: 100)))
        let partner = ShapeRecord(Box(full)), far = ShapeRecord(Box(full))
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(partner), AnyShapeRecord(pocket)]),
                              children: [pocket.id: CanvasDocument(shapes: [AnyShapeRecord(far)])])
        let h = try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin(), ValidationPlugin(), partnerRules(partners)], file: file)
        partners.of[far.id] = partner.id
        let registry = h.editor.registry
        let board = BoardID(owner: pocket.id)
        let found = uncommitted(h.editor) { transaction -> (touched: Set<ShapeID>, before: [String], after: [String]) in
            transaction.update(partner.id, as: Box.self) { $0.frame.size = .zero }
            let touched = registry.validationTouched(by: transaction.pending, in: transaction.shapes)
            let there = transaction.contents(of: board)
            return (touched, messages(registry, h.editor.contents(of: board)[far.id], in: h.editor.shapeContext.over(h.editor.contents(of: board))),
                    messages(registry, there[far.id], in: transaction.shapes.over(there)))
        }
        expectEqual(found?.touched, [far.id])
        expectEqual(found?.before, [])
        expectEqual(found?.after, ["its partner is empty"])

        // And the other way: a write on the board that is not shown is told as `elsewhere`, and reaches the root's box.
        partners.of = [partner.id: far.id]
        let back = uncommitted(h.editor) { transaction -> (elsewhere: Set<ShapeID>, touched: Set<ShapeID>) in
            transaction.update(inFile: far.id) { $0 = AnyShapeRecord(ShapeRecord(id: far.id, Box(.zero))) }
            let pending = transaction.pending
            return (pending.elsewhere, registry.validationTouched(by: pending, in: transaction.shapes))
        }
        expectEqual(back?.elsewhere, [far.id])
        expectEqual(back?.touched, [partner.id])
    },
    test("a part of what was written asks the rules of that part alone") {
        let partners = Partners()
        let h = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), partnerRules(partners)])
        let a = h.add(Box(full)), b = h.add(Box(full)), waitsOnA = h.add(Box(full)), waitsOnB = h.add(Box(full))
        partners.of = [waitsOnA: a, waitsOnB: b]
        let registry = h.editor.registry
        let found = uncommitted(h.editor) { transaction -> [Set<ShapeID>] in
            transaction.update(a, as: Box.self) { $0.frame.size = .zero }
            transaction.update(b, as: Box.self) { $0.frame.size = .zero }
            let pending = transaction.pending
            return [registry.validationTouched(by: pending, in: transaction.shapes),
                    registry.validationTouched(by: pending.restricted(to: [a]), in: transaction.shapes),
                    registry.validationTouched(by: pending.restricted(to: [b]), in: transaction.shapes),
                    registry.validationTouched(by: pending.restricted(to: []), in: transaction.shapes)]
        }
        expectEqual(found, [[waitsOnA, waitsOnB], [waitsOnA], [waitsOnB], []])
    },
    test("it costs what was written: a thousand bystanders are not read, and each rule is asked once") {
        let partners = Partners()
        let h = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), partnerRules(partners), tagRules()])
        for index in 0..<1_000 { h.add(Box(full.offsetBy(dx: CGFloat(index) * 50, dy: 0))) }
        let box = h.add(Box(full)), partner = h.add(Box(full))
        partners.of[box] = partner
        _ = h.editor.validation?.results
        partners.asked = 0
        let registry = h.editor.registry
        let touched = uncommitted(h.editor) { transaction -> Set<ShapeID> in
            transaction.update(partner, as: Box.self) { $0.frame.size = .zero }
            return registry.validationTouched(by: transaction.pending, in: transaction.shapes)
        }
        expectEqual(touched, [box])
        expectEqual(partners.asked, 1)
    },
])
