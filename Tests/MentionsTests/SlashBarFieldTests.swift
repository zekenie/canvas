import AppKit
@_spi(Host) import Canvas
import CanvasTesting
@_spi(Host) import CanvasUI
import Mentions
import Selection
import SlashCommands
import TestKit
import TextEditing

// The command bar's field from Mentions (`MentionSlashBarPlugin`): a pill typed in the bar is a shape the
// command takes, for every shape selected, and the `@` picker on its line lists for them. A canvas in an
// unshown window (the bar's card is the host's real one), keys as the keyboard sends them, the slash
// fixtures' `stack` and `shelve`, which act on the shapes they're typed for together.

private let endpoint = ShapeID(UUID(uuidString: "E0E0E0E0-1111-4222-8333-444444444444")!)

/// A canvas in an unshown window, 800 × 800, over Mentions' fixtures with the slash fixtures, the bar and,
/// unless left out, its field from Mentions. Three jots in a column, Ann, Bob and Cy, all three selected;
/// beside them the plate Groceries (idA) by Ann, and Grocery List (idB) by Bob, so the nearer to the
/// middle of the three; the token Grocery run (idC) by Cy; and the endpoint Grocery status between them
/// and the plates, nearest of all.
@MainActor private final class BarField {
    let h: EditorHarness
    let log = SlashLog()
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 800), styleMask: [.titled], backing: .buffered, defer: true)
    let canvas: CanvasView
    let jots: [ShapeID]

    init(mentions: Bool = true) throws {
        h = try mentionHarness([SlashFixturesPlugin(log: log), SlashBarPlugin()] + (mentions ? [MentionSlashBarPlugin()] : []))
        let editor = h.editor
        jots = [("Ann", 0.0), ("Bob", 300.0), ("Cy", 600.0)].map { name, y in
            editor.add(Jot(CGRect(x: 0, y: y, width: 100, height: 100), text: ""), titled: name)
        }
        editor.add(Plate(CGRect(x: 300, y: 0, width: 120, height: 80)), titled: "Groceries", id: idA)
        editor.add(Plate(CGRect(x: 300, y: 320, width: 120, height: 80)), titled: "Grocery List", id: idB)
        editor.add(Token(CGRect(x: 300, y: 640, width: 60, height: 60), caption: "Grocery run"), titled: nil, id: idC)
        editor.add(Endpoint(CGRect(x: 150, y: 330, width: 100, height: 40), path: "Grocery status"), titled: nil, id: endpoint)
        canvas = CanvasView(editor: editor)
        canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 800)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        window.makeFirstResponder(canvas)
        editor.selectedShapeIDs = jots
    }

    var editor: CanvasEditor { h.editor }
    var bar: SlashBar? { editor.slashBar }
    var isOpen: Bool { bar?.isOpen == true }
    var field: MentionTextView<AnyMentionable>? { bar?.field as? MentionTextView<AnyMentionable> }
    var listed: [String] { bar?.typing?.picker?.listed.map(\.name) ?? [] }
    var picker: MentionPicker? { field?.picker }
    var pickerTargets: [ShapeID] { picker?.rows.compactMap(\.candidate?.id) ?? [] }
    /// The pills in the field, in order.
    var pills: [ShapeID] {
        guard let storage = field?.textStorage else { return [] }
        var found: [ShapeID] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let pill = value as? MentionAttachment { found.append(pill.target.shape) }
        }
        return found
    }

    /// `/` on the canvas.
    func slash() { window.press("/") }
    func type(_ text: String) { window.type(text) }

    /// Pastes mention text into the field from a pasteboard of the test's own, in its stored form.
    func paste(_ text: MentionText) {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.declareTypes([.mentionText], owner: nil)
        pasteboard.setString(text.stored, forType: .mentionText)
        _ = field?.readSelection(from: pasteboard, type: .mentionText)
    }
}

@MainActor let slashBarFieldTests = Suite("The command bar's field from Mentions", [
    test("with Mentions' field the bar types in one line of mention text, and lists what takes a shape: three jots list stack and shelve, one what its text lists") {
        let rig = try BarField()
        rig.slash()
        expect(rig.isOpen)
        let field = try require(rig.field, "the field is Mentions' text view")
        expect(rig.window.firstResponder === field, "the field has the keyboard")
        expect(field.isOneLine)
        expectEqual(field.string, "/")
        expectEqual(field.slashCommands?.target, .selection(rig.jots))
        expectEqual(rig.listed, ["stack", "shelve"], "what acts on all three: each takes a shape, which a pill names")
        expectEqual(AccessibilityProbe.label(of: field), "Command")
        rig.window.pressEscape()
        rig.window.pressEscape()
        expect(!rig.isOpen)

        rig.editor.selectedShapeIDs = [rig.jots[0]]
        rig.window.makeFirstResponder(rig.canvas)
        rig.slash()
        expectEqual(rig.listed, ["ping", "near", "stack", "choose", "shelve", "title"], "one jot: what its own text lists")
    },

    test("/stack @ lists only the plates, nearest the middle of the three first; Return picks, a second Return runs it on all three, the bar gone first") {
        let rig = try BarField()
        rig.slash()
        rig.type("stack @")
        expect(rig.picker != nil, "the @ picker, on the command's line")
        expectEqual(described(rig.picker), ["# Nearby", "Grocery List", "Groceries"], "the plates, Bob's first: it's nearer the middle of the three than Ann's is")
        rig.window.pressReturn()
        expect(rig.picker == nil)
        expectEqual(rig.pills, [idB])
        expectEqual(rig.log.runs, [], "Return picked the plate")
        expect(rig.isOpen)
        rig.window.pressReturn()
        expectEqual(rig.log.runs, ["stack B @Grocery List"])
        expectEqual(rig.log.owners, [rig.jots], "handed the three, once")
        expect(!rig.isOpen, "the bar closed before it ran")
        expect(rig.window.firstResponder === rig.canvas, "the canvas has the keyboard back")
        expectEqual(rig.editor.selectedShapeIDs, rig.jots, "the selection kept")
    },

    test("a name typed after the / lists the shapes the commands take for the three, as the @ picker would; Return runs the first on all three, the bar gone first") {
        let rig = try BarField()
        rig.slash()
        rig.type("gro")
        expectEqual(rig.bar?.typing?.picker?.rows.compactMap(\.item?.title),
                    ["stack Grocery List", "stack Groceries", "shelve Groceries", "shelve Grocery run"],
                    "the plates for stack, Bob's first; for shelve the plate its rule admits and the token, never the endpoint")
        rig.window.pressReturn()
        expectEqual(rig.log.runs, ["stack B @Grocery List"])
        expectEqual(rig.log.owners, [rig.jots], "handed the three, once")
        expect(!rig.isOpen, "the bar closed before it ran")
    },

    test("the @ picker lists for the three: none of them is listed, though they're nearest, and nearness is measured from their middle") {
        let rig = try BarField()
        rig.slash()
        rig.type("foo @")
        expect(rig.picker != nil, "a line that is no command's lists any shape")
        expectEqual(rig.pickerTargets, [endpoint, idB, idC, idA], "nearest the middle of the three first, none of the three")
        expect(Set(rig.pickerTargets).isDisjoint(with: rig.jots))
    },

    test("/shelve @ lists its kinds' shapes the rule admits for all three: the token and Groceries; no endpoint, though it's nearest, and not Grocery List") {
        let rig = try BarField()
        rig.slash()
        rig.type("shelve @")
        expectEqual(described(rig.picker), ["# Nearby", "Grocery run", "Groceries"])
        rig.type("gro")
        expectEqual(rig.pickerTargets, [idA, idC], "the matches: the same two, the shorter name first")
        rig.window.pressReturn()
        rig.window.pressReturn()
        expectEqual(rig.log.runs, ["shelve A @Groceries"])
        expectEqual(rig.log.owners, [rig.jots])
    },

    test("a pill the command doesn't take, pasted in, leaves the line text: Return does nothing and the bar stays; a line break pasted is a space and a pill a pill, and Return runs") {
        let rig = try BarField()
        rig.slash()
        rig.paste(MentionText([.text("stack "), .mention(idC, label: "Grocery run")]))
        expectEqual(rig.pills, [idC])
        rig.window.pressReturn()
        expectEqual(rig.log.runs, [], "the token is text to stack")
        expect(rig.isOpen)
        expectEqual(rig.field?.string, "/stack \u{FFFC}", "and Return inserted nothing")

        let pasted = try BarField()
        pasted.slash()
        pasted.paste(MentionText([.text("stack\n"), .mention(idA, label: "Groceries")]))
        expectEqual(pasted.field?.string, "/stack \u{FFFC}", "the line break a space")
        expectEqual(pasted.pills, [idA], "the pill a pill")
        pasted.window.pressReturn()
        expectEqual(pasted.log.runs, ["stack A @Groceries"])
        expectEqual(pasted.log.owners, [pasted.jots])
    },

    test("one line: Return with nothing to pick inserts nothing, and the bar closes as its / is deleted and on Escape with no list open") {
        let rig = try BarField()
        rig.slash()
        rig.type("stack ")
        expect(rig.bar?.typing?.picker == nil, "the space closed the list")
        rig.window.pressReturn()
        expectEqual(rig.field?.string, "/stack ", "stack takes a plate, and nothing is given: Return inserts nothing")
        expect(rig.isOpen)
        rig.window.pressEscape()
        expect(!rig.isOpen, "Escape with no list open")
        expectEqual(rig.bar?.lastClosing, .asked)

        rig.window.makeFirstResponder(rig.canvas)
        rig.slash()
        expect(rig.isOpen)
        rig.field?.deleteBackward(nil)
        expect(!rig.isOpen, "the / deleted")
        expect(rig.window.firstResponder === rig.canvas)
    },

    test("without Mentions' field the bar types in its own, which names no shape: one jot lists what takes none, and three jots, which offer only what takes one, open nothing") {
        let rig = try BarField(mentions: false)
        rig.editor.selectedShapeIDs = [rig.jots[0]]
        rig.slash()
        expect(rig.bar?.field is SlashBarTextView, "the bar's own field")
        expectEqual(rig.listed, ["ping", "near", "choose", "title"], "stack and shelve left out: the field can't name a plate")
        rig.window.pressEscape()
        rig.window.pressEscape()
        rig.editor.selectedShapeIDs = rig.jots
        rig.window.makeFirstResponder(rig.canvas)
        rig.slash()
        expect(!rig.isOpen, "nothing to list")
    },
])
