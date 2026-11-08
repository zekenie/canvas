import AppKit
import Canvas
import CanvasTesting
import LineRows
import TestKit
import TextEditing

// An action row in a line's list ("New type Problem"): listed after every word whatever its score, done by Return (or a click),
// as Tab does it too (Tab picks either, the list's rule), while Return never picks a word; done, the host is handed the action and
// the range of the words it was offered for, and the words can stand for what it made. The session's part (one step with the
// line's commit, the caret kept) is held by the kit's tests, whose grammars offer one.

@MainActor private final class ActionField {
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
    let field = LineField()
    var done: [(action: LineAction, range: NSRange)] = []
    let action = LineAction(step: "New Tally") { _ in PartAddress(ShapeID()) }

    init() {
        window.isReleasedWhenClosed = false
        field.frame = CGRect(x: 0, y: 0, width: 400, height: 20)
        window.contentView = field
        field.offering = { [unowned self] in
            let length = (field.string as NSString).length
            return LineOffers(range: NSRange(location: 0, length: length), query: field.string,
                              items: [.action("New tally \(field.string)", action), LineOffer(CaretCompletion(label: "zebra", insert: "zebra"))])
        }
        field.onAction = { [unowned self] action, range in done.append((action, range)) }
        window.makeFirstResponder(field)
    }

    func type(_ text: String) {
        window.type(text)
        window.settle()
    }

    func press(_ chord: Chord) {
        window.press(chord)
        window.settle()
    }
}

@MainActor let actionTests = Suite("Action rows", [
    test("an action is listed after the words, whatever its score; Return does it, handing the host the words' range; the words then stand for what it made") {
        let a = ActionField()
        a.type("ze")
        expectEqual(a.field.listedOffers, ["zebra", "New tally ze"], "the action last though it was offered first")
        a.press(.down)
        expectEqual(a.field.highlightedOffer, "New tally ze")
        a.press(.return)
        expectEqual(a.done.count, 1)
        expectEqual(a.done.first?.action, a.action)
        expectEqual(a.done.first?.range, NSRange(location: 0, length: 2))
        expectEqual(a.field.string, "ze", "an action puts no words in")
        let made = PartAddress(ShapeID())
        a.field.stand(for: made, at: NSRange(location: 0, length: 2))
        expectEqual(a.field.line.references.map(\.target), [made])
    },
    test("Tab picks either, the list's rule: on an action it does it; Return on a word goes on to the line, as every line's list") {
        let a = ActionField()
        a.type("New")
        expectEqual(a.field.highlightedOffer, "New tally New")
        a.press(.tab)
        expectEqual(a.done.count, 1, "Tab does the action")
        a.field.selectAll(nil)
        a.type("zeb")
        expectEqual(a.field.highlightedOffer, "zebra")
        a.press(.return)
        expectEqual(a.done.count, 1)
        expect(!a.field.string.contains("zebra"), "Return never picks a word: \(a.field.string)")
    },
])
