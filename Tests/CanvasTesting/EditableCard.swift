import AppKit
@_spi(Host) import Canvas

public struct Card: BoxShapeProps {
    public static let kind: ShapeKind = "card"
    public static let properties = Properties<Card> {
        Property("frame", \.frame).required()
        Property("text", \.text)
    }
    public var frame: CGRect
    public var text: String
    public init(_ frame: CGRect, text: String = "") {
        self.frame = frame
        self.text = text
    }
}

extension Card {
    public init() { self.init(.zero) }
}

public struct CardDefinition {}

extension CardDefinition: ShapeDefinition, Editable {
    public func render(_ shape: ShapeRecord<Card>, in context: RenderContext) {}
    public func makeEditingView(for shape: ShapeRecord<Card>, context: EditContext<Card>) -> EditingView {
        let view = CardField(text: shape.props.text, context: context)
        return EditingView(view: view, firstResponder: view)
    }
}

/// The card's editing view: a text field that saves its text when editing ends, as an editor does
/// (in a window; with no window, editing never starts or ends). It keeps its context, so tests can
/// also write through it.
public final class CardField: NSTextField, NSTextFieldDelegate {
    public let context: EditContext<Card>
    public private(set) var saves = 0
    init(text: String, context: EditContext<Card>) {
        self.context = context
        super.init(frame: .zero)
        stringValue = text
        delegate = self
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func controlTextDidEndEditing(_ notification: Notification) {
        saves += 1
        context.update { $0.text = stringValue }
    }
}

/// A "card" kind that's editable, with a place tool (no key: CanvasTesting can't import Keyboard, so
/// a test that types one registers it). `optIn` adds what a test needs
/// (`CardsPlugin { card, place in card.createOnDoubleClick(place) }`), given the place tool's
/// placement.
public struct CardsPlugin: CanvasPlugin {
    let optIn: @MainActor (inout ShapeRegistrar<CardDefinition>, Placement) -> Void
    public init(_ optIn: @escaping @MainActor (inout ShapeRegistrar<CardDefinition>, Placement) -> Void = { _, _ in }) {
        self.optIn = optIn
    }
    public var id: PluginID { "cards" }
    public func register(into registrar: inout PluginRegistrar) {
        registrar.shape(CardDefinition()) { card in
            let place = card.editingPlacement(size: CGSize(width: 100, height: 60)) { Card(.zero) }
            card.tool(label: "Card", systemImage: "rectangle", placing: place)
            optIn(&card, place)
        }
    }
}
