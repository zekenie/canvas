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

    /// The grid for what `model` shows, telling `choose` what was picked.
    public init(model: ColorRowModel, choose: @escaping (ColorChoice) -> Void) {
        self.model = model
        self.choose = choose
    }

    /// What is being named: a new color (the value the shape holds), or one of the file's.
    private enum Naming: Equatable {
        case new
        case renaming(NamedColor)
    }
    @State private var naming: Naming?

    public var body: some View {
        switch naming {
        case .new:
            ColorNameForm(button: ColorsStyle.add, name: "", refusal: { model.refusal(ofName: $0) }) { choose(.name($0)) }
        case .renaming(let named):
            ColorNameForm(button: ColorsStyle.rename, name: named.name, refusal: { model.refusal(ofName: $0, renaming: named) }) {
                choose(.rename(named, to: $0))
            }
        case nil:
            choices
        }
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: ColorsStyle.groupSpacing) {
            ForEach(Array(model.groups.enumerated()), id: \.offset) { _, group in
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(ColorsStyle.dot + 2 * ColorsStyle.ringGap + 2 * ColorsStyle.ringWidth),
                                                              spacing: ColorsStyle.gridSpacing), count: ColorsStyle.dotsPerRow),
                          spacing: ColorsStyle.gridSpacing) {
                    ForEach(group, id: \.name) { named in
                        let isRinged = model.isRinged(named)
                        Button { choose(.color(model.writes(dot: named))) } label: {
                            ColorDot(tone: Tone(named.value))
                                .padding(ColorsStyle.ringGap + ColorsStyle.ringWidth)
                                .overlay { if isRinged { Circle().strokeBorder(.primary, lineWidth: ColorsStyle.ringWidth) } }
                        }
                        .buttonStyle(.plain)
                        .help(named.name)
                        .accessibilityLabel(named.name)
                        .accessibilityAddTraits(isRinged ? .isSelected : [])
                        .contextMenu {
                            // A color of the file's is the file's to change; a built-in one has no menu.
                            if !named.isBuiltIn {
                                Button(ColorsStyle.renameColorItem) { naming = .renaming(named) }
                                Button(ColorsStyle.changeColorItem) { choose(.changeValue(named)) }
                                Button(ColorsStyle.removeColorItem) { choose(.remove(named)) }
                            }
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                row(ColorsStyle.none) { choose(.color(model.writesNone)) }
                row(ColorsStyle.other) { choose(.other) }
                if model.nameable != nil { row(ColorsStyle.nameColor) { naming = .new } }
            }
        }
        .padding(ColorsStyle.popoverInset)
    }

    private func row(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(ColorsStyle.font)
                .frame(maxWidth: .infinity, minHeight: ColorsStyle.popoverRowHeight, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A name for a color, in the grid's place: a field and one button, dimmed while the name can't be
/// given (empty, taken, a built-in one's). Return gives it.
private struct ColorNameForm: View {
    let button: String
    @State var name: String
    let refusal: (String) -> ColorNameRefusal?
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
    }

    private func give() {
        if refusal(name) == nil { submit(name) }
    }
}
