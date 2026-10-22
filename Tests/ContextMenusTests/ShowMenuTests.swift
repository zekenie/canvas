import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import ContextMenus
import Keyboard
import Selection
import TestKit

@MainActor let showMenuTests = Suite("Show Context Menu", [
    test("⌃↩ and the Menu key pop the selection's menu below the selection, its first item highlighted") {
        let h = try harness()
        let lamp = h.add(Lamp(slot(1)))
        for chord in [Chord(Key.return, .control), Chord(Key.menu)] {
            h.editor.selectedShapeIDs = [lamp]
            expect(h.editor.menuToPopUp == nil)
            expect(h.key(chord), "the key is answered")
            let queued = try require(h.editor.menuToPopUp, "a menu waits for the host")
            expectEqual(queued.rect, slot(1), "below the selection")
            expectEqual(queued.menu.outline, try require(h.editor.menuForPoppedSelection()).outline)
            expectEqual(queued.menu.outline, try require(h.editor.menuForSelection(omitting: [.showContextMenu])).outline)
            expectEqual(h.editor.menuItemToHighlight?.title, queued.menu.items.first?.title, "the first item is highlighted")
            h.editor.menuDidPopUp()
        }
        expectEqual(h.editor.selectedShapeIDs, [lamp], "opening the menu changes nothing")
    },
    test("the rect is the whole selection's bounds") {
        let h = try harness()
        let a = h.add(Lamp(slot(0))), b = h.add(Fan(frame: slot(2)))
        h.editor.selectedShapeIDs = [a, b]
        h.key(Chord(Key.return, .control))
        expectEqual(h.editor.menuToPopUp?.rect, slot(0).union(slot(2)))
    },
    test("with nothing selected it is dimmed and the key goes on; Return alone is still Open Selection's") {
        let h = try harness()
        h.add(Lamp(slot(0)))
        h.editor.selection = nil
        expect(!h.editor.canPerform(.showContextMenu))
        expect(!h.key(Chord(Key.return, .control)))
        expect(h.editor.menuToPopUp == nil)
    },
    test("the Shape menu holds it, for the selection, and a right-click's menu does not") {
        let h = try harness()
        let lamp = h.add(Lamp(slot(0)))
        h.editor.selectedShapeIDs = [lamp]
        expect(try require(h.editor.menuForSelection(omitting: [])).outline.contains("Show Context Menu"))
        expect(!(try require(h.secondaryClick(at: middle(0))).outline.contains("Show Context Menu")))
        expect(!(try require(h.editor.menuForPoppedSelection()).outline.contains("Show Context Menu")), "the menu popped under the selection (VoiceOver's Show Menu too) would only open itself")
    },
    test("the keys are listed for the command, and no other command has them") {
        let h = try harness()
        let chords = h.editor.registry.shortcuts.filter { $0.commands.contains(.showContextMenu) }.map(\.chord)
        expectEqual(chords, [KeyChord("\r", .control), .menu])
        let others = h.editor.registry.shortcuts.filter { !$0.commands.contains(.showContextMenu) }.map(\.chord)
        expect(!others.contains(KeyChord("\r", .control)) && !others.contains(.menu), "free")
    },
])
