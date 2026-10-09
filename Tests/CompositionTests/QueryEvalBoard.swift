import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Composition
import Connections
import CoreGraphics
import Foundation
import LanguageModels
import Locking
import Mentions
import Queries
import Selection
import StickyNotes
import Subboards
import TestKit
import Titles
import Types

// The live evaluation's larger file (scripts/query-prompts, QueryLiveTests), built with the shipped
// kinds as the story file is, with fixed ids, `00000000-0000-4000-8000-0000000ENNNN`: 59 shapes on
// six boards, three subboards on the top board and two more inside them; titles that look alike
// ("Auth", "Auth service", "OAuth", "Auth proxy"; "Session" and "Sessions"); plain arrows and note
// links; types (notes that hold a schema) for the records and the architecture's boxes; and a note
// mentioned from two boards away (Password reset, in Identity › Legacy auth, mentions Auth, on the
// top board).
//
//     Platform (the top board), back to front:
//       subboard "Identity", subboard "Billing", subboard "Infra"
//       note "Auth"                 Single sign-on for every app
//       note "Roadmap Q4"           Ship @Identity first, then @Billing
//       note (untitled, …E0006)     Ask legal about GDPR
//       note "Launch checklist"     Docs, status page, on-call (locked)
//       type "Frontend" → type "Backend" → type "Database"   (plain arrows)
//       type "User" → type "Account"                                        (note link)
//       Roadmap Q4 → Launch checklist                                       (note link)
//     Identity's board:
//       note "Auth service"         Issues JWTs; delegates to @OAuth
//       note "OAuth"                Google and GitHub providers
//       note "Sessions"             Redis, 24 h TTL
//       note (untitled, …E0104)     TODO: rotate signing keys
//       type "Login page" → type "Token store"                    (plain arrow)
//       Auth service → Sessions, OAuth → Auth service                       (note links)
//       type "Session", subboard "Legacy auth"
//     Legacy auth's board (inside Identity):
//       note "LDAP bridge"          Deprecated; remove in 2027 (locked)
//       note "Password reset"       Emails a link; signs in through @Auth
//       type "Old DB", Password reset → Old DB                          (plain arrow)
//     Billing's board:
//       note "Payments API"         Stripe webhooks; refunds through @Refunds
//       note "Refunds"              Manual over $500
//       note "Pricing"              Three tiers
//       note (untitled, …E0304)     Retry failed charges nightly
//       type "Invoice" → type "Customer"                                    (note link)
//       Payments API → Refunds (note link), Payments API → type "Stripe" (plain arrow)
//       subboard "Invoices"
//     Invoices' board (inside Billing):
//       note "Invoice PDFs"         Rendered for @Payments API
//       note "Dunning"              Three reminders, then suspend; checks @Auth service
//       note "Tax"                  VAT by country (locked)
//       type "PDF renderer", Invoice PDFs → PDF renderer               (plain arrow)
//     Infra's board:
//       type "Kubernetes" → type "Postgres", Kubernetes → type "Redis"   (plain arrows)
//       note "Backups"              Nightly to S3
//       Backups → On-call                                                   (note link)
//       note "On-call"              PagerDuty rotation; see @Launch checklist
//       note "Auth proxy"           Envoy in front of @Auth service
//       note (untitled, …E0509)     Upgrade Postgres to 17
//       type "Metric", type "Alert" (its required names no property: a warning)
//
// Nothing is selected, and the top board is shown. No shape has an error; Alert alone has a warning.

/// The evaluation's larger file: its shapes' ids, the file (`file(in:)`), and the file open in an
/// editor of the shipped plugins (`harness`).
@MainActor
enum QueryEvalBoard {
    /// `…ENNNN`: the file's id for `n`.
    static func id(_ n: UInt16) -> ShapeID {
        ShapeID(UUID(uuidString: String(format: "00000000-0000-4000-8000-0000000E%04X", n))!)
    }

    // The top board.
    static let identity = id(0x01), billing = id(0x02), infra = id(0x03), auth = id(0x04), roadmap = id(0x05), gdpr = id(0x06)
    static let launch = id(0x07), frontend = id(0x08), backend = id(0x09), database = id(0x0A), frontendToBackend = id(0x0B)
    static let backendToDatabase = id(0x0C), user = id(0x0D), account = id(0x0E), userToAccount = id(0x0F), roadmapToLaunch = id(0x10)
    // Identity's board.
    static let authService = id(0x101), oauth = id(0x102), sessions = id(0x103), rotateKeys = id(0x104), login = id(0x105)
    static let tokenStore = id(0x106), loginToTokenStore = id(0x107), authServiceToSessions = id(0x108), oauthToAuthService = id(0x109)
    static let session = id(0x10A), legacy = id(0x10B)
    // Legacy auth's board.
    static let ldap = id(0x201), passwordReset = id(0x202), oldDB = id(0x203), resetToOldDB = id(0x204)
    // Billing's board.
    static let paymentsAPI = id(0x301), refunds = id(0x302), pricing = id(0x303), retryCharges = id(0x304), invoice = id(0x305)
    static let customer = id(0x306), invoiceToCustomer = id(0x307), paymentsToRefunds = id(0x308), stripe = id(0x309)
    static let paymentsToStripe = id(0x30A), invoices = id(0x30B)
    // Invoices' board.
    static let invoicePDFs = id(0x401), dunning = id(0x402), tax = id(0x403), renderer = id(0x404), pdfsToRenderer = id(0x405)
    // Infra's board.
    static let kubernetes = id(0x501), postgres = id(0x502), redis = id(0x503), kubernetesToPostgres = id(0x504)
    static let kubernetesToRedis = id(0x505), backups = id(0x506), onCall = id(0x507), authProxy = id(0x508), upgrade = id(0x509)
    static let backupsToOnCall = id(0x50A), metric = id(0x50B), alert = id(0x50C)

    /// The boards, each by its owner, and what each holds, back to front.
    static let boards: [(owner: ShapeID?, shapes: [ShapeID])] = [
        (nil, [identity, billing, infra, auth, roadmap, gdpr, launch, frontend, backend, database, frontendToBackend, backendToDatabase,
               user, account, userToAccount, roadmapToLaunch]),
        (identity, [authService, oauth, sessions, rotateKeys, login, tokenStore, loginToTokenStore, authServiceToSessions,
                    oauthToAuthService, session, legacy]),
        (legacy, [ldap, passwordReset, oldDB, resetToOldDB]),
        (billing, [paymentsAPI, refunds, pricing, retryCharges, invoice, customer, invoiceToCustomer, paymentsToRefunds, stripe,
                   paymentsToStripe, invoices]),
        (invoices, [invoicePDFs, dunning, tax, renderer, pdfsToRenderer]),
        (infra, [kubernetes, postgres, redis, kubernetesToPostgres, kubernetesToRedis, backups, onCall, authProxy, upgrade,
                 backupsToOnCall, metric, alert]),
    ]

    /// Every shape in file order: the top board back to front, each subboard followed at once by its
    /// board's shapes.
    static var fileOrder: [ShapeID] {
        let held = Dictionary(uniqueKeysWithValues: boards.compactMap { board in board.owner.map { ($0, board.shapes) } })
        func walk(_ shapes: [ShapeID]) -> [ShapeID] { shapes.flatMap { [$0] + walk(held[$0] ?? []) } }
        return walk(boards[0].shapes)
    }

    /// Alert's schema: its `required` names a property it doesn't have, which Validation warns about.
    static let alertSchema = #"{"type": "object", "properties": {"level": {"type": "string"}}, "required": ["severity"]}"#

    /// A schema that's an object with string properties `fields` (a type's name is its note's title).
    static func schema(_ fields: [String]) -> String {
        let properties = fields.map { #""\#($0)": {"type": "string"}"# }.joined(separator: ", ")
        return #"{"type": "object", "properties": {\#(properties)}}"#
    }

    /// The file, its arrows made by the shipped connector as a connection made by name is (both ends
    /// bound at their shapes' centers), on their channels.
    static func file(in registry: Registry) -> CanvasFile {
        /// A shape, placed where its board puts it.
        typealias Placed = (CGPoint) -> AnyShapeRecord
        func note(_ id: ShapeID, _ title: String?, _ text: MentionText, locked: Bool = false) -> Placed {
            { origin in
                var note = ShapeRecord(id: id, StickyNote(frame: CGRect(origin: origin, size: StickyNote.defaultSize), text: text))
                note[TitleProperty.self] = title
                note[LockedProperty.self] = locked ? true : nil
                return AnyShapeRecord(note)
            }
        }
        func subboard(_ id: ShapeID, _ title: String) -> Placed {
            { origin in
                var subboard = ShapeRecord(id: id, Subboard(frame: CGRect(origin: origin, size: Subboard.defaultSize)))
                subboard[TitleProperty.self] = title
                return AnyShapeRecord(subboard)
            }
        }
        /// A type: a note titled `title` that holds `schema`, saying nothing in words.
        func type(_ id: ShapeID, _ title: String, _ schema: String) -> Placed {
            { origin in
                var note = ShapeRecord(id: id, StickyNote(frame: CGRect(origin: origin, size: StickyNote.defaultSize)))
                note[TitleProperty.self] = title
                note[TypeSchemaProperty.self] = SchemaText(schema)
                return AnyShapeRecord(note)
            }
        }
        /// A box of the file's architecture diagrams, joined by plain arrows: a type for a record of
        /// that name.
        func box(_ id: ShapeID, _ title: String) -> Placed { type(id, title, schema(["id"])) }
        func text(_ runs: MentionRun...) -> MentionText { MentionText(runs) }
        /// A board: its shapes five to a row, and its arrows, each made against those shapes, in the
        /// order `boards` lists them.
        func board(_ owner: ShapeID?, _ shapes: [Placed], arrows: [(ShapeID, ConnectionRequest)]) -> CanvasDocument {
            let placed = shapes.enumerated().map { index, shape in shape(CGPoint(x: 80 + (index % 5) * 320, y: 80 + (index / 5) * 300)) }
            let context = ShapeContext(document: CanvasDocument(shapes: placed), registry: registry)
            let made = arrows.map { id, request in
                guard let arrow = registry.connection(request, in: context) else {
                    preconditionFailure("the shipped connector connects \(request.from) to \(request.to)")
                }
                return arrow.copy(as: id)
            }
            let byID = Dictionary(uniqueKeysWithValues: (placed + made).map { ($0.id, $0) })
            let order = boards.first { $0.owner == owner }?.shapes ?? []
            precondition(Set(order) == Set(byID.keys), "each board holds what `boards` lists")
            return CanvasDocument(shapes: order.compactMap { byID[$0] })
        }

        return CanvasFile(
            root: board(nil, [
                subboard(identity, "Identity"), subboard(billing, "Billing"), subboard(infra, "Infra"),
                note(auth, "Auth", MentionText(plain: "Single sign-on for every app")),
                note(roadmap, "Roadmap Q4", text(.text("Ship "), .mention(identity, label: "Identity"), .text(" first, then "),
                                                 .mention(billing, label: "Billing"))),
                note(gdpr, nil, MentionText(plain: "Ask legal about GDPR")),
                note(launch, "Launch checklist", MentionText(plain: "Docs, status page, on-call"), locked: true),
                box(frontend, "Frontend"), box(backend, "Backend"), box(database, "Database"),
                type(user, "User", schema(["id", "email"])), type(account, "Account", schema(["plan"])),
            ], arrows: [
                (frontendToBackend, ConnectionRequest(from: frontend, to: backend)),
                (backendToDatabase, ConnectionRequest(from: backend, to: database)),
                (userToAccount, ConnectionRequest(from: user, to: account, channel: NoteLink.id)),
                (roadmapToLaunch, ConnectionRequest(from: roadmap, to: launch, channel: NoteLink.id)),
            ]),
            children: [
                identity: board(identity, [
                    note(authService, "Auth service", text(.text("Issues JWTs; delegates to "), .mention(oauth, label: "OAuth"))),
                    note(oauth, "OAuth", MentionText(plain: "Google and GitHub providers")),
                    note(sessions, "Sessions", MentionText(plain: "Redis, 24 h TTL")),
                    note(rotateKeys, nil, MentionText(plain: "TODO: rotate signing keys")),
                    box(login, "Login page"), box(tokenStore, "Token store"),
                    type(session, "Session", schema(["token", "expires"])), subboard(legacy, "Legacy auth"),
                ], arrows: [
                    (loginToTokenStore, ConnectionRequest(from: login, to: tokenStore)),
                    (authServiceToSessions, ConnectionRequest(from: authService, to: sessions, channel: NoteLink.id)),
                    (oauthToAuthService, ConnectionRequest(from: oauth, to: authService, channel: NoteLink.id)),
                ]),
                legacy: board(legacy, [
                    note(ldap, "LDAP bridge", MentionText(plain: "Deprecated; remove in 2027"), locked: true),
                    note(passwordReset, "Password reset", text(.text("Emails a link; signs in through "), .mention(auth, label: "Auth"))),
                    box(oldDB, "Old DB"),
                ], arrows: [(resetToOldDB, ConnectionRequest(from: passwordReset, to: oldDB))]),
                billing: board(billing, [
                    note(paymentsAPI, "Payments API", text(.text("Stripe webhooks; refunds through "), .mention(refunds, label: "Refunds"))),
                    note(refunds, "Refunds", MentionText(plain: "Manual over $500")),
                    note(pricing, "Pricing", MentionText(plain: "Three tiers")),
                    note(retryCharges, nil, MentionText(plain: "Retry failed charges nightly")),
                    type(invoice, "Invoice", schema(["number", "total"])), type(customer, "Customer", schema(["name", "email"])),
                    box(stripe, "Stripe"), subboard(invoices, "Invoices"),
                ], arrows: [
                    (invoiceToCustomer, ConnectionRequest(from: invoice, to: customer, channel: NoteLink.id)),
                    (paymentsToRefunds, ConnectionRequest(from: paymentsAPI, to: refunds, channel: NoteLink.id)),
                    (paymentsToStripe, ConnectionRequest(from: paymentsAPI, to: stripe)),
                ]),
                invoices: board(invoices, [
                    note(invoicePDFs, "Invoice PDFs", text(.text("Rendered for "), .mention(paymentsAPI, label: "Payments API"))),
                    note(dunning, "Dunning", text(.text("Three reminders, then suspend; checks "), .mention(authService, label: "Auth service"))),
                    note(tax, "Tax", MentionText(plain: "VAT by country"), locked: true),
                    box(renderer, "PDF renderer"),
                ], arrows: [(pdfsToRenderer, ConnectionRequest(from: invoicePDFs, to: renderer))]),
                infra: board(infra, [
                    box(kubernetes, "Kubernetes"), box(postgres, "Postgres"), box(redis, "Redis"),
                    note(backups, "Backups", MentionText(plain: "Nightly to S3")),
                    note(onCall, "On-call", text(.text("PagerDuty rotation; see "), .mention(launch, label: "Launch checklist"))),
                    note(authProxy, "Auth proxy", text(.text("Envoy in front of "), .mention(authService, label: "Auth service"))),
                    note(upgrade, nil, MentionText(plain: "Upgrade Postgres to 17")),
                    type(metric, "Metric", schema(["name", "value"])), type(alert, "Alert", alertSchema),
                ], arrows: [
                    (kubernetesToPostgres, ConnectionRequest(from: kubernetes, to: postgres)),
                    (kubernetesToRedis, ConnectionRequest(from: kubernetes, to: redis)),
                    (backupsToOnCall, ConnectionRequest(from: backups, to: onCall, channel: NoteLink.id)),
                ]),
            ])
    }

    /// The file in an editor of the shipped plugins, their clipboard on `pasteboard` (a test's own)
    /// and their model `model`: the top board shown, in the story's viewport, nothing selected.
    static func harness(pasteboard: NSPasteboard, model: any LanguageModel = ScriptedLanguageModel()) throws -> EditorHarness {
        let registry = try ShippedPlugins.registry(pasteboard: pasteboard, model: model)
        let h = EditorHarness { CanvasEditor(registry: registry, file: file(in: registry), scheduler: $0) }
        h.editor.viewportDidResize(to: QueryStory.viewport)
        return h
    }
}

@MainActor let queryEvalBoardTests = Suite("Query eval board", [
    test("the eval board: 59 shapes on six boards in file order, look-alike titles, a mention from two boards away, one warning") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = try QueryEvalBoard.harness(pasteboard: pasteboard)
        expectEqual(h.file.children.count, 5, "Identity's, Legacy auth's, Billing's, Invoices' and Infra's boards")
        let queries = try require(h.editor.queries)
        @MainActor func ids(_ query: String) throws -> [ShapeID] {
            try awaitResult { try await queries.run(QueryRequest(query, limit: QueryBudget.maxRows, properties: .none)) }.rows.map(\.id)
        }
        let all = try ids("*")
        expectEqual(all.count, 59)
        expectEqual(all, QueryEvalBoard.fileOrder)

        // Titles that look alike, each its own shape.
        expectEqual(try ids(#"sticky-note[title*="auth" i]"#),
                    [QueryEvalBoard.authService, QueryEvalBoard.oauth, QueryEvalBoard.authProxy, QueryEvalBoard.auth])
        expectEqual(try ids(#""Auth""#), [QueryEvalBoard.auth])
        expectEqual(try ids(#"[title="Session"]"#), [QueryEvalBoard.session])

        // Password reset, two boards down, mentions Auth on the top board: a live mention, an edge.
        expectEqual(try ids(#":mentions("Auth")"#), [QueryEvalBoard.passwordReset])
        expectEqual(try ids(#""Password reset":inside("Identity")"#), [QueryEvalBoard.passwordReset])
        expectEqual(h.editor.mentions?.mentions(in: QueryEvalBoard.passwordReset), [QueryEvalBoard.auth])
        expectEqual(try ids(":dangling"), [], "every mention is of a shape in the file")

        // Arrows: eight plain, seven note links (two of them between types), each bound at both ends.
        expectEqual(try ids("arrow:not([channel])").count, 8)
        expectEqual(try ids("arrow[channel=note-link]").count, 7)
        expectEqual(try ids(#"sticky-note[schema]:connected-to("Customer", note-link)"#), [QueryEvalBoard.invoice])
        expectEqual(try ids(#":edge-from("Kubernetes")"#), [QueryEvalBoard.postgres, QueryEvalBoard.redis])

        // Alert's required names no property: its warning is the file's only issue.
        expectEqual(try ids(":warned"), [QueryEvalBoard.alert])
        expectEqual(try ids(":invalid"), [])
        expectEqual(try ids("[locked]"), [QueryEvalBoard.ldap, QueryEvalBoard.tax, QueryEvalBoard.launch])
        expectEqual(h.editor.selectedShapeIDs, [])
    },
])
