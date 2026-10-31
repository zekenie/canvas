import AppKit
import Canvas
import CanvasRPC
import DecisionModels
import DetailPanel
import Mentions
import SwiftUI
import Types
import Validation

// Rules in the panel: a type's Rules tab (its sentences, each editable, with the count of shapes it flags; the rules
// it inherits, dimmed; a box to add one), and a checked shape's Rules section in the Issues tab (each rule of its
// chain with what its check says, and Shown: what the model was shown, group by group).

/// A type's rules: on every shape that holds a schema, after its Schema.
public enum RulesTab {}

extension RulesTab: DetailTab {
    public static var title: String { RulesStyle.tab }
    public static var order: Order<Self> { .after(TypeSchemaTab.self) }
}

@MainActor
func registerRulePanels(into registrar: inout PluginRegistrar) {
    registrar.forShapes(holding: TypeSchemaProperty.self) { types in
        types.details {
            DetailSection<AnyShapeRecord>(in: RulesTab.self, id: "rules") { shape in
                TypeRulesView(record: shape.wrappedValue, checks: shape.service(RuleChecks.self), chips: shape.service(RuleChips.self),
                              lights: shape.service(RuleLights.self), index: shape.service(TypeIndex.self), mentions: shape.service(MentionState.self),
                              editor: shape.service(RuleChips.self)?.editorLent)
            }
            .shownWhile { shape, _ in shape[TypeSchemaProperty.self] != nil }
        }
    }
    registrar.forShapes(holding: IgnoredRulesProperty.self) { checked in
        checked.details {
            DetailSection<AnyShapeRecord>(RulesStyle.rules, in: IssuesTab.self, id: "rules") { shape in
                ShapeRulesView(record: shape.wrappedValue, checks: shape.service(RuleChecks.self), writer: shape.service(RuleWriter.self),
                               lights: shape.service(RuleLights.self))
            }
            .enabledWhileReadOnly()
            // Observed by the shape, so the section comes as the shape is first marked, with no commit to it.
            .shownWhile { shape, context in context.service(RuleChecks.self)?.hasCheck(shape.id) ?? false }
        }
    }
}

// MARK: A type's Rules tab

/// A type's own rules, each a box that writes on Return or as the keyboard leaves (one step, Change Rules; emptied, the
/// rule goes; `@` makes a chip of a shape or of words), with the count of shapes it flags beside it, which begins the
/// rule's walk and lights them while it's under the pointer or has the keyboard, and under it a line for each chip, what it found
/// for a sample; then the rules it inherits, dimmed, each going to its type; then a box that adds one. A line says why,
/// while checks fail.
struct TypeRulesView: View {
    let record: AnyShapeRecord
    let checks: RuleChecks?
    let chips: RuleChips?
    let lights: RuleLights?
    let index: TypeIndex?
    let mentions: MentionState?
    let editor: CanvasEditor?

    var body: some View {
        let _ = index?.observeChanges()
        let type = record.id
        let rules = record[TypeSchemaProperty.self].map { RuleBook.rules(inSchema: $0.text) } ?? []
        let inherited = inheritedRules(of: type)
        VStack(alignment: .leading, spacing: 8) {
            if !rules.isEmpty || !inherited.isEmpty, let failure = checks?.failure {
                DetailStatusLine(DetailStatus(failure.message, tone: .warning), actions: actions(for: failure))
            }
            ForEach(Array(rules.enumerated()), id: \.offset) { i, rule in
                let box = RuleBox(type: type, index: i)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 6) {
                        RuleTextArea(box: box, stored: rule, label: RulesStyle.rule(i + 1), placeholder: nil, chips: chips, mentions: mentions)
                        let key = RuleKey(type: type, says: rule.says)
                        FlagCount(key: key, ids: checks?.flagged(by: key) ?? [], lights: lights)
                    }
                    RuleChipLines(rule: chips?.rule(in: box, stored: rule) ?? rule, type: type, chips: chips, lights: lights, editor: editor)
                }
            }
            ForEach(Array(inherited.enumerated()), id: \.offset) { _, rule in
                InheritedRule(rule: rule, lights: lights)
            }
            let adding = RuleBox(type: type, index: nil)
            RuleTextArea(box: adding, stored: nil, label: RulesStyle.addRule, placeholder: RulesStyle.addRule, chips: chips, mentions: mentions)
            if let draft = chips?.rule(in: adding, stored: nil), !draft.find.isEmpty {
                RuleChipLines(rule: draft, type: type, chips: chips, lights: lights, editor: editor)
            }
        }
    }

    /// The rules along the type's own chain, but its own: most general first, as a shape of it is checked.
    private func inheritedRules(of type: ShapeID) -> [ChainedRule] {
        guard let index else { return [] }
        return index.lineage(of: type).filter { $0 != type && index.isType($0) }.reversed().flatMap { ancestor -> [ChainedRule] in
            let name = index.name(of: ancestor) ?? RulesStyle.untitled
            return (checks?.rules(ofType: ancestor) ?? []).map { ChainedRule(rule: $0, type: ancestor, typeName: name) }
        }
    }

    private func actions(for failure: DecisionModelError) -> [DetailStatusAction] {
        if failure.needsKey { return [DetailStatusAction(RulesStyle.openSettings) { _ = TypeSafeSettingsView.showSettings() }] }
        return [DetailStatusAction(RulesStyle.retry) { [weak checks] in checks?.retry() }]
    }
}

@MainActor
enum RuleBoxStyle {
    /// A rule's box: two lines of the panel's text.
    static let height: CGFloat = 40
    /// The count's column.
    static let countWidth: CGFloat = 26
    /// A chip's line under its rule, in from the box's edge.
    static let lineIndent: CGFloat = 4
}

/// How many shapes a rule flags: a button that begins the rule's walk at its first stop (Validation's issue walk, narrowed to
/// the rule: the band, the list and the shape's Issues tab), lighting the shapes while it's under the pointer or has the
/// keyboard. It no longer selects them (Select Flagged ▸ does). Nothing while it flags none.
struct FlagCount: View {
    let key: RuleKey
    let ids: Set<ShapeID>
    let lights: RuleLights?
    @FocusState private var hasKeyboard: Bool

    var body: some View {
        Group {
            if ids.isEmpty {
                Color.clear.frame(height: 1)
            } else {
                let shapes = Array(ids)
                Button { lights?.walk(key, at: .first, orGoTo: shapes) } label: {
                    Text("\(ids.count)").monospacedDigit().foregroundStyle(Color(nsColor: .systemOrange))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(RulesStyle.flags(ids.count))
                .focused($hasKeyboard)
                // Return as well as a click: a button answers Space, and Return only as the default (P6).
                .onKeyPress(.return) {
                    lights?.walk(key, at: .first, orGoTo: shapes)
                    return .handled
                }
                .onHover { inside in lights?.light(inside ? shapes : nil, by: RulesStyle.tab) }
                .onChange(of: hasKeyboard) { _, now in lights?.light(now ? shapes : nil, by: RulesStyle.tab) }
                // Gone while lit (its click begins the walk, which shows another tab): what it lit goes with it.
                .onDisappear { lights?.light(nil, by: RulesStyle.tab) }
            }
        }
        .frame(width: RuleBoxStyle.countWidth, alignment: .trailing)
        .padding(.top, 3)
    }
}

/// A rule the type has from one it builds on: its sentence dimmed and "from Car", going to that type.
struct InheritedRule: View {
    let rule: ChainedRule
    let lights: RuleLights?

    var body: some View {
        Button { lights?.go(to: [rule.type]) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.rule.says).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(RulesStyle.from(rule.typeName)).font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(RulesStyle.inherited(rule.rule.says, from: rule.typeName))
    }
}

// MARK: A checked shape's Rules section

/// Each rule of the shape's chain, most general first, with what its check says of it (flags, holds, unsure, ignored,
/// checking) and its type; Stop Ignoring under an ignored one; a line while its check failed; then Shown, the groups
/// of what the model was shown, one stop of Tab, a highlighted line lighting its shapes and Return going to them.
struct ShapeRulesView: View {
    let record: AnyShapeRecord
    let checks: RuleChecks?
    let writer: RuleWriter?
    let lights: RuleLights?
    @State private var folded: Set<Int> = []

    var body: some View {
        let id = record.id
        let standings = checks?.verdicts(of: record) ?? []
        let check = checks?.check(of: id)
        VStack(alignment: .leading, spacing: 8) {
            if case .failed(let error, _)? = check {
                DetailStatusLine(DetailStatus(error.message, tone: .warning), actions: actions(for: error))
            }
            // A check that failed before any answer has nothing to say of each rule.
            if !Self.failedFirst(check) {
                ForEach(Array(standings.enumerated()), id: \.offset) { _, standing in
                    RuleLine(standing: standing, look: lights?.look(of: standing.rule.type)) { [weak writer] in
                        writer?.stopIgnoring(standing.rule.rule.says, on: id)
                    }
                }
            }
            if let sent = checks?.sent(for: id), !sent.groups.isEmpty {
                Text(RulesStyle.shown).foregroundStyle(.secondary).padding(.top, 4)
                ShownList(groups: sent.groups, lights: lights, folded: $folded)
            }
        }
    }

    private func actions(for error: DecisionModelError) -> [DetailStatusAction] {
        if error.needsKey { return [DetailStatusAction(RulesStyle.openSettings) { _ = TypeSafeSettingsView.showSettings() }] }
        return [DetailStatusAction(RulesStyle.retry) { [weak checks] in checks?.retry() }]
    }

    private static func failedFirst(_ check: RuleCheck?) -> Bool {
        if case .failed(_, nil)? = check { true } else { false }
    }
}

/// One rule of a shape: a symbol for a rule that flags (a spinner while checking), its sentence and its type, and its
/// state at the right; Stop Ignoring under an ignored one.
struct RuleLine: View {
    let standing: RuleStanding
    let look: (ink: NSColor, fill: NSColor)?
    let stopIgnoring: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Group {
                    switch standing.state {
                    case .flags: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(nsColor: .systemOrange))
                    case .checking: ProgressView().controlSize(.mini)
                    default: Color.clear.frame(height: 1)
                    }
                }
                .frame(width: 14)
                VStack(alignment: .leading, spacing: 3) {
                    Text(standing.rule.rule.says).fixedSize(horizontal: false, vertical: true)
                    Text(standing.rule.typeName)
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: look?.ink ?? .secondaryLabelColor))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color(nsColor: look?.fill ?? .quaternaryLabelColor)))
                }
                Spacer(minLength: 4)
                Text(RulesStyle.word(standing.state)).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(standing.rule.rule.says), \(standing.rule.typeName), \(RulesStyle.word(standing.state))")
            if standing.state == .ignored {
                Button(RulesStyle.stopIgnoring, action: stopIgnoring).buttonStyle(.link).padding(.leading, 20)
            }
        }
    }
}

/// A line of Shown: a group's head, or a row of it.
enum ShownLine: Hashable, Sendable {
    case head(Int)
    case row(Int, Int)
}

/// What the model was shown, group by group: one list, one stop of Tab; a group's head folds it (← →), a highlighted
/// line lights its shapes, Return on a row goes to its shape.
struct ShownList: View {
    let groups: [RuleShownGroup]
    let lights: RuleLights?
    @Binding var folded: Set<Int>

    var body: some View {
        let items = items()
        DetailRowList(items, label: RulesStyle.shown, onHighlight: { line in highlight(line) }) { item in
            switch item.id {
            case .head(let g):
                let isFolded = folded.contains(g)
                DetailGroupHeader(groups[g].label, count: count(of: g), tint: IssueWalkStyle.light, isCollapsed: isFolded, isRow: true) {}
                    .detailRowAccessibility(label: groups[g].label, value: DetailGroupHeader.spoken(count: count(of: g), isCollapsed: isFolded),
                                            activate: item.activate)
            case .row(let g, let r):
                let line = lights?.line(groups[g], r, isType: groups[g].label == "its types")
                    ?? ShownRow(symbol: "square", name: "", detail: nil, caption: nil)
                DetailShapeRow(symbol: line.symbol, name: line.name, detail: line.detail, lines: line.caption.map { [$0] } ?? [])
                    .detailRowAccessibility(label: [line.name, line.detail, line.caption].compactMap { $0 }.joined(separator: ", "), activate: item.activate)
            }
        }
    }

    private func count(of g: Int) -> Int { groups[g].place != nil && groups[g].shapes.isEmpty ? 1 : groups[g].shapes.count }

    private func items() -> [DetailRowItem<ShownLine>] {
        var items: [DetailRowItem<ShownLine>] = []
        for (g, group) in groups.enumerated() {
            let isFolded = folded.contains(g)
            items.append(DetailRowItem(id: .head(g), kind: .head(isFolded: isFolded)) {
                if folded.contains(g) { folded.remove(g) } else { folded.insert(g) }
            })
            guard !isFolded else { continue }
            let rows = group.shapes.isEmpty && group.place != nil ? 1 : group.shapes.count
            for r in 0..<rows {
                let shape = group.shapes.indices.contains(r) ? group.shapes[r] : nil
                let captioned = group.label == "its types"
                items.append(DetailRowItem(id: .row(g, r), parent: .head(g), height: captioned ? DetailRowItem<ShownLine>.height(captionLines: 1) : nil) {
                    if let shape { lights?.go(to: [shape]) }
                })
            }
        }
        return items
    }

    private func highlight(_ line: ShownLine?) {
        switch line {
        case .head(let g)?: lights?.light(groups[g].shapes, by: RulesStyle.shown)
        case .row(let g, let r)?: lights?.light(groups[g].shapes.indices.contains(r) ? [groups[g].shapes[r]] : [], by: RulesStyle.shown)
        case nil: lights?.light(nil, by: RulesStyle.shown)
        }
    }
}

/// A row of Shown as drawn.
struct ShownRow {
    let symbol: String
    let name: String
    let detail: String?
    let caption: String?
}
