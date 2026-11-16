import AppKit
import Canvas
import DetailPanel
import Palette
import Queries
import QueryLanguage
import QueryTranslation
import Selection
import SwiftUI
import Titles
import Validation

// Constraints in the Rules tab (Validation's): on a container, the lists it has from elsewhere (each under its source's pill,
// read-only), its own (a row each: the words in a box, the query under it, the reach, ×) and a box that adds one, then the
// shapes inside that break one ("Not accepted"); on a holder (a type), its own rows, the lists it inherits (dimmed, read-only,
// each going to its holder) and the box that adds one. Words typed in a row are turned into a query through the one lifecycle
// every host of words shares (`ConstraintBoxes`).

/// The panel's sections, on the kinds that hold constraints: a container's, and the shapes inside it that break one.
@MainActor
func registerConstraintPanels(into registrar: inout PluginRegistrar) {
    registrar.forShapes(holding: ConstraintsProperty.self) { held in
        held.details {
            DetailSection<AnyShapeRecord>(in: RulesTab.self, id: "constraints") { shape in
                ConstraintsView(record: shape.wrappedValue, index: shape.service(ConstraintIndex.self), boxes: shape.service(ConstraintBoxes.self))
            }
            .shownWhile { shape, context in context.service(ConstraintIndex.self)?.constraints(of: .shape(shape.id)).isEmpty == false }
            DetailSection<AnyShapeRecord>(in: RulesTab.self, id: "not-accepted") { shape in
                NotAcceptedView(place: .shape(shape.shapeID), index: shape.service(ConstraintIndex.self), boxes: shape.service(ConstraintBoxes.self))
            }
            .enabledWhileReadOnly()
            .shownWhile { shape, context in context.service(ConstraintIndex.self)?.breakers(of: .shape(shape.id)).isEmpty == false }
        }
    }
}

extension ConstraintIndex {
    /// What a shape's row in a place's Not accepted list says: the words of the first constraint of the place it breaks, and how many
    /// others of the place it breaks (the Issues tab has each); nil for a shape that breaks none of them.
    public func breakSummary(of id: ShapeID, in place: ConstraintTarget) -> (says: String, more: Int)? {
        let breaches = breaches(of: id).filter { $0.place == place }
        return breaches.first.map { ($0.constraint.says, breaches.count - 1) }
    }

    /// Whether a shape keeps a list its own way now (a type): its Rules tab has its section.
    func isHolder(_ record: AnyShapeRecord) -> Bool { editor?.constraintHolder(of: record) != nil }

    /// The list a shape keeps, as the record has it: a holder's, else its own.
    func list(of record: AnyShapeRecord) -> [Constraint] {
        guard let editor else { return [] }
        return ConstraintWriter.list(of: record, in: editor) ?? []
    }
}

extension ScopedRegistrar {
    /// The section of a holder in its Rules tab, the shapes the scope reaches: its heading, its rows, what it inherits and the
    /// box that adds one. Registered with the holder, so a kind that keeps a list has its rows in the panel with no second call;
    /// it follows in the tab the sections of the plugins registered before it.
    mutating func constraintHolderSection() {
        details {
            DetailSection<AnyShapeRecord>(in: RulesTab.self, id: "holder-constraints") { shape in
                ConstraintHolderView(record: shape.wrappedValue, index: shape.service(ConstraintIndex.self), boxes: shape.service(ConstraintBoxes.self))
            }
            .shownWhile { shape, context in context.service(ConstraintBoxes.self) != nil && (context.service(ConstraintIndex.self)?.isHolder(shape) ?? false) }
        }
    }
}

// MARK: A container's section

/// The lists a container has from elsewhere, each under its source's pill and read-only; then "Own": its own rows and the box
/// that adds one.
struct ConstraintsView: View {
    let record: AnyShapeRecord
    let index: ConstraintIndex?
    let boxes: ConstraintBoxes?

    var body: some View {
        let id = record.id
        let sources = index?.sources(of: .shape(id)) ?? []
        VStack(alignment: .leading, spacing: ConstraintsStyle.sectionSpacing) {
            ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                SourceRows(source: source, boxes: boxes, dimmed: false)
            }
            DetailSectionTitle(ConstraintsStyle.ownHeading(hasSources: !sources.isEmpty))
            if let boxes {
                ConstraintRows(place: .shape(id), constraints: record.ownConstraints, index: index, boxes: boxes)
            }
        }
    }
}

/// A holder's section: its heading, the lists it inherits (dimmed, first), its own rows and the box that adds one.
struct ConstraintHolderView: View {
    let record: AnyShapeRecord
    let index: ConstraintIndex?
    let boxes: ConstraintBoxes?

    var body: some View {
        let id = record.id
        let editor = boxes?.editorLent
        let sources = index?.sources(of: .shape(id)) ?? []
        VStack(alignment: .leading, spacing: ConstraintsStyle.sectionSpacing) {
            // The section's title follows the shape (a section's own is fixed), so the view heads itself, in the look of one.
            if let heading = editor?.constraintHeading(of: id) {
                DetailSectionTitle(heading)
            }
            // The lists from elsewhere come first, as in a frame's section: most general first, then its own.
            ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                SourceRows(source: source, boxes: boxes, dimmed: true)
            }
            if let boxes {
                ConstraintRows(place: .shape(id), constraints: index?.list(of: record) ?? [], index: index, boxes: boxes)
            }
        }
    }
}

// MARK: Rows

/// A list's rows, what goes between them and the box that adds one (a holder's inherited lists go there).
struct ConstraintRows<Between: View>: View {
    let place: ConstraintTarget
    let constraints: [Constraint]
    let index: ConstraintIndex?
    let boxes: ConstraintBoxes
    let between: Between

    init(place: ConstraintTarget, constraints: [Constraint], index: ConstraintIndex?, boxes: ConstraintBoxes, @ViewBuilder between: () -> Between) {
        self.place = place
        self.constraints = constraints
        self.index = index
        self.boxes = boxes
        self.between = between()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ConstraintsStyle.sectionSpacing) {
            // By position, not by value: a write to a row (its reach, its words landing) keeps the row's views, and with them where
            // the keyboard is. A box's draft is by its words, so it keeps up.
            ForEach(Array(constraints.enumerated()), id: \.offset) { number, constraint in
                ConstraintRow(box: ConstraintBox(place: place, constraint: constraint), constraint: constraint, number: number + 1, index: index, boxes: boxes)
            }
            between
            AddConstraintRow(box: ConstraintBox(place: place, constraint: nil), boxes: boxes)
        }
    }
}

extension ConstraintRows where Between == EmptyView {
    init(place: ConstraintTarget, constraints: [Constraint], index: ConstraintIndex?, boxes: ConstraintBoxes) {
        self.init(place: place, constraints: constraints, index: index, boxes: boxes) { EmptyView() }
    }
}

/// One own constraint: its words in a box (which writes on Return or as the keyboard leaves, a change asking for a new query),
/// the query under it, the reach and ×.
struct ConstraintRow: View {
    let box: ConstraintBox
    /// The constraint as the list has it now, which SwiftUI compares as it decides whether the row is drawn again: a box is its
    /// place's and its words (a draft outlives a write to its reach or query), so by `box` alone a row would keep what it was
    /// given, and its × and reach would act on a constraint that has changed since.
    let constraint: Constraint?
    let number: Int
    let index: ConstraintIndex?
    let boxes: ConstraintBoxes

    var body: some View {
        let _ = boxes.revision
        let constraint = box.constraint ?? Constraint()
        VStack(alignment: .leading, spacing: ConstraintsStyle.rowSpacing) {
            HStack(alignment: .top, spacing: ConstraintsStyle.pairSpacing) {
                DetailTextArea(Binding(get: { boxes.text(of: box) }, set: { boxes.typed($0, in: box) }), height: ConstraintsStyle.boxHeight,
                               label: ConstraintsStyle.rowLabel(number), onCommit: { boxes.commit(box) },
                               draft: DetailDraft(isHeld: boxes.hasDraft(box)) { boxes.discard(box) })
                Button { boxes.remove(constraint, from: box.place) } label: { Image(systemName: ConstraintsStyle.removeSymbol) }
                    .buttonStyle(.borderless)
                    .padding(.top, ConstraintsStyle.removeTop)
                    .help(ConstraintsStyle.removeConstraint)
                    .accessibilityLabel(ConstraintsStyle.removeLabel(constraint.says))
            }
            ConstraintQueryLines(box: box, constraint: constraint, index: index, boxes: boxes)
            HStack {
                ReachPicker(constraint: constraint, place: box.place, boxes: boxes)
                Spacer(minLength: 0)
            }
        }
    }
}

/// The box that adds a constraint, and what's asked of the words in it.
struct AddConstraintRow: View {
    let box: ConstraintBox
    let boxes: ConstraintBoxes

    var body: some View {
        let _ = boxes.revision
        VStack(alignment: .leading, spacing: ConstraintsStyle.rowSpacing) {
            DetailTextArea(Binding(get: { boxes.text(of: box) }, set: { boxes.typed($0, in: box) }), height: ConstraintsStyle.boxHeight,
                           placeholder: ConstraintsStyle.addPlaceholder, label: ConstraintsStyle.addPlaceholder, onCommit: { boxes.commit(box) },
                           draft: DetailDraft(isHeld: boxes.hasDraft(box)) { boxes.discard(box) })
            StatusLines(status: boxes.status(of: box), box: box, boxes: boxes)
        }
    }
}

/// What's asked of the words in a box, under it: a spinner while it's asked, the query that came, or why not with its button.
struct StatusLines: View {
    let status: ConstraintBoxStatus
    let box: ConstraintBox
    let boxes: ConstraintBoxes

    var body: some View {
        switch status {
        case .none:
            EmptyView()
        case .interpreting:
            DetailStatusLine(DetailStatus(InterpretationWords.interpreting, tone: .neutral), isBusy: true)
        case .drafted(let query):
            InterpretedQueryView(query, label: ConstraintsStyle.draftQueryLabel)
        case .failed(let failure):
            DetailStatusLine(DetailStatus(failure.words, tone: .warning),
                             actions: failure.action.map { [$0.button(retry: { [weak boxes] in boxes?.retry(box) })] } ?? [])
        case .held(let line), .refused(let line):
            DetailStatusLine(DetailStatus(line, tone: .warning))
        }
    }
}

/// Under a row's words: what's asked of them while they are being interpreted, else the stored query, colored and editable in
/// place as code (with completions), written as the keyboard leaves it if the engine reads it as a stored query, else its
/// refusal under it; for words with no query that nobody is asking about, Interpret.
struct ConstraintQueryLines: View {
    let box: ConstraintBox
    let constraint: Constraint
    let index: ConstraintIndex?
    let boxes: ConstraintBoxes

    var body: some View {
        let status = boxes.status(of: box)
        if status != .none {
            StatusLines(status: status, box: box, boxes: boxes)
        } else if constraint.query != nil {
            StoredQueryBox(query: boxes.shown(constraint) ?? "", constraint: constraint, place: box.place, boxes: boxes,
                           refusal: { if case .refused(let error)? = index?.state(of: constraint) { error.message } else { nil } }())
        } else if boxes.offersInterpret(box) {
            Button(ConstraintsStyle.interpret) { boxes.interpret(box) }
                .buttonStyle(.link)
                .font(.system(size: ConstraintsStyle.captionSize))
        }
    }
}

/// A stored query as code: written as the keyboard leaves it (or ⌘↩) if the engine reads it, else its refusal under it.
struct StoredQueryBox: View {
    let query: String
    let constraint: Constraint
    let place: ConstraintTarget
    let boxes: ConstraintBoxes
    /// Why the engine can't read what is stored, if it can't.
    let refusal: String?
    @State private var editing: String?
    @State private var refused: String?

    var body: some View {
        VStack(alignment: .leading, spacing: ConstraintsStyle.queryGap) {
            DetailCodeEditor(Binding(get: { editing ?? query }, set: { editing = $0 }), height: InterpretationStyle.queryBoxHeight,
                             coloring: QueryColoring.spans, completions: completions, label: ConstraintsStyle.queryLabel(constraint.says)) {
                finishEditing()
            }
            if let line = refused ?? refusal { DetailStatusLine(DetailStatus(line, tone: .warning)) }
        }
    }

    private var completions: DetailCodeCompleting? {
        boxes.editorLent?.queries.map { QueryCompletions.completer(for: $0.vocabulary) }
    }

    private func finishEditing() {
        guard let text = editing else { return }
        let written = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard written != query, !written.isEmpty else {
            editing = nil
            refused = nil
            return
        }
        if let refusal = boxes.write(written, of: constraint, in: place) {
            refused = refusal
        } else {
            editing = nil
            refused = nil
        }
    }
}

/// How far a constraint reaches: a pop-up of Directly inside and Anywhere inside.
struct ReachPicker: View {
    let constraint: Constraint
    let place: ConstraintTarget
    let boxes: ConstraintBoxes

    var body: some View {
        Picker(ConstraintsStyle.reachLabel(constraint.says), selection: Binding(get: { constraint.reach }, set: { boxes.setReach($0, of: constraint, in: place) })) {
            ForEach(ConstraintReach.allCases, id: \.self) { Text($0.schemaTitle).tag($0) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .accessibilityLabel(ConstraintsStyle.reachLabel(constraint.says))
    }
}

// MARK: Lists from elsewhere

/// A list a place has from elsewhere: under its source's pill (the name in the color's wash, a button that goes to the holder),
/// each constraint read-only, its words, its query and its reach. `dimmed` for a holder's: the same rows, quieter.
struct SourceRows: View {
    let source: ConstraintSource
    let boxes: ConstraintBoxes?
    let dimmed: Bool
    /// What the pill's click does, if not going to the holder (see `NotAcceptedView.onGo`).
    var onGo: (@MainActor ([ShapeID]) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: ConstraintsStyle.rowSpacing) {
            Button { if let onGo { onGo([source.holder]) } else { boxes?.go(to: [source.holder]) } } label: { pill }
                .buttonStyle(.borderless)
                .accessibilityLabel(name)
            ForEach(source.constraints, id: \.self) { constraint in
                InheritedRow(constraint: constraint, shown: boxes?.shown(constraint), from: name, dimmed: dimmed)
            }
        }
    }

    /// What the holder is called now.
    private var name: String { boxes?.editorLent?.constraintSourceName(of: source.holder) ?? ConstraintsStyle.untitled }

    @ViewBuilder private var pill: some View {
        if let swatch = source.swatch {
            Text(name)
                .font(.system(size: ConstraintsStyle.pillSize))
                .foregroundStyle(Color(nsColor: NSColor(swatch.ink)))
                .padding(.horizontal, ConstraintsStyle.pillPadding.width)
                .padding(.vertical, ConstraintsStyle.pillPadding.height)
                .background(Capsule().fill(Color(nsColor: NSColor(swatch.wash))))
        } else {
            Text(name).font(.system(size: ConstraintsStyle.pillSize)).foregroundStyle(.secondary)
        }
    }
}

/// A constraint from elsewhere: its words, then its query (read-only, a stop named for the words) and its reach as text, none of it
/// editable; the same look under a frame's pill and under a type's, dimmed under a type's.
struct InheritedRow: View {
    let constraint: Constraint
    /// Its query as read now (`ConstraintBoxes.shown`); its own where nothing shows it.
    let shown: String?
    let from: String?
    let dimmed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: ConstraintsStyle.rowSpacing) {
            Text(constraint.says).foregroundStyle(dimmed ? .secondary : .primary).fixedSize(horizontal: false, vertical: true)
            if let query = shown ?? constraint.query {
                InterpretedQueryView(query, label: ConstraintsStyle.queryLabel(constraint.says)).opacity(dimmed ? ConstraintsStyle.dimmedOpacity : 1)
            }
            Text(constraint.reach.schemaTitle).font(.system(size: ConstraintsStyle.captionSize)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ConstraintsStyle.inherited(constraint.says, reach: constraint.reach.schemaTitle, from: from))
    }
}

// MARK: Not accepted

/// The shapes inside that break a constraint, a row each: the kind's symbol in its tint, the shape's title or its kind, and the
/// constraint it breaks at the right. A click or Return goes to the shape, and the pointer over a row lights it on the board.
struct NotAcceptedView: View {
    let place: ConstraintTarget
    let index: ConstraintIndex?
    let boxes: ConstraintBoxes?
    /// What a click or Return does: goes to the shape (the panel's; the canvas part the panes leave clear shows it), or what the host
    /// of the view says (the board's popover, which is over the shapes, gives way first).
    var onGo: (@MainActor ([ShapeID]) -> Void)?

    /// One row of the list.
    private struct Row {
        let id: ShapeID
        let symbol: String
        let tint: NSColor?
        let name: String
        /// The first constraint of the place it breaks, and how many others of it.
        let breaks: String?
        let more: Int
    }

    var body: some View {
        if let index, let boxes, let editor = boxes.editorLent {
            let rows = rows(index: index, editor: editor, place: place)
            let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            VStack(alignment: .leading, spacing: ConstraintsStyle.sectionSpacing) {
                HStack(spacing: ConstraintsStyle.rowSpacing) {
                    DetailSectionTitle(ConstraintsStyle.notAcceptedHeading)
                    DetailSectionTitle("\(rows.count)", isHeader: false).foregroundStyle(.secondary)
                }
                DetailRowList(rows.map { row in DetailRowItem(id: row.id) { go([row.id], boxes) } }, label: ConstraintsStyle.notAcceptedList,
                              onHighlight: { id in editor.hovered = id }) { item in
                    if let row = byID[item.id] {
                        DetailShapeRow(symbol: row.symbol, tint: row.tint, name: row.name,
                                       detail: row.breaks.map { ConstraintsStyle.breakDetail($0, more: row.more).words }, detailTruncation: .tail,
                                       detailCount: row.breaks.flatMap { ConstraintsStyle.breakDetail($0, more: row.more).count })
                            .onHover { inside in
                                if inside { editor.hovered = row.id } else if editor.hovered == row.id { editor.hovered = nil }
                            }
                            .detailRowAccessibility(label: row.breaks.map { ConstraintsStyle.breaks(row.name, $0, more: row.more) } ?? row.name) { go([row.id], boxes) }
                    }
                }
            }
        }
    }

    private func go(_ ids: [ShapeID], _ boxes: ConstraintBoxes) {
        if let onGo { onGo(ids) } else { boxes.go(to: ids) }
    }

    /// A row each, by name, so the list holds still as shapes come and go.
    private func rows(index: ConstraintIndex, editor: CanvasEditor, place: ConstraintTarget) -> [Row] {
        editor.withoutObservingDocument {
            index.breakers(of: place).compactMap { id -> Row? in
                guard let record = editor.shape(inFile: id) else { return nil }
                let label = editor.registry.label(of: record.kind)
                let summary = index.breakSummary(of: id, in: place)
                return Row(id: id, symbol: label.systemImage ?? ConstraintsStyle.fallbackSymbol, tint: editor.tint(of: record) ?? label.tint,
                           name: editor.registry.title(of: record) ?? label.name, breaks: summary?.says, more: summary?.more ?? 0)
            }
            .sorted { ($0.name.lowercased(), $0.id.description) < ($1.name.lowercased(), $1.id.description) }
        }
    }
}
