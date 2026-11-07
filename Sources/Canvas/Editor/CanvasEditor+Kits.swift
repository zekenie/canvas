import Foundation

// Kits in an editor (Kits.swift): which kits its file has turned on (`kits`), turning one on or off in one
// step, and the reads of a point a kit switches, which leave out what a plugin of an off kit gave.

extension CanvasEditor {
    /// Whether a kit is on in the file.
    public func isOn(_ kit: KitID) -> Bool { kits.contains(kit) }

    /// Whether a kit is on in the file.
    public func isOn<K: Kit>(_: K.Type) -> Bool { isOn(K.id) }

    /// Whether a plugin's ways in are on in the file: one in no kit always is, one in a kit while its kit is
    /// on (`kits`). Observed through `kits`.
    public func isOn(plugin: PluginID) -> Bool { registry.kit(of: plugin).map(kits.contains) ?? true }

    /// Whether a tool's plugin is on in the file (`isOn(plugin:)`): what the toolbar and `isToolEnabled` ask.
    func isOn(tool id: ToolID) -> Bool { registry.toolPlugins[id].map(isOn(plugin:)) ?? true }

    /// Turns a kit on in the file, or off, in one step named for it ("Turn On Stickers", "Turn Off Stickers"),
    /// as File ▸ Kits does: the file's value (`KitsOn`) gains or loses its id, and every other id it holds,
    /// a kit this app has or not, stays. Nothing for a kit no plugin joins, or one already so.
    public func turn(kit id: KitID, on: Bool) {
        guard let kit = registry.kit(id), isOn(id) != on else { return }
        transact((on ? "Turn On " : "Turn Off ") + kit.title) { transaction in
            var ids = Set(transaction.fileValue(KitsOn.self))
            if on { ids.insert(id) } else { ids.remove(id) }
            transaction.setFileValue(KitsOn.self, to: ids.sorted())
        }
    }

    /// Turns a kit on in the file, or off (`turn(kit:on:)`).
    public func turn<K: Kit>(_: K.Type, on: Bool) { turn(kit: K.id, on: on) }

    /// The kits a file has on that a plugin joins.
    static func kits(on file: CanvasFile, registry: Registry) -> Set<KitID> {
        guard !registry.kits.isEmpty else { return [] }
        return Set(file[KitsOn.self].filter { registry.kit($0) != nil })
    }

    /// Works out again which kits the file has on (`kits`), setting it only if it changed; returns whether a
    /// kit went off, for what then leaves a tool of it (`leaveDisabledTool`).
    func noteKits() -> Bool {
        let now = Self.kits(on: storedFile, registry: registry)
        guard now != kits else { return false }
        let wentOff = !kits.isSubset(of: now)
        kits = now
        return wentOff
    }

    // MARK: Reading what a kit switches

    /// Every contribution to a point a kit switches, in plugin order, less what a plugin of a kit that's off
    /// in the file gave (`isOn(plugin:)`): how such a point is read, where `registry.contributions(to:)` gives
    /// every kit's. Worked out once a set of kits on.
    public func contributions<P: ExtensionPoint & KitSwitched>(to point: P.Type) -> [Contributed<P.Contribution>] {
        let all = registry.contributions(to: P.self)
        guard kits.count < registry.kits.count else { return all }
        return registry.memo(SwitchedRead(point: ObjectIdentifier(P.self), kind: nil, kits: kits)) {
            all.filter { isOn(plugin: $0.pluginID) }
        }
    }

    /// The contributions to a point a kit switches that apply to a kind (`registry.contributions(to:for:)`),
    /// less what a plugin of a kit that's off in the file gave. Worked out once a kind and set of kits on.
    public func contributions<P: ExtensionPoint & KitSwitched>(to point: P.Type, for kind: ShapeKind) -> [P.Contribution] {
        guard kits.count < registry.kits.count else { return registry.contributions(to: P.self, for: kind) }
        return registry.memo(SwitchedRead(point: ObjectIdentifier(P.self), kind: kind, kits: kits)) {
            registry.contributions(to: P.self, reaching: kind).filter { isOn(plugin: $0.pluginID) }.map(\.value)
        }
    }

    /// The same, with where each came from (`registry.contributions(to:reaching:)`).
    public func contributions<P: ExtensionPoint & KitSwitched>(to point: P.Type, reaching kind: ShapeKind) -> [Contributed<P.Contribution>] {
        let all = registry.contributions(to: P.self, reaching: kind)
        guard kits.count < registry.kits.count else { return all }
        return registry.memo(SwitchedRead(point: ObjectIdentifier(P.self), kind: kind, kits: kits)) {
            all.filter { isOn(plugin: $0.pluginID) }
        }
    }
}

/// The key a switched read is kept by (`Registry.memo`): the point, the kind if one, and the kits on.
private struct SwitchedRead: Hashable {
    let point: ObjectIdentifier
    let kind: ShapeKind?
    let kits: Set<KitID>
}
