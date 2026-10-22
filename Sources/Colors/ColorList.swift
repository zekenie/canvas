import AppKit
import Canvas
import Observation
import Palette
import SwiftUI
import TextEditing

/// Edit Colors…: the file's own colors as a list the keys drive. A row is renamed with Return, removed with
/// Delete and given another value by its Change… button (the system color panel), each written as the grid's
/// choices are, through `ColorRowModel.apply`. Headless: the view only shows it and calls it.
@MainActor
@Observable
public final class ColorListModel {
    /// The file's book; nil once the file is closed (the list is closed with it).
    public private(set) weak var book: ColorBook?
    /// The file's own colors, in the order added.
    public private(set) var colors: [NamedColor] = []
    /// The row the keys act on, by its name.
    public var selected: String?
    /// The row being renamed, and the name typed so far.
    public private(set) var renaming: String?
    public var draft = ""
    @ObservationIgnored private var subscription: ColorBook.Subscription?

    public init(book: ColorBook) {
        self.book = book
        refresh()
        selected = colors.first?.name
        subscription = book.subscribe { [weak self] in self?.refresh() }
    }

    /// Writes through the book's row model, as the grid's choices are; nothing once the file is gone.
    private func apply(_ choice: ColorChoice, openPanel: ((NSColor?, @escaping (NSColor) -> Void) -> Void)? = nil) {
        guard let book else { return }
        ColorRowModel(book: book).apply(choice, to: .constant(nil), openPanel: openPanel)
    }

    /// Reads the file's colors again, keeping the selection where its row still is.
    private func refresh() {
        colors = (book?.fileColors ?? []).filter { !$0.isBuiltIn }
        if let selected, !colors.contains(where: { $0.name == selected }) { self.selected = nil }
        if let renaming, !colors.contains(where: { $0.name == renaming }) { self.renaming = nil }
    }

    private var current: NamedColor? { colors.first { $0.name == selected } }

    /// Up (-1) or down (+1) a row, staying at the ends; the first row when none is selected.
    public func move(by step: Int) {
        guard !colors.isEmpty else { return }
        guard let selected, let index = colors.firstIndex(where: { $0.name == selected }) else { return self.selected = colors.first?.name }
        self.selected = colors[min(max(index + step, 0), colors.count - 1)].name
    }

    /// Return: the selected row's name becomes a field.
    public func beginRename() {
        guard let current else { return }
        renaming = current.name
        draft = current.name
    }

    /// Why the typed name can't be given, nil when it can.
    public var refusal: ColorNameRefusal? {
        guard let book, let renaming, let named = colors.first(where: { $0.name == renaming }) else { return nil }
        return ColorRowModel(book: book).refusal(ofName: draft, renaming: named)
    }

    /// Return in the field: gives the name, if it can be given; leaves the field either way a name that
    /// is the old one unchanged.
    public func commitRename() {
        guard let renaming, let named = colors.first(where: { $0.name == renaming }) else { return }
        if draft == named.name { self.renaming = nil; return }
        guard refusal == nil else { return }
        apply(.rename(named, to: draft))
        selected = ShapeColor.folded(draft)
        self.renaming = nil
    }

    /// A key the list answers, as the panel hears it: Up and Down walk the rows, Return renames, Delete
    /// removes, Escape drops a name being typed (and is not taken otherwise: the panel closes). While a name
    /// is typed Return gives it and every other key is the field's. A key held down acts once: its repeats
    /// are taken and do nothing for Return and Delete, which would otherwise go on removing rows. Whether the
    /// key was taken.
    public func key(_ reading: KeyMeaning.Reading, isRepeat: Bool = false) -> Bool {
        guard reading.modifiers.isEmpty else { return false }
        if isRepeat, reading.meaning == .activate || reading.meaning == .delete { return true }
        if renaming != nil {
            switch reading.meaning {
            case .activate: commitRename(); return true
            case .back: cancelRename(); return true
            default: return false
            }
        }
        switch reading.meaning {
        case .up: move(by: -1)
        case .down: move(by: 1)
        case .activate: beginRename()
        case .delete: removeSelected()
        default: return false
        }
        return true
    }

    /// Escape in the field: back to the list, the name as it was.
    public func cancelRename() { renaming = nil }

    /// Delete: the selected color is taken out of the file ("Remove Color"), and the keys stay on the row
    /// that took its place.
    public func removeSelected() {
        guard let named = current, let index = colors.firstIndex(of: named) else { return }
        apply(.remove(named))
        // Refused (a locked shape holds the color): the row is still there, and the keys stay on it.
        if book?.fileColors.contains(where: { $0.name == named.name }) == true { return }
        let left = colors.filter { $0.name != named.name }
        selected = left.isEmpty ? nil : left[min(index, left.count - 1)].name
    }

    /// The Change… button: the system color panel, its colors written to the selected row's value.
    public func change(_ named: NamedColor, openPanel: ((NSColor?, @escaping (NSColor) -> Void) -> Void)? = nil) {
        selected = named.name
        apply(.changeValue(named), openPanel: openPanel)
    }
}

/// The list: a row a color, its dot, name and Change… button. Its keys are the panel's (`ColorListPanel`),
/// which hears them before any view does, so they work with or without Keyboard navigation.
struct ColorListView: View {
    @Bindable var model: ColorListModel
    @FocusState private var nameFocused: Bool

    var body: some View {
        Group {
            if model.colors.isEmpty {
                Text(ColorsStyle.noFileColors).font(ColorsStyle.font).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selected) {
                    ForEach(model.colors, id: \.name) { named in
                        HStack(spacing: ColorsStyle.rowSpacing) {
                            Circle().fill(Color(nsColor: NSColor(named.value)))
                                .overlay(Circle().strokeBorder(.primary.opacity(ColorsStyle.dotHairline)))
                                .frame(width: ColorsStyle.dot, height: ColorsStyle.dot)
                            if model.renaming == named.name {
                                TextField(ColorsStyle.namePlaceholder, text: $model.draft)
                                    .textFieldStyle(.roundedBorder)
                                    .font(ColorsStyle.font)
                                    .focused($nameFocused)
                                    .onAppear { nameFocused = true }
                            } else {
                                Text(named.title).font(ColorsStyle.font).lineLimit(1)
                            }
                            Spacer(minLength: ColorsStyle.rowGap)
                            Button(ColorsStyle.changeColorItem) { model.change(named) }
                                .font(ColorsStyle.font)
                        }
                        .tag(named.name)
                        .frame(minHeight: ColorsStyle.rowHeight)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(named.title)
                    }
                }
            }
        }
        .frame(width: ColorsStyle.listWidth, height: ColorsStyle.listHeight)
    }
}

/// The window Edit Colors… opens: a small utility panel with the list, one a file's editor. Escape closes it,
/// and so does its file closing.
@MainActor
public final class ColorListPanel: NSPanel {
    /// The list shown last, if any is open.
    public private(set) static var current: ColorListPanel?
    /// Every list that is open, one a file.
    private static var open: [ColorListPanel] = []
    /// Whether opening it puts it on screen: a test turns it off, so nothing flashes.
    public static var ordersFront = true

    /// Opens the list of `editor`'s file colors (or brings it forward), and gives it the keyboard. Another
    /// file's list is left as it is.
    @discardableResult
    public static func show(for editor: CanvasEditor) -> ColorListPanel? {
        guard let book = editor.colors else { return nil }
        if let shown = open.first(where: { $0.book === book }) {
            current = shown
            if ordersFront { shown.makeKeyAndOrderFront(nil) }
            return shown
        }
        let panel = ColorListPanel(book: book)
        open.append(panel)
        current = panel
        panel.center()
        if ordersFront { panel.makeKeyAndOrderFront(nil) }
        return panel
    }

    /// The file's book, nil once it has closed.
    public private(set) weak var book: ColorBook?
    public let model: ColorListModel
    /// Closes the list when its file goes: the book goes with the document, and its editor with it.
    private var release: ColorBook.Subscription?

    private init(book: ColorBook) {
        self.book = book
        model = ColorListModel(book: book)
        super.init(contentRect: CGRect(x: 0, y: 0, width: ColorsStyle.listWidth, height: ColorsStyle.listHeight),
                   styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        title = ColorsStyle.colorsTitle
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        let hosting = NSHostingView(rootView: ColorListView(model: model))
        contentView = hosting
        setContentSize(hosting.fittingSize)
        release = book.onRelease { [weak self] in self?.close() }
    }

    public override var canBecomeKey: Bool { true }

    public override func cancelOperation(_ sender: Any?) { close() }

    /// Whether an input method has marked text in the name being typed: its Return picks a candidate and
    /// its Escape drops the composition, neither is the list's.
    private var composing: Bool { (firstResponder as? NSTextView)?.hasMarkedText() == true }

    /// The keys of the list (`ColorListModel.key`) are heard here, before the first responder: the
    /// keyboard is on the list whichever view has it, and Escape, which it does not take, closes.
    public override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, !composing, let reading = KeyMeaning.Reading(event: event) {
            if model.key(reading, isRepeat: event.isARepeat) { return }
            if reading.meaning == .back, reading.modifiers.isEmpty { return close() }
        }
        super.sendEvent(event)
    }

    public override func close() {
        Self.open.removeAll { $0 === self }
        if Self.current === self { Self.current = Self.open.last }
        super.close()
    }
}
