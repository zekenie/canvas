@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit
import Types

// The readings of types' schemas (`SchemaReadings`), kept for every type of the files open: a file with
// more types than any fixed number is read once, not again each time the sync or a panel comes round to a
// type the cache has just dropped; and past what's kept, the one used longest ago goes first.

/// A file of `count` types, titled "Type n", each with a schema of its own.
@MainActor private func typesFile(_ count: Int) -> CanvasDocument {
    CanvasDocument(shapes: (0..<count).map { n in
        typeRecord(#"{"type": "object", "properties": {"f\#(n)": {"type": "string"}}}"#, words: "a thing \(n)", title: "Type \(n)",
                   at: CGPoint(x: CGFloat(n % 100) * 260, y: CGFloat(n / 100) * 260))
    })
}

@MainActor let schemaReadingsTests = Suite("Schema readings", [
    test("a file with more types than the fewest kept is read once as it opens, and a second window over it reads none") {
        let count = TypesPlugin.schemaReadingsMinimum + 500
        let document = typesFile(count)
        let registry = try Registry(plugins: typePlugins())
        let read = TypesPlugin.schemasRead
        let first = CanvasEditor(registry: registry, document: document, scheduler: ManualScheduler())
        expectEqual(first.types?.types.count, count)
        expectEqual(TypesPlugin.schemasRead - read, count, "each type's schema read once as the file opens")
        expect(TypesPlugin.schemaReadingsCapacity >= count + count / 4, "room for every type, and some to spare: \(TypesPlugin.schemaReadingsCapacity)")
        expect(TypesPlugin.schemaReadingsKept >= count, "every one kept: \(TypesPlugin.schemaReadingsKept)")
        // The same ids again (a copy of the file opened beside it, or a second window over it): the capacity grows with it,
        // and what is kept is found.
        let beside = CanvasEditor(registry: registry, document: document, scheduler: ManualScheduler())
        expectEqual(TypesPlugin.schemasRead - read, count, "opened again, none is read again")
        expect(TypesPlugin.schemaReadingsCapacity >= 2 * count)
        _ = (first, beside)
    },
    test("what is kept follows the files open: closing one cuts it to what is left, the readings used longest ago going, and the last used are found again") {
        // Fewer than a file's types are kept once no file holds them, however many editors other tests left open (their types
        // count as long as they live, so the sizes here are what they add to).
        let was = TypesPlugin.schemaReadingsMinimum
        TypesPlugin.schemaReadingsMinimum = 8
        defer { TypesPlugin.schemaReadingsMinimum = was }
        let registry = try Registry(plugins: typePlugins())
        let n = 400
        let a = typesFile(n), b = typesFile(n)
        let read = TypesPlugin.schemasRead
        var first: CanvasEditor? = CanvasEditor(registry: registry, document: a, scheduler: ManualScheduler())
        var second: CanvasEditor? = CanvasEditor(registry: registry, document: b, scheduler: ManualScheduler())
        expectEqual(TypesPlugin.schemasRead - read, 2 * n, "each type read once")
        expect(TypesPlugin.schemaReadingsKept >= 2 * n, "both files' readings are kept while both are open: \(TypesPlugin.schemaReadingsKept)")
        // The first file closes: what is kept is cut to what is left (its types, and a quarter more), the ones used longest ago going.
        first = nil
        let afterFirst = TypesPlugin.schemaReadingsKept
        expectEqual(afterFirst, TypesPlugin.schemaReadingsCapacity, "cut to the capacity")
        expect(afterFirst >= n + n / 4, "the second file's types and room to spare: \(afterFirst)")
        // The second closes: what is kept is the readings used last, the second file's.
        second = nil
        let kept = TypesPlugin.schemaReadingsKept
        expectEqual(kept, TypesPlugin.schemaReadingsCapacity)
        expect(kept < n, "fewer than the second file has: \(kept)")
        // Opened again, its types that were let go are read again, and those kept are found.
        let again = CanvasEditor(registry: registry, document: b, scheduler: ManualScheduler())
        expectEqual(TypesPlugin.schemasRead - read, 2 * n + (n - kept), "the readings used last were the second file's")
        _ = again
    },
    test("a type typed into keeps its last readings, up to four, and the one used longest ago goes") {
        let editor = try typeEditor()
        let id = editor.addType(#"{"type": "object", "properties": {"a": {}}}"#, words: "a thing")
        let read = TypesPlugin.schemasRead
        for n in 1...6 {
            editor.transact { $0.update(id) { $0[TypeSchemaProperty.self] = SchemaText(#"{"type": "object", "properties": {"a\#(n)": {}}}"#) } }
        }
        expectEqual(TypesPlugin.schemasRead - read, 6, "each text typed read once")
        // Back to the text before the last: kept, so read again by nobody.
        editor.transact { $0.update(id) { $0[TypeSchemaProperty.self] = SchemaText(#"{"type": "object", "properties": {"a5": {}}}"#) } }
        expectEqual(TypesPlugin.schemasRead - read, 6, "the fifth text is still kept: found, not read again")
        editor.transact { $0.update(id) { $0[TypeSchemaProperty.self] = SchemaText(#"{"type": "object", "properties": {"a1": {}}}"#) } }
        expectEqual(TypesPlugin.schemasRead - read, 7, "the first went when the fifth text came, so it is read again")
    },
])
