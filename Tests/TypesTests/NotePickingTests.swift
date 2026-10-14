import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Foundation
import TestKit
import TextEditing
import Types

// What every list of notes does with its keys (`NotePicking.perform`): Tab never picks, Return picks the highlighted
// line and with none is swallowed, Backspace on an empty query closes the list. Headless, over a list of fixed lines:
// the rule is the protocol's, so whatever lists notes next is held to it by this one.

@MainActor
private final class Lines: NotePicking {
    let all: [ShapeID]
    let names: [String]
    private(set) var query = ""
    let list = CaretList(metrics: CaretListMetrics(width: 280, rowHeight: 24, rowsShown: 8, offset: 4))
    private(set) var picked: [ShapeID] = []

    init(_ names: [String]) {
        self.names = names
        all = names.map { _ in ShapeID() }
        setQuery("")
    }

    func setQuery(_ text: String) {
        query = text
        let shown = names.filter { text.isEmpty || $0.lowercased().contains(text.lowercased()) }
        list.setRows(shown.isEmpty ? [.empty("No matches")] : shown.map { .item(CaretListItem($0)) })
    }

    func pickNote(row: Int) -> ShapeID? {
        guard let name = list.rows[safe: row]?.item?.title, let index = names.firstIndex(of: name) else { return nil }
        picked.append(all[index])
        return all[index]
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

@MainActor let notePickingTests = Suite("The keys of a list of notes", [
    test("Tab and ⇧Tab are never a pick; Return picks the highlighted line and with none is swallowed; Backspace on an empty query closes") {
        let picker = Lines(["Anders Holm", "Dana Novak", "Ann Lee"])
        expect(picker.list.highlighted != nil)
        for selector in [#selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:))] {
            let (taken, action) = picker.perform(selector)
            expect(!taken && action == .close, "\(selector): not taken, the host closes")
        }
        expect(picker.perform(#selector(NSResponder.insertNewline(_:))) == (true, .pick))
        expect(picker.perform(#selector(NSResponder.moveDown(_:))) == (true, nil))
        expect(picker.perform(#selector(NSResponder.cancelOperation(_:))) == (true, .close))
        expect(picker.perform(#selector(NSResponder.deleteBackward(_:))) == (true, .close), "empty query")
        picker.setQuery("an")
        expect(picker.perform(#selector(NSResponder.deleteBackward(_:))) == (false, nil), "a query: the field deletes")
        picker.setQuery("zzqx")
        expect(picker.perform(#selector(NSResponder.insertNewline(_:))) == (true, nil), "nothing highlighted: taken, nothing picked")
        expectEqual(picker.pickNote(row: 0), nil, "the empty line is no note")
        expectEqual(picker.picked, [])
    },
    test("a pick is the note of the line, a line that is none is nobody, and the host asks the same of every list") {
        let picker = Lines(["Anders Holm", "Dana Novak"])
        picker.setQuery("dana")
        let id = picker.pickNote(row: 0)
        expectEqual(id, picker.all[1])
        expectEqual(picker.pickNote(row: 99), nil, "no such line")
        let lists: [any NotePicking] = [picker]
        expectEqual(lists.map(\.query), ["dana"])
    },
])
