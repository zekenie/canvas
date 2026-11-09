import AppKit
import Canvas
import DetailPanel
import FuzzyMatching
import Keyboard
import SwiftUI

extension PluginID {
    public static let findPanel: PluginID = "find-panel"
}

/// Find's panel in the detail panel's place while Find is open (`DetailTakeovers`): Escape and ⌘.
/// there close Find, before the panel gives the keyboard back to the canvas. A plugin value of its
/// own, after `FindPlugin` and `DetailPanelPlugin`: a list without the panel leaves it out, and
/// keeps Find's state, highlights and commands.
public struct FindPanelPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .findPanel }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.keyHint("↩ or ⇧↩ in Find", "Next or Previous Hit", while: .text)
        registrar.keyHint("↑ or ↓ in Find", "Previous or Next Result", while: .text)
        registrar.keyHint("⌘↩ in Find", "Select Hit and Close", while: .text)
        registrar.detailTakeover(isActive: { $0.find?.isActive ?? false }, onEscape: { $0.find?.close() }) { editor, onExit in
            FindPanel(editor: editor, onExit: onExit)
        }
    }
}

/// Find's panel, for the detail panel's place while Find is open (`FindPanelPlugin`):
/// its own header (the field, with a spinner while the index is built, and Done), the count ("3 of
/// 12", hits) with the buttons that step, and a row per shape with hits, under its board's heading
/// (`editor.boardHeading(of:)`), in order: the kind's symbol, the text around its first hit with each
/// hit there semibold, and its count when it has more than one. A click on a row makes its first hit
/// current, keeping the keyboard in the field, and so do Up, Down, Page Up and Page Down there; ⌘↩
/// closes Find on the current hit's shape, selected (`FindState.finish()`). A row is read as its text,
/// kind, board and hit's number, the current one selected; each step is announced. `onExit` gives the keyboard to the canvas (Done).
/// A shape's symbol is its kind's, in the tint the shape has (`FindState.symbol(of:)`; none: secondary).
public struct FindPanel: View {
    let editor: CanvasEditor
    let onExit: @MainActor () -> Void

    public init(editor: CanvasEditor, onExit: @escaping @MainActor () -> Void) {
        self.editor = editor
        self.onExit = onExit
    }

    public var body: some View {
        if let find = editor.find {
            FindPanelContent(find: find, editor: editor, onExit: onExit)
        }
    }
}

private struct FindPanelContent: View {
    @Bindable var find: FindState
    let editor: CanvasEditor
    let onExit: @MainActor () -> Void
    @FocusState private var focused: Bool
    @State private var handledRequest = 0
    @State private var window = FieldWindow()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
        }
        .background(FieldWindowReader(box: window))
        .onAppear { focusIfAsked() }
        .onChange(of: find.focusRequest) { focusIfAsked() }
        .onChange(of: find.stepCount) { announceStep() }
    }

    /// Whether an input method has marked text in the field.
    private var composing: Bool { (window.window?.firstResponder as? NSTextView)?.hasMarkedText() == true }

    /// VoiceOver hears each step: "Hit 3 of 12, Note, …".
    private func announceStep() {
        guard let text = find.announcement else { return }
        AccessibilityNotification.Announcement(text).post()
    }

    /// The field and Done, the panel's first line (in the window's title bar's row while the panel's sheet runs under one), then
    /// the count and the buttons that step.
    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: FindStyle.fieldSpacing) {
                HStack(spacing: FindStyle.buttonSpacing) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find", text: $find.query)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onKeyPress(.return, phases: [.down, .repeat]) { press in
                            // An input method composing: Return picks its candidate, and isn't a step.
                            if composing { return .ignored }
                            if press.modifiers == .command {
                                // ⌘↩ finishes: the hit's shape selected, Find closed, the keyboard on the canvas.
                                if find.finish() { onExit() }
                                return .handled
                            }
                            find.step(forward: !press.modifiers.contains(.shift))
                            return .handled
                        }
                        .onKeyPress(keys: [.upArrow, .downArrow, .pageUp, .pageDown], phases: [.down, .repeat]) { press in
                            // The composing method moves in its candidates; a modified arrow is the field's (text selection).
                            // An arrow's events carry the keypad flag, which isn't a modifier held.
                            if composing || !press.modifiers.intersection([.shift, .control, .option, .command]).isEmpty { return .ignored }
                            switch press.key {
                            case .upArrow: find.move(by: -1)
                            case .downArrow: find.move(by: 1)
                            case .pageUp: find.move(by: -FindStyle.pageRows)
                            default: find.move(by: FindStyle.pageRows)
                            }
                            return .handled
                        }
                    if find.isIndexing { ProgressView().controlSize(.mini) }
                }
                .padding(.horizontal, FindStyle.fieldSpacing)
                .padding(.vertical, FindStyle.buttonSpacing)
                .background(RoundedRectangle(cornerRadius: FindStyle.rowCorner).fill(FindStyle.fieldFill))
                Button("Done") {
                    find.close()
                    onExit()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tint)
            }
            .detailTitleRow(else: EdgeInsets(top: FindStyle.fieldSpacing, leading: DetailStyle.inset, bottom: FindStyle.fieldSpacing,
                                             trailing: DetailStyle.inset))
            HStack(spacing: FindStyle.buttonSpacing) {
                Text(countText).font(FindStyle.count).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button { find.step(forward: false) } label: { Image(systemName: "chevron.up") }
                    .help(editor.registry.help("Previous", forCommand: .findPrevious))
                    .accessibilityLabel("Previous")
                    .disabled(find.total == 0)
                Button { find.step(forward: true) } label: { Image(systemName: "chevron.down") }
                    .help(editor.registry.help("Next", forCommand: .findNext))
                    .accessibilityLabel("Next")
                    .disabled(find.total == 0)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, DetailStyle.inset)
            .padding(.bottom, FindStyle.fieldSpacing)
        }
        .frame(minHeight: DetailStyle.headerHeight)
    }

    /// "3 of 12": the current hit's number, and the hits in all.
    private var countText: String {
        guard !find.query.isEmpty, find.total > 0 else { return " " }
        return "\(find.currentNumber ?? 0) of \(find.total)"
    }

    @ViewBuilder private var list: some View {
        if find.query.isEmpty {
            Spacer()
        } else if find.results.isEmpty {
            if find.isSettled {
                Text(FindStyle.noMatches).font(FindStyle.noMatchesFont).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
            }
        } else {
            rows
        }
    }

    /// A window of rows around the current one: a lazy list of thousands would still cost each
    /// row's identity on every change.
    private var rows: some View {
        let results = find.results
        let current = find.current?.result ?? 0
        let lower = max(0, min(current - FindStyle.rowWindow / 2, results.count - FindStyle.rowWindow))
        let upper = min(results.count, lower + FindStyle.rowWindow)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: FindStyle.rowSpacing) {
                    if lower > 0 { more(lower) }
                    ForEach(lower..<upper, id: \.self) { i in
                        let result = results[i]
                        if i == lower || results[i - 1].board != result.board { boardHeading(result.board) }
                        FindRow(find: find, editor: editor, result: result, index: i) {
                            find.select(result.id)
                            focused = true
                        }
                        .id(result.id)
                    }
                    if upper < results.count { more(results.count - upper) }
                }
                .padding(.horizontal, FindStyle.fieldSpacing)
                .padding(.vertical, FindStyle.fieldSpacing)
            }
            .onChange(of: find.current) {
                guard let current = find.current, find.results.indices.contains(current.result) else { return }
                proxy.scrollTo(find.results[current.result].id)
            }
        }
    }

    private func more(_ count: Int) -> some View {
        Text("\(count) more").font(FindStyle.tally).foregroundStyle(.secondary).padding(.horizontal, FindStyle.fieldSpacing)
    }

    private func boardHeading(_ board: BoardID) -> some View {
        let named = editor.boardHeading(of: board)
        return HStack(spacing: FindStyle.buttonSpacing) {
            if let symbol = named.systemImage { Image(systemName: symbol).foregroundStyle(.secondary) }
            Text(named.title).font(FindStyle.boardTitle).lineLimit(1)
        }
        .frame(height: FindStyle.headerHeight)
        .padding(.horizontal, FindStyle.fieldSpacing)
    }

    /// The field takes the keyboard, its text selected, for each ⌘F not yet answered.
    ///
    /// A turn later: written in the pass that makes the field (`onAppear`, the panel just shown for Find), under the
    /// panel's stack (a band over it), the request is dropped, the field not yet one SwiftUI's focus knows.
    private func focusIfAsked() {
        guard find.focusRequest != handledRequest else { return }
        handledRequest = find.focusRequest
        DispatchQueue.main.async { focused = true }
        // Once it has the keyboard, what's typed is selected, as a second ⌘F selects it.
        DispatchQueue.main.async { [window] in
            (window.window?.firstResponder as? NSTextView)?.selectAll(nil)
        }
    }
}

/// One shape's row.
private struct FindRow: View {
    let find: FindState
    let editor: CanvasEditor
    let result: FindResult
    let index: Int
    let pick: () -> Void

    var body: some View {
        let isCurrent = find.current?.result == index
        let symbol = find.symbol(of: result.id)
        Button(action: pick) {
            HStack(spacing: FindStyle.fieldSpacing) {
                Image(systemName: symbol.systemImage ?? "square")
                    .foregroundStyle(symbol.tint.map { Color(nsColor: $0) } ?? Color.secondary)
                    .frame(width: FindStyle.rowSymbolWidth)
                // A titled shape's row names it first, the hit's snippet after it, faint (T6: "products  weight_grams int").
                if let name = find.rowName(of: result) {
                    // Two texts, the snippet first in line for room: a long name is cut in its middle, never the hit away.
                    HStack(spacing: FindStyle.nameSpacing) {
                        Text(name).font(FindStyle.rowName).lineLimit(1).truncationMode(.middle)
                        Text(FindSnippet.faint(of: result, in: find)).lineLimit(1).truncationMode(.tail).layoutPriority(1)
                    }
                } else {
                    Text(FindSnippet.attributed(of: result, in: find)).font(FindStyle.snippet).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
                if result.hitCount > 1 {
                    Text(isCurrent ? "\((find.current?.ordinal ?? 0) + 1)/\(result.hitCount)" : "\(result.hitCount)")
                        .font(FindStyle.tally).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, FindStyle.fieldSpacing)
            .frame(maxWidth: .infinity, minHeight: FindStyle.rowHeight, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: FindStyle.rowCorner).fill(isCurrent ? FindStyle.rowSelected : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        // As the rows of the panel's lists: a borderless button's label is otherwise drawn dimmed.
        .foregroundStyle(.primary)
        .focusable(false)
        .accessibilityLabel(find.rowLabel(of: index))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// Which part of a text a row shows around its first hit.
@MainActor
public enum FindSnippet {
    /// The part of `text` (UTF-16 offsets) to show around `first`, a hit: from a word's start a
    /// little before it, `FindStyle.snippetLength` long at most, both ends on composed character
    /// sequences (a surrogate pair, an emoji with its modifiers, a letter with its marks are never
    /// split).
    public static func range(in text: String, around first: Range<Int>) -> Range<Int> {
        let text = text as NSString
        var from = max(0, first.lowerBound - FindStyle.snippetBefore)
        // From a word's start, so the snippet doesn't begin mid-word.
        if from > 0 {
            let space = text.rangeOfCharacter(from: .whitespacesAndNewlines, options: [], range: NSRange(location: from, length: first.lowerBound - from))
            if space.location != NSNotFound { from = NSMaxRange(space) }
        }
        let to = min(text.length, from + FindStyle.snippetLength)
        guard to > from else { return min(from, text.length)..<min(from, text.length) }
        let snapped = text.rangeOfComposedCharacterSequences(for: NSRange(location: from, length: to - from))
        return snapped.location..<NSMaxRange(snapped)
    }
}

extension FindSnippet {
    /// The text around a result's first hit, on one line, every hit in it semibold.
    static func attributed(of result: FindResult, in find: FindState) -> AttributedString {
        let texts = find.texts(of: result.id)
        guard texts.indices.contains(result.first.text) else { return AttributedString() }
        let text = texts[result.first.text] as NSString
        let hits = find.hits(of: result.id)[safe: result.first.text] ?? []
        let shown = range(in: text as String, around: result.first.range)
        let from = shown.lowerBound, to = shown.upperBound
        var snippet = AttributedString(from > 0 ? "…" : "")
        var cursor = from
        for hit in hits where hit.range.upperBound > from && hit.range.lowerBound < to {
            let lower = max(hit.range.lowerBound, cursor), upper = min(hit.range.upperBound, to)
            guard lower < upper else { continue }
            if lower > cursor { snippet += plain(text.substring(with: NSRange(location: cursor, length: lower - cursor))) }
            var bold = plain(text.substring(with: NSRange(location: lower, length: upper - lower)))
            bold.font = FindStyle.snippetHit
            snippet += bold
            cursor = upper
        }
        if cursor < to { snippet += plain(text.substring(with: NSRange(location: cursor, length: to - cursor))) }
        return snippet
    }

    /// A titled shape's row: its name, then the snippet faint, its hits still bold.
    public static func named(_ name: String, of result: FindResult, in find: FindState) -> AttributedString {
        var named = AttributedString(name)
        named.font = FindStyle.rowName
        var gap = AttributedString(FindStyle.nameGap)
        gap.font = FindStyle.snippet
        return named + gap + faint(of: result, in: find)
    }

    /// The snippet after a name: faint, its hits still bold.
    public static func faint(of result: FindResult, in find: FindState) -> AttributedString {
        var snippet = attributed(of: result, in: find)
        for run in snippet.runs where run.font == nil { snippet[run.range].font = FindStyle.snippet }
        snippet.foregroundColor = .secondary
        return snippet
    }

    /// The same, as plain text, for VoiceOver.
    static func text(of result: FindResult, in find: FindState) -> String {
        String(attributed(of: result, in: find).characters)
    }

    private static func plain(_ text: String) -> AttributedString {
        AttributedString(text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\u{FFFC}", with: ""))
    }
}

/// The panel's window, for selecting the field's text once it has the keyboard.
@MainActor
private final class FieldWindow {
    weak var window: NSWindow?
}

private struct FieldWindowReader: NSViewRepresentable {
    let box: FieldWindow
    func makeNSView(context: Context) -> ReaderView { ReaderView(box: box) }
    func updateNSView(_ view: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        let box: FieldWindow
        init(box: FieldWindow) {
            self.box = box
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("not from a nib") }
        override func viewDidMoveToWindow() { if let window { box.window = window } }
    }
}
