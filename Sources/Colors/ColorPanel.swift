import AppKit
import Canvas
import DetailPanel
import Observation
import Palette
import SwiftUI

/// The panel's Color row, on every kind that has colors: a plugin value of its own, so a list
/// without the detail panel leaves it out.
public struct ColorDetailsPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { "color-details" }

    public func register(into registrar: inout PluginRegistrar) {
        // On the kinds that have colors, over the whole record: a shape with no color of its own holds no
        // value, so a section over the property's value would leave it out.
        registrar.forShapes(holding: ColorProperty.self) { colorable in
            colorable.details {
                // No header: the row's own label says what it is, so the color costs the panel one line.
                DetailSection(in: StyleTab.self, id: ColorsStyle.color) { $record in ColorRow(record: $record) }
                    .named(ColorsStyle.color)
            }
        }
    }
}

/// A color as a small filled circle with a hairline around it; nothing inside for none.
private struct ColorDot: View {
    let tone: Tone?
    var body: some View {
        Circle()
            .fill(tone.map { Color(nsColor: NSColor($0)) } ?? .clear)
            .overlay(Circle().strokeBorder(.primary.opacity(ColorsStyle.dotHairline)))
            .frame(width: ColorsStyle.dot, height: ColorsStyle.dot)
    }
}

/// The row: the color as a dot and its name, which opens the grid.
struct ColorRow: View {
    @ShapeBinding var record: AnyShapeRecord
    @State private var isOpen = false

    var body: some View {
        if let book = $record.service(ColorBook.self) {
            let model = ColorRowModel(record: record, book: book)
            let color = $record[ColorProperty.self]
            LabeledContent(ColorsStyle.color) {
                Button { isOpen = true } label: {
                    HStack(spacing: ColorsStyle.rowSpacing) {
                        ColorDot(tone: model.tone)
                        Text(model.title).font(ColorsStyle.font).opacity(model.isDimmed ? ColorsStyle.dimmed : 1).lineLimit(1)
                        Spacer(minLength: ColorsStyle.rowGap)
                        Image(systemName: "chevron.up.chevron.down").font(ColorsStyle.chevron).foregroundStyle(.secondary)
                    }
                    .frame(minHeight: ColorsStyle.rowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(ColorsStyle.color)
                .accessibilityValue(model.title)
                .popover(isPresented: $isOpen, arrowEdge: .bottom) {
                    ColorGrid(model: model) { choice in
                        isOpen = false
                        model.apply(choice, to: color)
                    }
                }
            }
            // The system color panel floats on after the row shows another shape, or none.
            .onChange(of: record.id) { old, _ in ColorPanelTarget.release(old) }
            .onDisappear { ColorPanelTarget.release(record.id) }
        }
    }
}

/// The named colors as dots, the built-in ones, then the file's under them, and under those the
/// plain rows; or, while a color is being named, a field in their place.
public struct ColorGrid: View {
    let model: ColorRowModel
    let choose: (ColorChoice) -> Void

    /// The grid for what `model` shows, telling `choose` what was picked. `state` is what a test reads
    /// the grid's levels from.
    public init(model: ColorRowModel, state: ColorGridState = ColorGridState(), choose: @escaping (ColorChoice) -> Void) {
        self.model = model
        self.choose = choose
        _state = State(initialValue: state)
    }

    @State private var state: ColorGridState
    @FocusState private var focus: ColorGridStop?

    public var body: some View {
        switch state.naming {
        case .new:
            ColorNameForm(button: ColorsStyle.add, name: "", refusal: { model.refusal(ofName: $0) }, back: { state.escape() }) { choose(.name($0)) }
        case .renaming(let named):
            ColorNameForm(button: ColorsStyle.rename, name: named.name, refusal: { model.refusal(ofName: $0, renaming: named) },
                          back: { state.escape() }) {
                choose(.rename(named, to: $0))
            }
        case nil:
            choices
        }
    }

    /// The plain rows under the dots, in order.
    private var plainRows: [(title: String, action: () -> Void)] {
        var rows: [(title: String, action: () -> Void)] = [
            (ColorsStyle.none, { choose(.color(model.writesNone)) }),
            (ColorsStyle.other, { choose(.other) }),
        ]
        if model.nameable != nil { rows.append((ColorsStyle.nameColor, { state.naming = .new })) }
        return rows
    }

    private var map: ColorGridMap { ColorGridMap(groups: model.groups.map(\.count), rows: plainRows.count) }

    /// The dot the shape's color rings, where the keyboard starts.
    private var ringedStop: ColorGridStop? {
        for (group, colors) in model.groups.enumerated() {
            if let index = colors.firstIndex(where: model.isRinged) { return .dot(group: group, index: index) }
        }
        return nil
    }

    private func move(_ direction: ColorGridMap.Direction) {
        guard let focus else { return }
        self.focus = map.move(direction, from: focus)
    }

    /// Return or Space on the stop the keyboard is at.
    private func chooseFocused() -> KeyPress.Result {
        switch focus {
        case .dot(let group, let index)?:
            guard model.groups.indices.contains(group), model.groups[group].indices.contains(index) else { return .ignored }
            choose(.color(model.writes(dot: model.groups[group][index])))
        case .row(let row)?:
            guard plainRows.indices.contains(row) else { return .ignored }
            plainRows[row].action()
        case nil: return .ignored
        }
        return .handled
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: ColorsStyle.groupSpacing) {
            ForEach(Array(model.groups.enumerated()), id: \.offset) { groupIndex, group in
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(ColorsStyle.dot + 2 * ColorsStyle.ringGap + 2 * ColorsStyle.ringWidth),
                                                              spacing: ColorsStyle.gridSpacing), count: ColorsStyle.dotsPerRow),
                          spacing: ColorsStyle.gridSpacing) {
                    ForEach(Array(group.enumerated()), id: \.element.name) { index, named in
                        let isRinged = model.isRinged(named)
                        let stop = ColorGridStop.dot(group: groupIndex, index: index)
                        Button { choose(.color(model.writes(dot: named))) } label: {
                            ColorDot(tone: Tone(named.value))
                                .padding(ColorsStyle.ringGap + ColorsStyle.ringWidth)
                                .overlay { if isRinged { Circle().strokeBorder(.primary, lineWidth: ColorsStyle.ringWidth) } }
                                .overlay { if focus == stop { Circle().strokeBorder(Color.accentColor, lineWidth: ColorsStyle.focusWidth) } }
                        }
                        .buttonStyle(.plain)
                        .focusable()
                        .focusEffectDisabled()
                        .focused($focus, equals: stop)
                        .help(named.name)
                        .accessibilityLabel(named.name)
                        .accessibilityAddTraits(isRinged ? .isSelected : [])
                        .contextMenu {
                            // A color of the file's is the file's to change; a built-in one has no menu.
                            if !named.isBuiltIn {
                                Button(ColorsStyle.renameColorItem) { state.naming = .renaming(named) }
                                Button(ColorsStyle.changeColorItem) { choose(.changeValue(named)) }
                                Button(ColorsStyle.removeColorItem) { choose(.remove(named)) }
                            }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(plainRows.enumerated()), id: \.offset) { index, item in
                    row(item.title, stop: .row(index), action: item.action)
                }
            }
        }
        .padding(ColorsStyle.popoverInset)
        .focusSection()
        .onMoveCommand { direction in
            switch direction {
            case .left: move(.left)
            case .right: move(.right)
            case .up: move(.up)
            case .down: move(.down)
            @unknown default: break
            }
        }
        .onKeyPress(.return) { chooseFocused() }
        .onKeyPress(.space) { chooseFocused() }
        .onAppear { focus = map.start(ringed: ringedStop) }
    }

    private func row(_ title: String, stop: ColorGridStop, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(ColorsStyle.font)
                .frame(maxWidth: .infinity, minHeight: ColorsStyle.popoverRowHeight, alignment: .leading)
                .contentShape(Rectangle())
                .overlay(alignment: .leading) {
                    if focus == stop { RoundedRectangle(cornerRadius: 3).strokeBorder(Color.accentColor, lineWidth: ColorsStyle.focusWidth) }
                }
        }
        .buttonStyle(.plain)
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: stop)
    }
}

/// A name for a color, in the grid's place: a field and one button, dimmed while the name can't be
/// given (empty, taken, a built-in one's). Return gives it.
private struct ColorNameForm: View {
    let button: String
    @State var name: String
    let refusal: (String) -> ColorNameRefusal?
    /// Escape: back to the grid, keeping nothing of the name.
    let back: () -> Void
    let submit: (String) -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: ColorsStyle.rowSpacing) {
            TextField(ColorsStyle.namePlaceholder, text: $name)
                .textFieldStyle(.roundedBorder)
                .font(ColorsStyle.font)
                .frame(width: ColorsStyle.nameFieldWidth)
                .focused($isFocused)
                .onSubmit(give)
            Button(button, action: give).disabled(refusal(name) != nil)
        }
        .padding(ColorsStyle.popoverInset)
        .onAppear { isFocused = true }
        .onExitCommand(perform: back)
    }

    private func give() {
        if refusal(name) == nil { submit(name) }
    }
}
