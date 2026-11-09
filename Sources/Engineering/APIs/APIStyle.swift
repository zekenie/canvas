import AppKit
import Palette

/// An API's look at rest, beside the kit's own (`KitStyle`): its paper is a table's, its first line the server (where it's
/// served in grey code, a lock and how a client signs in at the right, a hairline under it), then a row an endpoint, 24 apart:
/// its method in a chip of the method's color, its path in code with its parameters in the chip's color, and at the right its
/// body's pill, an arrow, its first response's status and its type's pill (the path cut short first); a path-prefix header a
/// row of its own, a chevron and the prefix, its endpoints' count at the right, the endpoints under it indented. World units.
/// The colors are Palette's of the frames' hues, made to read on the paper (decided 25): a chip's white text at 4.5, a
/// parameter's color as text at 4.5 on the paper.
@MainActor
enum APIStyle {
    static let label = "API"
    static let symbol = "arrow.right.to.line.compact"
    /// Its row in the table of contents and its panel's header while it has no title.
    static let placeholder = "Untitled API"
    /// A new API's width.
    static let width: CGFloat = 420
    /// The narrowest it's resized to.
    static let minimumWidth: CGFloat = 200
    /// The widest a pasted API is made for its rows to show whole (`APIDrawing.wholeWidth`): past it, paths are cut short.
    static let mostWholeWidth: CGFloat = 760
    /// What a pasted OpenAPI file with no title (and no file name) is called.
    static let pastedTitle = "API"
    /// What the type notes a pasted OpenAPI file puts down are called where the paste is announced.
    static let pastedTypeLabel = "Type"
    /// The status a response with a type leaves out on its row: the type says it (`→ Statement`), where a response of none says
    /// `→ 200`.
    static let plainStatus = "200"
    /// A type note a paste makes is this wide, and as tall as its rows are (this, and a row's height, and the room above and
    /// below them), not the note's default size.
    static let pastedTypeWidth: CGFloat = 240
    static let pastedTypeRowHeight: CGFloat = 22
    static let pastedTypePad: CGFloat = 14
    /// What its rows are, said by VoiceOver: "7 endpoints".
    static func accessibleRows(_ count: Int) -> String { count == 1 ? "1 endpoint" : "\(count.formatted()) endpoints" }
    /// What VoiceOver calls the field its name is typed in.
    static let titleFieldName = "API name"
    /// What an API made by `/api` with no name is called: its board's name and this.
    static let boardSuffix = " API"
    static let addStep = "Add API"
    static let renameStep = "Rename API"
    /// A row's steps, each a commit of its line.
    static let addEndpointStep = "Add Endpoint"
    static let pasteEndpointsStep = "Paste Endpoints"
    static let changeEndpointStep = "Change Endpoint"
    static let changeMethodStep = "Change Method"
    static let deleteEndpointStep = "Delete Endpoint"
    static let deleteEndpointsStep = "Delete Endpoints"
    static let moveEndpointStep = "Move Endpoint"
    /// A header's: typed, retyped (every member's full path following), taken out, moved.
    static let addPrefixStep = "Add Path Prefix"
    static let renamePrefixStep = "Rename Path Prefix"
    static let deletePrefixStep = "Delete Path Prefix"
    static let movePrefixStep = "Move Path Prefix"
    /// An endpoint's connection lines written (its card): one made, one's relation changed alone, one re-aimed, one taken out.
    static let connectStep = "Connect"
    static let changeRelationStep = "Change Relation"
    static let changeConnectionStep = "Change Connection"
    static let deleteArrowStep = "Delete Arrow"
    /// What the card's connection lines are called.
    static let connectionsLine = "relations"
    /// The server line written.
    static let changeServerStep = "Change Server"
    /// A type note made from a line's or a card's list ("New type Problem"), with the words that name it: Types' step's name.
    static let newTypeStep = "New Type"
    /// What the list's action row says: "New type Problem".
    static func newTypeOffer(_ name: String) -> String { "New type \(name)" }
    /// What a path segment's offers say after them: a table's name, another path's rest.
    static let tableDetail = "table"
    static let pathDetail = "path"
    /// How strong the band behind the row with the caret is, so a header's chevron and count show through it.
    static let bandAlpha: CGFloat = 0.7
    /// How strong a type's color is behind its name in a line, as a light pill's is.
    static let pillFill: CGFloat = 0.14
    /// A row's kind words, in Mentions' catalog, the picker, VoiceOver.
    static let endpointWord = "Endpoint"
    static let prefixWord = "Path Prefix"

    /// The server line: its placeholder, faint and slanted, while it says nothing (E1 panel 2), and what VoiceOver calls it.
    static let serverPlaceholder = "server"
    static let serverName = "Server"
    /// An endpoint's card is wider than the usual: a summary is a sentence, a response a status and a type's pill.
    static let cardWidth: CGFloat = 360
    /// The lines of an endpoint's card.
    static let nameLine = "name", summaryLine = "summary", authLine = "auth", bodyLine = "body", responsesLine = "responses"
    static let deprecatedLine = "deprecated"
    static let methodLine = "method"
    /// The card's deprecated toggled on, and off.
    static let deprecateStep = "Deprecate Endpoint"
    static let undeprecateStep = "Undeprecate Endpoint"
    /// What VoiceOver says of an old version, a retired endpoint (its row, or one standing alone).
    static let deprecatedState = "deprecated"

    /// What VoiceOver calls an endpoint's chip, a button after its row: "Method, PATCH".
    static func methodButton(_ method: String) -> String { method.isEmpty ? methodWord : "\(methodWord), \(method)" }
    static let methodWord = "Method"
    /// Change Method ▸ in the selection's menu.
    static let changeMethodMenu = "Change Method"
    /// `/new-version` and New Version: the step, the command's name, and what a copy's title gets where it ends in no version.
    static let newVersionStep = "New Version"
    static let newVersionCommand = "new-version"
    static let firstNewVersion = "v2"
    /// Group by Prefix, the step and the command's name.
    static let groupByPrefixStep = "Group by Prefix"
    /// What Group by Prefix says it did to VoiceOver: the step, and how many groups the endpoints are under.
    static func groupedWords(_ groups: Int) -> String { "\(groupByPrefixStep), \(groups) \(groups == 1 ? "group" : "groups")" }
    static let groupByPrefixCommand = "group-by-prefix"
    /// What Group by Prefix says where no two endpoints share a first segment that aren't under its header already.
    static let nothingToGroup = "Nothing to group"

    /// From the paper's left to where a top row's text (the server, a chip, a header's chevron) starts.
    static let inset: CGFloat = 14
    /// How much further in a header's prefix and the endpoints under it start: the chevron's room.
    static let memberIndent: CGFloat = 18
    /// The server's band: its line (a row's height) above the hairline, and the gap under it.
    static let serverBand: CGFloat = KitStyle.rowHeight + 10
    /// The hairline under the server, down from the server line's bottom, and its ink.
    static let hairlineDrop: CGFloat = 5
    static let hairline = NSColor(white: 0, alpha: 0.12)

    /// A method's chip: bold caps (`KitStyle.chipFont`), white, in a rounded rect 18 tall, 6 in.
    static let chipHeight: CGFloat = 18
    static let chipPadding: CGFloat = 6
    static let chipRadius: CGFloat = 3
    /// The narrowest a chip is: GET's and POST's alike, as the frames draw them.
    static let chipLeast: CGFloat = 38
    /// Between a chip and its path, and between the things at a row's right.
    static let gap: CGFloat = 8
    /// A header's chevron: open, closed, its size.
    static let openChevron = "chevron.down", closedChevron = "chevron.right"
    static let chevronSize: CGFloat = 10
    /// Between the things at an endpoint's right: its pills, its arrow, its status.
    static let pillGap: CGFloat = 6
    static let lockSymbol = "lock"

    /// The frames' hues of the methods; any other method a grey.
    static let hues: [String: RGB] = [
        "GET": RGB(hex: 0x3A9E4F), "POST": RGB(hex: 0x2C72DB), "PUT": RGB(hex: 0x5B5FE0), "PATCH": RGB(hex: 0xD9792B), "DELETE": RGB(hex: 0xD23D86),
    ]
    static let otherHue = RGB(hex: 0x848488)

    /// A method's chip: its hue made dark enough that its white text reads at 4.5, the hue kept.
    static func chipFill(_ method: String) -> NSColor {
        if let kept = chipFills[method] { return kept }
        let fill = NSColor(chipRGB(method))
        chipFills[method] = fill
        return fill
    }
    private static var chipFills: [String: NSColor] = [:]

    /// A method's chip's color as its components: what an endpoint's row says its lead is (`PartLead.chip`), for a pill to draw.
    static func chipRGB(_ method: String) -> RGB {
        Swatch.reading(hues[method] ?? otherHue, against: [.white], atLeast: Swatch.textContrast)
    }

    /// A path parameter in its method's color, as text on the paper at 4.5.
    static func parameterInk(_ method: String) -> NSColor {
        if let kept = parameterInks[method] { return kept }
        let ink = NSColor(Swatch.reading(hues[method] ?? otherHue, against: [KitStyle.paper], atLeast: Swatch.textContrast))
        parameterInks[method] = ink
        return ink
    }
    private static var parameterInks: [String: NSColor] = [:]

    /// A chip's text.
    static let chipInk = NSColor.white

    /// A method's chip's color as a hex number: a deprecated endpoint's hollow chip's caps are in it.
    static func chipHex(_ method: String) -> UInt32 { UInt32(chipRGB(method).hexString.dropFirst(), radix: 16) ?? 0 }

    /// A deprecated endpoint (E5 panel 3): its chip hollow, its edge this wide, edge and caps at `deprecatedChipAlpha`; its words
    /// (path, pills, status) at `deprecatedAlpha`, as is all of an old version's content (E5 panel 4), its paper as ever.
    static let hollowChipEdge: CGFloat = 1.25
    static let deprecatedChipAlpha: CGFloat = 0.55
    static let deprecatedAlpha: CGFloat = 0.45

    /// A chip as the field lays a method out, so nothing moves as editing starts: its glyphs `chipPadding` in from where the chip
    /// is at rest (the row's indent), the chip behind them reaching `fieldChipPad` past each end (TextEditing's highlight) and the
    /// share of a kern a range's last character takes (`kernShare`; TextKit 2 splits it with the next character), so it is as wide
    /// as the chip drawn at rest, and the kern after the space past it so the path starts where the rest's does.
    static let fieldChipPad: CGFloat = 2
    static let kernShare: CGFloat = 0.5
    /// The kerns that lay out a line's `method` as typed (its glyphs `textWidth` wide in the chip's font) with a space of
    /// `spaceWidth` after it: after its last character, and after the space.
    static func chipKerns(textWidth: CGFloat, spaceWidth: CGFloat) -> (afterMethod: CGFloat, afterSpace: CGFloat) {
        let chip = max(chipLeast, textWidth + 2 * chipPadding)
        let after = max(0, (chip - chipPadding - textWidth - fieldChipPad) / kernShare)
        return (after, chip + gap - chipPadding - textWidth - after - spaceWidth)
    }

    /// A path parameter's color at rest, as the kit's row text keys it: its RGB as a hex number. Kept per method, as a frame asks
    /// it of every endpoint in view.
    static func parameterHex(_ method: String) -> UInt32 {
        if let kept = parameterHexes[method] { return kept }
        let rgb = Swatch.reading(hues[method] ?? otherHue, against: [KitStyle.paper], atLeast: Swatch.textContrast)
        let hex = UInt32(rgb.hexString.dropFirst(), radix: 16) ?? 0
        parameterHexes[method] = hex
        return hex
    }
    private static var parameterHexes: [String: UInt32] = [:]

    /// Zoomed out: a bar where a path is (the code's 0.6 em a column), and a method's chip a bar of its own.
    static let skeletonColumn: CGFloat = 0.6 * 14
}
