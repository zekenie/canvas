@_spi(Host) import Canvas
import CanvasTesting
import AppKit
import CoreGraphics
import TestKit

// A plugin's yes-or-no question waits in a line for the host to show it, and a menu a canvas button asks
// for waits for the host to pop it up.

/// A host that notes each time the question or the menu waiting changed.
@MainActor private final class Host {
    var questions: [CanvasQuestion?] = []
    var menus = 0
}

extension Host: CanvasEditorDelegate {
    func editorNeedsDisplay(_ editor: CanvasEditor) {}
    func editorCursorDidChange(_ editor: CanvasEditor) {}
    func editorEditingDidChange(_ editor: CanvasEditor) {}
    func editorQuestionDidChange(_ editor: CanvasEditor) { questions.append(editor.question) }
    func editorMenuToPopUpDidChange(_ editor: CanvasEditor) { menus += 1 }
}

@MainActor private func question(_ id: String, _ message: String = "") -> CanvasQuestion {
    CanvasQuestion(id: id, message: message.isEmpty ? id : message, confirm: "Go")
}

@MainActor private final class Answers {
    var heard: [String] = []
    func answer(_ name: String) -> @MainActor (Bool) -> Void { { [self] yes in heard.append("\(name) \(yes ? "yes" : "no")") } }
}

@MainActor let questionTests = Suite("Questions", [
    test("a question has its words and two buttons: yes says what it does, no says Cancel unless it says otherwise") {
        let q = CanvasQuestion(id: "read", message: "Read 120 shapes?", detail: "About 2 minutes.", confirm: "Read Again")
        expectEqual(q.message, "Read 120 shapes?")
        expectEqual(q.detail, "About 2 minutes.")
        expectEqual(q.confirm, "Read Again")
        expectEqual(q.cancel, "Cancel")
        expectEqual(CanvasQuestion(id: 1, message: "m", confirm: "c", cancel: "Not Now").cancel, "Not Now")
        expectEqual(CanvasQuestion(id: "a", message: "m", confirm: "c"), CanvasQuestion(id: "a", message: "m", confirm: "c"))
        expect(CanvasQuestion(id: "a", message: "m", confirm: "c") != CanvasQuestion(id: "b", message: "m", confirm: "c"))
    },
    test("questions are answered first in, first out, one at a time; the host is told as the one to show changes") {
        let h = try EditorHarness(plugins: [FixturesPlugin()]), host = Host(), answers = Answers()
        h.editor.delegate = host
        expect(h.editor.question == nil)
        h.editor.ask(question("one"), answers.answer("one"))
        h.editor.ask(question("two"), answers.answer("two"))
        h.editor.ask(question("three"), answers.answer("three"))
        expectEqual(h.editor.question?.id, AnyHashable("one"))
        expectEqual(host.questions.map { $0?.id }, [AnyHashable("one")], "told once: the others wait")
        h.editor.answerQuestion(true)
        expectEqual(answers.heard, ["one yes"])
        expectEqual(h.editor.question?.id, AnyHashable("two"))
        h.editor.answerQuestion(false)
        h.editor.answerQuestion(true)
        expectEqual(answers.heard, ["one yes", "two no", "three yes"])
        expect(h.editor.question == nil)
        expectEqual(host.questions.map { $0?.id }, [AnyHashable("one"), AnyHashable("two"), AnyHashable("three"), nil])
        h.editor.answerQuestion(true)
        expectEqual(answers.heard.count, 3, "with none waiting, nothing is answered")
    },
    test("asking again with the id of a question that waits replaces it where it is, and the replaced one is never answered") {
        let h = try EditorHarness(plugins: [FixturesPlugin()]), host = Host(), answers = Answers()
        h.editor.delegate = host
        h.editor.ask(question("a", "first"), answers.answer("a1"))
        h.editor.ask(question("b"), answers.answer("b"))
        h.editor.ask(question("b", "second"), answers.answer("b2"))
        expectEqual(host.questions.count, 1, "one that isn't the one shown changes nothing to show")
        h.editor.ask(question("a", "again"), answers.answer("a2"))
        expectEqual(host.questions.count, 2, "the one shown replaced: the host shows it again")
        expectEqual(h.editor.question?.message, "again")
        h.editor.answerQuestion(true)
        expectEqual(h.editor.question?.message, "second")
        h.editor.answerQuestion(true)
        expectEqual(answers.heard, ["a2 yes", "b2 yes"])
        expect(h.editor.question == nil)
    },
    test("an answer may ask again: the new question is next in line, or shown at once with none waiting") {
        let h = try EditorHarness(plugins: [FixturesPlugin()]), host = Host(), answers = Answers()
        h.editor.delegate = host
        h.editor.ask(question("a")) { yes in
            answers.heard.append("a \(yes)")
            h.editor.ask(question("a", "retry"), answers.answer("retry"))
        }
        h.editor.ask(question("b"), answers.answer("b"))
        h.editor.answerQuestion(true)
        expectEqual(h.editor.question?.id, AnyHashable("b"))
        h.editor.answerQuestion(true)
        expectEqual(h.editor.question?.message, "retry")
        h.editor.answerQuestion(false)
        expectEqual(answers.heard, ["a true", "b yes", "retry no"])
    },
    test("headless, a question waits, however long, until it is answered through the host API") {
        let h = try EditorHarness(plugins: [FixturesPlugin()]), answers = Answers()
        h.editor.ask(question("a"), answers.answer("a"))
        h.wait(60_000)
        expectEqual(answers.heard, [])
        expectEqual(h.editor.question?.id, AnyHashable("a"))
        h.editor.answerQuestion(true)
        expectEqual(answers.heard, ["a yes"])
    },
    test("a file put in place answers every question that waits no, in order") {
        let h = try EditorHarness(plugins: [FixturesPlugin()]), host = Host(), answers = Answers()
        h.editor.delegate = host
        h.editor.ask(question("a"), answers.answer("a"))
        h.editor.ask(question("b"), answers.answer("b"))
        h.editor.replaceDocument(with: CanvasDocument())
        expectEqual(answers.heard, ["a no", "b no"])
        expect(h.editor.question == nil)
        expect(host.questions.last! == nil, "and the host is told to take the sheet down")
    },
    test("cancelling answers them no too: a window closing") {
        let h = try EditorHarness(plugins: [FixturesPlugin()]), answers = Answers()
        h.editor.ask(question("a"), answers.answer("a"))
        h.editor.cancelQuestions()
        expectEqual(answers.heard, ["a no"])
        h.editor.cancelQuestions()
        expectEqual(answers.heard, ["a no"])
    },
    test("an answer is heard outside any transaction: it may transact") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        h.editor.ask(question("a")) { yes in
            if yes { h.editor.add(Box(.zero)) }
        }
        h.editor.answerQuestion(true)
        expectEqual(h.editor.document.shapes.count, 1)
    },
])

@MainActor let popUpMenuTests = Suite("Menus popped up from the canvas", [
    test("a menu asked for waits for the host, with the rect it opens below; the host says it popped it up") {
        let h = try EditorHarness(plugins: [FixturesPlugin()]), host = Host()
        h.editor.delegate = host
        expect(h.editor.menuToPopUp == nil)
        let menu = NSMenu(title: "Types")
        let rect = CGRect(x: 10, y: 20, width: 30, height: 12)
        h.editor.popUpMenu(menu, below: rect)
        expect(h.editor.menuToPopUp?.menu === menu)
        expectEqual(h.editor.menuToPopUp?.rect, rect)
        expectEqual(host.menus, 1)
        h.editor.menuDidPopUp()
        expect(h.editor.menuToPopUp == nil)
    },
    test("a second menu asked for while one waits replaces it") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let first = NSMenu(title: "1"), second = NSMenu(title: "2")
        h.editor.popUpMenu(first, below: .zero)
        h.editor.popUpMenu(second, below: CGRect(x: 1, y: 1, width: 1, height: 1))
        expect(h.editor.menuToPopUp?.menu === second)
    },
    test("a press that begins drops a menu that waits, and so does a file put in place") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        h.editor.popUpMenu(NSMenu(title: "1"), below: .zero)
        h.press(at: CGPoint(x: 50, y: 50))
        expect(h.editor.menuToPopUp == nil)
        h.release()
        h.editor.popUpMenu(NSMenu(title: "2"), below: .zero)
        h.release()
        expect(h.editor.menuToPopUp != nil, "a release isn't a press")
        h.editor.replaceDocument(with: CanvasDocument())
        expect(h.editor.menuToPopUp == nil)
    },
    test("a pan from a middle-button press drops it too") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        h.editor.popUpMenu(NSMenu(title: "1"), below: .zero)
        _ = h.editor.panPointerDown(PointerEvent(location: .zero, timestamp: 1, modifiers: [], clickCount: 1))
        expect(h.editor.menuToPopUp == nil)
    },
])
