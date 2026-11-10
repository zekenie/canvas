import AppKit
import Canvas
import Chrome
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
/// (`DetailPanelPlugin`'s `shownWhile`). A band a plugin gave (`DetailBands`) shows above whichever
/// of them shows, the first that's active. In the window's inspector the panel's first line is in the
/// title bar's row (`PaneTitleRow`, `detailTitleRow(else:height:)`): the band's while one shows, else the
/// header of what shows under it.
public struct DetailPanelView: View {
    let editor: CanvasEditor
    let onExit: @MainActor () -> Void
    let takeovers: [PlacedTakeover]
    let bands: [PlacedBand]
    @State private var window = WindowBox()
    @State private var drafts = DraftTracker()
    @Environment(\.paneTitleRow) private var titleRow

    public init(editor: CanvasEditor, onExit: @escaping @MainActor () -> Void = {}) {
        self.editor = editor
        self.onExit = onExit
        takeovers = editor.registry.detailTakeovers.map { PlacedTakeover(takeover: $0, content: $0.content(editor, onExit)) }
        bands = editor.registry.detailBands.enumerated().map { PlacedBand(index: $0.offset, band: $0.element, content: $0.element.content(editor, onExit)) }
    }

    /// The takeover that shows: the first that's active, in plugin order. Read in the body, so the
    /// panel redraws as what each `isActive` reads changes.
    private var activeTakeover: PlacedTakeover? { takeovers.first { $0.takeover.isActive(editor) } }

    /// Which takeover shows, by its place in the list.
    private var activeTakeoverIndex: Int? { takeovers.firstIndex { $0.takeover.isActive(editor) } }

    /// The band that shows: the first that's active, in plugin order. Read in the body, like the takeover.
    private var activeBand: PlacedBand? { bands.first { $0.band.isActive(editor) } }

    public var body: some View {
        let band = activeBand
        VStack(spacing: 0) {
            if let band {
                band.content
                    .background(BandReader(box: window))
                    .id(band.index)
            }
            // The title bar's row is the first line's: under a band, the header is a header's height.
            content
                .environment(\.paneTitleRow, band == nil ? titleRow : nil)
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
            // Like it, for a takeover that has just closed over the shape's panel: and the canvas if the panel has no control.
            editor.detailPanel?.focusesContent = { [window, weak editor, onExit] in
                guard let scheduler = editor?.scheduler else { return }
                window.focusFirstControl(excluding: window.controls(), retries: DetailStyle.focusRetries, scheduler: scheduler) {
                    if let host = window.window, host.firstResponder === host { onExit() }
                }
            }
            // Where the keyboard enters the panel: the header's field.
            editor.detailPanel?.keyboardEntry = { [window] in window.entry() }
            editor.detailPanel?.keyboardPlaceReader = { [window, weak editor] in
                guard let editor else { return nil }
                return window.place(isTakeoverShown: editor.registry.activeDetailTakeover(in: editor) != nil)
            }
            editor.detailPanel?.focusesBand = { [window] in window.focusBand() }
            editor.detailPanel?.exitsToCanvas = onExit
            window.scheduler = editor.scheduler
            closeRingSoon()
        }
        .onKeyPress(.escape, phases: [.down, .repeat]) { press in
            exitByKey(.escape, withOption: press.modifiers.contains(.option)) ? .handled : .ignored
        }
        // ⌘., which the window sends up the responder chain as `cancelOperation:` with no key
        // down: the panel's text views and fields leave it to their superviews. So does Escape in a
        // table (a list), which `WindowBox.takeCommandPeriod` tells apart.
        .onExitCommand { _ = exitByKey(window.takeCommandPeriod() ? .commandPeriod : .escape, withOption: false) }
        .onChange(of: editor.selectedShapeIDs) { reclaimSoon() }
        // The band's controls join the ring first (they are above everything), or leave it; a band that goes with the keyboard
        // in it (Done, pressed) leaves it on the window, which the canvas then has.
        .onChange(of: activeBand?.index) { reclaimSoonOfBand() }
        // A takeover coming or going swaps the panel's controls a turn after the key that closed it made the ring (Escape to the
        // band): made again once its views are gone.
        .onChange(of: activeTakeoverIndex) { closeRingSoon() }
    }

    /// What the panel shows under the band: a takeover, else the selection's panel.
    @ViewBuilder
    private var content: some View {
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
                               statuses: state.statuses(of: record), hidden: state.hiddenSections(of: record),
                               through: state.shown(through: id), contentChanged: reclaimSoon, place: window)
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
    }

    /// The keys that leave the panel, which differ when a band is over it (`DetailBands`).
    private enum ExitKey {
        /// One level out: the takeover closes, then the band has the keyboard, then (from the band, or
        /// with no band) the canvas has it. The band stays.
        case escape
        /// All the way out: the takeover closes, the band is cancelled, the canvas has the keyboard.
        case commandPeriod
    }

    /// Escape or ⌘.: drops a number being typed rather than committing it, the first time, and leaves the
    /// panel the next; unless a text view holding keys (a list it shows over its text) has the keyboard, whose key
    /// it is (the panel hears keys before the view with the keyboard does), or, for ⌥⎋, one that
    /// completes what's typed (a code editor's `complete:`). Whether it left.
    private func exitByKey(_ key: ExitKey, withOption: Bool) -> Bool {
        let text = window.window?.firstResponder as? EditingTextView
        if text?.holdsKeys == true || (withOption && text?.offersCompletions == true) { return false }
        // A number being typed goes first, alone: the field shows what it was, and the next Escape leaves.
        if drafts.pending != nil {
            drafts.revert(in: window.window?.firstResponder as? NSTextView)
            return true
        }
        switch key {
        case .escape:
            // From inside the band, the canvas: what's under the band (a list) is as it was.
            if window.place(isTakeoverShown: activeTakeover != nil) == .band {
                onExit()
                return true
            }
            activeTakeover?.takeover.onEscape(editor)
            // A band with nothing the keys reach (a button, with Keyboard navigation off) lets Escape through.
            if activeBand != nil, window.focusBand() { return true }
            onExit()
        case .commandPeriod:
            activeTakeover?.takeover.onEscape(editor)
            activeBand?.band.onCancel(editor)
            onExit()
        }
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
    ///
    /// With `whenHostHasIt` (a band that has gone: its focused button left the window) the view that hosts the panel, or any view
    /// above it, having the keyboard is as good as the window having it: SwiftUI gives the host the focus its control had.
    private func reclaimSoon() { reclaimSoon(whenHostHasIt: false) }

    private func reclaimSoon(whenHostHasIt: Bool) {
        closeRingSoon()
        _ = editor.scheduler.schedule(after: .zero) { [window, onExit] in
            guard let host = window.window else { return }
            if host.firstResponder === host || (whenHostHasIt && window.hostHasKeyboard) { onExit() }
        }
    }

    /// As `reclaimSoon`, for a band that has come or gone.
    private func reclaimSoonOfBand() { reclaimSoon(whenHostHasIt: true) }
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
    /// The view that fills the band over the panel, while there is one.
    weak var band: NSView?
    /// For clearing `commandPeriodSeen`: the editor's, set as the panel appears.
    var scheduler: (any Scheduler)?
    /// ⌘. went by as a key equivalent just now (`ReaderView`), so the `cancelOperation:` that follows
    /// is its, not an Escape's: the two reach the panel the same way.
    private var commandPeriodSeen = false
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

    /// Whether `view` is in the band's place: placed as every control of the panel is (`isPlaced`), so a
    /// table taller than the panel, scrolled through the band's strip, is not the band's.
    private func isInBand(_ view: NSView) -> Bool {
        guard let band, !band.isHiddenOrHasHiddenAncestor else { return false }
        return Self.isPlaced(view, in: band.convert(band.bounds, to: nil))
    }

    /// Whether the keyboard is in the panel: the window's first responder is a view in its place.
    var hasKeyboard: Bool {
        guard let panel = reader, let responder = window?.firstResponder as? NSView, responder !== panel else { return false }
        return Self.isPlaced(responder, in: panel.convert(panel.bounds, to: nil))
    }

    /// Whether the keyboard is in a view that contains the panel (the view that hosts it): no control of the panel has it.
    var hostHasKeyboard: Bool {
        guard let panel = reader, let responder = window?.firstResponder as? NSView, responder !== panel else { return false }
        return panel.isDescendant(of: responder)
    }

    /// Where in the panel the keyboard is: the band (the responder's middle is in the band's place),
    /// else a takeover while one shows, else the rest; nil with the keyboard out of the panel.
    func place(isTakeoverShown: Bool) -> KeyboardPlace? {
        guard hasKeyboard, let responder = window?.firstResponder as? NSView else { return nil }
        if isInBand(responder) { return .band }
        return isTakeoverShown ? .takeover : .content
    }

    /// Gives the keyboard to the band's first control: the first of the panel's controls in its place.
    /// Whether anything took it.
    func focusBand() -> Bool {
        guard let window, let band, !band.isHiddenOrHasHiddenAncestor else { return false }
        guard let first = controls().first(where: { isInBand($0) }) else { return false }
        closeRing()
        return window.makeFirstResponder(first)
    }

    /// A key equivalent is going by: if it is ⌘., the next `takeCommandPeriod` says so, until this turn is over.
    func noteKeyEquivalent(_ event: NSEvent) {
        commandPeriodSeen = event.charactersIgnoringModifiers == "." && event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command
        guard commandPeriodSeen else { return }
        _ = scheduler?.schedule(after: .zero) { [weak self] in self?.commandPeriodSeen = false }
    }

    /// Whether the `cancelOperation:` being answered is ⌘.'s, once.
    func takeCommandPeriod() -> Bool {
        defer { commandPeriodSeen = false }
        return commandPeriodSeen
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
    /// or two on. A tab with no control leaves the keyboard where it is, or, given, `exhausted` runs.
    func focusFirstControl(excluding old: [NSView], retries: Int, scheduler: any Scheduler, exhausted: (@MainActor () -> Void)? = nil) {
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
                self?.focusFirstControl(excluding: old, retries: retries - 1, scheduler: scheduler, exhausted: exhausted)
            }
        } else {
            exhausted?()
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

/// Fills the box, and reports the panel being hidden (it, or a view it's in) or taken out of its window
/// (the window's inspector hidden), which `onDisappear` doesn't, before the keyboard it had is lost.
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
            // Going out of its window with the panel (the inspector hidden): the keyboard it had falls to the window.
            if newWindow == nil, window != nil { onHide() }
            super.viewWillMove(toWindow: newWindow)
        }
        override func viewDidMoveToWindow() {
            guard let window else { return }
            box.window = window
            box.reader = self
            box.watchKeyboard()
        }
        override func viewDidHide() { onHide() }
        /// Hears the key equivalents the window offers its views, to tell ⌘. from Escape.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            MainActor.assumeIsolated { box.noteKeyEquivalent(event) }
            return super.performKeyEquivalent(with: event)
        }
    }
}

/// Fills the band over the panel: where the band is, so the keyboard in it is told from the keyboard in
/// the panel under it.
struct BandReader: NSViewRepresentable {
    let box: WindowBox
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.band = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { box.band = view }
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
    /// What a stand-in shows (a mirror's original): its tabs follow the stand-in's own, bound to it. Nil for any other shape.
    let through: ShownThrough?
    let contentChanged: @MainActor () -> Void
    /// Where the panel is in its window: the area under the strip is told to it.
    let place: WindowBox

    nonisolated static func == (a: Self, b: Self) -> Bool {
        MainActor.assumeIsolated {
            a.record == b.record && a.isReadOnly == b.isReadOnly && a.statuses == b.statuses && a.hidden == b.hidden
                && a.through == b.through
        }
    }

    var body: some View {
        #if DEBUG
        let _ = (state.panelsDrawn += 1)
        #endif
        let layout = state.layout(for: record, statuses: statuses.tabs, hidden: hidden, through: through)
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
                    TabContent(state: state, editor: editor, record: record, isReadOnly: isReadOnly, through: through, lines: lines, sections: sections)
                        .equatable()
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
        .detailTitleRow(else: EdgeInsets(top: 0, leading: DetailStyle.inset, bottom: 0, trailing: DetailStyle.inset),
                        height: DetailStyle.headerHeight)
    }
}

extension View {
    /// This, the panel's first line (the shape's header, Find's field and Done, the issue walk's band), in the window's title
    /// bar's row while the panel's sheet runs under one and nothing above it in the panel has the row (a band does while it
    /// shows: `DetailPanelView`): as tall as the row, its ends clear of the window's buttons there (`PaneTitleRow`), and a
    /// press on what of it takes none (its words, its symbol, the room between) the window's (`TitleRowDragArea`). Elsewhere
    /// it's padded by `insets`, and `height` tall where that's given.
    public func detailTitleRow(else insets: EdgeInsets, height: CGFloat? = nil) -> some View {
        modifier(DetailTitleRow(insets: insets, height: height))
    }
}

struct DetailTitleRow: ViewModifier {
    let insets: EdgeInsets
    let height: CGFloat?
    @Environment(\.paneTitleRow) private var row

    // One chain of modifiers in or out of the row, so the line keeps its views (the header's field) as a band comes or goes.
    func body(content: Content) -> some View {
        content
            .padding(.top, row == nil ? insets.top : 0)
            .padding(.bottom, row == nil ? insets.bottom : 0)
            .padding(.leading, row?.leading ?? insets.leading)
            .padding(.trailing, row?.trailing ?? insets.trailing)
            .frame(height: row?.height ?? height)
            .background {
                if row != nil { TitleRowDragArea() }
            }
    }
}

extension DetailHeader: View {
    public var body: some View {
        // Words a press goes through, to the window in the title bar's row.
        DetailHeaderLabel(subtitle: subtitle, systemImage: systemImage) { Text(title).allowsHitTesting(false) }
    }
}

/// The header's layout, for a header view a kind builds itself: the shape's symbol (this one, else
/// its kind's), then its title on one line in the header's font, over an optional subtitle. The
/// title is any view: `DetailHeader` makes it text, and a header that renames its shape a
/// `DetailHeaderField` (Titles' `TitleHeader`). In the window's title bar's row its words are in the
/// window's title's type there (`DetailStyle.rowTitle`; over a subtitle, the title's two-line form), and
/// a press on the symbol or the subtitle goes through to the window.
public struct DetailHeaderLabel<Title: View>: View {
    let subtitle: String?
    let systemImage: String?
    let title: Title
    let place: [PlaceStep]
    let lead: String
    @Environment(\.detailKindSymbol) private var kindSymbol
    @Environment(\.paneTitleRow) private var row
    @State private var width: CGFloat?

    /// `place`: when the subtitle is an address after `lead` ("Note · "), its steps, which the line folds in the room it has
    /// (`PlaceFold`, boards semibold) with `subtitle`, the whole, as its help; the header stays one line.
    public init(subtitle: String? = nil, systemImage: String? = nil, place: [PlaceStep] = [], lead: String = "", @ViewBuilder title: () -> Title) {
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.place = place
        self.lead = lead
        self.title = title()
    }

    public var body: some View {
        HStack(spacing: DetailStyle.pairSpacing) {
            if let symbol = systemImage ?? kindSymbol {
                Image(systemName: symbol)
                    .font(DetailStyle.headerSymbol)
                    .foregroundStyle(.secondary)
                    .frame(width: DetailStyle.headerSymbolWidth)
                    .allowsHitTesting(false)
            }
            VStack(alignment: .leading, spacing: 1) {
                title.font(titleType.font).lineLimit(1)
                    .environment(\.detailHeaderTitleType, titleType)
                if !place.isEmpty {
                    let size = row == nil ? DetailStyle.captionSize : DetailStyle.rowSubtitleSize
                    let shortened = DetailPlaceText.line(place, lead: lead, room: placeRoom, size: size).isShortened
                    DetailPlaceText(steps: place, lead: lead, room: placeRoom, size: size)
                        .help(shortened ? subtitle ?? "" : "")
                        .accessibilityLabel(subtitle ?? "")
                        .allowsHitTesting(shortened)
                } else if let subtitle {
                    Text(subtitle).font(row == nil ? DetailStyle.caption : DetailStyle.rowSubtitle).foregroundStyle(.secondary).lineLimit(1)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(maxWidth: place.isEmpty ? nil : .infinity, alignment: .leading)
        .background {
            if !place.isEmpty {
                GeometryReader { geometry in Color.clear.preference(key: DetailHeaderWidthKey.self, value: geometry.size.width) }
            }
        }
        .onPreferenceChange(DetailHeaderWidthKey.self) { if !place.isEmpty, width != $0 { width = $0 } }
    }

    /// What the subtitle may take: the header's width less the symbol's column; all of it until it is read.
    private var placeRoom: CGFloat {
        guard let width else { return .infinity }
        return max(0, width - (systemImage ?? kindSymbol == nil ? 0 : DetailStyle.headerSymbolWidth + DetailStyle.pairSpacing))
    }

    private var titleType: DetailHeaderTitleType {
        guard row != nil else { return .header }
        return subtitle == nil ? .row : .rowOverSubtitle
    }
}

/// The width a header was given.
private struct DetailHeaderWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The type a header's title is set in: the header's, or in the window's title bar's row the window's title's, alone or over a
/// subtitle; `fieldFont` the same for a title AppKit draws (`HeaderTitleField`).
enum DetailHeaderTitleType: Sendable {
    case header, row, rowOverSubtitle

    @MainActor var font: Font {
        switch self {
        case .header: DetailStyle.headerTitle
        case .row: DetailStyle.rowTitle
        case .rowOverSubtitle: DetailStyle.rowTitleOverSubtitle
        }
    }

    @MainActor var fieldFont: NSFont {
        switch self {
        case .header: DetailStyle.headerTitleFont
        case .row: DetailStyle.rowTitleFont
        case .rowOverSubtitle: DetailStyle.rowTitleOverSubtitleFont
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

/// The type the header's title is in, which `DetailHeaderLabel` hands its title: what `HeaderTitleField` sets.
struct DetailHeaderTitleTypeKey: EnvironmentKey {
    static let defaultValue = DetailHeaderTitleType.header
}

extension EnvironmentValues {
    var detailHeaderTitleType: DetailHeaderTitleType {
        get { self[DetailHeaderTitleTypeKey.self] }
        set { self[DetailHeaderTitleTypeKey.self] = newValue }
    }

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

/// Back to the last place gone from, as data-canvas's details panel has: Selection's `.goBack`, Go › Back,
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
            ForEach(statuses.indices, id: \.self) { i in DetailStatusLine(statuses[i], actions: statuses[i].actions) }
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
