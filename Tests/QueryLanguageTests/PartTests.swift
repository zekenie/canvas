import Foundation
import QueryLanguage
import TestKit

// `#<shape>::part(<row>)`: a row of a shape, CSS's own pseudo-element, which only an edge word's anchor takes (`:edge-to`,
// `:edge-from`, `:starts-at`, `:ends-at`, `:start-of`, `:end-of`), after a shape's id alone; printed canonically, the ids in capitals;
// refused anywhere else with a message that says where it goes.

private let shape = "7C1E2A04-1B2C-4D3E-8F90-0A1B2C3D4E5F"
private let row = "5A1E0000-0000-4000-8000-00000000A0B1"

@MainActor let partTests = Suite("A row of a shape: ::part(…)", [
    test("an edge word's anchor names a row, read into its compound, printed canonically") {
        let read = try parse(":edge-to(#\(shape.lowercased())::part( \(row.lowercased()) ), calls)")
        guard case .pseudo(let pseudo)? = read.selectors.first?.compounds.first?.filters.first,
              case .anchored(let anchors, _) = pseudo.argument else { return expect(false, "an anchored word") }
        expectEqual(anchors.first?.compounds.first?.part?.id, UUID(uuidString: row))
        expectCanonical(":edge-to(#\(shape.lowercased())::part( \(row.lowercased()) ), calls)", ":edge-to(#\(shape)::part(\(row)), calls)")
        for word in ["edge-from", "starts-at", "ends-at", "start-of", "end-of"] {
            expectCanonical(":\(word)(#\(shape)::PART(\(row)))", ":\(word)(#\(shape)::part(\(row)))")
        }
    },
    test("refused off an edge word's anchor, after anything but a shape's id alone, and when it isn't a row's id") {
        let elsewhere = "::part(…) names a row of a shape, and only an edge word's anchor names one."
        let hint = ":edge-to(#<shape>::part(<row>))"
        expectRefused([
            Refused("#\(shape)::part(\(row))", .unsupported, elsewhere, hint: hint, at: 37, 44),
            Refused(":not(#\(shape)::part(\(row)))", .unsupported, elsewhere, hint: hint, at: 42, 44),
            Refused(":connected-to(#\(shape)::part(\(row)))", .unsupported, elsewhere, hint: hint, at: 51, 44),
            Refused(":between(#\(shape)::part(\(row)), \"B\")", .unsupported, elsewhere, hint: hint, at: 46, 44),
            Refused(":edge-to(\"orders\"::part(\(row)))", .badArgument, "::part(…) follows a shape's id alone: #<shape>::part(<row>).", at: 17, 44),
            Refused(":edge-to(#\(shape)[x]::part(\(row)))", .badArgument, "::part(…) follows a shape's id alone: #<shape>::part(<row>).", at: 49, 44),
            Refused(":edge-to(#\(shape)::part(customer_id))", .badArgument, "::part takes a row's id: ::part(<row>), the row's UUID.", at: 46, 19),
            Refused(":edge-to(#\(shape)::part)", .badArgument, "::part takes a row's id: ::part(<row>).", at: 46, 6),
            Refused(":edge-to(#\(shape)::part(\(row))[x])", .syntax, "::part(…) comes last in its part of a query, after [ and :.", at: 90, 1),
        ])
    },
])
