import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Mentions
import TestKit

// What a text may mention: its type's scope.

private let frame = CGRect(x: 0, y: 0, width: 100, height: 80)

/// A scope nobody declares.
enum Undeclared {}

extension Undeclared: DeclaredMentionScope {
    static let title = "Undeclared"
}

/// Another scope titled like `Blockers`.
enum OtherBlockers {}

extension OtherBlockers: DeclaredMentionScope {
    static let title = "Blockers"
}

@MainActor let scopeTests = Suite("Scopes", [
    test("AnyMentionable admits every mentionable shape; Only admits its kind; a declared scope, the kinds that joined it") {
        let h = try mentionHarness()
        let registry = h.editor.registry
        let plate = try require(h.record(h.editor.add(Plate(frame), titled: "P")))
        let token = try require(h.record(h.add(Token(frame, caption: "T"))))
        let jot = try require(h.record(h.add(Jot(frame))))
        let endpoint = try require(h.record(h.add(Endpoint(frame, path: "/"))))
        let box = try require(h.record(h.add(Box(frame))))
        @MainActor func admitted<S: MentionScope>(_: S.Type) -> [Bool] { [plate, token, jot, endpoint, box].map { S.admits($0, in: registry) } }
        expectEqual(admitted(AnyMentionable.self), [true, true, true, true, false])
        expectEqual(admitted(Only<Plate>.self), [true, false, false, false, false])
        expectEqual(admitted(Only<Box>.self), [false, false, false, false, false], "a kind that isn't mentionable admits nothing")
        expectEqual(admitted(Blockers.self), [true, true, false, false, false])
        expect(registry.joins(Plate.kind, Blockers.self))
        expect(registry.joins(Token.kind, Blockers.self), "joined from outside the kind's block, as a bridge does")
        expect(!registry.joins(Jot.kind, Blockers.self))
    },

    test("what each scope says in a schema") {
        expectEqual(AnyMentionable.schemaAnnotation(), nil)
        expectEqual(Only<Plate>.schemaAnnotation(), ["kinds": ["plate"]])
        expectEqual(Blockers.schemaAnnotation(), ["scope": "Blockers"])
    },

    test("the picker lists only what the text's scope admits") {
        let h = try mentionHarness()
        let plate = h.editor.add(Plate(frame), titled: "Alpha plate")
        let token = h.add(Token(frame, caption: "Alpha token"))
        let jot = h.add(Jot(frame, text: "Alpha jot"))
        let state = h.editor.mentionState
        @MainActor func listed<S: MentionScope>(_: S.Type) -> Set<ShapeID> {
            Set(state.candidates(matching: "alpha", in: S.self, for: nil).matches.map(\.id))
        }
        expectEqual(listed(AnyMentionable.self), [plate, token, jot])
        expectEqual(listed(Only<Plate>.self), [plate])
        expectEqual(listed(Blockers.self), [plate, token])
    },

    test("the registry refuses a join to a scope nobody declares, a join by a kind that can't be mentioned, and two scopes titled alike") {
        let undeclared = Contributor(id: "undeclared") { $0.mentionable(Plate.self, in: Undeclared.self) }
        do {
            _ = try Registry(plugins: mentionPlugins([undeclared]))
            expect(false, "a join to an undeclared scope")
        } catch let RegistryError.invalid(point, reason) {
            expectEqual(point, "MentionScopeJoins")
            expect(reason.contains("Undeclared") && reason.contains("no installed plugin declares"), reason)
        }
        let unmentionable = Contributor(id: "unmentionable") { $0.mentionable(Box.self, in: Blockers.self) }
        do {
            _ = try Registry(plugins: mentionPlugins([unmentionable]))
            expect(false, "a join by a kind that isn't mentionable")
        } catch let RegistryError.invalid(point, reason) {
            expectEqual(point, "MentionScopeJoins")
            expect(reason.contains("box") && reason.contains("can't be mentioned"), reason)
        }
        let twin = Contributor(id: "twin") { $0.mentionScope(OtherBlockers.self) }
        do {
            _ = try Registry(plugins: mentionPlugins([twin]))
            expect(false, "two scopes titled alike")
        } catch let RegistryError.invalid(point, reason) {
            expectEqual(point, "MentionScopes")
            expect(reason.contains("OtherBlockers") && reason.contains("\"Blockers\""), reason)
        }
        let again = Contributor(id: "again") { $0.mentionScope(Blockers.self) }
        do {
            _ = try Registry(plugins: mentionPlugins([again]))
            expect(false, "one scope declared twice")
        } catch let RegistryError.conflict(point, _, plugins) {
            expectEqual(point, "MentionScopes")
            expectEqual(plugins, ["mention-fixtures", "again"])
        }
        let twice = Contributor(id: "twice") { $0.mentionable(Plate.self, in: Blockers.self) }
        do {
            _ = try Registry(plugins: mentionPlugins([twice]))
            expect(false, "one kind joining one scope twice")
        } catch let RegistryError.conflict(point, _, _) {
            expectEqual(point, "MentionScopeJoins")
        }
        let mentionedTwice = Contributor(id: "mentioned-twice") { $0.mentionable(Plate.self) }
        do {
            _ = try Registry(plugins: mentionPlugins([mentionedTwice]))
            expect(false, "one kind mentionable twice")
        } catch let RegistryError.conflict(point, _, _) {
            expectEqual(point, "ShapeMentions")
        }
    },
])
