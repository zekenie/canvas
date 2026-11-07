import Foundation

// Kits: a named set of the plugins the app ships, which a file turns on or off as one (File ▸ Kits ▸
// Stickers). A plugin joins a kit (`registrar.join`), and while its kit is off in a file, what it gives a
// point a kit switches (`KitSwitched`: the ways in a person makes or does something with, a tool, a
// command, a key, a slash command, a menu's item, a paste reader) is gone from that file. Everything
// else it gives stays: the registry is built once with every plugin, so a kit's kinds, looks, panel
// tabs, rows and rules are always there, and its shapes stay drawn, editable and checked. Which kits are
// on is a value the file keeps (`KitsOn`), so every board of it, and everyone who opens it, has the same
// set; every kit is off until someone turns it on. The core knows what a kit is, never which kits exist,
// as it knows what a command is and never which commands exist.

/// A kit's name, as a file keeps it (`KitsOn`): unique among kits, and never changed once shipped.
public struct KitID: RawRepresentable, Hashable, Comparable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// A kit: the type is the key, as a file property's is, and says everything about the kit once.
///
///     public enum StickersKit {}
///     extension StickersKit: Kit {
///         public static let id: KitID = "stickers"
///         public static var title: String { "Stickers" }
///     }
///
/// Each plugin of the kit joins it, in its `register(into:)` (`registrar.join(StickersKit.self)`): there is
/// no list of a kit's plugins anywhere, and the kit is the plugins that join it. A module whose ways in are
/// partly always on puts those in a plugin value of their own, which joins nothing.
public protocol Kit: SendableMetatype {
    /// What a file keeps while the kit is on (`KitsOn`): unique among kits, and never changed once shipped.
    static var id: KitID { get }
    /// What it's called: its item in File ▸ Kits, its submenu in Insert, its segment in the toolbar, and the
    /// steps that turn it on and off ("Turn On Stickers").
    static var title: String { get }
}

/// A point whose contributions are ways in, which a kit switches: while the kit a plugin joined is off in a
/// file, what that plugin gave the point is left out there. A marker the point's owner adds, in an extension of
/// its own (`extension ShapeSlashCommands: KitSwitched {}`); its readers read the point through the editor
/// (`editor.contributions(to:)`, `(to:for:)`, `(to:reaching:)`), never the registry, which holds every
/// contribution, a kit's too (a point's own `check` reads them all there). The core's are the tools
/// (`registry.tools`; an off kit's tool isn't enabled, `editor.isToolEnabled`), the commands (an off kit's
/// isn't claimed in the file, `editor.claims`) and the Keyboard Shortcuts window's hints.
public protocol KitSwitched {}

/// What the registry knows of a kit (`registry.kits`).
public struct KitDescriptor: Sendable {
    public let id: KitID
    public let title: String
    /// The kit's type, by which two kits that share an id are told apart and named.
    let type: ObjectIdentifier
    let typeName: String
    /// Insert's submenu for the kit (`KitShapes<K>`), which its tools' items go in.
    let insertSection: any MenuBarSection.Type

    init<K: Kit>(_: K.Type) {
        id = K.id
        title = K.title
        type = ObjectIdentifier(K.self)
        typeName = String(reflecting: K.self)
        insertSection = KitShapes<K>.self
    }
}

extension PluginRegistrar {
    /// Puts this plugin in a kit: what it gives a point a kit switches (`KitSwitched`) is the kit's, gone from a
    /// file while the kit is off there, and nothing else it gives is (its kinds, properties, services, overlays,
    /// adornments, panel tabs and rules are always there). Once, in its `register(into:)`; a plugin is in one
    /// kit at most. The kit's tools put their Insert items in a submenu named for it, and the core gives the
    /// kit its item in File ▸ Kits (`CanvasCommand.kit`), which turns it on or off in the file.
    public mutating func join<K: Kit>(_: K.Type) {
        contribute(KitMembership(kit: KitDescriptor(K.self), plugin: pluginID), to: CorePoints.KitMemberships.self)
    }
}

/// What `CorePoints.KitMemberships` stores: a plugin's kit.
struct KitMembership {
    let kit: KitDescriptor
    let plugin: PluginID
}

extension CorePoints {
    /// The kits plugins join (`registrar.join`): each plugin in one kit at most, each kit's id and title its
    /// own (its item in File ▸ Kits, its submenu in Insert).
    enum KitMemberships {}
}

extension CorePoints.KitMemberships: ExtensionPoint {
    typealias Contribution = KitMembership
    static var owner: PluginID { .core }

    static func check(_ registry: Registry) throws(RegistryError) {
        var joined: [PluginID: KitDescriptor] = [:]
        var byID: [KitID: KitDescriptor] = [:]
        var byTitle: [String: KitDescriptor] = [:]
        for membership in registry.contributions(to: Self.self).map(\.value) {
            let kit = membership.kit
            if let first = joined[membership.plugin] {
                throw .invalid(point: "KitMemberships", reason: first.type == kit.type
                               ? "\(membership.plugin) joins \(kit.id) twice"
                               : "\(membership.plugin) joins two kits, \(first.id) and \(kit.id); a plugin is in one kit at most")
            }
            joined[membership.plugin] = kit
            if let other = byID[kit.id], other.type != kit.type {
                throw .invalid(point: "KitMemberships", reason: "two kits are called \(kit.id): \(other.typeName) and \(kit.typeName)")
            }
            byID[kit.id] = kit
            if let other = byTitle[kit.title], other.id != kit.id {
                throw .invalid(point: "KitMemberships", reason: "kits \(other.id) and \(kit.id) are both titled \(kit.title)")
            }
            byTitle[kit.title] = kit
        }
    }

    static func summary(of membership: KitMembership, for _: ShapeTarget) -> String { "kit \(membership.kit.id)" }
}

/// The kits a file has turned on (File ▸ Kits): the core's file value, declared once a plugin joins a kit.
/// Their ids, sorted, each once; a kit no installed plugin joins stays in the value as it was and is
/// written back, so a file keeps a kit this app doesn't have. None on, the default, is written as a file
/// always was.
public enum KitsOn {}

extension KitsOn: FileProperty {
    public static let key: PropertyKey = "kits"
    public static var defaultValue: [KitID] { [] }
}

extension CanvasCommand {
    /// File ▸ Kits ▸ the kit's title: turns the kit on in the file, or off, in one step ("Turn On Stickers"),
    /// checked while it's on. The core gives every kit one (no kit switches it).
    public static func kit(_ id: KitID) -> CanvasCommand { CanvasCommand("kit:\(id.rawValue)") }
}

/// The File menu's sections the core's items are in: Kits, after the window's own (New, Open…, Open
/// Recent; Close, Save…).
public enum FileMenu {
    /// The Kits submenu, after Save's section.
    public enum Kits {}
    /// The Kits submenu's items: one a kit (`CanvasCommand.kit`), in the order plugins first join them.
    public enum KitList {}
}

extension FileMenu.Kits: MenuBarSection {
    public static var menu: MenuBarMenu { "File" }
}

extension FileMenu.KitList: MenuBarSection {
    public static var menu: MenuBarMenu { .submenu("Kits", in: FileMenu.Kits.self) }
}

/// Insert's submenu for a kit, named for it: the Insert items of the tools its plugins give
/// (`CanvasCommand.insert`), in place of Insert's own section (`InsertMenu.Shapes`), in which the submenu
/// is an item.
public enum KitShapes<K: Kit> {}

extension KitShapes: MenuBarSection {
    public static var menu: MenuBarMenu { .submenu(K.title, in: InsertMenu.Shapes.self) }
}

/// What the registry keeps of kits (`registry.kits`), found as it's built.
struct KitTable {
    /// Each kit once, in the order plugins first join them.
    let kits: [KitDescriptor]
    /// Each plugin in a kit, with its kit.
    let byPlugin: [PluginID: KitID]

    static let none = KitTable(kits: [], byPlugin: [:])

    init(kits: [KitDescriptor], byPlugin: [PluginID: KitID]) {
        self.kits = kits
        self.byPlugin = byPlugin
    }

    init(memberships: [KitMembership]) {
        var kits: [KitDescriptor] = []
        var byPlugin: [PluginID: KitID] = [:]
        for membership in memberships {
            if !kits.contains(where: { $0.id == membership.kit.id }) { kits.append(membership.kit) }
            byPlugin[membership.plugin] = byPlugin[membership.plugin] ?? membership.kit.id
        }
        self.init(kits: kits, byPlugin: byPlugin)
    }
}

extension Registry {
    /// Every kit plugins join (`registrar.join`), each once, in the order they first join.
    public var kits: [KitDescriptor] { kitTable.kits }

    /// The kit of this id, if a plugin joins it.
    public func kit(_ id: KitID) -> KitDescriptor? { kitTable.kits.first { $0.id == id } }

    /// The kit a plugin joined, nil for one in no kit (whose ways in are always on).
    public func kit(of plugin: PluginID) -> KitID? { kitTable.byPlugin[plugin] }

    /// The kit whose plugin gives a tool, nil for a tool in no kit.
    public func kit(ofTool id: ToolID) -> KitID? { toolPlugins[id].flatMap(kit(of:)) }

    /// The kit whose plugin declares a command, nil for a command in no kit (or one none declares).
    public func kit(ofCommand command: CanvasCommand) -> KitID? { commandTable.plugins[command].flatMap(kit(of:)) }

    /// The plugins in a kit, in plugin order.
    public func plugins(in kit: KitID) -> [PluginID] { pluginIDs.filter { kitTable.byPlugin[$0] == kit } }

    /// What the core gives a list whose plugins join kits, once they're known: its file value (`KitsOn`), and
    /// each kit's item in File ▸ Kits (`CanvasCommand.kit`), none of them in a kit. And each kit's tools'
    /// Insert items go in its submenu (`KitShapes`) rather than in Insert's own section.
    /// Returns them with the kits' table, which the registry keeps.
    static func kitContributions(_ contributions: [RawContribution]) -> (contributions: [RawContribution], table: KitTable) {
        let memberships = contributions.compactMap { $0.value as? KitMembership }
        guard !memberships.isEmpty else { return (contributions, .none) }
        let table = KitTable(memberships: memberships)
        let sections = Dictionary(table.kits.map { ($0.id, $0.insertSection) }, uniquingKeysWith: { first, _ in first })
        var placed = contributions.map { c -> RawContribution in
            guard let registration = c.value as? CommandRegistration, registration.inserts != nil,
                  let kit = table.byPlugin[c.pluginID], let section = sections[kit] else { return c }
            return RawContribution(registration.placed(in: section), to: CorePoints.Commands.self, for: c.target, from: c.pluginID)
        }
        placed.append(RawContribution(FilePropertyDeclaration(KitsOn.self), to: CorePoints.FilePropertyDeclarations.self, for: .any, from: .core))
        for kit in table.kits {
            let id = kit.id
            placed.append(RawContribution(CommandRegistration(command: .kit(id), title: kit.title, section: FileMenu.KitList.self, placement: .natural,
                                                              answering: nil, moment: .anytime, menuTitle: nil,
                                                              isChecked: { $0.isOn(id) }, isEnabled: { _ in true },
                                                              run: { $0.editor.turn(kit: id, on: !$0.editor.isOn(id)) }),
                                          to: CorePoints.Commands.self, for: .any, from: .core))
        }
        return (placed, table)
    }
}
