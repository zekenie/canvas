import AppKit
import Canvas
import FuzzyMatching
import TextEditing

/// Slash commands typed in a text view: the list at a `/` on an empty line, choosing from it, and
/// entering a command line. It types for a target (`SlashTarget`): one shape's text (`.text(owner)`)
/// or the shapes selected (the command bar's field), and asks `commands` what the target offers, so the
/// same text view code serves a note on the canvas, a card's description, a box in the panel and the
/// bar. The host, an `EditingTextView` subclass that makes one, tells it what's typed
/// (`didType`) and where the text and the caret go (`didChange`), asks it first about each key
/// (`takesKey`), and shows its list as its own (`caretListWindow` returns `window` while it's open),
/// so the view's keys, and its closing as the keyboard or the window goes, are every caret list's.
///
/// - A `/` typed (not pasted, not composed) on an empty line, in a view that can be written, with no
///   other list open, opens the list at it when the shape offers a command; none offered, a slash
///   is a slash. What's typed after it is the query (`SlashCommandPicker`).
/// - The keys are every caret list's. Tab, or a click on a row, completes: `/` and the name typed
///   become `/` and the command's name, and a space if it takes an argument; one step of the text's
///   undo. Return is the list's own: a highlighted command that runs with nothing after it runs at
///   once, and any other completes, so its argument can be typed; with nothing highlighted it's a
///   new line, which closes the list.
/// - Return with the list closed, on a line that's a command the shape offers, with arguments the
///   command accepts, takes the line's text (from its `/` to its end) out of the text, as an edit
///   of the person's, leaving the caret on the now empty line, and runs the command. Anything else
///   is Return as ever: a new line, or what the host does with it (a box's commit).
///
/// - A command that takes one shape (`SlashCommand`'s `shapes:` form) has a rule for which, and the
///   kinds it takes at most; a host that lets shapes be picked asks for them where an `@` was just
///   typed (`admittedShapes(at:)`, a `SlashShapeRule`) to list only those the command admits, so
///   what a person picks on its line is a shape it can take.
///
/// - The command is marked as it's typed, as a mention's pill is marked (`EditingTextView.highlights`,
///   drawn by the view under the text, in the text's own color): the `/name` on the line the caret is
///   on, while the list lists something for it and, with the list closed, while the shape offers the
///   command, and what it's given in a lighter shade, if it accepts that. So a line that Return
///   would run looks different from one that is only text. Nothing is marked in a view that can't
///   be written.
///
/// - A command that takes one choice (`SlashCommand`'s `choices:` form) opens a second list when its
///   name is done: Tab, Return or a click on it in the names' list writes `/name ` and the list
///   becomes the choices (`SlashChoicePicker`), and a space typed after a complete name opens it
///   too; nothing else does (not a click into an old line, not typing after Escape). The keys are
///   every caret list's, and a pick (Return, Tab, a click) takes the whole line out of the text and
///   runs the command with the row at once. With the list closed, Return on the line typed whole
///   runs the first row whose title is what was typed; none, a new line. Only the name of such a
///   line is marked, never what follows it.
///
/// - A command that answers later (one about the command bar's target as a whole,
///   `OfferedSlashCommand.answersLater`) isn't run: Return on its line, as on any command line, leaves the
///   line as typed and hands the command to the host (`willAnswer`), which starts it and waits.
///
/// It writes the text only through the view, as a person's edit (undoable, heard by the host), its
/// list closed first, and ignores its own callbacks while it does. The command runs after the text
/// is written, so a command that makes the shape read-only has its line gone already. Running is the
/// state's: one undo step named for the command; while a shape is being edited that step comes after
/// the editing session's step so far, which has the typing and the line's removal in it.
@MainActor
public final class SlashCommandTyping {
    /// The open list's model.
    public private(set) var picker: SlashCommandPicker?
    /// The open list of a choice command's choices; never open with `picker`.
    public private(set) var choices: SlashChoicePicker?
    /// The window the open list shows in, while it's open.
    public private(set) var window: CaretListWindow?

    /// What it types for: one shape's text, or the shapes selected.
    public let target: SlashTarget
    /// Called once a command's line is out of the text and before the command runs (a Return on a line,
    /// a pick of a choice), with the command and the row picked: the command bar closes there, so the
    /// command runs from the canvas, as from a key. Nothing of the view or this object is touched after it.
    public var willRun: (@MainActor (_ command: OfferedSlashCommand, _ choice: SlashChoice?) -> Void)?
    /// Called in place of running a command that answers later (`OfferedSlashCommand.answersLater`), with
    /// what was typed after its name: its line stays in the text as typed, and the host starts it and waits
    /// for its answer (the command bar does). With none, such a command's line is text, and Return is as ever.
    public var willAnswer: (@MainActor (_ command: OfferedSlashCommand, _ arguments: SlashArguments) -> Void)?
    /// Called after each change to the text that isn't this object's own writing: what a host waiting on a
    /// line's answer stops at (the line changed).
    public var didEdit: (@MainActor () -> Void)?

    private weak var view: EditingTextView?
    private weak var commands: SlashCommandState?
    private let readArguments: (@MainActor (NSRange) -> SlashArguments)?
    /// Whether what's typed can name a shape: without, the commands that take one are left out of the
    /// lists, the marks and Return (a field that can't name a shape could never give them one).
    private let takesShapes: Bool
    /// The substitutions the list turned off while it's open, to put back as they were.
    private var substitutions: CaretListSubstitutions?
    private var isWriting = false

    /// For a line of one shape's text: `init(over:target:commands:arguments:)` with `.text(owner)`.
    public convenience init(over view: EditingTextView, owner: ShapeID, commands: SlashCommandState,
                            arguments: (@MainActor (NSRange) -> SlashArguments)? = nil) {
        self.init(over: view, target: .text(owner), commands: commands, arguments: arguments)
    }

    /// `arguments` reads what's typed in a range as runs (a mention text view's pills as shapes);
    /// the default reads it as plain text. `takesShapes` false leaves out the commands that take a
    /// shape, for a field that can't name one.
    public init(over view: EditingTextView, target: SlashTarget, commands: SlashCommandState,
                arguments: (@MainActor (NSRange) -> SlashArguments)? = nil, takesShapes: Bool = true) {
        self.view = view
        self.target = target
        self.commands = commands
        readArguments = arguments
        self.takesShapes = takesShapes
    }

    /// What the target offers now that this field can give what it takes.
    private func offered(by commands: SlashCommandState) -> [OfferedSlashCommand] {
        let all = commands.commands(for: target)
        return takesShapes ? all : all.filter { !$0.takesShape }
    }

    /// The command of a name the target offers now that this field can give what it takes.
    private func command(named name: String, in commands: SlashCommandState) -> OfferedSlashCommand? {
        guard let found = commands.command(named: name, for: target), takesShapes || !found.takesShape else { return nil }
        return found
    }

    // MARK: Opening and closing

    /// After the view inserted what a person typed (not what it pasted, nor what an input method is
    /// still composing): a `/` on an empty line opens the list.
    public func didType(_ string: String) {
        if string.utf16.count == 1, let character = string.utf16.first, SlashCommandLine.isWhitespace(character),
           !SlashCommandLine.isLineBreak(character) {
            openChoicesAfterSpace()
            return
        }
        guard string == "/", !isWriting, picker == nil, choices == nil, let view, let commands, view.isEditable, view.caretListWindow == nil,
              !view.hasMarkedText(), let storage = view.textStorage else { return }
        let selection = view.selectedRange()
        guard selection.length == 0, selection.location > 0 else { return }
        let location = selection.location - 1
        guard SlashCommandPicker.opens(in: storage.string as NSString, at: location) else { return }
        let offered = self.offered(by: commands)
        guard !offered.isEmpty else { return }
        open(at: location, offering: offered, over: view)
    }

    /// After the text changed (`isEdit`) or the caret moved alone: reads what's typed after the `/`
    /// again, and closes the list if that's what the change says.
    public func didChange(isEdit: Bool) {
        guard !isWriting else { return }
        read(isEdit: isEdit)
        readChoices(isEdit: isEdit)
        showCommand()
        if isEdit { didEdit?() }
    }

    /// Closes the list, if it's open: its `/` stays as typed, and nothing opens until another is
    /// typed. The substitutions it turned off come back, and VoiceOver hears the list go.
    public func close() {
        guard picker != nil || choices != nil else { return }
        picker?.list.onChange = nil
        choices?.list.onChange = nil
        picker = nil
        choices = nil
        if let view { substitutions?.apply(to: view) }
        substitutions = nil
        let closing = window
        window = nil
        closing?.dismiss()
        showCommand()
    }

    private func open(at location: Int, offering offered: [OfferedSlashCommand], over view: EditingTextView) {
        let picker = SlashCommandPicker(at: location, offering: offered)
        self.picker = picker
        substitutions = CaretListSubstitutions(of: view)
        CaretListSubstitutions.off.apply(to: view)
        window = CaretListWindow(picker.list, accessibilityLabel: SlashCommandStyle.accessibilityLabel, over: view,
                                 anchor: { [weak self] in self?.anchor },
                                 pick: { [weak self] row in self?.pick(row: row) },
                                 close: { [weak self] in self?.close() })
        picker.list.onChange = { [weak self] in self?.window?.listDidChange() }
        read(isEdit: true)
        if self.picker != nil { window?.listDidChange() }
        showCommand()
    }

    /// Where the list goes: under its `/`, while it's in the text.
    private var anchor: NSRange? {
        guard let location = picker?.location ?? choices?.nameRange.location, let storage = view?.textStorage,
              location < storage.length else { return nil }
        return NSRange(location: location, length: 1)
    }

    /// A whitespace typed after a complete choice command's name, with nothing but whitespace after it
    /// and no list open: opens the choices.
    private func openChoicesAfterSpace() {
        guard !isWriting, picker == nil, choices == nil, let view, let commands, view.isEditable, view.caretListWindow == nil,
              !view.hasMarkedText(), let storage = view.textStorage else { return }
        let selection = view.selectedRange()
        guard selection.length == 0, selection.location > 1,
              let line = SlashCommandLine(in: storage.string as NSString, caret: selection.location),
              line.arguments.length == 0,
              let command = command(named: line.name, in: commands), command.takesChoice else { return }
        openChoices(command, nameRange: line.nameRange, start: selection.location, over: view)
    }

    private func openChoices(_ command: OfferedSlashCommand, nameRange: NSRange, start: Int, over view: EditingTextView) {
        let picker = SlashChoicePicker(offering: command, nameRange: nameRange, start: start)
        choices = picker
        substitutions = CaretListSubstitutions(of: view)
        CaretListSubstitutions.off.apply(to: view)
        window = CaretListWindow(picker.list, accessibilityLabel: SlashCommandStyle.choicesAccessibilityLabel, over: view,
                                 anchor: { [weak self] in self?.anchor },
                                 pick: { [weak self] row in self?.pick(row: row) },
                                 close: { [weak self] in self?.close() })
        picker.list.onChange = { [weak self] in self?.window?.listDidChange() }
        readChoices(isEdit: true)
        if choices != nil { window?.listDidChange() }
        showCommand()
    }

    private func readChoices(isEdit: Bool) {
        guard let choices, let view, let storage = view.textStorage else { return }
        if choices.read(storage.string as NSString, selection: view.selectedRange(), isEdit: isEdit) != nil { close() }
    }

    private func read(isEdit: Bool) {
        guard let picker, let view, let storage = view.textStorage else { return }
        if picker.read(storage.string as NSString, selection: view.selectedRange(), isEdit: isEdit) != nil { close() }
    }

    // MARK: Keys

    /// Whether a key is the list's or a command line's before the view has it: a plain Return
    /// (Return or Enter with no ⌘, ⇧, ⌥ or ⌃) is, when `takesReturn` says so. The host asks first,
    /// and gives the key to the view when it isn't taken.
    public func takesKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76,
              event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty else { return false }
        return takesReturn()
    }

    /// A plain Return: whether it took it. With the list open, the highlighted command runs if it
    /// runs with nothing after it and nothing else is on the line, else it completes; with nothing
    /// highlighted, Return isn't taken. With the list closed, a command line runs (see the type).
    public func takesReturn() -> Bool {
        guard !isWriting, let view, let commands, view.isEditable, !view.hasMarkedText(), let storage = view.textStorage else { return false }
        let text = storage.string as NSString
        // The choices' list has the key: Return is the caret list's own, a pick or a new line.
        if choices != nil { return false }
        if let picker {
            guard window != nil, let command = picker.highlightedCommand else { return false }
            let name = picker.nameRange
            close()
            var start = 0, end = 0, contentsEnd = 0
            text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: picker.location, length: 0))
            let rest = NSRange(location: NSMaxRange(name), length: max(0, contentsEnd - NSMaxRange(name)))
            let isAlone = start == picker.location && NSMaxRange(name) <= text.length && text.substring(with: rest).allSatisfy(\.isWhitespace)
            if isAlone, command.accepts(SlashArguments([])) {
                return run(command, with: SlashArguments([]), removing: NSRange(location: start, length: contentsEnd - start))
            }
            return complete(command, replacing: name)
        }
        guard view.caretListWindow == nil else { return false }
        let selection = view.selectedRange()
        guard selection.length == 0, let line = SlashCommandLine(in: text, caret: selection.location),
              let command = command(named: line.name, in: commands) else { return false }
        if command.takesChoice { return runTyped(command, line: line, in: text) }
        let arguments = arguments(in: line.arguments)
        guard command.accepts(arguments) else { return false }
        return run(command, with: arguments, removing: line.range)
    }

    /// What's typed in a range, as the command is given it.
    private func arguments(in range: NSRange) -> SlashArguments {
        if let readArguments { return readArguments(range) }
        guard range.length > 0, let storage = view?.textStorage else { return SlashArguments([]) }
        return SlashArguments((storage.string as NSString).substring(with: range))
    }

    // MARK: Completing and running

    /// A click on a row of the list completes its command.
    private func pick(row index: Int) {
        if let choices {
            guard choices.listed.indices.contains(index) else { return }
            _ = choose(choices.listed[index], of: choices.command, line: choices.nameRange.location)
            return
        }
        guard let picker, picker.listed.indices.contains(index) else { return }
        _ = complete(picker.listed[index], replacing: picker.nameRange)
    }

    /// Takes the line (from its `/` to its end) out of the text and runs the command with the
    /// choice. The command is asked of the shape again, as `run` does; nothing of the view or this
    /// object is touched after, since a pick may end this editing and take the view away.
    private func choose(_ choice: SlashChoice, of command: OfferedSlashCommand, line location: Int) -> Bool {
        guard let commands, let current = self.command(named: command.name, in: commands), current.takesChoice,
              let storage = view?.textStorage, location < storage.length else { return false }
        let text = storage.string as NSString
        var start = 0, end = 0, contentsEnd = 0
        text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
        close()
        guard write(NSRange(location: location, length: contentsEnd - location), with: "") else { return false }
        willRun?(current, choice)
        commands.run(current, choosing: choice)
        return true
    }

    /// Return on a closed choice command's line typed whole: runs the first row whose title is what
    /// was typed (folded as every list folds), asking for the rows now and not before.
    private func runTyped(_ command: OfferedSlashCommand, line: SlashCommandLine, in text: NSString) -> Bool {
        guard line.arguments.length > 0 else { return false }
        let typed = text.substring(with: line.arguments)
        guard let choice = command.choices().first(where: { FuzzyMatcher.match(typed, in: $0.title)?.score == FuzzyRanking.exact })
        else { return false }
        return choose(choice, of: command, line: line.range.location)
    }

    /// Writes `/` and the command's name in the place of what was typed, and a space if it takes an
    /// argument and no whitespace follows on its line (a line break doesn't count: the argument is
    /// typed on the line, not run into the one below): the caret after, one step of the text's undo.
    private func complete(_ command: OfferedSlashCommand, replacing range: NSRange) -> Bool {
        guard let view, let storage = view.textStorage, NSMaxRange(range) <= storage.length else { return false }
        close()
        var completed = "/" + command.name
        if command.argument != nil {
            let text = storage.string as NSString
            let next: unichar? = NSMaxRange(range) < text.length ? text.character(at: NSMaxRange(range)) : nil
            let spaceFollows = next.map { SlashCommandLine.isWhitespace($0) && !SlashCommandLine.isLineBreak($0) } ?? false
            if !spaceFollows { completed += " " }
        }
        guard write(range, with: completed) else { return false }
        if command.takesChoice { openChoicesAfterCompleting(command, over: view) }
        return true
    }

    /// The caret is after the name's `/name` and the space `complete` wrote, or before the one that
    /// was there already: after it either way, and the choices open.
    private func openChoicesAfterCompleting(_ command: OfferedSlashCommand, over view: EditingTextView) {
        guard let storage = view.textStorage else { return }
        let text = storage.string as NSString
        var caret = view.selectedRange().location
        if caret < text.length, SlashCommandLine.isWhitespace(text.character(at: caret)), !SlashCommandLine.isLineBreak(text.character(at: caret)) {
            caret += 1
            view.setSelectedRange(NSRange(location: caret, length: 0))
        }
        guard let line = SlashCommandLine(in: text, caret: caret), NSMaxRange(line.nameRange) == caret - 1 else { return }
        openChoices(command, nameRange: line.nameRange, start: caret, over: view)
    }

    /// Takes the line out of the text and runs the command. The command is asked of the shape now
    /// and run as found, once the line is gone (what the text removed may change what a shape
    /// offers, which doesn't take the command back); not found or not accepting, nothing is taken
    /// out. One that answers later is handed to the host instead (`willAnswer`), its line left as typed.
    private func run(_ command: OfferedSlashCommand, with arguments: SlashArguments, removing range: NSRange) -> Bool {
        guard let commands, let current = self.command(named: command.name, in: commands), current.accepts(arguments) else { return false }
        if current.answersLater {
            guard let willAnswer else { return false }
            close()
            willAnswer(current, arguments)
            return true
        }
        close()
        guard write(range, with: "") else { return false }
        willRun?(current, nil)
        commands.run(current, with: arguments)
        return true
    }

    /// Replaces a range as an edit a person makes: undoable and heard by the host
    /// (`shouldChangeText`, `didChangeText`), its own step of the text's undo, with the view's
    /// typing attributes; the caret lands after it. This object's callbacks are ignored meanwhile.
    private func write(_ range: NSRange, with string: String) -> Bool {
        guard let view, let storage = view.textStorage else { return false }
        isWriting = true
        defer { isWriting = false }
        view.breakUndoCoalescing()
        guard view.shouldChangeText(in: range, replacementString: string) else { return false }
        storage.replaceCharacters(in: range, with: NSAttributedString(string: string, attributes: view.typingAttributes))
        view.setSelectedRange(NSRange(location: range.location + (string as NSString).length, length: 0))
        view.didChangeText()
        view.breakUndoCoalescing()
        showCommand()
        return true
    }

    // MARK: The shapes a command takes

    /// The rule for the shapes an `@` typed at `location` may pick, if the line it's on is a command
    /// line (`SlashCommandLine`, read with the caret at `location`) whose command the shape offers
    /// now and which takes one shape: the kinds it takes at most and its rule (`SlashShapeRule`).
    /// Nil anywhere else (a plain line, a command that takes no shape, one the shape doesn't offer),
    /// where every shape may be picked as ever. The host asks as it opens the picker, for the line
    /// as it is then.
    public func admittedShapes(at location: Int) -> SlashShapeRule? {
        guard let storage = view?.textStorage, let commands,
              let line = SlashCommandLine(in: storage.string as NSString, caret: location),
              let command = command(named: line.name, in: commands) else { return nil }
        return command.shapeRule
    }

    /// Whether the line the location is on is a choice command's line that the shape offers: where
    /// an `@` is a letter, since a pill would be an argument the command can't take. The host asks as
    /// it would open the picker, for the line as it is then.
    public func listsChoices(at location: Int) -> Bool {
        guard let storage = view?.textStorage, let commands,
              let line = SlashCommandLine(in: storage.string as NSString, caret: location),
              let command = command(named: line.name, in: commands) else { return false }
        return command.takesChoice
    }

    // MARK: Marking the command

    /// Marks what's typed as a command, as the view draws it under the text: the `/name`, and what
    /// it's given in a lighter shade. While the list is open it's the `/` and the name there, if the
    /// list lists a command for it (not "No matches", which is no command); with the list closed it's
    /// the line the caret is on, if it's a command line whose command the shape offers now, and the
    /// arguments only if the command accepts them (so `/lock now`, which stays text, marks `/lock`
    /// alone). The color is the text's own, so the marks follow the surface the text is on.
    private func showCommand() {
        guard let view else { return }
        view.highlights = marks(over: view)
    }

    private func marks(over view: EditingTextView) -> [TextHighlight] {
        guard view.isEditable, let storage = view.textStorage else { return [] }
        if let picker {
            guard !picker.listed.isEmpty, NSMaxRange(picker.nameRange) <= storage.length else { return [] }
            return [mark(picker.nameRange, SlashCommandStyle.commandFill, over: view)]
        }
        if let choices {
            guard NSMaxRange(choices.nameRange) <= storage.length else { return [] }
            return [mark(choices.nameRange, SlashCommandStyle.commandFill, over: view)]
        }
        let selection = view.selectedRange()
        guard let commands, selection.length == 0,
              let line = SlashCommandLine(in: storage.string as NSString, caret: selection.location),
              let command = command(named: line.name, in: commands) else { return [] }
        var found = [mark(line.nameRange, SlashCommandStyle.commandFill, over: view)]
        if command.takesChoice { return found }
        if line.arguments.length > 0, command.accepts(arguments(in: line.arguments)) {
            found.append(mark(line.arguments, SlashCommandStyle.argumentsFill, over: view))
        }
        return found
    }

    /// A range marked in the text's own color at `strength` of what it is (a pill's fill is the
    /// text's color at 10%), so the mark follows the surface the text is on.
    private func mark(_ range: NSRange, _ strength: CGFloat, over view: EditingTextView) -> TextHighlight {
        let color = view.typingAttributes[.foregroundColor] as? NSColor ?? .labelColor
        let alpha = color.usingColorSpace(.deviceRGB)?.alphaComponent ?? 1
        return TextHighlight(range: range, fill: color.withAlphaComponent(strength * alpha))
    }
}
