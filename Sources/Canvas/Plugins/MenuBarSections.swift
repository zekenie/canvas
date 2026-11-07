// The menu bar's sections: a menu is sections of items, a line between two, each section a type that
// says which menu it's in and where it goes among that menu's sections, and each item placed among its
// section's items, both by `Order`, never a number. The window keeps its own items in sections (Edit's
// Cut, Copy and Paste in `EditMenu.CutCopyPaste`), and a command's item goes in the section its
// declaration names (`registrar.command(… in:placed:…)`).

/// A section of a menu in the menu bar: items with a line between it and the next. The type is the
/// section, as a tab is the detail panel's: every command that names it has its item there, sharing one
/// means importing the module that declares it, and a typo doesn't compile.
///
///     public enum GroupingSection {}
///     extension GroupingSection: MenuBarSection {
///         public static var menu: MenuBarMenu { "Arrange" }
///     }
public protocol MenuBarSection: SendableMetatype {
    /// The menu it's in: one of the menu bar's, by title, or a submenu, an item of another section.
    static var menu: MenuBarMenu { get }
    /// Where it goes among its menu's sections (`Order`): by default where it first appears, the
    /// window's own in the order it lists them, then those commands name, in plugin order.
    static var order: Order<Self> { get }
}

extension MenuBarSection {
    public static var order: Order<Self> { .natural }

    /// How another section names this one, to be placed beside it.
    public static var orderAnchor: OrderAnchor { OrderAnchor(Self.self, name: reportedName) { order.rule } }
    /// Its order without its type, as the window arranges a menu's sections.
    public static var orderRule: OrderRule { order.rule }

    /// As the registry's report names it: the type, in what it's declared in (`EditMenu.CutCopyPaste`), its
    /// module left out, and the private context a file's own type is in; a generic one's arguments named the
    /// same way (`KitShapes<EngineeringKit>`).
    static var reportedName: String {
        let reflected = String(reflecting: Self.self)
        guard let open = reflected.firstIndex(of: "<"), reflected.hasSuffix(">") else { return named(reflected) ?? "\(Self.self)" }
        let arguments = reflected[reflected.index(after: open)..<reflected.index(before: reflected.endIndex)]
            .split(separator: ",").map { argument in named(String(argument.drop { $0 == " " })) ?? String(argument) }
        return (named(String(reflected[..<open])) ?? "\(Self.self)") + "<" + arguments.joined(separator: ", ") + ">"
    }

    /// A type's reflected name, its module and any private context it's in left out; nil for none left.
    private static func named(_ reflected: String) -> String? {
        let start = reflected.lastIndex(of: ")").map { reflected.index(after: $0) } ?? reflected.firstIndex(of: ".") ?? reflected.startIndex
        let name = reflected[start...].drop { $0 == "." }
        return name.isEmpty ? nil : String(name)
    }
}

extension Order where Subject: MenuBarSection {
    /// Right before `section`, in the same menu.
    public static func before<Section: MenuBarSection>(_: Section.Type) -> Self { Self(.before(Section.orderAnchor)) }
    /// Right after `section`, in the same menu.
    public static func after<Section: MenuBarSection>(_: Section.Type) -> Self { Self(.after(Section.orderAnchor)) }
}

extension Order where Subject == CanvasCommand {
    /// Right before the item that runs `command`, in the same section: a command's, or one of the
    /// window's own that runs the command answering it (Edit › Paste runs the one that answers `.paste`).
    public static func before(_ command: CanvasCommand) -> Self { Self(.before(OrderAnchor(command))) }
    /// Right after the item that runs `command`, in the same section.
    public static func after(_ command: CanvasCommand) -> Self { Self(.after(OrderAnchor(command))) }
}

/// The menu a section is in: one of the menu bar's, by title (`"Arrange"`), or a submenu, an item of
/// another section, placed among that section's items as a command's item is (Find's:
/// `.submenu("Find", in: EditMenu.FindAndSpelling.self, placed: .first)`). The window puts the menu
/// bar's menus in the Mac's order (Edit, Arrange, View, Go, …), and one it doesn't know before Window.
/// Every section in a submenu says the same section and place for it, and none is inside itself: the
/// registry refuses either.
public enum MenuBarMenu: Sendable, ExpressibleByStringLiteral {
    case named(String)
    case submenu(String, in: any MenuBarSection.Type, placed: Order<CanvasCommand> = .natural)

    public init(stringLiteral title: String) { self = .named(title) }

    /// Where it is, as a path through menus: `"Edit › Find"`.
    public var path: MenuPath {
        switch self {
        case .named(let title): MenuPath([title])
        case .submenu(let title, let section, _): MenuPath(section.menu.path.titles + [title])
        }
    }
}

// MARK: The core's sections

/// The Edit menu's sections the window's own items share with commands: AppKit's own items, which
/// text answers first, and which run on the board the commands that answer them, so a command placed
/// beside one is placed beside the command it runs (`.after(.paste)`).
public enum EditMenu {
    /// Undo and Redo.
    public enum Undo {}
    /// Cut, Copy, Copy as Image, Paste, Delete and Select All.
    public enum CutCopyPaste {}
    /// Spelling and Grammar, and a submenu a command makes (Find's).
    public enum FindAndSpelling {}
}

extension EditMenu.Undo: MenuBarSection {
    public static var menu: MenuBarMenu { "Edit" }
}

extension EditMenu.CutCopyPaste: MenuBarSection {
    public static var menu: MenuBarMenu { "Edit" }
}

extension EditMenu.FindAndSpelling: MenuBarSection {
    public static var menu: MenuBarMenu { "Edit" }
}

/// The Insert menu, the core's: a shape of each kind a tool places, put down without the pointer
/// (`CanvasCommand.insert`, `editor.insert`).
public enum InsertMenu {
    /// An item for each tool that places a shape, in plugin order, as the toolbar lists them.
    public enum Shapes {}
}

extension InsertMenu.Shapes: MenuBarSection {
    public static var menu: MenuBarMenu { "Insert" }
}

/// The View menu's sections commands share with the window's own items, and the core's own commands
/// are in. Enter Full Screen's, the window's, comes last.
public enum ViewMenu {
    /// Show Toolbar, Show Inspector and Focus Inspector, then what a plugin adds beside them, then the
    /// panes' focus and Show Minimap (the window's, placed last), then what a plugin places last.
    public enum Panels {}
    /// Zoom In, Zoom Out, Actual Size and Zoom to Fit, the core's own, and the commands that zoom beside
    /// them.
    public enum Zoom {}
}

extension ViewMenu.Panels: MenuBarSection {
    public static var menu: MenuBarMenu { "View" }
}

extension ViewMenu.Zoom: MenuBarSection {
    public static var menu: MenuBarMenu { "View" }
}
