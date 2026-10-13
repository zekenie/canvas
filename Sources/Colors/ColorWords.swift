import Canvas
import Draw
import Queries

/// What `canvas draw` takes for a color (`color: blue`, `color: "#4465E9"`): a plugin value of its
/// own, so a list without the draw engine leaves it out. A hex value is kept as `#RRGGBB`
/// (`#46e` is `#4466EE`), a name in its list's spelling (`BLUE` is `blue`, `ColorBook.canonical`);
/// a name the file lacks and a `#…` that is no hex value are refused on the statement's line,
/// saying which names there are.
public struct ColorNamesPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { "color-names" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.drawTextFormat(mediaType: ShapeColor.mediaType, describes: "a color's name or #RRGGBB") { text, context throws(DrawError) in
            let names = context.service(ColorBook.self)?.names.map(\.name) ?? BuiltInColors.all.map(\.name)
            let known = "the colors are \(names.joined(separator: ", ")), or #RRGGBB"
            guard let color = ShapeColor(text) else {
                let written = ShapeColor.folded(text)
                if written.isEmpty {
                    throw DrawError("A color needs a name or a #RRGGBB value", reason: "invalid_value", hint: known)
                }
                throw DrawError("\"\(written)\" isn't a color value", reason: "invalid_value", hint: "write #RRGGBB or #RGB; \(known)")
            }
            guard let book = context.service(ColorBook.self) else { return color.text }
            guard let stored = book.canonical(color) else {
                throw DrawError("\"\(color.text)\" isn't a color; \(known)", reason: "invalid_value", hint: known)
            }
            return stored.text
        }
    }
}

/// What `canvas query` reads of a color (`[color="blue"]`, `[color]`): the stored string, with a
/// hex value written as `#RRGGBB`. The engine tests the literal a query writes as it is written
/// (`[color="BLUE" i]` ignores case), so a name or a hex value is found as it is stored, which
/// `canvas draw` and `editor.setColor` keep canonical. A plugin value of its own, so a list
/// without the query engine leaves it out.
public struct ColorQueriesPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { "color-queries" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.queryTextFormat(mediaType: ShapeColor.mediaType, describes: "colors read as their names or #RRGGBB", reads: .file,
                                  prepare: { _ in () },
                                  read: { stored, _ in ShapeColor(stored)?.text ?? stored })
    }
}
