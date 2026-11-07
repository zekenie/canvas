import AppKit
import Canvas
import CanvasRPC
import Clipboard
import ContextMenus
import Publishing
import Selection
import SlashCommands

// Stickers, the example kit (Kits.swift, the core's): emoji stickers, off in a file until File ▸ Kits ▸
// Stickers turns them on, and here only until the first real kit lands. What it gives a person to make or
// change a sticker with is a way in the kit switches: four tools (Thumbs Up, Heart, Star and Party), the kit's
// one segment in the toolbar, with their items in Insert ▸ Stickers; `/sticker`, typed in the command bar on
// stickers; Change Sticker ▸ in a sticker's menu; and a paste reader, which turns text of nothing but emoji
// into stickers. The sticker itself (its kind, its look, its resizing, what VoiceOver says of it) is always
// there, so one drawn while the kit was on stays drawn, moved, resized, copied and deleted with it off.

/// The example kit: File ▸ Kits ▸ Stickers.
public enum StickersKit {}

extension StickersKit: Kit {
    public static let id: KitID = "stickers"
    public static var title: String { "Stickers" }
}

extension PluginID {
    public static let stickers: PluginID = "stickers"
}

/// A sticker: an emoji drawn in a square.
public struct Sticker: BoxShapeProps {
    public static let kind: ShapeKind = "emoji-sticker"
    public static let properties = Properties<Sticker>(title: "Sticker") {
        Property("frame", \.frame).required()
        Property("emoji", \.emoji).description("The emoji it shows.").keywords(["minLength": 1])
    }
    public var frame: CGRect
    public var emoji: String

    public init(frame: CGRect, emoji: String) {
        self.frame = frame
        self.emoji = emoji
    }

    /// A thumbs up, the first tool's: what `canvas draw` draws with no emoji said.
    public init() { self.init(frame: .zero, emoji: "👍") }
}

/// On the main actor as a whole, so its drawing shares the protocol's isolation.
@MainActor
struct StickerDefinition {}

/// The emoji, as big as the square holds, in the middle of it; zoomed out, the core's gray square.
extension StickerDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Sticker>, in context: RenderContext) {
        StickersStyle.draw(shape.props.emoji, in: shape.frame)
    }
}

/// Nothing stands for a sticker: it has no name a picker could offer it by, so it's never public.
extension StickerDefinition: NeverPublic {}

public struct StickersPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .stickers }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.join(StickersKit.self)                                    // every way in below is the kit's
        registrar.shape(StickerDefinition()) { sticker in
            sticker.label(StickersStyle.label, systemImage: StickersStyle.symbol)
            // A tool for each, its item in Insert ▸ Stickers, and together the kit's segment in the toolbar.
            for (index, kind) in StickersStyle.stickers.enumerated() {
                let place = sticker.placement(size: StickersStyle.size) { Sticker(frame: .zero, emoji: kind.emoji) }
                sticker.tool(index == 0 ? nil : ToolID("\(Sticker.kind.rawValue)-\(kind.name)"), label: kind.label, systemImage: kind.symbol, placing: place)
            }
            sticker.resizable(minimumSize: StickersStyle.minimumSize)          // eight handles, Selection's
            sticker.accessibility { sticker, _ in AccessibleTraits(value: sticker.props.emoji) }
            // In the command bar, on the stickers selected: one of the four, or any emoji typed.
            sticker.slashCommands {
                SlashCommand.together(StickersStyle.command, argument: StickersStyle.argument,
                                      choices: { _, _ in StickersStyle.choices },
                                      otherwise: { typed, _, _ in StickersStyle.choice(typed: typed) }, step: StickersStyle.step) { ids, choice, editor in
                    editor.setEmoji(of: ids, to: choice.id)
                }
            }
            sticker.contextMenu {
                Submenu(StickersStyle.step) {
                    for kind in StickersStyle.stickers {
                        MenuItem(kind.label, isChecked: { $0.emoji == kind.emoji }, stepName: StickersStyle.step) { ids, editor in
                            editor.setEmoji(of: ids, to: kind.emoji)
                        }
                    }
                }
            }
        }
        // ⌘V of text that is nothing but emoji: a sticker each, in a row.
        registrar.pasteReader(StickersStyle.pasted) { text, _ in StickersStyle.stickers(reading: text) }
    }
}

extension CanvasEditor {
    /// The stickers among `ids` given `emoji`, in one step, Change Sticker.
    func setEmoji(of ids: [ShapeID], to emoji: String) {
        transact(StickersStyle.step) { transaction in
            for id in ids { transaction.update(id, as: Sticker.self) { $0.props.emoji = emoji } }
        }
    }
}

/// The example kit's stickers, words and sizes.
@MainActor
enum StickersStyle {
    /// A sticker each tool puts down: its name in a tool's id, what it's called, its emoji and the symbol
    /// its tool shows.
    struct Kind {
        let name: String
        let label: String
        let emoji: String
        let symbol: String
    }

    static let stickers = [
        Kind(name: "thumbs-up", label: "Thumbs Up", emoji: "👍", symbol: "hand.thumbsup"),
        Kind(name: "heart", label: "Heart", emoji: "❤️", symbol: "heart"),
        Kind(name: "star", label: "Star", emoji: "⭐", symbol: "star"),
        Kind(name: "party", label: "Party", emoji: "🎉", symbol: "party.popper"),
    ]

    /// What the kind is called, and its symbol, wherever a sticker is listed by its kind.
    static let label = "Sticker"
    static let symbol = "face.smiling"
    /// A sticker put down, and the smallest a resize takes it, world units.
    static let size = CGSize(width: 96, height: 96)
    static let minimumSize = CGSize(width: 24, height: 24)
    /// How much of its square the emoji fills.
    static let emojiScale: CGFloat = 0.78
    /// Between two stickers a paste puts down, world units.
    static let gap: CGFloat = 16
    /// The most a paste reads: more emoji than this is text no sticker is made of.
    static let mostPasted = 12

    /// `/sticker`: its name, the hint beside it, and the step it and Change Sticker ▸ make.
    static let command = "sticker"
    static let argument = "emoji"
    static let step = "Change Sticker"
    /// What the paste reader reads, for the registry's report.
    static let pasted = "emoji"

    /// `/sticker`'s rows: the four, each its emoji and name.
    static var choices: [SlashChoice] {
        stickers.map { SlashChoice($0.emoji, title: $0.label, detail: $0.emoji) }
    }

    /// The row for an emoji typed after `/sticker`, nil for anything else.
    static func choice(typed: String) -> SlashChoice? {
        let typed = typed.trimmingCharacters(in: .whitespaces)
        guard typed.count == 1, let character = typed.first, isEmoji(character) else { return nil }
        return SlashChoice(typed, title: typed)
    }

    /// Whether a character is an emoji as a sticker shows one: one drawn as an emoji by itself, or made into
    /// one by what follows it (❤️ is ❤ and a variation selector); never a digit or a letter.
    static func isEmoji(_ character: Character) -> Bool {
        guard let first = character.unicodeScalars.first else { return false }
        return first.properties.isEmojiPresentation || (first.properties.isEmoji && character.unicodeScalars.count > 1)
    }

    /// What a paste of `text` puts down: a sticker for each emoji, in a row, `gap` apart, where the text is
    /// nothing but emoji (spaces and line breaks between them aside), and at most `mostPasted`; nil for any
    /// other text.
    static func stickers(reading text: String) -> CanvasFile? {
        var emoji: [String] = []
        for character in text where !character.isWhitespace {
            guard isEmoji(character), emoji.count < mostPasted else { return nil }
            emoji.append(String(character))
        }
        guard !emoji.isEmpty else { return nil }
        let shapes = emoji.enumerated().map { index, emoji in
            let origin = CGPoint(x: CGFloat(index) * (size.width + gap), y: 0)
            return AnyShapeRecord(ShapeRecord(Sticker(frame: CGRect(origin: origin, size: size), emoji: emoji)))
        }
        return CanvasFile(root: CanvasDocument(shapes: shapes))
    }

    /// Draws `emoji` as big as `frame` holds it, in its middle (string drawing, which the canvas draws in a
    /// flipped graphics context).
    static func draw(_ emoji: String, in frame: CGRect) {
        let text = NSAttributedString(string: emoji, attributes: [.font: NSFont.systemFont(ofSize: min(frame.width, frame.height) * emojiScale)])
        let size = text.size()
        text.draw(at: CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
    }
}
