import AppKit
import Chrome
import TestKit

/// The width of text in the pill's place line: SF 11, a board's name semibold, to a whole point (the width the critic's
/// measure gave, the figures these cases were worked out with).
private func placeWidth(_ text: String, _ isBoard: Bool) -> CGFloat {
    let font = NSFont.systemFont(ofSize: 11, weight: isBoard ? .semibold : .regular)
    return ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width)
}

private func frame(_ name: String) -> PlaceStep { PlaceStep(name: name) }
private func board(_ name: String) -> PlaceStep { PlaceStep(name: name, opensBoard: true) }
private func untitled(_ name: String) -> PlaceStep { PlaceStep(name: name, isPlaceholder: true) }

private func fold(_ steps: [PlaceStep], _ room: CGFloat) -> PlaceLine {
    PlaceFold.line(for: steps, room: room, measure: placeWidth)
}

private func text(_ steps: [PlaceStep], _ room: CGFloat) -> String { fold(steps, room).text }

/// "Shop" the file, Policies a frame, Refunds a subboard, Escalations and EU frames, Disputes a subboard, Q3 review a
/// frame: one note moved a level deeper each time, across three boards. From the third level on the file's name does
/// not lead (a step opens a board).
private func ladder(_ levels: Int) -> [PlaceStep] {
    let all = [board("Shop"), frame("Policies"), board("Refunds"), frame("Escalations"), frame("EU"), board("Disputes"), frame("Q3 review")]
    let steps = Array(all.prefix(levels))
    return levels >= 3 ? Array(steps.dropFirst()) : steps
}

/// The room a pill gets at each level of the ladder (its width less the 46 around the line: the pad, the symbol, the
/// gap and the trailing pad), for the note "Chargeback reply".
private let ladderRooms: [CGFloat] = [134, 134, 134, 171, 198, 208, 215]

@MainActor let placeFoldTests = Suite("PlaceFold", [
    test("a place that fits is said whole, with its separators measured in") {
        let steps = [board("Shop"), frame("Policies"), frame("Refunds")]
        let line = fold(steps, 234)
        expectEqual(line.text, "Shop › Policies › Refunds")
        expect(!line.isShortened, "whole is neither folded nor cut")
        expectEqual(line.width, placeWidth("Shop", true) + placeWidth("Policies", false) + placeWidth("Refunds", false) + 2 * placeWidth(" › ", false))
    },
    test("its pieces say which step each is, whether it opens a board or is untitled, and the separators between") {
        let line = fold([board("Shop"), untitled("Untitled Frame"), frame("Refunds")], 234)
        expectEqual(line.pieces.map(\.kind), [
            .step(index: 0, opensBoard: true, isPlaceholder: false), .separator,
            .step(index: 1, opensBoard: false, isPlaceholder: true), .separator,
            .step(index: 2, opensBoard: false, isPlaceholder: false),
        ])
        expectEqual(line.pieces.map(\.text), ["Shop", " › ", "Untitled Frame", " › ", "Refunds"])
        expect(line.pieces.allSatisfy { !$0.wasCut })
    },
    test("an untitled board is both a board and untitled") {
        let line = fold([PlaceStep(name: "Untitled Subboard", opensBoard: true, isPlaceholder: true)], 234)
        expectEqual(line.pieces.first?.kind, .step(index: 0, opensBoard: true, isPlaceholder: true))
        // Measured in the board's weight.
        expectEqual(line.width, placeWidth("Untitled Subboard", true))
    },
    test("no steps say nothing, and under 24 points of room nothing is said") {
        expect(fold([], 234).isEmpty)
        expect(!fold([frame("A")], 24).isEmpty)
        expect(fold([frame("A")], 23.9).isEmpty)
        expect(fold([frame("Platform layer"), frame("Horizontals"), frame("Types")], 0).isEmpty)
        expectEqual(fold([frame("Platform layer"), frame("Types")], 23).width, 0)
    },
    test("Medusa's two Workflows places that round 1 read alike are told apart") {
        // Both are board › board › frame, the nearest frames' names differing past a cut of their end.
        let customer = [board("Workflows and steps"), board("customer flows"), frame("Workflows (customer)")]
        let group = [board("Workflows and steps"), board("customer-group flows"), frame("Workflows (customer-group)")]
        let first = fold(customer, 234), second = fold(group, 234)
        expectEqual(first.text, "Workflows… › … › Workflows (customer)")
        expectEqual(second.text, "Workfl… › … › Workflows (customer-group)")
        expect(first.text != second.text)
        for line in [first, second] {
            expect(line.isFolded && line.isCut, "folded and cut")
            expect(line.width <= 234, "within its room")
        }
        expect(first.pieces.last?.wasCut == false, "the nearest is whole")
        expect(first.pieces.first?.wasCut == true)
    },
    test("a path-like name keeps its leaf when it is cut") {
        expectEqual(text([frame("nexus-messaging-temporal-operation/src/callerpattern/caller")], 234), "nexus-messaging-temporal…/caller")
        expectEqual(text([frame("nexus-messaging-temporal-operation/src/callerpattern/service")], 234), "nexus-messaging-temporal…/service")
        expectEqual(text([frame("src/callerpattern/caller")], 80), "src/call…/caller")
    },
    test("a name with spaces is cut at its end, never keeping a leaf") {
        expectEqual(text([frame("Antidisestablishmentarianism and other long words that run on")], 100), "Antidisestablish…")
    },
    test("a cut falls at a word when one is within 30% of the cut, else by characters") {
        // "Workflows and steps" cut to about 70 points ends at the word, "Workflows…", not mid-word.
        expectEqual(text([board("Workflows and steps"), frame("Workflows (customer)")], 200), "Workflows… › Workflows (customer)")
        // Nothing within 30% of the cut is a word's end: by characters.
        let characters = text([frame("Antidisestablishmentarianism and other long words")], 90)
        expect(characters.hasSuffix("…") && !characters.contains(" "), "no word within 30%: \(characters)")
    },
    test("the ladder from one to seven levels across three boards") {
        let expected = [
            "Shop",
            "Shop › Policies",
            "Policies › Refunds",
            "Policies › Refunds › Escalations",
            "Policies › Refunds › Escalations › EU",
            "Policies › Refunds › … › EU › Disputes",
            "Policies › … › EU › Disputes › Q3 review",
        ]
        for level in 1...7 {
            expectEqual(text(ladder(level), ladderRooms[level - 1]), expected[level - 1], "level \(level)")
        }
    },
    test("the ladder folds the middle only once the place stops fitting, and names the original's own board before frames") {
        let five = fold(ladder(5), ladderRooms[4])
        expect(!five.isFolded, "five levels still fit")
        let six = fold(ladder(6), ladderRooms[5])
        expect(six.isFolded && !six.isCut, "six levels are folded, no name cut")
        // Disputes (a board) is the nearest here; at seven it is the original's own board and is put back before Refunds.
        let seven = fold(ladder(7), ladderRooms[6])
        expectEqual(seven.pieces.compactMap { piece -> String? in piece.isStep ? piece.text : nil }, ["Policies", "EU", "Disputes", "Q3 review"])
    },
    test("the middle comes back from the original's own board first, then from the near end outward") {
        let steps = [frame("Platform layer"), frame("Horizontals"), frame("Group"), board("Types"), frame("Fields"), frame("Rows"), frame("Nearest frame")]
        // Room for the first, the nearest and one more: the board comes back before the near frames.
        let line = fold(steps, 220)
        expect(line.text.contains("Types"), "the original's own board is put back: \(line.text)")
        let wide = fold(steps, 234)
        expectEqual(wide.text, "Platform layer › … › Rows › Nearest frame")
    },
    test("two … at most: the first, the board the original is on, and the nearest, with a gap on each side") {
        let steps = [frame("Platform layer"), frame("Horizontals"), board("Types"), frame("Fields"), frame("Nearest frame")]
        let line = fold(steps, 200)
        expectEqual(line.text, "Platform layer › … › Nearest frame")
        let two = fold([frame("Platform layer"), frame("Horizontals"), frame("Group"), board("Types"), frame("Fields"), frame("Rows"), frame("Nearest frame")], 220)
        expectEqual(two.text, "Platfor… › … › Types › … › Nearest frame")
        expectEqual(two.pieces.filter { $0.kind == .ellipsis }.count, 2)
        for room in stride(from: 24 as CGFloat, through: 300, by: 7) {
            for steps in [steps, ladder(7)] {
                expect(fold(steps, room).pieces.filter { $0.kind == .ellipsis }.count <= 2, "room \(room)")
            }
        }
    },
    test("with the middle empty, the first name is cut to bring back the step beside the nearest, never under 34 points") {
        let steps = [frame("Platform layer"), frame("Horizontals"), board("Types"), frame("Fields"), frame("Nearest frame")]
        expectEqual(text(steps, 205), "Platform layer › … › Nearest frame")
        expectEqual(text(steps, 210), "Platf… › … › Types › … › Nearest frame")
        expectEqual(text(steps, 215), "Platfo… › … › Types › … › Nearest frame")
        // Under what a first name cut to its floor leaves, the board stays out and the first is cut at its end only.
        expectEqual(text(steps, 175), "Platform… › … › Nearest frame")
        expectEqual(text(steps, 141), "Platf… › … › Nearest frame")
        // The first name is cut to a target no smaller than the floor, so some of it is always said.
        for room in stride(from: 100 as CGFloat, through: 234, by: 1) {
            let line = fold(steps, room)
            guard let first = line.pieces.first(where: { $0.isStep }), first.wasCut, case .step(let index, _, _) = first.kind, index == 0 else { continue }
            expect(first.text.count >= 4, "room \(room): \(line.text)")
        }
    },
    test("the first name is not cut under 34 points: the nearest stands after a … instead") {
        let steps = [frame("Platform layer"), frame("Horizontals: shape traits"), frame("A very long nearest frame name here")]
        expectEqual(text(steps, 150), "… › A very long nearest…")
        expectEqual(text(steps, 110), "… › A very long…")
        expectEqual(text(steps, 80), "… › A very…")
        let narrow = fold(steps, 30)
        expectEqual(narrow.text, "… › …")
        expect(narrow.width <= 30)
        let alone = fold([frame("Platform layer"), frame("Horizontals"), frame("Types"), frame("Types/Fields")], 100)
        expectEqual(alone.text, "… › Types/Fields")
        expect(alone.isFolded && !alone.isCut, "the nearest fits whole")
    },
    test("the nearest is cut only when it doesn't fit alone") {
        let steps = [frame("Platform layer"), frame("Horizontals"), frame("Types"), frame("Types/Fields")]
        let whole = fold(steps, 90)
        expectEqual(whole.text, "… › Types/Fields")
        expect(whole.pieces.last?.wasCut == false)
        let cut = fold([frame("Platform layer"), frame("Horizontals: shape traits"), frame("A very long nearest frame name here")], 110)
        expect(cut.pieces.last?.wasCut == true)
    },
    test("a line never exceeds its room, folded and cut as it must be, over many rooms") {
        let cases: [[PlaceStep]] = [
            ladder(7),
            [board("Workflows and steps"), board("order/exchange flows"), frame("Workflows (order/exchange)")],
            [frame("nexus-messaging-temporal-operation/src/callerpattern/caller")],
            [frame("Platform layer"), frame("Horizontals: shape traits"), board("Types"), frame("Types/Fields")],
        ]
        for steps in cases {
            for room in stride(from: 24 as CGFloat, through: 400, by: 1) {
                let line = fold(steps, room)
                // The shortest line there is, "… › …" (30), is the one that may stand over a narrow room.
                expect(line.width <= max(room, 30), "room \(room): \(line.text) is \(line.width)")
                let measured = line.pieces.reduce(0 as CGFloat) { total, piece in
                    if case .step(_, let isBoard, _) = piece.kind { return total + placeWidth(piece.text, isBoard) }
                    return total + placeWidth(piece.text, false)
                }
                expectEqual(line.width, measured, "room \(room): width is the pieces'")
            }
        }
    },
    test("a wider room only ever says more: the steps shown at one room are shown at a wider one") {
        let steps = ladder(7)
        var before = 0
        for room in stride(from: 24 as CGFloat, through: 400, by: 1) {
            let shown = fold(steps, room).pieces.filter { piece in if case .step = piece.kind { true } else { false } }.count
            expect(shown >= before - 0 || room < 60, "room \(room) shows \(shown) after \(before)")
            before = shown
        }
        expect(!fold(steps, 400).isShortened, "and the whole in the end")
    },
    test("the measure is the caller's: a wider font folds sooner, and a board's name is measured as a board") {
        let steps = [board("Workflows and steps"), board("customer flows"), frame("Workflows (customer)")]
        let wide = PlaceFold.line(for: steps, room: 234) { text, isBoard in placeWidth(text, isBoard) * 1.5 }
        expect(wide.text != fold(steps, 234).text)
        var boards: [String] = [], frames: [String] = []
        _ = PlaceFold.line(for: steps, room: 234) { text, isBoard in
            if isBoard { boards.append(text) } else { frames.append(text) }
            return placeWidth(text, isBoard)
        }
        expect(boards.contains("Workflows and steps") && boards.contains("customer flows"))
        expect(!frames.contains("Workflows and steps"))
        expect(frames.contains("Workflows (customer)"))
    },
])
