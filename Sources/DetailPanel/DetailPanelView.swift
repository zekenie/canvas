import AppKit
import Canvas
import Selection
import SwiftUI

/// The panel. The app places it (in `.inspector`, through Composition); it follows the editor's
/// selection by itself. `onExit` gives the keyboard back to the canvas: the panel calls it on
/// Escape, when it has just removed the control that had the keyboard, and when it's hidden with
/// that control in it (an `.inspector` hides its content without removing it). The keyboard would
/// otherwise land on the window itself, and tool shortcuts would stop.
public struct DetailPanelView: View {
    let editor: CanvasEditor
    let onExit: @MainActor () -> Void
    let overview: AnyView?
    @State private var window = WindowBox()
    @State private var drafts = DraftTracker()

    public init(editor: CanvasEditor, onExit: @escaping @MainActor () -> Void = {}) {
        self.editor = editor
        self.onExit = onExit
        overview = nil
    }

    /// With `overview` where the panel has no shape to show: in place of "No Selection", and under
    /// the header when several shapes are selected (as data-canvas's details panel shows its table
    /// of contents). The panel doesn't know what it is; Composition decides.
    public init<Overview: View>(editor: CanvasEditor, onExit: @escaping @MainActor () -> Void, @ViewBuilder overview: () -> Overview) {
        self.editor = editor
        self.onExit = onExit
        self.overview = AnyView(overview())
    }

    public var body: some View {
        Group {
            if let state = editor.detailPanel {
                let ids = editor.selectedShapeIDs
                if ids.count > 1 {
                    SelectionSummary(header: state.selectionSummary(of: ids.compactMap { editor.document[$0] }), overview: overview)
                } else if let id = editor.selection, let record = editor.document[id] {
                    ShapePanel(state: state, editor: editor, record: record, statuses: state.statuses(for: record),
                               contentChanged: reclaimSoon)
                        .equatable()
                        .id(id)
                } else if let overview {
                    overview
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
        .onKeyPress(.escape) {
            // Leaves the panel, dropping a number being typed rather than committing it.
            drafts.revert()
            onExit()
            return .handled
        }
        .onChange(of: editor.selectedShapeIDs) { reclaimSoon() }
        .inspectorColumnWidth(min: DetailStyle.minWidth, ideal: DetailStyle.idealWidth, max: DetailStyle.maxWidth)
    }

    /// After SwiftUI has removed (or AppKit hidden) views: if the keyboard fell to the window, hand
    /// it to the canvas. A control that is still there keeps it.
    private func reclaimSoon() {
        _ = editor.scheduler.schedule(after: .zero) { [window, onExit] in
            if let window = window.window, window.firstResponder === window { onExit() }
        }
    }
}

/// The panel's window, for `reclaimSoon`.
@MainActor
final class WindowBox {
    weak var window: NSWindow?
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
        }
        required init?(coder: NSCoder) { fatalError("not from a nib") }
        // Never cleared: an `.inspector` moves a new reader in before it takes the old one out.
        override func viewDidMoveToWindow() { if let window { box.window = window } }
        override func viewDidHide() { onHide() }
    }
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

/// Several shapes are selected: their header, then the overview if there is one. Details are per
/// shape: editing several at once isn't built.
struct SelectionSummary: View {
    let header: DetailHeader
    let overview: AnyView?
    var body: some View {
        VStack(spacing: 0) {
            HeaderView(header: header)
            Divider()
            if let overview {
                overview
            } else {
                Placeholder(text: "Select one shape to see its details")
            }
        }
    }
}

/// One shape's panel. Skipped (`.equatable()`) unless its record or statuses change, so dragging
/// another shape costs one comparison.
struct ShapePanel: View, Equatable {
    let state: DetailPanelState
    let editor: CanvasEditor
    let record: AnyShapeRecord
    let statuses: [DetailStatus]
    let contentChanged: @MainActor () -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool {
        MainActor.assumeIsolated { a.record == b.record && a.statuses == b.statuses }
    }

    var body: some View {
        let layout = state.layout(for: record)
        let current = state.currentTab(in: layout, for: record.kind)
        let sections = current.map { layout.resolved(in: $0) } ?? []
        VStack(spacing: 0) {
            HeaderView(header: layout.header)
            if let current {
                if layout.tabs.count > 1 {
                    TabStrip(tabs: layout.tabs, selection: current) { state.choose($0, for: record.kind) }
                }
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(sections, id: \.key) { resolved in
                            SectionView(resolved: resolved, editor: editor, record: record,
                                        isCollapsed: state.isCollapsed(resolved.key),
                                        toggle: { state.setCollapsed(resolved.key, !state.isCollapsed(resolved.key)) })
                                .equatable()
                            if resolved.key != sections.last?.key { Divider() }
                        }
                    }
                }
            } else {
                Divider()
                Placeholder(text: "No Options")
            }
            Spacer(minLength: 0)
            FooterView(statuses: statuses)
        }
        // A tab switch, a collapse, or a section hidden by `when` may remove the control that had
        // the keyboard.
        .onChange(of: current.map { tab in layout.sections(in: tab).filter { !state.isCollapsed($0) } } ?? []) {
            contentChanged()
        }
    }
}

struct HeaderView: View {
    let header: DetailHeader
    var body: some View {
        HStack(spacing: DetailStyle.pairSpacing) {
            if let symbol = header.systemImage {
                Image(systemName: symbol)
                    .font(DetailStyle.headerSymbol)
                    .foregroundStyle(.secondary)
                    .frame(width: DetailStyle.headerSymbolWidth)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(header.title).font(DetailStyle.headerTitle).lineLimit(1)
                if let subtitle = header.subtitle {
                    Text(subtitle).font(DetailStyle.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DetailStyle.inset)
        .frame(height: DetailStyle.headerHeight)
    }
}

struct TabStrip: View {
    let tabs: [DetailTabID]
    let selection: DetailTabID
    let choose: (DetailTabID) -> Void

    var body: some View {
        TabStripLayout(spacing: DetailStyle.tabSpacing) {
            ForEach(tabs, id: \.self) { tab in
                let selected = tab == selection
                Button { choose(tab) } label: {
                    // Sized for the semibold title, so selecting a tab doesn't move the others.
                    Text(tab.title).font(DetailStyle.tabSelected).hidden()
                        .overlay {
                            Text(tab.title)
                                .font(selected ? DetailStyle.tabSelected : DetailStyle.tab)
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
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, DetailStyle.stripInset)
        .padding(.bottom, DetailStyle.stripBottom)
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

struct SectionView: View, Equatable {
    let resolved: ResolvedSection
    let editor: CanvasEditor
    let record: AnyShapeRecord
    let isCollapsed: Bool
    let toggle: @MainActor () -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool {
        MainActor.assumeIsolated { a.resolved.key == b.resolved.key && a.record == b.record && a.isCollapsed == b.isCollapsed }
    }

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
                    Spacer(minLength: DetailStyle.pairSpacing)
                    resolved.section.accessory?(record, editor)
                }
                .frame(height: DetailStyle.sectionHeaderHeight)
            }
            // A collapsed section's content isn't built.
            if !isCollapsed || resolved.section.title == nil {
                resolved.section.content(record, editor)
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
            VStack(alignment: .leading, spacing: DetailStyle.smallSpacing) {
                ForEach(statuses.indices, id: \.self) { i in
                    // Only the symbol takes the tone: orange or red text on the bar is hard to read.
                    Label {
                        Text(statuses[i].text).foregroundStyle(statuses[i].tone == .neutral ? .secondary : .primary)
                    } icon: {
                        Image(systemName: statuses[i].tone.symbol).foregroundStyle(statuses[i].tone.color)
                    }
                }
            }
            .padding(.horizontal, DetailStyle.inset)
            .padding(.vertical, DetailStyle.footerPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
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
