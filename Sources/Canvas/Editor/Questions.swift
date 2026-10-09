import AppKit

/// A yes-or-no question a plugin puts to the person (`editor.ask`), which the host shows as a sheet on
/// the board's window: what a plugin asks before it does something large or dear, in words that say
/// what and how much (quiet: a sentence and a verb, not a paragraph).
public struct CanvasQuestion: Equatable {
    /// What it's about, as its plugin knows it: asking again with the same id replaces the question
    /// still waiting.
    public let id: AnyHashable
    public let message: String
    /// A second line under the message, if the message needs one.
    public let detail: String?
    /// The button that says yes: a verb ("Read Again").
    public let confirm: String
    /// The button that says no.
    public let cancel: String

    public init<ID: Hashable & Sendable>(id: ID, message: String, detail: String? = nil, confirm: String, cancel: String = "Cancel") {
        self.id = AnyHashable(id)
        self.message = message
        self.detail = detail
        self.confirm = confirm
        self.cancel = cancel
    }
}

extension CanvasEditor {
    /// Asks the person `question`; `answer` hears yes (true) or no. Questions wait in the order they were
    /// asked, one at a time, each for the host to show once the one before it is answered
    /// (`question`). Asking again with the id of one that waits replaces it, in its place in the line,
    /// and the replaced one's `answer` is never called (it was superseded, not answered). Every
    /// waiting question is answered no when a file is put in place (`replaceFile`) or the window
    /// closes. With no host (a headless editor), a question waits until it is answered through the
    /// host API, as a test does. `answer` runs on the main actor, outside any transaction: it
    /// transacts if it needs to.
    public func ask(_ question: CanvasQuestion, _ answer: @escaping @MainActor (Bool) -> Void) {
        if let index = questions.firstIndex(where: { $0.question.id == question.id }) {
            questions[index] = (question, answer)
            if index == 0 { delegate?.editorQuestionDidChange(self) }
        } else {
            questions.append((question, answer))
            if questions.count == 1 { delegate?.editorQuestionDidChange(self) }
        }
    }

    /// The question for the host to show: the first one asked that is still waiting.
    @_spi(Host) public var question: CanvasQuestion? { questions.first?.question }

    /// The person's answer to `question`: its `answer` hears it, and the next question, if one waits,
    /// is the one to show.
    @_spi(Host) public func answerQuestion(_ yes: Bool) {
        guard !questions.isEmpty else { return }
        let answered = questions.removeFirst()
        delegate?.editorQuestionDidChange(self)
        answered.answer(yes)
    }

    /// Answers every waiting question no, in the order they were asked: the window closes, or a file
    /// is put in place.
    @_spi(Host) public func cancelQuestions() {
        guard !questions.isEmpty else { return }
        let waiting = questions
        questions = []
        delegate?.editorQuestionDidChange(self)
        for asked in waiting { asked.answer(false) }
    }
}

extension CanvasEditor {
    /// Shows a menu under a rect of the board, as the host pops it up: a plugin's canvas button that
    /// opens a menu (a chip's) calls this from its click. The host pops it up on the next turn of the
    /// run loop, not inside the click, which is still bookkeeping the press it ends; a press that
    /// begins before that drops it. A menu asked for while another waits replaces it. In world units.
    public func popUpMenu(_ menu: NSMenu, below worldRect: CGRect) {
        menuWaiting = (menu, worldRect)
        delegate?.editorMenuToPopUpDidChange(self)
    }

    /// The menu waiting for the host to pop it up, and the rect it opens below (world units).
    @_spi(Host) public var menuToPopUp: (menu: NSMenu, rect: CGRect)? { menuWaiting }

    /// The host is popping the menu up: it no longer waits.
    @_spi(Host) public func menuDidPopUp() { menuWaiting = nil }
}
