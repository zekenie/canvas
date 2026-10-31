import AppKit
import Canvas
import Keyboard
import Selection
import SwiftUI
import TextEditing

/// The panel. The window places it (in `.inspector`, the host's slot for one); it follows the editor's
/// selection by itself. `onExit` gives the keyboard back to the canvas: the panel calls it on
/// Escape and ⌘., when it has just removed the control that had the keyboard, and when it's hidden
/// with that control in it (an `.inspector` hides its content without removing it). The keyboard
/// would otherwise land on the window itself, and tool shortcuts would stop.
///
/// With several shapes selected it shows their header; while a takeover a plugin gave is active
/// (`DetailTakeovers`), that in place of everything. It reads the takeovers from the editor's
/// registry, and makes their views as it's made. With nothing selected the window hides it
/// (`DetailPanelPlugin`'s `shownWhile`).
public struct DetailPanelView: View {
    let editor: CanvasEditor
    let onExit: @MainActor () -> Void
    let takeovers: [PlacedTakeover]
    @State private var window = WindowBox()
    @State private var drafts = DraftTracker()

    public init(editor: CanvasEditor, onExit: @escaping @MainActor () -> Void = {}) {
        self.editor = editor
        self.onExit = onExit
        takeovers = editor.registry.detailTakeovers.map { PlacedTakeover(takeover: $0, content: $0.content(editor, onExit)) }
    }

    /// The takeover that shows: the first that's active, in plugin order. Read in the body, so the
    /// panel redraws as what each `isActive` reads changes.
    private var activeTakeover: PlacedTakeover? { takeovers.first { $0.takeover.isActive(editor) } }

    public var body: some View {
        Group {
            if let takeover = activeTakeover {
                takeover.content
            } else if let state = editor.detailPanel {
                let ids = editor.selectedShapeIDs
                if ids.count > 1 {
                    SelectionSummary(header: state.selectionSummary(of: ids.compactMap { editor.document[$0] }), editor: editor)
                } else if let id = editor.selection, let record = editor.document[id] {
                    // Status lines and `shownWhile` read services, and whether the shape can change
                    // reads the containers it's in (a locked frame's shapes are locked too: O(its
                    // depth)) and its board (a locked subboard's), so they're read here, on every
                    // commit: the panel below draws again only when they, or its shape, change.
                    ShapePanel(state: state, editor: editor, record: record, isReadOnly: editor.isReadOnly(id),
                               statuses: state.statuses(of: record), hidden: state.hiddenSections(of: record), contentChanged: reclaimSoon, place: window)
                        .equatable()
                        .id(id)
                } else {
                    Placeholder(text: "No Selection")
                }
            } else {
                Placeholder(text: "No Details")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WindowReader(box: window, onHide: reclaimSoon))
        .controlSize(.small)
        .font(DetailStyle.body)
        .labeledContentStyle(DetailRowStyle())
        .toggleStyle(DetailCheckboxStyle())
        .environment(\.detailDrafts, drafts)
        .environment(\.detailExit, onExit)
        .environment(\.detailReclaim, reclaimSoon)
        .environment(\.detailEditor, editor)
        // So a number being typed lands on its shape before another board is shown.
        .onAppear {
            editor.detailPanel?.drafts = drafts
            // Weak: the state is the editor's, and the editor would never go.
            editor.detailPanel?.focusesFirstControl = { [window, weak editor] in
                guard let scheduler = editor?.scheduler else { return }
                window.focusFirstControl(excluding: window.controls(), retries: DetailStyle.focusRetries, scheduler: scheduler)
            }
            // Where the keyboard enters the panel: the header's field.
            editor.detailPanel?.keyboardEntry = { [window] in window.entry() }
            closeRingSoon()
        }
        .onKeyPress(.escape, phases: [.down, .repeat]) { press in
            exitByKey(withOption: press.modifiers.contains(.option)) ? .handled : .ignored
        }
        // ⌘., which the window sends up the responder chain as `cancelOperation:` with no key
        // down: the panel's text views and fields leave it to their superviews.
        .onExitCommand { _ = exitByKey(withOption: false) }
        .onChange(of: editor.selectedShapeIDs) { reclaimSoon() }
        .inspectorColumnWidth(min: DetailStyle.minWidth, ideal: DetailStyle.idealWidth, max: DetailStyle.maxWidth)
    }

    /// Escape or ⌘.: drops a number being typed rather than committing it, the first time, and leaves the
    /// panel the next; unless a text view holding keys (a list it shows over its text) has the keyboard, whose key
    /// it is (the panel hears keys before the view with the keyboard does), or, for ⌥⎋, one that
    /// completes what's typed (a code editor's `complete:`). Whether it left.
    private func exitByKey(withOption: Bool) -> Bool {
        let text = window.window?.firstResponder as? EditingTextView
        if text?.holdsKeys == true || (withOption && text?.offersCompletions == true) { return false }
        // A number being typed goes first, alone: the field shows what it was, and the next Escape leaves.
        if drafts.pending != nil {
            drafts.revert(in: window.window?.firstResponder as? NSTextView)
            return true
        }
        activeTakeover?.takeover.onEscape(editor)
        onExit()
        return true
    }

    /// The panel's Tab ring, closed once SwiftUI has drawn what changed, if the keyboard is in the
    /// panel: with it elsewhere nobody is in the ring, and it is closed as the keyboard comes in
    /// (`WindowBox.watchKeyboard`), so a selection stepping on the canvas costs no walk of the window.
    private func closeRingSoon() {
        _ = editor.scheduler.schedule(after: DetailStyle.focusRetry) { [window] in if window.hasKeyboard { window.closeRing() } }
    }

    /// After SwiftUI has removed (or AppKit hidden) views: if the keyboard fell to the window, hand
    /// it to the canvas. A control that is still there keeps it. Asked as the selection changes, the
    /// panel hides, the tab's sections change, and a status line goes (its text may have been
    /// selected: `detailReclaim`); it acts only when the window has the keyboard, so asking is free.
    private func reclaimSoon() {
        closeRingSoon()
        _ = editor.scheduler.schedule(after: .zero) { [window, onExit] in
            if let window = window.window, window.firstResponder === window { onExit() }
        }
    }
}

/// The panel's window, for `reclaimSoon`, and the panel's place in it: the view that fills the panel
/// (`reader`) and the one that fills the area under its tab strip (`content`), which tell which of the
/// window's controls are the panel's (an `.inspector` is the window's content beside the canvas, whose
/// views are not the panel's subtree). The keys that move the keyboard within the panel
/// (`focusFirstControl`, `closeRing`) read the controls off them.
@MainActor
final class WindowBox {
    weak var window: NSWindow?
    weak var reader: NSView?
    weak var content: NSView?
    /// Watches the window's first responder: the panel's Tab ring is closed as the keyboard comes into it.
    private var watching: NSKeyValueObservation?

    /// Whether `view` is in the panel's place (`region`, in window coordinates): its middle is, or the
    /// middle of the outermost scroll view it is in is. A control scrolled out of the panel's view, or
    /// a table taller than the panel (its frame is all its rows), is the panel's still, and in its Tab
    /// ring: AppKit scrolls it into view as the key reaches it.
    private static func isPlaced(_ view: NSView, in region: CGRect) -> Bool {
        var anchor = view
        while let scroll = anchor.enclosingScrollView, scroll !== anchor { anchor = scroll }
        let frame = anchor.convert(anchor.bounds, to: nil)
        return region.contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    /// Whether the keyboard is in the panel: the window's first responder is a view in its place.
    var hasKeyboard: Bool {
        guard let panel = reader, let responder = window?.firstResponder as? NSView, responder !== panel else { return false }
        return Self.isPlaced(responder, in: panel.convert(panel.bounds, to: nil))
    }

    /// The panel's controls the key view loop visits, in reading order: the views of the window under
    /// `reader` (by place, not by subtree) that can take the keyboard by Tab, a row at a time (a
    /// stepper beside its field is one row), left to right in it.
    func controls() -> [NSView] {
        guard let root = window?.contentView, let panel = reader, panel.window != nil else { return [] }
        let region = panel.convert(panel.bounds, to: nil)
        var found: [(view: NSView, frame: CGRect)] = []
        func walk(_ view: NSView) {
            guard !view.isHidden else { return }
            if view !== panel, view.canBecomeKeyView, !(view is NSScrollView || view is NSClipView),
               !((view as? NSTextView)?.isFieldEditor ?? false) {
                let frame = view.convert(view.bounds, to: nil)
                if !frame.isEmpty, Self.isPlaced(view, in: region) { found.append((view, frame)) }
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        var rows: [[(view: NSView, frame: CGRect)]] = []
        for entry in found.sorted(by: { $0.frame.maxY > $1.frame.maxY }) {
            if let top = rows.last?.first?.frame.maxY, top - entry.frame.maxY < DetailStyle.rowTolerance {
                rows[rows.count - 1].append(entry)
            } else {
                rows.append([entry])
            }
        }
        return rows.flatMap { $0.sorted { $0.frame.minX < $1.frame.minX }.map(\.view) }
    }

    /// Where the keyboard enters the panel: its first text field or text view (the header's, at the
    /// top), else its first list or table. Nil for neither.
    func entry() -> NSView? {
        let controls = controls()
        return controls.first { ($0 as? NSTextField)?.isEditable == true || $0 is NSTextView } ?? controls.first { $0 is NSTableView }
    }

    /// Tab off the panel's last control goes round to its first, and ⇧Tab off the first to the last:
    /// the panel's key view loop is closed on itself. Redone as the keyboard comes into the panel and
    /// as its content changes, since controls come and go with its tab.
    func closeRing() {
        let ring = controls()
        guard ring.count > 1 else { return }
        for (view, next) in zip(ring, ring.dropFirst() + [ring[0]]) where view.nextKeyView !== next { view.nextKeyView = next }
    }

    /// The first control under the tab strip that is not one of `old` (those the tab just left) gets the
    /// keyboard, once the panel has drawn the new tab: tried a few times, as SwiftUI makes its views a turn
    /// or two on. A tab with no control leaves the keyboard where it is.
    func focusFirstControl(excluding old: [NSView], retries: Int, scheduler: any Scheduler) {
        guard let window else { return }
        let below = content.map { $0.convert($0.bounds, to: nil) }
        let first = controls().first { control in
            guard !old.contains(where: { $0 === control }) else { return false }
            guard let below else { return true }
            let frame = control.convert(control.bounds, to: nil)
            return below.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
        if let first {
            closeRing()
            window.makeFirstResponder(first)
        } else if retries > 0 {
            _ = scheduler.schedule(after: DetailStyle.focusRetry) { [weak self] in
                self?.focusFirstControl(excluding: old, retries: retries - 1, scheduler: scheduler)
            }
        }
    }

    /// Stops, before the window or the reader goes: an observation of a window that is gone crashes.
    func stopWatchingKeyboard() {
        watching?.invalidate()
        watching = nil
    }

    /// Starts watching the window's keyboard, once it has one.
    func watchKeyboard() {
        guard watching == nil, let window else { return }
        watching = window.observe(\.firstResponder, options: [.new]) { [weak self] window, _ in
            MainActor.assumeIsolated {
                if let self, self.hasKeyboard { self.closeRing() }
            }
        }
    }
}

/// Fills the box, and reports the panel being hidden (it, or a view it's in), which `onDisappear`
/// doesn't.
struct WindowReader: NSViewRepresentable {
    let box: WindowBox
    let onHide: @MainActor () -> Void
    func makeNSView(context: Context) -> ReaderView { ReaderView(box: box, onHide: onHide) }
    func updateNSView(_ view: ReaderView, context: Context) { view.onHide = onHide }

    final class ReaderView: NSView {
        let box: WindowBox
        var onHide: @MainActor () -> Void
        init(box: WindowBox, onHide: @escaping @MainActor () -> Void) {
            self.box = box
            self.onHide = onHide
            super.init(frame: .zero)
            box.reader = self
        }
        required init?(coder: NSCoder) { fatalError("not from a nib") }
        // Never cleared: an `.inspector` moves a new reader in before it takes the old one out.
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            // Only the reader the box has: a new reader (`init` made it the box's) is in before the old one
            // goes, and the watch it started is the box's, not the old reader's to stop.
            if newWindow !== window, box.reader === self { box.stopWatchingKeyboard() }
            super.viewWillMove(toWindow: newWindow)
        }
        override func viewDidMoveToWindow() {
            guard let window else { return }
            box.window = window
            box.reader = self
            box.watchKeyboard()
        }
        override func viewDidHide() { onHide() }
    }
}

/// Fills the area under the tab strip: where the panel's tab content is.
struct ContentReader: NSViewRepresentable {
    let box: WindowBox
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.content = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { box.content = view }
}

struct Placeholder: View {
    let text: String
    var body: some View {
        Text(text)
            .font(DetailStyle.placeholder)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Several shapes are selected: their header. Details are per shape: editing several at once isn't
/// built.
struct SelectionSummary: View {
    let header: DetailHeader
    let editor: CanvasEditor
    var body: some View {
        VStack(spacing: 0) {
            HeaderView(editor: editor, content: header)
            Divider()
        }
    }
}

/// One shape's panel. Skipped (`.equatable()`) unless its record, whether it can change, its status
/// lines or the sections `shownWhile` hides change, so dragging another shape costs one comparison.
struct ShapePanel: View, Equatable {
    let state: DetailPanelState
    let editor: CanvasEditor
    let record: AnyShapeRecord
    /// Whether the shape can't change (`editor.isReadOnly(_:)`: locked, in a locked frame, or on a
    /// locked subboard's board): it shows its details, but none of them edits it. Read by the panel's root, which reads the
    /// document, so this view, which doesn't, draws again only when it changes.
    let isReadOnly: Bool
    let statuses: ShapeStatuses
    let hidden: Set<DetailSectionKey>
    let contentChanged: @MainActor () -> Void
    /// Where the panel is in its window: the area under the strip is told to it.
    let place: WindowBox

    nonisolated static func == (a: Self, b: Self) -> Bool {
        MainActor.assumeIsolated {
            a.record == b.record && a.isReadOnly == b.isReadOnly && a.statuses == b.statuses && a.hidden == b.hidden
        }
    }

    var body: some View {
        #if DEBUG
        let _ = (state.panelsDrawn += 1)
        #endif
        let layout = state.layout(for: record, statuses: statuses.tabs, hidden: hidden)
        let current = state.currentTab(in: layout, for: record.kind)
        let sections = current.map { layout.resolved(in: $0) } ?? []
        let lines = current.map { layout.statuses(in: $0) } ?? []
        VStack(spacing: 0) {
            HeaderView(editor: editor, kindName: layout.kindName, kindSymbol: layout.kindSymbol, content: layout.resolvedHeader.view,
                       isReadOnly: isReadOnly)
            if let current {
                if layout.tabs.count > 1 {
                    TabStrip(tabs: layout.tabs, alert: layout.alert(in:), selection: current) { state.choose($0, for: record.kind) }
                        .onMoveCommand { direction in
                            switch direction {
                            case .left: state.stepTab(by: -1)
                            case .right: state.stepTab(by: 1)
                            default: break
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityAddTraits(.isTabBar)
                }
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        // The tab's status lines lead, as a headerless block.
                        if !lines.isEmpty {
                            StatusList(statuses: lines, spacing: DetailStyle.rowSpacing)
                                .padding(.horizontal, DetailStyle.inset)
                                .padding(.top, DetailStyle.sectionTop)
                                .padding(.bottom, DetailStyle.sectionBottom)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if !sections.isEmpty { Divider() }
                        }
                        ForEach(sections, id: \.key) { resolved in
                            SectionView(resolved: resolved, editor: editor, record: record, isReadOnly: isReadOnly,
                                        isCollapsed: state.isCollapsed(resolved.key),
                                        toggle: { state.setCollapsed(resolved.key, !state.isCollapsed(resolved.key)) })
                                .equatable()
                            if resolved.key != sections.last?.key { Divider() }
                        }
                    }
                }
                .background(ContentReader(box: place))
            } else {
                Divider()
                Placeholder(text: "No Options")
            }
            Spacer(minLength: 0)
            FooterView(statuses: statuses.footer)
        }
        // A tab switch, a collapse, or a section hidden by `when` or `shownWhile` may remove the
        // control that had the keyboard.
        .onChange(of: current.map { tab in layout.sections(in: tab).filter { !state.isCollapsed($0) } } ?? []) {
            contentChanged()
        }
    }
}

/// A back button, then the shape's header (or the selection's), told what the panel calls the
/// shape's kind and its symbol, for a placeholder and a header without a symbol. A read-only
/// shape's header renames nothing; going back still works.
struct HeaderView<Content: View>: View {
    let editor: CanvasEditor
    var kindName = ""
    var kindSymbol: String?
    let content: Content
    var isReadOnly = false
    var body: some View {
        HStack(spacing: DetailStyle.pairSpacing) {
            BackButton(editor: editor)
            content
                .environment(\.detailKindName, kindName)
                .environment(\.detailKindSymbol, kindSymbol)
                .disabled(isReadOnly)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DetailStyle.inset)
        .frame(height: DetailStyle.headerHeight)
    }
}

extension DetailHeader: View {
    public var body: some View {
        DetailHeaderLabel(subtitle: subtitle, systemImage: systemImage) { Text(title) }
    }
}

/// The header's layout, for a header view a kind builds itself: the shape's symbol (this one, else
/// its kind's), then its title on one line in the header's font, over an optional subtitle. The
/// title is any view: `DetailHeader` makes it text, and a header that renames its shape a
/// `DetailHeaderField` (Titles' `TitleHeader`).
public struct DetailHeaderLabel<Title: View>: View {
    let subtitle: String?
    let systemImage: String?
    let title: Title
    @Environment(\.detailKindSymbol) private var kindSymbol

    public init(subtitle: String? = nil, systemImage: String? = nil, @ViewBuilder title: () -> Title) {
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.title = title()
    }

    public var body: some View {
        HStack(spacing: DetailStyle.pairSpacing) {
            if let symbol = systemImage ?? kindSymbol {
                Image(systemName: symbol)
                    .font(DetailStyle.headerSymbol)
                    .foregroundStyle(.secondary)
                    .frame(width: DetailStyle.headerSymbolWidth)
            }
            VStack(alignment: .leading, spacing: 1) {
                title.font(DetailStyle.headerTitle).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(DetailStyle.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

/// The header's title as a field, for a header that renames its shape in place (Titles'
/// `TitleHeader`): borderless, so it reads as the title until it's clicked. It writes as you type,
/// as the panel's other text fields do, its words' spelling checked as the app's is (`Spelling.app`:
/// an AppKit field, `HeaderTitleField`, since SwiftUI's can't be told to); Return, like Escape
/// anywhere in the panel, gives the keyboard back to the canvas. While it's empty it shows
/// `placeholder`, dimmed: by default what the panel calls the shape's kind ("Note").
/// `isEditable: false`, for a title that can't be written just now, shows it as text in the field's
/// place, as it reads in the field: at full strength, unlike a disabled field (dimmed, for a while
/// something else writes it).
public struct DetailHeaderField: View {
    @Binding var text: String
    let placeholder: String?
    let isEditable: Bool
    @Environment(\.detailKindName) private var kindName
    @Environment(\.detailExit) private var exit
    @Environment(\.isEnabled) private var isEnabled

    public init(_ text: Binding<String>, placeholder: String? = nil, isEditable: Bool = true) {
        _text = text
        self.placeholder = placeholder
        self.isEditable = isEditable
    }

    public var body: some View {
        if isEditable {
            HeaderTitleField(text: $text, placeholder: placeholder ?? kindName, onSubmit: exit)
        } else if text.isEmpty {
            Text(placeholder ?? kindName).foregroundStyle(Color(nsColor: .placeholderTextColor))
        } else {
            // Dimmed as the field would be where the panel is read-only (a locked shape).
            Text(text).foregroundStyle(Color(nsColor: isEnabled ? .labelColor : .disabledControlTextColor))
        }
    }
}

struct DetailKindNameKey: EnvironmentKey {
    static let defaultValue = ""
}

struct DetailKindSymbolKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

/// The panel's `onExit`, for a control that gives the keyboard back to the canvas by itself.
struct DetailExitKey: EnvironmentKey {
    static var defaultValue: @MainActor () -> Void { {} }
}

/// The panel's `reclaimSoon`, for a view that may have the keyboard as it goes (a status line's
/// selected text): once it's gone, if the keyboard fell to the window, the canvas has it again.
/// Outside the panel, nothing.
struct DetailReclaimKey: EnvironmentKey {
    static var defaultValue: @MainActor () -> Void { {} }
}

extension EnvironmentValues {
    var detailKindName: String {
        get { self[DetailKindNameKey.self] }
        set { self[DetailKindNameKey.self] = newValue }
    }

    var detailKindSymbol: String? {
        get { self[DetailKindSymbolKey.self] }
        set { self[DetailKindSymbolKey.self] = newValue }
    }

    var detailExit: @MainActor () -> Void {
        get { self[DetailExitKey.self] }
        set { self[DetailExitKey.self] = newValue }
    }

    var detailReclaim: @MainActor () -> Void {
        get { self[DetailReclaimKey.self] }
        set { self[DetailReclaimKey.self] = newValue }
    }
}

/// Back to the previous selection, as data-canvas's details panel has: Selection's `.goBack`, Go › Back,
/// called and keyed as the command is ("Back (⌘[)"), shown while its rule says there's a step back (the
/// rule alone, `canPerform(_:on:)`: a press on the canvas doesn't take the button away, and the command
/// waits for it). Its own view, so a new step back redraws only it, not the panel it's in.
struct BackButton: View {
    let editor: CanvasEditor
    var body: some View {
        if editor.canPerform(.goBack, on: []) {
            let title = editor.registry.title(of: .goBack) ?? CanvasCommand.goBack.rawValue
            Button { editor.perform(.goBack, on: []) } label: {
                Image(systemName: "chevron.backward")
                    .font(DetailStyle.backSymbol)
                    .frame(width: DetailStyle.backWidth, height: DetailStyle.backWidth)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(editor.registry.help(title, forCommand: .goBack))
            .accessibilityLabel(title)
        }
    }
}

/// The tabs, the one shown filled. A tab whose status lines warn or err (`DetailLayout.alert(in:)`,
/// Validation's Issues) has its worst tone's symbol before its title, in the tone's color,
/// as the lines draw it, so it reads as a tab of problems from any tab; no count.
struct TabStrip: View {
    let tabs: [DetailTabID]
    let alert: @MainActor (DetailTabID) -> DetailStatus.Tone?
    let selection: DetailTabID
    let choose: (DetailTabID) -> Void

    var body: some View {
        TabStripLayout(spacing: DetailStyle.tabSpacing) {
            ForEach(tabs, id: \.self) { tab in
                let selected = tab == selection
                let alert = alert(tab)
                Button { choose(tab) } label: {
                    // Sized for the semibold title, so selecting a tab doesn't move the others.
                    TabTitle(title: tab.title, alert: alert, font: DetailStyle.tabSelected).hidden()
                        .overlay {
                            TabTitle(title: tab.title, alert: alert, font: selected ? DetailStyle.tabSelected : DetailStyle.tab)
                                .foregroundStyle(selected ? .primary : .secondary)
                        }
                        .lineLimit(1)
                        .padding(.horizontal, DetailStyle.tabPadding)
                        .frame(maxWidth: .infinity, minHeight: DetailStyle.tabHeight)
                        .background(selected ? DetailStyle.tabFill : .clear, in: RoundedRectangle(cornerRadius: DetailStyle.tabCorner))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityValue(alert == .error ? "Errors" : alert == .warning ? "Warnings" : "")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, DetailStyle.stripInset)
        .padding(.bottom, DetailStyle.stripBottom)
    }
}

/// A tab's title, after its alert's symbol if it has one.
struct TabTitle: View {
    let title: String
    let alert: DetailStatus.Tone?
    let font: Font

    var body: some View {
        HStack(spacing: DetailStyle.tabAlertSpacing) {
            if let alert {
                Image(systemName: alert.symbol).font(DetailStyle.tabAlert).foregroundStyle(alert.color)
            }
            Text(title).font(font)
        }
    }
}

/// Equal widths while every title fits its equal share, as in Keynote. Otherwise each tab gets its
/// title's width plus an equal share of what's left, so five short titles fit the ideal width.
struct TabStripLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = proposal.width ?? ideal.map(\.width).reduce(gaps(subviews), +)
        return CGSize(width: width, height: ideal.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }
        let available = bounds.width - gaps(subviews)
        let share = available / CGFloat(max(subviews.count, 1))
        let extra = (available - ideal.reduce(0, +)) / CGFloat(max(subviews.count, 1))
        var x = bounds.minX
        for (subview, idealWidth) in zip(subviews, ideal) {
            let width = ideal.allSatisfy { $0 <= share } ? share : max(0, idealWidth + extra)
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }

    private func gaps(_ subviews: Subviews) -> CGFloat { spacing * CGFloat(max(subviews.count - 1, 0)) }
}

/// A section: its header (which collapses it, read-only shape or not), then its content. A
/// read-only shape's content is there to read, not to use, unless the section says it changes
/// nothing of it (`enabledWhileReadOnly()`).
struct SectionView: View, Equatable {
    let resolved: ResolvedSection
    let editor: CanvasEditor
    let record: AnyShapeRecord
    /// The shape's, which a container's lock changes, though not its record.
    let isReadOnly: Bool
    let isCollapsed: Bool
    let toggle: @MainActor () -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool {
        MainActor.assumeIsolated {
            a.resolved.key == b.resolved.key && a.record == b.record && a.isReadOnly == b.isReadOnly && a.isCollapsed == b.isCollapsed
        }
    }

    private var isDisabled: Bool { isReadOnly && !resolved.section.isEnabledWhileReadOnly }

    var body: some View {
        VStack(alignment: .leading, spacing: DetailStyle.rowSpacing) {
            if let title = resolved.section.title {
                HStack(spacing: DetailStyle.smallSpacing) {
                    Button(action: toggle) {
                        HStack(spacing: DetailStyle.smallSpacing) {
                            Image(systemName: "chevron.right")
                                .font(DetailStyle.disclosure)
                                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                            Text(title).font(DetailStyle.sectionTitle)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(title)
                    .accessibilityValue(isCollapsed ? DetailStyle.collapsed : DetailStyle.expanded)
                    Spacer(minLength: DetailStyle.pairSpacing)
                }
                .frame(height: DetailStyle.sectionHeaderHeight)
            }
            // A collapsed section's content isn't built.
            if !isCollapsed || resolved.section.title == nil {
                resolved.section.content(record, editor).disabled(isDisabled)
            }
        }
        .padding(.horizontal, DetailStyle.inset)
        .padding(.top, DetailStyle.sectionTop)
        .padding(.bottom, DetailStyle.sectionBottom)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FooterView: View {
    let statuses: [DetailStatus]
    var body: some View {
        if !statuses.isEmpty {
            StatusList(statuses: statuses, spacing: DetailStyle.smallSpacing)
                .padding(.horizontal, DetailStyle.inset)
                .padding(.vertical, DetailStyle.footerPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
        }
    }
}

/// Status lines, in the footer or at the top of a tab: each its tone's symbol, then its text.
struct StatusList: View {
    let statuses: [DetailStatus]
    let spacing: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(statuses.indices, id: \.self) { i in DetailStatusLine(statuses[i]) }
        }
    }
}

extension DetailStatus.Tone {
    var symbol: String {
        switch self {
        case .neutral: "circle.fill"
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    @MainActor var color: Color {
        switch self {
        case .neutral: .secondary
        case .info: DetailStyle.info
        case .warning: DetailStyle.warning
        case .error: DetailStyle.error
        }
    }
}
