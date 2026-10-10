// The product's plugin list: which plugins ship, in which order. It's data, a table in
// Package.swift ("WHAT SHIPS") that the build puts, as text, in every executable that is the
// product, and each plugin is made here by its name, found in the binary. So no module imports the
// plugins to list them: the app, the window and the core name none, and adding a plugin is writing
// it and adding its line.

/// A plugin the product's list can name: one that can be made from nothing. Every shipped plugin
/// is one; a plugin that takes what it needs as arguments (a test's fixture, one a function makes)
/// stays a `CanvasPlugin`, and is handed to a registry by whoever makes it.
public protocol ListedPlugin: CanvasPlugin {
    init()
}

/// A listed plugin that, made from nothing, reaches outside the process: the network (the language
/// model's), the user's pasteboard (the clipboard's). Only the product itself is made of these as
/// they come (`ShippedList.plugins()`, the app's and its extensions'). Anything else that loads the
/// list (a test) hands over its own, and the list refuses to load without it
/// (`ShippedList.plugins(supplying:)`), so nothing reaches the network or the user's pasteboard by
/// leaving an argument out.
public protocol OutwardPlugin: ListedPlugin {}

/// Why the product's list didn't load.
public enum ShippedListError: Error, Equatable, CustomStringConvertible {
    /// This executable isn't the product: the build put no list in it.
    case notTheProduct
    /// A line that isn't `Module.Type`.
    case malformed(String)
    /// No such type in this executable: misspelled, or its module isn't linked in.
    case notFound(String)
    /// A type that isn't a `ListedPlugin`.
    case notListed(String)
    /// Plugins that reach outside the process, which the caller must hand over and didn't.
    case notSupplied([String])
    /// Plugins the caller handed over that the list doesn't have.
    case notInList([String])

    public var description: String {
        switch self {
        case .notTheProduct: "this executable has no plugin list: only the product's do (a line of Package.swift that ends `+ shipped`)"
        case .malformed(let line): "the plugin list has a line that isn't Module.Type: \(line)"
        case .notFound(let name): "the plugin list names \(name), and this executable has no such type"
        case .notListed(let name): "the plugin list names \(name), which isn't a ListedPlugin (a plugin made with no arguments)"
        case .notSupplied(let names): "\(names.joined(separator: " and ")) reach\(names.count == 1 ? "es" : "") outside the process, so only the app is made of \(names.count == 1 ? "it" : "them") as listed: hand over your own (ShippedList.plugins(supplying:))"
        case .notInList(let names): "the plugin list has no \(names.joined(separator: " or ")) to take the place of"
        }
    }
}

/// The product's plugins, as its list names them.
@MainActor
public enum ShippedList {
    /// The list: each plugin's `Module.Type`, in order. Nil in an executable that isn't the product.
    public static var names: [String]? {
        ShippedText.named(text)?.split(whereSeparator: \.isNewline).map(String.init)
    }

    /// The product's plugins, in the list's order, each made from nothing. The app's and its
    /// extensions' alone (the audit lets no other layer import this): the ones that reach outside the
    /// process (`OutwardPlugin`) come as the product has them, on the network and the user's
    /// pasteboard.
    @_spi(Product) public static func plugins() throws(ShippedListError) -> [any CanvasPlugin] {
        guard let names else { throw .notTheProduct }
        return try types(named: names).map { $0.type.init() }
    }

    /// The product's plugins, in the list's order, with `own` in place of the listed plugins of
    /// their types: every one that reaches outside the process (`OutwardPlugin`), or it throws
    /// `notSupplied`, and any other the caller would rather make itself (one that asks its model
    /// another way). A plugin handed over that the list hasn't is `notInList`.
    public static func plugins(supplying own: [any CanvasPlugin]) throws(ShippedListError) -> [any CanvasPlugin] {
        guard let names else { throw .notTheProduct }
        return try plugins(named: names, supplying: own)
    }

    /// The plugins a list of names makes, as the product's own is made (`plugins(supplying:)` is
    /// this, of `names`): each `Module.Type` found in this executable and made from nothing, but
    /// for those `own` takes the place of, which every one that reaches outside the process must be.
    public static func plugins(named names: [String], supplying own: [any CanvasPlugin] = []) throws(ShippedListError) -> [any CanvasPlugin] {
        var own = Dictionary(own.map { (String(reflecting: type(of: $0)), $0) }, uniquingKeysWith: { first, _ in first })
        var plugins: [any CanvasPlugin] = [], missing: [String] = []
        for entry in try types(named: names) {
            if let supplied = own.removeValue(forKey: entry.name) {
                plugins.append(supplied)
            } else if entry.type is any OutwardPlugin.Type {
                missing.append(entry.name)
            } else {
                plugins.append(entry.type.init())
            }
        }
        guard missing.isEmpty else { throw .notSupplied(missing) }
        guard own.isEmpty else { throw .notInList(own.keys.sorted()) }
        return plugins
    }

    /// A list's types, in order, each found in this executable by its name.
    private static func types(named names: [String]) throws(ShippedListError) -> [(name: String, type: any ListedPlugin.Type)] {
        var listed: [(name: String, type: any ListedPlugin.Type)] = []
        for name in names {
            let parts = name.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") } }) else {
                throw .malformed(name)
            }
            guard let found = metatype(named: parts[1], in: parts[0]) else { throw .notFound(name) }
            guard let type = found as? any ListedPlugin.Type else { throw .notListed(name) }
            listed.append((name, type))
        }
        return listed
    }

    /// A top-level type of a module, by its name, with no import: the runtime finds it by its
    /// mangled name, a struct's, a class's or an enum's (`6Boards12BoardsPluginV`). It's in the
    /// binary whether or not anything names it, since every library links whole.
    private static func metatype(named name: Substring, in module: Substring) -> Any.Type? {
        for kind in ["V", "C", "O"] {
            if let type = _typeByName("\(module.utf8.count)\(module)\(name.utf8.count)\(name)\(kind)") { return type }
        }
        return nil
    }

    /// The list's text among the product's (`ShippedText`): the build writes it from Package.swift's
    /// table, a name a line.
    static let text = "plugins"
}
