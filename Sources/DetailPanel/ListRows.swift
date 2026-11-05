import AppKit
import Chrome
import SwiftUI
import TextEditing

/// A checkbox with its title after it, for a `LabeledContent` row's content ("Label [] Title"): a
/// label-hidden toggle beside a `Text` that toggles on a click, so the row reads alike on macOS 14,
/// where the checkbox style puts a toggle's own label in the row's label column, and on 15, where it
/// doesn't.
public struct DetailCheckbox: View {
    let title: String
    @Binding var isOn: Bool

    public init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    public var body: some View {
        HStack(spacing: DetailStyle.smallSpacing) {
            Toggle(title, isOn: $isOn).labelsHidden()
            // A click on the title toggles; to assistive apps it is the toggle's, not a text of its own.
            Text(title)
                .lineLimit(1)
                .contentShape(Rectangle())
                .onTapGesture { isOn.toggle() }
                .accessibilityHidden(true)
        }
    }
}

/// A row for a shape in a panel's list, laid out as the panel's status lines are: the kind's symbol
/// (in `tint`, else secondary) in the status icon's column, then the shape's `name` on one line in the
/// panel's text size, with an optional `detail` at the end of it and up to two `lines` of caption
/// text under it (`place`: when the detail is an address, its steps, folded in the room the row has by `PlaceFold`
/// as every address is, boards semibold, the nearest whole; `detail` stays its plain text; `detailTruncation`: which end of the detail is cut when it doesn't fit, the start by default, for a path,
/// and `.tail` for a value read from its start). A `dimmed` row (a shape that can't be gone to, say) is all dimmed, its secondary
/// text with it. The row is a plain view: wrap it in a `Button` to make it one.
public struct DetailShapeRow: View {
    let symbol: String
    let tint: NSColor?
    let name: String
    let detail: String?
    let detailTruncation: Text.TruncationMode
    let lines: [String]
    let dimmed: Bool
    let place: [PlaceStep]
    @State private var width: CGFloat?

    public init(symbol: String, tint: NSColor? = nil, name: String, detail: String? = nil, detailTruncation: Text.TruncationMode = .head,
                place: [PlaceStep] = [], lines: [String] = [], dimmed: Bool = false) {
        self.place = place
        self.symbol = symbol
        self.tint = tint
        self.name = name
        self.detail = detail
        self.detailTruncation = detailTruncation
        self.lines = Array(lines.prefix(DetailStyle.shapeRowLines))
        self.dimmed = dimmed
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DetailStyle.smallSpacing) {
            Image(systemName: symbol)
                .foregroundStyle(tint.map { Color(nsColor: $0) } ?? Color.secondary)
                .frame(width: DetailStyle.statusIconWidth)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: DetailStyle.pairSpacing) {
                    Text(name).font(DetailStyle.body).lineLimit(1)
                    if !place.isEmpty {
                        Spacer(minLength: 0)
                        DetailPlaceText(steps: place, room: placeRoom).fixedSize(horizontal: true, vertical: false)
                    } else if let detail {
                        Spacer(minLength: 0)
                        // A path is told by the container its shape is in, which is last: cut at the start.
                        Text(detail).font(DetailStyle.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(detailTruncation)
                    }
                }
                ForEach(lines.indices, id: \.self) { i in
                    Text(lines[i]).font(DetailStyle.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if !place.isEmpty {
                    GeometryReader { geometry in Color.clear.preference(key: DetailRowWidthKey.self, value: geometry.size.width) }
                }
            }
        }
        .onPreferenceChange(DetailRowWidthKey.self) { if place.isEmpty == false, width != $0 { width = $0 } }
        .frame(minHeight: DetailStyle.listRowHeight, alignment: .top)
        .opacity(dimmed ? DetailStyle.dimmedRow : 1)
        .contentShape(Rectangle())
    }

    /// What the place may take of the row: what the name leaves, but at least `DetailStyle.placeShare` of it; all of it
    /// until the row's width is read.
    private var placeRoom: CGFloat {
        guard let width else { return .infinity }
        let named = ceil(NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: DetailStyle.bodySize)]).size().width)
        return max(width - named - DetailStyle.pairSpacing, width * DetailStyle.placeShare)
    }
}

/// The width a row's text column was given.
private struct DetailRowWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// A place's steps as one line of text in `room` points, folded as every address is (`PlaceFold`): boards semibold,
/// an untitled container's name and the marks between fainter, in the panel's caption.
public struct DetailPlaceText: View {
    let steps: [PlaceStep]
    let lead: String
    let room: CGFloat
    let size: CGFloat
    let wraps: Bool

    /// `wraps`: the whole place in as many lines as it takes, in the panel's caption (the Reference tab's).
    public init(steps: [PlaceStep], lead: String = "", room: CGFloat = .infinity, size: CGFloat? = nil, wraps: Bool = false) {
        self.steps = steps
        self.lead = lead
        self.room = room
        self.size = size ?? DetailStyle.captionSize
        self.wraps = wraps
    }

    /// The steps folded in `room`, less the lead, in the font of `size`.
    public static func line(_ steps: [PlaceStep], lead: String = "", room: CGFloat, size: CGFloat? = nil) -> PlaceLine {
        let size = size ?? DetailStyle.captionSize
        let measure: (String, Bool) -> CGFloat = { text, isBoard in
            ceil(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: isBoard ? .semibold : .regular)]).size().width)
        }
        return PlaceFold.line(for: steps, room: room - measure(lead, false), measure: measure)
    }

    public var body: some View {
        let line = Self.line(steps, lead: lead, room: room, size: size)
        line.pieces.reduce(Text(lead).foregroundStyle(.secondary)) { text, piece in
            switch piece.kind {
            case .separator, .ellipsis:
                text + Text(piece.text).foregroundStyle(.tertiary)
            case .step(_, let opensBoard, let isPlaceholder):
                text + Text(piece.text).fontWeight(opensBoard ? .semibold : .regular)
                    .foregroundStyle(isPlaceholder ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            }
        }
        .font(.system(size: size)).lineLimit(wraps ? nil : 1).fixedSize(horizontal: false, vertical: wraps)
    }
}

/// The head of a list of rows inside a section, which folds it: a disclosure triangle and the title,
/// set as a section's are, with a dot in `tint` between them when the list has a color of its own,
/// and how many rows the list has after it. The caller keeps whether it's folded, and leaves the
/// rows out while it is.
public struct DetailGroupHeader: View {
    let title: String
    let count: Int?
    let tint: NSColor?
    let isCollapsed: Bool
    let isRow: Bool
    let toggle: @MainActor () -> Void

    /// `isRow`: the head is a row of a `DetailRowList`, which folds it with its keys and takes its
    /// clicks and its accessibility itself, so it is no button of its own.
    public init(_ title: String, count: Int? = nil, tint: NSColor? = nil, isCollapsed: Bool, isRow: Bool = false,
                toggle: @escaping @MainActor () -> Void) {
        self.title = title
        self.count = count
        self.tint = tint
        self.isCollapsed = isCollapsed
        self.isRow = isRow
        self.toggle = toggle
    }

    public var body: some View {
        if isRow {
            label
        } else {
            Button(action: toggle) { label }
                .buttonStyle(.borderless)
                .foregroundStyle(.primary)
                .accessibilityLabel(title)
                .accessibilityValue(Self.spoken(count: count, isCollapsed: isCollapsed))
        }
    }

    /// What assistive apps hear of the head besides its title: how many rows it has, and whether
    /// they are shown.
    public static func spoken(count: Int?, isCollapsed: Bool) -> String {
        [count.map { "\($0)" }, isCollapsed ? DetailStyle.collapsed : DetailStyle.expanded].compactMap { $0 }.joined(separator: ", ")
    }

    private var label: some View {
        HStack(spacing: DetailStyle.smallSpacing) {
            Image(systemName: "chevron.right")
                .font(DetailStyle.disclosure)
                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
            if let tint {
                Circle().fill(Color(nsColor: tint)).frame(width: DetailStyle.groupDot, height: DetailStyle.groupDot)
            }
            Text(title).font(DetailStyle.sectionTitle).lineLimit(1)
            if let count {
                Text("\(count)").font(DetailStyle.body).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(height: DetailStyle.sectionHeaderHeight)
        .contentShape(Rectangle())
    }
}

/// A field that searches a list in the panel: a magnifying glass, the text, typed as keyed (nothing
/// corrected), and, once there's text, a button that clears it. Escape clears the text first (it is a
/// draft, as a number being typed is), and, with none, gives the keyboard back to the canvas as
/// anywhere in the panel; ↓ goes into the list
/// (`list`, the handle the `DetailRowList` under it was given).
public struct DetailSearchField: View {
    let prompt: String
    @Binding var text: String
    let list: DetailListHandle?
    @FocusState private var isFocused: Bool
    @State private var owner = UUID()
    @Environment(\.detailDrafts) private var drafts

    public init(_ prompt: String, text: Binding<String>, list: DetailListHandle? = nil) {
        self.prompt = prompt
        _text = text
        self.list = list
    }

    public var body: some View {
        HStack(spacing: DetailStyle.smallSpacing) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .accessibilityLabel(prompt)
                .focused($isFocused)
                .onChange(of: text) { holdsDraft() }
                .onChange(of: isFocused) { holdsDraft() }
                .onDisappear { drafts?.release(owner) }
                .onKeyPress(.downArrow) {
                    guard let list else { return .ignored }
                    list.enter()
                    return .handled
                }
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, DetailStyle.textInset)
        .frame(height: DetailStyle.listRowHeight)
        .background(RoundedRectangle(cornerRadius: DetailStyle.fieldCorner).fill(DetailStyle.searchFill))
    }

    /// While the field has the keyboard and text, Escape clears the text rather than leaving the panel.
    private func holdsDraft() {
        guard let drafts else { return }
        if isFocused, !text.isEmpty {
            drafts.hold(owner, shown: "") { text = "" }
        } else {
            drafts.release(owner)
        }
    }
}

// MARK: Lists of rows

/// One line of a `DetailRowList`: a row, or the head of a group of rows that folds them. `parent` is
/// the head a row is under, which ← goes up to. `activate` is what Return, Space and a click do (a head:
/// fold or unfold), unless `click` says what a click does.
public struct DetailRowItem<ID: Hashable & Sendable>: Identifiable {
    public enum Kind: Equatable, Sendable {
        case row
        case head(isFolded: Bool)
    }

    public let id: ID
    public var kind: Kind
    public var parent: ID?
    /// How tall: `DetailRowItem.height(captionLines:)`, or a head's.
    public var height: CGFloat
    public var activate: @MainActor () -> Void
    /// What a click on the line does instead of `activate`, when it is not the same as Return and Space: a list whose
    /// highlight is the place of a walk moves the walk on a click and closes on Return. Nil: a click activates.
    public var click: (@MainActor () -> Void)?

    @MainActor public init(id: ID, kind: Kind = .row, parent: ID? = nil, height: CGFloat? = nil,
                activate: @escaping @MainActor () -> Void) {
        self.id = id
        self.kind = kind
        self.parent = parent
        self.height = height ?? (kind == .row ? DetailStyle.listRowHeight : DetailStyle.sectionHeaderHeight)
        self.activate = activate
    }

    /// A row of a shape (`DetailShapeRow`) with `captionLines` of caption under its name.
    @MainActor public static func height(captionLines: Int) -> CGFloat {
        DetailStyle.listRowHeight + CGFloat(min(captionLines, DetailStyle.shapeRowLines)) * DetailStyle.captionLine
    }
}

/// What a `DetailRowList` is given to hand the keyboard to it by code: the search field above it, whose ↓
/// goes in.
@MainActor
public final class DetailListHandle {
    fileprivate weak var anchor: NSView?
    fileprivate var onEnter: (@MainActor () -> Void)?
    fileprivate var label = ""

    public init() {}

    /// The keyboard goes to the list, on its highlighted row, else its first. Whether it did: false while the list
    /// has no table in a window yet (a list just made), so a caller that enters as the list appears asks again.
    @discardableResult
    public func enter() -> Bool {
        onEnter?()
        guard let table = table(), let window = table.window else { return false }
        return window.makeFirstResponder(table)
    }

    /// The list's table is named for assistive apps (a `List` hands its label to the container, not the table).
    fileprivate func nameTable() {
        guard !label.isEmpty, let table = table(), table.accessibilityLabel() != label else { return }
        table.setAccessibilityLabel(label)
    }

    fileprivate var currentTable: NSTableView? { table() }

    /// The list's table: the one under the anchor view, in the window's place.
    private func table() -> NSTableView? {
        guard let anchor, anchor.window != nil else { return nil }
        let place = anchor.convert(anchor.bounds, to: nil)
        var view: NSView? = anchor
        while let current = view {
            if let found = Self.table(in: current, containing: CGPoint(x: place.midX, y: place.midY)) { return found }
            view = current.superview
        }
        return nil
    }

    private static func table(in view: NSView, containing point: CGPoint) -> NSTableView? {
        if let table = view as? NSTableView, table.convert(table.bounds, to: nil).contains(point) { return table }
        for subview in view.subviews { if let found = table(in: subview, containing: point) { return found } }
        return nil
    }
}

/// A list of rows in the panel that is one stop of Tab: ↑ ↓ Home End Page Up and Page Down move its
/// highlight (built on `List(selection:)`), Return and Space run the
/// highlighted row's `activate`, ← and → fold the head the highlight is on (← on a row goes up to its
/// head), and a click on a row highlights it and runs it. Tab goes on out of it, ⇧Tab back, Escape out of
/// the panel. `onHighlight` hears the highlighted row (nil for none) while the list has the keyboard,
/// and nil as it leaves, so a list can light what the row stands for as the pointer on the row does.
/// `label` is what assistive apps call the list.
///
/// `highlight`, given, is the highlight, kept by the caller: the list reads it and writes the row a key
/// or a click lands on, and never writes nil, as the keyboard leaves it or the row it is on folds away
/// (it stays, a row of no list for now), so it is the caller's place in the list whether or not the list
/// has the keyboard, and the caller moves it by writing it (the list scrolls to the row, also when the row appears later,
/// as its head unfolds). Without it the list keeps its own, which it clears as its row goes.
///
/// `pages`, given, takes Page Up and Page Down: it is asked for the row to go to (true: Page Down, the
/// next), and the highlight goes there; nil from it leaves the highlight where it is, the key taken
/// all the same. Without it they are the table's own, a screenful.
///
/// Rows are `item.height` tall; the list is as tall as its rows, and no taller than the panel less 96 points, or, with
/// `maxHeightShare`, than that share of the panel's height (a list that leaves room under it for more). `row`
/// draws the row's content, which says how assistive apps read it (`detailRowAccessibility`).
public struct DetailRowList<ID: Hashable & Sendable, Row: View>: View {
    let items: [DetailRowItem<ID>]
    let label: String
    let handle: DetailListHandle?
    let highlight: Binding<ID?>?
    let pages: ((Bool) -> ID?)?
    let maxHeightShare: CGFloat?
    let onHighlight: @MainActor (ID?) -> Void
    let row: (DetailRowItem<ID>) -> Row
    @State private var ownHighlight: ID?
    @State private var ownHandle = DetailListHandle()
    @FocusState private var hasKeyboard: Bool

    public init(_ items: [DetailRowItem<ID>], label: String, handle: DetailListHandle? = nil, highlight: Binding<ID?>? = nil,
                pages: ((Bool) -> ID?)? = nil, maxHeightShare: CGFloat? = nil, onHighlight: @escaping @MainActor (ID?) -> Void = { _ in },
                @ViewBuilder row: @escaping (DetailRowItem<ID>) -> Row) {
        self.items = items
        self.label = label
        self.handle = handle
        self.highlight = highlight
        self.pages = pages
        self.maxHeightShare = maxHeightShare
        self.onHighlight = onHighlight
        self.row = row
    }

    /// The highlighted row: the caller's, which the list never clears, else its own.
    private var highlighted: ID? {
        get { highlight?.wrappedValue ?? ownHighlight }
        nonmutating set {
            if let highlight {
                if let newValue { highlight.wrappedValue = newValue }
            } else {
                ownHighlight = newValue
            }
        }
    }

    /// What the table selects: `highlighted`, read and written (a caller's is never written nil).
    private var selection: Binding<ID?> { Binding(get: { highlighted }, set: { highlighted = $0 }) }

    public var body: some View {
        let fitted = items.reduce(DetailStyle.rowListChrome) { $0 + $1.height }
        ScrollViewReader { proxy in
            List(selection: selection) {
                ForEach(items) { item in rowButton(item) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, DetailStyle.sectionHeaderHeight)
            .focused($hasKeyboard)
            .accessibilityLabel(label)
            .onKeyPress(phases: [.down, .repeat]) { press in key(press, proxy: proxy) }
            .onChange(of: highlighted) { _, now in
                if hasKeyboard { onHighlight(now) }
            }
            .onChange(of: hasKeyboard) { _, has in keyboardMoved(has) }
            .onChange(of: items.map(\.id)) { old, ids in
                rowsChanged(ids)
                // The caller's highlight is on a row that has just appeared (its head unfolded): in view.
                if let now = highlight?.wrappedValue, ids.contains(now), !old.contains(now) { proxy.scrollTo(now) }
            }
            // Moved from outside, by a walk's key while the list has the keyboard too: the row comes into
            // view (a no-op for one that is, so the keys' own moves, which scroll, cost nothing).
            .onChange(of: highlight?.wrappedValue) { _, now in
                if let now { proxy.scrollTo(now) }
            }
            .onDisappear { onHighlight(nil) }
            .background(ListAnchor(handle: handle ?? ownHandle, label: label, takesPages: pages != nil, enter: { enter(proxy: proxy) }) { code in move(code, proxy: proxy) })
        }
        .containerRelativeFrame(.vertical, alignment: .top) { visible, _ in
            let room = maxHeightShare.map { visible * $0 } ?? visible - DetailStyle.rowListMargin
            return min(fitted, max(DetailStyle.rowListMinHeight, room))
        }
    }

    /// A click is a button's, as it is in any list of the panel; the keys are the list's.
    private func rowButton(_ item: DetailRowItem<ID>) -> some View {
        Button {
            highlighted = item.id
            (item.click ?? item.activate)()
        } label: {
            row(item)
                .frame(height: item.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .focusable(false)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .tag(item.id)
    }

    /// Entering the list highlights its first row, unless the highlight is on one of them.
    private func keyboardMoved(_ has: Bool) {
        if has, !items.contains(where: { $0.id == highlighted }), let first = items.first { highlighted = first.id }
        onHighlight(has ? highlighted : nil)
    }

    /// A list's own highlight goes with its row; a caller's stays where it is put.
    private func rowsChanged(_ ids: [ID]) {
        if highlight == nil, let highlighted, !ids.contains(highlighted) { self.highlighted = nil }
    }

    /// The keyboard comes into the list (↓ in the search field above, `DetailListHandle.enter()`): the highlight is where it was,
    /// else on the first row, and the table shows it. A list that opens on a highlight far down scrolls nowhere by itself.
    private func enter(proxy: ScrollViewProxy) {
        if highlighted == nil || !items.contains(where: { $0.id == highlighted }) { highlighted = items.first?.id }
        if let now = highlighted { proxy.scrollTo(now) }
    }

    /// Return and Space run the highlighted row (the table leaves them to SwiftUI).
    private func key(_ press: KeyPress, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard KeyMeaning.Modifiers(press.modifiers).isEmpty, press.key == .return || press.key == .space,
              let current = items.first(where: { $0.id == highlighted }) else { return .ignored }
        if press.phase == .down { current.activate() }
        return .handled
    }

    /// Home, End, Page Up and Page Down (when `pages` is given), ← and → by their key codes: the table takes those itself (it scrolls, and opens and
    /// closes the rows it knows), so they come by the key equivalents, which the window offers its views first.
    private func move(_ code: UInt16, proxy: ScrollViewProxy) -> Bool {
        switch code {
        case 115: return go(items.first, proxy) == .handled
        case 119: return go(items.last, proxy) == .handled
        case 116, 121:
            guard let pages else { return false }
            _ = go(pages(code == 121).flatMap { id in items.first { $0.id == id } }, proxy)
            return true
        case 123:
            guard let current = items.first(where: { $0.id == highlighted }) else { return false }
            if case .head(let isFolded) = current.kind {
                if !isFolded { current.activate() }
            } else if let parent = current.parent {
                return go(items.first { $0.id == parent }, proxy) == .handled
            }
            return true
        case 124:
            guard let current = items.first(where: { $0.id == highlighted }) else { return false }
            if case .head(let isFolded) = current.kind, isFolded { current.activate() }
            return true
        default: return false
        }
    }

    private func go(_ item: DetailRowItem<ID>?, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        guard let item else { return .ignored }
        highlighted = item.id
        proxy.scrollTo(item.id)
        return .handled
    }
}

extension View {
    /// A row of a `DetailRowList` as assistive apps read it: one element, said by `label` (a shape's
    /// name, the board it is on, its caption; a head's title) and `value` (a head's count and whether it
    /// is folded), which pressing runs `activate` for.
    public func detailRowAccessibility(label: String, value: String = "", activate: @escaping @MainActor () -> Void) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(value)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { activate() }
    }
}

/// Tells a `DetailListHandle` where its list is, how to put the highlight where ↓ enters, and what to
/// call its table.
private struct ListAnchor: NSViewRepresentable {
    let handle: DetailListHandle
    let label: String
    let takesPages: Bool
    let enter: @MainActor () -> Void
    let move: @MainActor (UInt16) -> Bool

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ view: Anchor, context: Context) {
        view.move = move
        view.takesPages = takesPages
        handle.anchor = view
        handle.label = label
        handle.onEnter = enter
        view.handle = handle
        handle.nameTable()
    }

    /// Names the table as the list lays out, which is when it has one.
    final class Anchor: NSView {
        weak var handle: DetailListHandle?
        var move: (@MainActor (UInt16) -> Bool)?
        /// Page Up and Page Down are the list's too, rather than the table's, where it has pages of its own.
        var takesPages = false

        /// Home, End, ← and → (and Page Up and Page Down, if `takesPages`) with the list's table having the keyboard are the list's, and ⌘↓, ⌘↑ and ⌥Tab do nothing.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let held = event.modifierFlags.intersection([.command, .shift, .option, .control])
            // ⌘↓ and ⌘↑ (into a thing's content, out to its container) and ⌥Tab and ⌥⇧Tab (into a thing's drawn parts) mean nothing
            // to a list, whose rows hold neither: the table would take the first two as ↓ and ↑ and the loop the others as Tab (P6).
            let inertKeys: [UInt16] = held == .command ? [125, 126] : held == .option || held == [.option, .shift] ? [48] : []
            if inertKeys.contains(event.keyCode), let table = window?.firstResponder as? NSTableView, table === handle?.currentTable { return true }
            let plain = held.isEmpty
            let keys: [UInt16] = takesPages ? [115, 119, 123, 124, 116, 121] : [115, 119, 123, 124]
            guard plain, keys.contains(event.keyCode), let table = window?.firstResponder as? NSTableView,
                  table === handle?.currentTable, MainActor.assumeIsolated({ move?(event.keyCode) }) == true else {
                return super.performKeyEquivalent(with: event)
            }
            return true
        }

        override func layout() {
            super.layout()
            handle?.nameTable()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            handle?.nameTable()
        }
    }
}
