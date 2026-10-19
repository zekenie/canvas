import Canvas
import CanvasRPC
import Foundation
import TestKit
import Types

// What typed text is stored as, and how a value shows: pinned to a locale, so no machine's region moves a date.

private let us = Locale(identifier: "en_US"), gb = Locale(identifier: "en_GB")
private let status = PlainKind.choice([FieldOption(value: .string("draft"), label: "draft"), FieldOption(value: .string("paid"), label: "paid"),
                                       FieldOption(value: .number(2), label: "2")])

private func number(_ typed: String) -> JSONValue? { FieldText.value(from: typed, as: .number(integer: false), locale: us) }

@MainActor let fieldTextTests = Suite("Field text", [
    test("text is stored as typed: spaces are a value, empty clears, a line break is kept") {
        expectEqual(FieldText.value(from: "Ann Lee", as: .text, locale: us), "Ann Lee")
        expectEqual(FieldText.value(from: "  ", as: .text, locale: us), "  ")
        expectEqual(FieldText.value(from: "", as: .text, locale: us), nil)
        expectEqual(FieldText.value(from: "a\nb", as: .text, locale: us), "a\nb")
        expectEqual(FieldText.value(from: "", as: .number(integer: false), locale: us), nil)
        expectEqual(FieldText.value(from: "", as: .date, locale: us), nil)
    },
    test("a number is stored as a number only when it reads back as typed") {
        let numbers: [(String, JSONValue)] = [
            ("12", 12), ("9.5", 9.5), ("9.50", 9.5), ("12.00", 12), ("-3", -3), ("-3.0", -3), ("+5", 5), ("0", 0), ("0.1", 0.1),
            ("0.30", 0.3), ("100", 100), ("1000000", 1_000_000), ("0.00001", 0.00001), ("123456.789", 123_456.789),
        ]
        for (typed, value) in numbers { expectEqual(number(typed), value, typed) }
        let text = ["02134", "1e3", "1.", "-", ".5", "+", "abc", "1,5", "9.5.1", "12 ", " 12", "-0", "00.5", "1_000", "12345678901234567", "0.1234567890123456789",
                    "9007199254740993", "١٢"]
        for typed in text { expectEqual(number(typed), .string(typed), "\(typed) stays text") }
        expectEqual(FieldText.value(from: "2.5", as: .number(integer: true), locale: us), 2.5, "2.5 in an integer field is stored as typed, and wrong")
        expectEqual(FieldText.value(from: "abc", as: .number(integer: true), locale: us), "abc")
    },
    test("a date is a full date however it is written, stored as 2026-03-03; a part of a date stays text") {
        let written = ["2026-03-03", "Mar 3, 2026", "March 3, 2026", "3 Mar 2026", "3 March 2026", "3/3/26", "3/3/2026", " 2026-03-03 "]
        for typed in written { expectEqual(FieldText.value(from: typed, as: .date, locale: us), "2026-03-03", "\(typed) in en_US") }
        for typed in ["2026-03-03", "3 Mar 2026", "3 March 2026", "3/3/26", "03/03/2026"] {
            expectEqual(FieldText.value(from: typed, as: .date, locale: gb), "2026-03-03", "\(typed) in en_GB")
        }
        expectEqual(FieldText.date(from: "4/3/26", locale: us), "2026-04-03", "month first in the US")
        expectEqual(FieldText.date(from: "4/3/26", locale: gb), "2026-03-04", "day first in Britain")
        expectEqual(FieldText.date(from: "13/3/26", locale: us), nil, "there is no month 13")
        expectEqual(FieldText.date(from: "13/3/26", locale: gb), "2026-03-13")
        expectEqual(FieldText.date(from: "3/3/99", locale: us), "2099-03-03", "a two-digit year is 2000 to 2099")
        expectEqual(FieldText.date(from: "2024-02-29", locale: us), "2024-02-29", "a leap day")
        for typed in ["Jan 2024", "2024", "Mar 3", "2026-03", "2026-3-3", "2026-02-30", "2025-02-29", "3/3", "3/3/266", "soon", "Mar 3, 2026 10:00"] {
            expectEqual(FieldText.value(from: typed, as: .date, locale: us), .string(typed), "\(typed) is kept as typed")
            expectEqual(FieldText.date(from: typed, locale: us), nil, typed)
        }
    },
    test("a date-time stores a full date as UTC midnight, and any stored date shows as the day") {
        expectEqual(FieldText.dateTime(from: "Mar 3, 2026", locale: us), "2026-03-03T00:00:00Z")
        expectEqual(FieldText.dateTime(from: "Jan 2024", locale: us), nil)
        expectEqual(FieldText.shown("2026-03-03T00:00:00Z", as: .date, locale: us), "Mar 3, 2026")
        expectEqual(FieldText.shown("2026-03-03T00:00:00.000Z", as: .date, locale: us), "Mar 3, 2026")
        expectEqual(FieldText.shown("2026-03-03T14:30:00Z", as: .date, locale: us), "2026-03-03T14:30:00Z", "a time of day is shown as stored")
        expectEqual(FieldText.shown("2026-03-03T00:00:00+02:00", as: .date, locale: us), "2026-03-03T00:00:00+02:00")
    },
    test("a typed date in a date-time field is stored as a date-time, and shows as the day") {
        for typed in ["Mar 3, 2026", "2026-03-03", "3/3/26"] {
            expectEqual(FieldText.value(from: typed, as: .dateTime, locale: us), "2026-03-03T00:00:00Z", typed)
        }
        expectEqual(FieldText.value(from: "Jan 2024", as: .dateTime, locale: us), "Jan 2024", "a part of a date is kept as typed")
        expectEqual(FieldText.shown("2026-03-03T00:00:00Z", as: .dateTime, locale: us), "Mar 3, 2026")
        expectEqual(FieldText.shown("2026-03-03", as: .dateTime, locale: us), "Mar 3, 2026", "the older form shows too")
        expectEqual(FieldText.value(from: "Mar 3, 2026", asOneOf: [.dateTime, .text], locale: us), "2026-03-03T00:00:00Z")
        expectEqual(FieldText.shown("2026-03-03T00:00:00Z", asOneOf: [.dateTime, .text], locale: us), "Mar 3, 2026")
        let stored = try require(FieldText.value(from: "Mar 3, 2026", as: .dateTime, locale: us)?.stringValue)
        expect(ISO8601DateFormatter().date(from: stored) != nil, "a date-time format check (RFC 3339: a date, a T and a time) accepts it")
    },
    test("yes or no is a Bool and a choice is the option's value") {
        expectEqual(FieldText.value(from: "true", as: .yesNo, locale: us), true)
        expectEqual(FieldText.value(from: "False", as: .yesNo, locale: us), false)
        expectEqual(FieldText.value(from: "maybe", as: .yesNo, locale: us), "maybe")
        expectEqual(FieldText.value(from: "paid", as: status, locale: us), "paid")
        expectEqual(FieldText.value(from: "2", as: status, locale: us), 2, "an option whose label is its number")
        expectEqual(FieldText.value(from: "refunded", as: status, locale: us), "refunded", "nothing is refused")
    },
    test("how a value shows: a date as Mar 3, 2026, a number by its value, a choice its label, text on one line") {
        expectEqual(FieldText.shown("2026-03-03", as: .date, locale: us), "Mar 3, 2026")
        expectEqual(FieldText.shown("2026-03-03", as: .date, locale: gb), "3 Mar 2026")
        expectEqual(FieldText.shown("Jan 2024", as: .date, locale: us), "Jan 2024", "stored text that is not a date is shown as stored")
        expectEqual(FieldText.shown(9.5, as: .number(integer: false), locale: us), "9.5")
        expectEqual(FieldText.shown(12, as: .number(integer: false), locale: us), "12", "12, never 12.00")
        expectEqual(FieldText.shown(0.00001, as: .number(integer: false), locale: us), "0.00001")
        expectEqual(FieldText.shown(-0.5, as: .number(integer: true), locale: us), "-0.5")
        expectEqual(FieldText.shown("paid", as: status, locale: us), "paid")
        expectEqual(FieldText.shown(2, as: status, locale: us), "2")
        expectEqual(FieldText.shown("refunded", as: status, locale: us), "refunded", "a value no option has")
        expectEqual(FieldText.shown(true, as: .yesNo, locale: us), "yes")
        expectEqual(FieldText.shown(false, as: .yesNo, locale: us), "no")
        expectEqual(FieldText.shown("Ann Lee", as: .text, locale: us), "Ann Lee")
        expectEqual(FieldText.shown("line one\nline two\r\nthree\rfour", as: .text, locale: us), "line one line two three four")
        expectEqual(FieldText.value(from: "line one\nline two", as: .text, locale: us), "line one\nline two", "stored with its break")
    },
    test("a value of another JSON type shows as its own type would: the check is what calls it wrong") {
        expectEqual(FieldText.shown("abc", as: .number(integer: false), locale: us), "abc", "text in a number field, as typed")
        expectEqual(FieldText.shown(12, as: .text, locale: us), "12", "a number in a text field, by its value")
        expectEqual(FieldText.shown(true, as: .text, locale: us), "true")
        expectEqual(FieldText.shown(false, as: .number(integer: false), locale: us), "false")
        expectEqual(FieldText.shown(3, as: .date, locale: us), "3")
        expectEqual(FieldText.shown(["a": 1], as: .text, locale: us), #"{"a":1}"#)
        expectEqual(FieldText.shown(["a", "b"], as: .text, locale: us), #"["a","b"]"#)
        expectEqual(FieldText.shown(.null, as: .text, locale: us), "")
        expectEqual(FieldText.shown("x", as: .yesNo, locale: us), "x")
    },
    test("either of two kinds: the kinds that are not text are tried in order, else the text typed") {
        let both: [PlainKind] = [.number(integer: false), .text]
        expectEqual(FieldText.value(from: "12", asOneOf: both, locale: us), 12)
        expectEqual(FieldText.value(from: "9.50", asOneOf: both, locale: us), 9.5)
        expectEqual(FieldText.value(from: "L", asOneOf: both, locale: us), "L")
        expectEqual(FieldText.value(from: "02134", asOneOf: both, locale: us), "02134")
        expectEqual(FieldText.value(from: "12", asOneOf: [.text, .number(integer: false)], locale: us), 12, "the order of the kinds does not put text first")
        expectEqual(FieldText.value(from: "", asOneOf: both, locale: us), nil)
        expectEqual(FieldText.value(from: "true", asOneOf: [.text, .yesNo], locale: us), true)
        expectEqual(FieldText.value(from: "Mar 3, 2026", asOneOf: [.date, .text], locale: us), "2026-03-03")
        expectEqual(FieldText.value(from: "Mar 3", asOneOf: [.date, .text], locale: us), "Mar 3")
        expectEqual(FieldText.value(from: "paid", asOneOf: [status, .number(integer: false)], locale: us), "paid")
        expectEqual(FieldText.value(from: "7", asOneOf: [status, .number(integer: false)], locale: us), 7)
        expectEqual(FieldText.value(from: "12", asOneOf: [.number(integer: false), .yesNo], locale: us), 12)
        expectEqual(FieldText.value(from: "x", asOneOf: [], locale: us), "x")
    },
    test("with one kind, either's form equals the kind's own, for text, number, date and a choice") {
        let kinds: [PlainKind] = [.text, .number(integer: false), .date, status]
        let typed = ["", "Ann", "12", "9.50", "02134", "Mar 3, 2026", "2026-03-03", "Jan 2024", "paid", "2", " "]
        for kind in kinds {
            for text in typed {
                expectEqual(FieldText.value(from: text, asOneOf: [kind], locale: us), FieldText.value(from: text, as: kind, locale: us), "\(kind) \(text)")
            }
        }
    },
    test("an either shows as the first kind its value fits, else as its own type") {
        let both: [PlainKind] = [.number(integer: false), .text]
        expectEqual(FieldText.shown(12, asOneOf: both, locale: us), "12")
        expectEqual(FieldText.shown("L", asOneOf: both, locale: us), "L")
        expectEqual(FieldText.shown("2026-03-03", asOneOf: [.date, .text], locale: us), "Mar 3, 2026")
        expectEqual(FieldText.shown("soon", asOneOf: [.date, .text], locale: us), "soon")
        expectEqual(FieldText.shown("paid", asOneOf: [status, .number(integer: false)], locale: us), "paid")
        expectEqual(FieldText.shown(true, asOneOf: [.number(integer: false), .yesNo], locale: us), "yes")
        expectEqual(FieldText.shown(true, asOneOf: both, locale: us), "true", "a Bool fits neither")
        expectEqual(FieldText.shown(["a": 1], asOneOf: both, locale: us), #"{"a":1}"#)
        expectEqual(FieldText.shown("x", asOneOf: [], locale: us), "x")
    },
    test("every call takes the locale, and the default is the machine's") {
        expectEqual(FieldText.value(from: "Mar 3, 2026", as: .date), FieldText.value(from: "Mar 3, 2026", as: .date, locale: .autoupdatingCurrent))
        expectEqual(FieldText.shown("2026-03-03", as: .date), FieldText.shown("2026-03-03", as: .date, locale: .autoupdatingCurrent))
        expectEqual(FieldText.date(from: "2026-03-03"), "2026-03-03", "the ISO day needs no locale")
        expectEqual(FieldText.value(from: "12", asOneOf: [.number(integer: false)]), 12)
        expectEqual(FieldText.shown(12, asOneOf: [.number(integer: false)]), "12")
    },
])
