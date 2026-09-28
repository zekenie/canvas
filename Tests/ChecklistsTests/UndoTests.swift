@_spi(Host) import Canvas
import CanvasTesting
import Checklists
import DetailPanel
import SwiftUI
import TestKit

@MainActor let undoTests = Suite("Checklists and undo", [
    test("typing into an item is one step; each checkbox toggled (a click, which seals the run) and each bulk action is one") {
        let editor = try choreEditor()
        let id = editor.add(Chore(choreFrame), items: laundry())
        editor.replaceDocument(with: editor.document)
        let items = try require(editor.propertyBinding(id, ChecklistProperty.self))
        let text = items[dynamicMember: \.[0].text]
        for typed in ["wash ", "wash t", "wash th", "wash the"] { text.wrappedValue = typed }
        editor.undoHistory.seal()
        items[dynamicMember: \.[1].isDone].wrappedValue = true
        editor.undoHistory.seal()
        items[dynamicMember: \.[2].isDone].wrappedValue = true
        items.update { ChecklistBulkAction.removeChecked.apply(to: &$0) }
        items.update { ChecklistBulkAction.checkAll.apply(to: &$0) }
        expectEqual(editor.items(id)?.map(\.isDone), [true])
        var lists: [[ChecklistItem]] = []
        while editor.canUndo {
            editor.undo()
            lists.append(editor.items(id) ?? [])
        }
        expectEqual(lists.map { $0.map(\.isDone) }, [[false], [false, true, true], [false, true, false], [false, false, false], [false, false, false]])
        expectEqual(lists.dropLast().map { $0.first?.text }, ["wash the", "wash the", "wash the", "wash the"])
        expectEqual(lists.last?.first?.text, "wash", "the typing, one step")
    },
])
