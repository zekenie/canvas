import AppKit
import Canvas
import Geometry
import Keyboard
import Selection
import TextEditing

extension PluginID {
    public static let slashBar: PluginID = "slash-bar"
}

extension CanvasCommand {
    /// `/` on the canvas: the command bar, under the shapes selected.
    public static let runSlashCommand: CanvasCommand = "runSlashCommand"
}

/// The command bar: `/` on the canvas, with shapes selected and nothing being edited, opens a line under
/// them where a slash command is typed for them (`SlashTarget.selection`) and run on them with Return, so
/// a command reaches every shape, frames, subboards and references too, which have no text to type in,
/// and several at once. Typing in a shape's text keeps its own `/`. A plugin value of its own, so a
/// plugin list that has `SlashCommandsPlugin` for Titles' or Locking's commands needs neither Keyboard
/// nor Selection.
public struct SlashBarPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .slashBar }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { SlashBar(editor: $0) }
        registrar.command(.runSlashCommand, title: SlashBarStyle.commandTitle, shortcut: KeyChord("/"), runs: .whenIdle,
                          isEnabled: { $0.editor.slashBar?.canOpen(on: $0.shapes) ?? false }) { $0.editor.slashBar?.open(on: $0.shapes) }
        // Never acting on shapes it wasn't opened for.
        registrar.selectionChanged { editor, _, _ in editor.slashBar?.close() }
    }
}

/// What the command bar is as a card, to the core.
struct SlashBarCard: Hashable, Sendable {}

// MARK: The field it types in

/// What the bar hears from the field it types in, whichever plugin made it, so a field of another
/// plugin's closes the bar as the bar's own does.
@MainActor
public struct SlashBarFieldEvents {
    /// Escape with no list open (the field's `onExit`): the person closed the bar.
    public let escape: @MainActor () -> Void
    /// The keyboard left the field (its `onLeave`).
    public let left: @MainActor () -> Void
    /// Its text was emptied: the `/` deleted.
    public let emptied: @MainActor () -> Void
    /// What its typing calls before a command runs (`SlashCommandTyping.willRun`): the bar closes.
    public let willRun: @MainActor (_ command: OfferedSlashCommand, _ choice: SlashChoice?) -> Void
}

/// The field the bar types in, as the plugin that gives it made it: a one-line text view, and the slash
/// commands it hosts, typing for the bar's target.
@MainActor
public struct SlashBarField {
    public let view: EditingTextView
    public let typing: SlashCommandTyping

    public init(view: EditingTextView, typing: SlashCommandTyping) {
        self.view = view
        self.typing = typing
    }

    /// The font of a field's text: the bar's own field's.
    public static var font: NSFont { SlashBarStyle.font }

    /// Sets a text view up as the bar's own field is: one line clipped at its end, centered in the bar's
    /// height for `font`, on no ground of its own, its substitutions and spelling off, Tab the host's (with
    /// nothing to complete it does nothing), "Command" to VoiceOver. Keeping what's typed to one line
    /// (Return and line breaks inserting nothing, one pasted a space) is the view's.
    public static func setUp(_ view: EditingTextView) {
        view.drawsBackground = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.maximumNumberOfLines = 1
        view.textContainer?.lineBreakMode = .byClipping
        let line = font.ascender - font.descender + font.leading
        view.textContainerInset = NSSize(width: 0, height: max(0, ((SlashBarStyle.height - line) / 2).rounded(.down)))
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.smartInsertDeleteEnabled = false
        CaretListSubstitutions.off.apply(to: view)
        view.tabBehavior = .host
        view.setAccessibilityLabel(SlashBarStyle.fieldLabel)
    }
}

/// The field the command bar types in, from the one plugin that gives it (Mentions', whose pills are
/// shapes a command can take: `/move-to @Roadmap`); without one, the bar's own, `SlashBarTextView`, which
/// reads what's typed as text and so names no shape. At most one contribution, the report's `slash bar
/// field`.
public enum SlashBarFields {}

extension SlashBarFields: KeyedExtensionPoint {
    public typealias Contribution = SlashBarFieldMaker
    public static var owner: PluginID { .slashBar }
    public static func uniqueKeys(of _: SlashBarFieldMaker, for _: ShapeTarget) -> [AnyHashable] { ["the command bar's field"] }
    public static func summary(of _: SlashBarFieldMaker, for _: ShapeTarget) -> String { "slash bar field" }
}

/// What `SlashBarFields` holds: whether the field can name a shape, and how it's made.
@MainActor
public struct SlashBarFieldMaker {
    let namesShapes: Bool
    let make: @MainActor (CanvasEditor, SlashTarget, SlashBarFieldEvents) -> SlashBarField?
}

extension PluginRegistrar {
    /// The field the command bar types in: made each time the bar opens, for its target, hosting
    /// `SlashCommandTyping` over it and handing what it hears on to `events` (Escape with no list open, the
    /// keyboard leaving, the text emptied, and the typing's `willRun`). `namesShapes`: what's typed in it
    /// can name a shape (a pill), so the commands that take one are listed in the bar. Nil from `make`
    /// leaves the bar its own field.
    public mutating func slashBarField(namesShapes: Bool,
                                       _ make: @escaping @MainActor (CanvasEditor, SlashTarget, SlashBarFieldEvents) -> SlashBarField?) {
        contribute(SlashBarFieldMaker(namesShapes: namesShapes, make: make), to: SlashBarFields.self)
    }
}

/// The command bar (`editor.slashBar`, a service; nil without `SlashBarPlugin`): a core card about no
/// shape's content (`showsZoomedOut`), so it works among skeletons too, hung under the shapes it was
/// opened on, out to their outline, its field typing slash commands for them. It closes as anything
/// else happens: a command run (before it runs, so the canvas has the keyboard), Escape with no list
/// open, ⌘., the `/` deleted, the keyboard leaving its field (a click on the canvas, the panel), the
/// selection changing, and every way a card closes (a press elsewhere, another board, an undo, editing,
/// another card shown). It keeps nothing per shape.
@MainActor
public final class SlashBar {
    private unowned let editor: CanvasEditor
    /// The bar showing, while it does.
    private var shown: Shown?
    /// The field the bar showed last, kept past its closing: a command run from it closes the bar from
    /// inside the field's own key, and runs after.
    private var lastField: SlashBarField?

    private struct Shown {
        let shapes: [ShapeID]
        let field: SlashBarField
    }

    /// The field another plugin gives, if one does (`SlashBarFields`).
    private var maker: SlashBarFieldMaker? { editor.registry.contributions(to: SlashBarFields.self).first?.value }

    init(editor: CanvasEditor) {
        self.editor = editor
    }

    /// Whether the bar shows.
    public var isOpen: Bool { shown != nil }
    /// Its field, while it shows: the bar's own, or the one a plugin gives (`SlashBarFields`).
    public var field: EditingTextView? { shown?.field.view }
    /// The slash commands typed in its field, while it shows.
    public var typing: SlashCommandTyping? { shown?.field.typing }
    /// The shapes it acts on, while it shows.
    public var shapes: [ShapeID] { shown?.shapes ?? [] }
    /// Why it closed last, as its card heard it (`.asked` for its own closing: a command run, Escape).
    public private(set) var lastClosing: CanvasCardClosing?

    /// Whether `/` opens it on these shapes: there are some, and they offer a command its field can give
    /// what it takes (one that takes a shape only with a field that names one).
    public func canOpen(on shapes: [ShapeID]) -> Bool {
        guard !shapes.isEmpty, let commands = editor.slashCommands else { return false }
        let namesShapes = maker?.namesShapes ?? false
        return commands.commands(for: .selection(shapes)).contains { namesShapes || !$0.takesShape }
    }

    /// Opens it under the shapes, brought into view first if they aren't (as a nudge does, so what the key
    /// acts on shows), with a `/` typed in its field, which lists what they offer. In place of another
    /// card, which closes `.replaced`.
    public func open(on shapes: [ShapeID]) {
        guard canOpen(on: shapes), let commands = editor.slashCommands else { return }
        editor.revealIfOffscreen(shapes)
        guard let anchor = anchor(of: shapes) else { return }
        let events = SlashBarFieldEvents(escape: { [weak self] in self?.close() }, left: { [weak self] in self?.close() },
                                         emptied: { [weak self] in self?.close() },
                                         willRun: { [weak self] command, choice in self?.willRun(command, choosing: choice) })
        let target = SlashTarget.selection(shapes)
        let made = maker?.make(editor, target, events)
        // Without the field a plugin gives, the bar's own names no shape: it opens only for what that can type.
        guard made != nil || commands.commands(for: target).contains(where: { !$0.takesShape }) else { return }
        let field = made ?? Self.ownField(for: target, commands: commands, events: events)
        let label = SlashBarStyle.label(for: shapes, in: editor)
        let view = SlashBarView(field: field.view, acting: label)
        let card = CanvasCard(id: SlashBarCard(), anchor: anchor, view: view, firstResponder: field.view, showsZoomedOut: true,
                              accessibilityLabel: SlashBarStyle.accessibilityLabel(for: label),
                              size: { room in CGSize(width: min(SlashBarStyle.width, room.width), height: SlashBarStyle.height) },
                              didClose: { [weak self, weak view = field.view] reason in self?.didClose(view, reason) })
        shown = Shown(shapes: shapes, field: field)
        lastField = field
        guard editor.showCard(card) else {
            shown = nil
            return
        }
        // Typed once the field is in the window (the host puts the card's view there as it's told), so
        // its list has a window to open in.
        field.view.insertText("/", replacementRange: field.view.selectedRange())
    }

    /// The bar's own field: one line that reads what's typed as text, so it names no shape and lists no
    /// command that takes one.
    private static func ownField(for target: SlashTarget, commands: SlashCommandState, events: SlashBarFieldEvents) -> SlashBarField {
        let view = SlashBarTextView(frame: .zero)
        let typing = SlashCommandTyping(over: view, target: target, commands: commands, takesShapes: false)
        typing.willRun = events.willRun
        view.slashCommands = typing
        view.onExit = events.escape
        view.onEmptied = events.emptied
        view.onLeave = events.left
        return SlashBarField(view: view, typing: typing)
    }

    /// Takes the bar down, if it shows: the canvas has the keyboard back, the selection as it was.
    public func close() {
        guard shown != nil else { return }
        if editor.card?.id == AnyHashable(SlashBarCard()) {
            editor.closeCard()
        } else {
            shown = nil
        }
    }

    /// Its card closed, for whatever reason. (Its field gave up the keyboard as the card went, which
    /// asked `close()` first: the bar is down already, and the reason is the card's.)
    private func didClose(_ view: EditingTextView?, _ reason: CanvasCardClosing) {
        guard let view, view === lastField?.view else { return }
        if shown?.field.view === view { shown = nil }
        lastClosing = reason
    }

    /// A command is about to run from the field, its line out of the text: the bar closes first, so it
    /// runs from the canvas as from a key, and VoiceOver hears the step it makes, and on how many shapes
    /// where that's fewer than the bar was opened on.
    private func willRun(_ command: OfferedSlashCommand, choosing choice: SlashChoice?) {
        close()
        let step = choice?.step ?? command.stepName
        let spoken = command.isPartial ? SlashBarStyle.acted(step, on: command.shapes.count, of: command.targetCount) : step
        // Heard once it has run, and only if it changed something: a move refused, or a row that only opens
        // a list (Edit Colors…), commits nothing and says nothing.
        let before = editor.revision
        _ = editor.scheduler.schedule(after: .zero) { [weak editor] in
            guard let editor, editor.revision != before else { return }
            editor.announce(spoken)
        }
    }

    /// The rect it hangs from: the shapes' bounds out to the outline drawn round them (none zoomed out,
    /// where outlines stand off nothing), so it sits clear of the selection's line.
    private func anchor(of shapes: [ShapeID]) -> CGRect? {
        guard let bounds = editor.shapeContext.bounds(of: shapes) else { return nil }
        let zoom = editor.cameraTarget.zoom
        let gap = editor.drawsSkeletons || zoom <= 0 ? 0 : editor.outlineGap / zoom
        return bounds.insetBy(dx: -gap, dy: -gap)
    }
}

extension SlashBar: EditorService {
    /// A commit moved what it acts on (a drag, an agent's draw): it follows, under them as they are now.
    public func documentDidSettle(_ changes: ChangeSet, in editor: CanvasEditor) {
        guard let shown, editor.card?.id == AnyHashable(SlashBarCard()), let anchor = anchor(of: shown.shapes) else { return }
        editor.moveCard(to: anchor)
    }
}

extension CanvasEditor {
    /// The command bar; nil without `SlashBarPlugin`.
    public var slashBar: SlashBar? { service(SlashBar.self) }
}

/// The bar's size and words.
@MainActor
enum SlashBarStyle {
    /// The list's 240 and room for what it acts on.
    static let width: CGFloat = 280
    static let height: CGFloat = 28
    /// Inside its box, either end, and between the field and the label.
    static let inset: CGFloat = 8
    /// The most of the bar what it acts on takes.
    static let labelShare: CGFloat = 0.45
    /// The panel's text.
    static let font = NSFont.systemFont(ofSize: 13)
    static let labelFont = NSFont.systemFont(ofSize: 12)
    /// The command `/` runs, as the Keyboard Shortcuts window lists it.
    static let commandTitle = "Run a Command"
    /// What VoiceOver calls the field.
    static let fieldLabel = "Command"

    /// What it acts on, at its right: one shape as VoiceOver calls it (its title, else its kind), or how many.
    static func label(for shapes: [ShapeID], in editor: CanvasEditor) -> String {
        if shapes.count == 1, let one = editor.accessibleDescription(of: shapes[0]) { return one.name }
        return Self.shapes(shapes.count)
    }

    static func shapes(_ count: Int) -> String { "\(count) shapes" }

    /// What VoiceOver calls the bar: "Command for Groceries", "Command for 5 shapes".
    static func accessibilityLabel(for label: String) -> String { "Command for \(label)" }

    /// What VoiceOver hears once a command ran on fewer shapes than the bar was opened on.
    static func acted(_ step: String, on count: Int, of total: Int) -> String { "\(step), on \(count) of \(total) shapes" }
}
