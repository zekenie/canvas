import AppKit
import Canvas
import TextEditing

/// Slash commands typed in a text view: the list at a `/` on an empty line, choosing from it, and
/// entering a command line. It belongs to one shape's text (`owner`) and asks `commands` what the
/// shape offers, so the same text view code serves a note on the canvas, a card's description and a
/// box in the panel. The host, an `EditingTextView` subclass that makes one, tells it what's typed
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
/// It writes the text only through the view, as a person's edit (undoable, heard by the host), its
/// list closed first, and ignores its own callbacks while it does. The command runs after the text
/// is written, so a command that makes the shape read-only has its line gone already. Running is the
/// state's: one undo step named for the command; while a shape is being edited that step comes after
/// the editing session's step so far, which has the typing and the line's removal in it.
@MainActor
public final class SlashCommandTyping {
    /// The open list's model.
    public private(set) var picker: SlashCommandPicker?
    /// The window it shows in, while it's open.
    public private(set) var window: CaretListWindow?

    private weak var view: EditingTextView?
    private weak var commands: SlashCommandState?
    private let owner: ShapeID
    private let readArguments: (@MainActor (NSRange) -> SlashArguments)?
    /// The substitutions the list turned off while it's open, to put back as they were.
    private var substitutions: CaretListSubstitutions?
    private var isWriting = false

    /// `arguments` reads what's typed in a range as runs (a mention text view's pills as shapes);
    /// the default reads it as plain text.
    public init(over view: EditingTextView, owner: ShapeID, commands: SlashCommandState,
                arguments: (@MainActor (NSRange) -> SlashArguments)? = nil) {
        self.view = view
        self.owner = owner
        self.commands = commands
        readArguments = arguments
    }

    // MARK: Opening and closing

    /// After the view inserted what a person typed (not what it pasted, nor what an input method is
    /// still composing): a `/` on an empty line opens the list.
    public func didType(_ string: String) {
        guard string == "/", !isWriting, picker == nil, let view, let commands, view.isEditable, view.caretListWindow == nil,
              !view.hasMarkedText(), let storage = view.textStorage else { return }
        let selection = view.selectedRange()
        guard selection.length == 0, selection.location > 0 else { return }
        let location = selection.location - 1
        guard SlashCommandPicker.opens(in: storage.string as NSString, at: location) else { return }
        let offered = commands.commands(for: owner)
        guard !offered.isEmpty else { return }
        open(at: location, offering: offered, over: view)
    }

    /// After the text changed (`isEdit`) or the caret moved alone: reads what's typed after the `/`
    /// again, and closes the list if that's what the change says.
    public func didChange(isEdit: Bool) {
        guard !isWriting else { return }
        read(isEdit: isEdit)
        showCommand()
    }

    /// Closes the list, if it's open: its `/` stays as typed, and nothing opens until another is
    /// typed. The substitutions it turned off come back, and VoiceOver hears the list go.
    public func close() {
        guard picker != nil else { return }
        picker?.list.onChange = nil
        picker = nil
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
        guard let picker, let storage = view?.textStorage, picker.location < storage.length else { return nil }
        return NSRange(location: picker.location, length: 1)
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
              let command = commands.command(named: line.name, for: owner) else { return false }
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
        guard let picker, picker.listed.indices.contains(index) else { return }
        _ = complete(picker.listed[index], replacing: picker.nameRange)
    }

    /// Writes `/` and the command's name in the place of what was typed, and a space if it takes an
    /// argument and no whitespace follows on its line (a line break doesn't count: the argument is
    /// typed on the line, not run into the one below): the caret after, one step of the text's undo.
    private func complete(_ command: OfferedSlashCommand, replacing range: NSRange) -> Bool {
        guard let storage = view?.textStorage, NSMaxRange(range) <= storage.length else { return false }
        close()
        var completed = "/" + command.name
        if command.argument != nil {
            let text = storage.string as NSString
            let next: unichar? = NSMaxRange(range) < text.length ? text.character(at: NSMaxRange(range)) : nil
            let spaceFollows = next.map { SlashCommandLine.isWhitespace($0) && !SlashCommandLine.isLineBreak($0) } ?? false
            if !spaceFollows { completed += " " }
        }
        return write(range, with: completed)
    }

    /// Takes the line out of the text and runs the command. The command is asked of the shape now
    /// and run as found, once the line is gone (what the text removed may change what a shape
    /// offers, which doesn't take the command back); not found or not accepting, nothing is taken
    /// out.
    private func run(_ command: OfferedSlashCommand, with arguments: SlashArguments, removing range: NSRange) -> Bool {
        guard let commands, let current = commands.command(named: command.name, for: owner), current.accepts(arguments) else { return false }
        close()
        guard write(range, with: "") else { return false }
        commands.run(current, on: owner, with: arguments)
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
              let command = commands.command(named: line.name, for: owner) else { return nil }
        return command.shapeRule
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
        let selection = view.selectedRange()
        guard let commands, selection.length == 0,
              let line = SlashCommandLine(in: storage.string as NSString, caret: selection.location),
              let command = commands.command(named: line.name, for: owner) else { return [] }
        var found = [mark(line.nameRange, SlashCommandStyle.commandFill, over: view)]
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
