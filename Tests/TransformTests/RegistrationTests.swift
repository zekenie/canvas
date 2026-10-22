import Canvas
import CanvasTesting
import ContextMenus
import CoreGraphics
import SlashCommands
import TestKit
import Transform

// How transforms are registered: what the report says of a source, a target and what a target brings,
// the graph of transforms, and what the registry refuses.

@MainActor private func registry(_ more: [any CanvasPlugin]) throws -> Registry {
    try Registry(plugins: transformBase() + more)
}

/// A kind whose id can't be typed as a command's name: a target's command is named for it.
private struct OddKind: BoxShapeProps {
    static let kind: ShapeKind = "odd_one"
    static let properties = Properties<OddKind> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
}

extension OddKind {
    init() { self.init(frame: .zero) }
}

private struct OddKindDefinition {}

extension OddKindDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<OddKind>, in context: RenderContext) {}
}

@MainActor let transformRegistrationTests = Suite("Transform registration", [
    test("the report says which kind offers a channel and which takes it, and what a target brings: its menu item and its command") {
        let r = try Registry(plugins: transformPlugins([boxesTurnIntoDiscs()]))
        let lines = r.report.split(separator: "\n").map(String.init)
        let turning = try require(lines.first { $0.hasPrefix("turning") })
        expect(turning.hasSuffix("offers channel container → corral · takes channel container → pocket · CanvasContextMenu in TransformMenuGroup after ActionsMenuGroup · /turn-into-pocket → every shape that can turn into pocket"), turning)
        let discs = try require(lines.first { $0.hasPrefix("disc-turning") })
        expect(discs.hasSuffix("offers channel box → box · takes channel box → disc · CanvasContextMenu in TransformMenuGroup after ActionsMenuGroup · /turn-into-disc → every shape that can turn into disc"), discs)
        let transform = try require(lines.first { $0.hasPrefix("transform") })
        expect(transform.hasSuffix("service TransformState"), transform)
        expectEqual(r.contributions(to: TransformSources.self).count, 2)
        expectEqual(r.contributions(to: TransformTargets.self).count, 2)
    },

    test("the graph of transforms: a kind turns into each kind whose target takes a channel it offers, in plugin order, never into itself") {
        let r = try registry([corralsTurnIntoPockets(), boxesTurnIntoDiscs()])
        expectEqual(r.turnTargets(of: Corral.kind), [Pocket.kind])
        expectEqual(r.turnTargets(of: Box.kind), [Disc.kind])
        expectEqual(r.turnTargets(of: Pocket.kind), [], "takes a channel, offers none")
        expectEqual(r.turnTargets(of: Disc.kind), [])
        expectEqual(r.turnTargets(of: "no-such-kind"), [])

        let tags = plugin("tags") { $0.turnable(into: Tag.self, through: ContainerChannel.self) { _, _ in } }
        expectEqual(try registry([corralsTurnIntoPockets(), tags]).turnTargets(of: Corral.kind), [Pocket.kind, Tag.kind])
        expectEqual(try registry([tags, corralsTurnIntoPockets()]).turnTargets(of: Corral.kind), [Tag.kind, Pocket.kind], "plugin order")

        let itself = plugin("itself") { $0.turnable(into: Corral.self, through: ContainerChannel.self) { _, _ in } }
        expectEqual(try registry([corralsTurnIntoPockets(), itself]).turnTargets(of: Corral.kind), [Pocket.kind], "a kind that takes what it offers has no edge to itself")
    },

    test("a kind offers a channel once, and takes one: two claims to either are conflicts, from two plugins or from one; another channel or kind is another claim") {
        expectThrows(RegistryError.conflict(point: "TransformSources", key: "corral offering container", plugins: ["a", "b"])) {
            _ = try registry([plugin("a") { $0.turnable(Corral.self, through: ContainerChannel.self) },
                              plugin("b") { $0.turnable(Corral.self, through: ContainerChannel.self) }])
        }
        expectThrows(RegistryError.conflict(point: "TransformSources", key: "corral offering container", plugins: ["dup", "dup"])) {
            _ = try registry([plugin("dup") { r in
                r.turnable(Corral.self, through: ContainerChannel.self)
                r.turnable(Corral.self, through: ContainerChannel.self)
            }])
        }
        expectThrows(RegistryError.conflict(point: "TransformTargets", key: "disc", plugins: ["disc-turning", "again"])) {
            _ = try registry([boxesTurnIntoDiscs(),
                              plugin("again") { $0.turnable(into: Disc.self, through: ContainerChannel.self) { _, _ in } }])
        }
        _ = try registry([plugin("both") { r in
            r.turnable(Corral.self, through: ContainerChannel.self)
            r.turnable(Corral.self, through: LooseChannel.self)
            r.turnable(Box.self, through: LooseChannel.self)
            r.turnable(into: Disc.self, through: LooseChannel.self) { _, _ in }
            r.turnable(into: Pocket.self, through: LooseChannel.self) { _, _ in }
        }])
    },

    test("a channel is offered and taken by a kind at a time, never by every kind or a scope's kinds: both points say so, and the registry holds them to it") {
        expect(TransformSources.scope == .kinds)
        expect(TransformTargets.scope == .kinds)
    },

    test("only a kind the channel admits offers it: the container channel is for kinds that hold shapes, and a channel of its own says what it takes") {
        expectThrows(RegistryError.invalid(point: "TransformSources", reason: "bad offers the container channel on box, which can't offer it")) {
            _ = try registry([plugin("bad") { $0.turnable(Box.self, through: ContainerChannel.self) }])
        }
        expectThrows(RegistryError.invalid(point: "TransformSources", reason: "bad offers the container channel on pocket, which can't offer it")) {
            _ = try registry([plugin("bad") { $0.turnable(Pocket.self, through: ContainerChannel.self) }])
        }
        expectThrows(RegistryError.invalid(point: "TransformSources", reason: "bad offers the box channel on disc, which can't offer it")) {
            _ = try registry([plugin("bad") { $0.turnable(Disc.self, through: BoxChannel.self) }])
        }
        _ = try registry([plugin("good") { $0.turnable(Corral.self, through: ContainerChannel.self) }])
    },

    test("contributing needs TransformPlugin installed, and a kind that is; a target needs the context menu and slash commands too") {
        expectThrows(RegistryError.ownerNotInstalled(point: "TransformSources", owner: .transform, contributor: "bridge")) {
            _ = try Registry(plugins: [FixturesPlugin(), CorralsPlugin(), plugin("bridge") { $0.turnable(Corral.self, through: ContainerChannel.self) }])
        }
        expectThrows(RegistryError.ownerNotInstalled(point: "TransformTargets", owner: .transform, contributor: "bridge")) {
            _ = try Registry(plugins: [ContextMenusPlugin(), SlashCommandsPlugin(), PocketsPlugin(),
                                       plugin("bridge") { $0.turnable(into: Pocket.self, through: ContainerChannel.self) { _, _ in } }])
        }
        expectThrows(RegistryError.unknownKind(Corral.kind, point: "TransformSources", contributor: "bridge")) {
            _ = try Registry(plugins: [TransformPlugin(), plugin("bridge") { $0.turnable(Corral.self, through: ContainerChannel.self) }])
        }
        expectThrows(RegistryError.ownerNotInstalled(point: "CanvasContextMenu", owner: .contextMenus, contributor: "takes")) {
            _ = try Registry(plugins: [TransformPlugin(), SlashCommandsPlugin(), PocketsPlugin(),
                                       plugin("takes") { $0.turnable(into: Pocket.self, through: ContainerChannel.self) { _, _ in } }])
        }
        expectThrows(RegistryError.ownerNotInstalled(point: "ShapeSlashCommands", owner: .slashCommands, contributor: "takes")) {
            _ = try Registry(plugins: [TransformPlugin(), ContextMenusPlugin(), PocketsPlugin(),
                                       plugin("takes") { $0.turnable(into: Pocket.self, through: ContainerChannel.self) { _, _ in } }])
        }
        // A kind that offers a channel needs only Transform.
        _ = try Registry(plugins: [TransformPlugin(), CorralsPlugin(), plugin("offers") { $0.turnable(Corral.self, through: ContainerChannel.self) }])
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        expect(h.editor.transforms == nil, "no service without the plugin")
    },

    test("a target's command is named for its kind's id, so one that can't be typed as a command's name refuses the plugin list") {
        expectThrows(RegistryError.invalid(point: "ShapeSlashCommands", reason: "odd offers /turn-into-odd_one, which can't be typed as a command's name: "
                                           + "lowercase letters and digits, words joined by hyphens")) {
            _ = try registry([plugin("odd") { r in
                r.shape(OddKindDefinition())
                r.turnable(into: OddKind.self, through: ContainerChannel.self) { _, _ in }
            }])
        }
    },

    test("the plugin makes the service and contributes nothing else: an editor finds it, and a kind that offers no channel turns into nothing") {
        let r = try Registry(plugins: [TransformPlugin()])
        expectEqual(r.report.split(separator: "\n").last.map(String.init), "transform     service TransformState")
        let h = try transformHarness()
        expect(h.editor.transforms != nil)
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        expectEqual(h.editor.transforms?.targets(of: box), [])
    },
])
