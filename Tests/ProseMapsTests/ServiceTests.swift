@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import LanguageModels
import ProseMaps
import TestKit

@MainActor let serviceTests = Suite("Prose maps: asking", [
    test("a pair read with no answer is asked about as the frame ends, once; its answer is placed, and read again it's the same map, placed once") {
        let b = try MapBench()
        let id = b.box()
        expect(b.read(id) == nil, "no answer yet")
        expectEqual(b.asked.count, 0, "not until the frame that read it ends")
        b.frame()
        b.settle()
        expectEqual(b.asked.count, 1)
        expectEqual(b.asked.first?.messages, [.user("<prose>\n\(menuProse)\n</prose>\n\n<code>\n\(menuCode)\n</code>")])
        expectEqual(b.asked.first?.system, ProseMapPrompt.system(for: Snippet.self))
        let map = try require(b.read(id))
        expectEqual(b.quotes(map), ["sum", "every item", "over ten dollars"])
        expectEqual(b.maps.revision(of: id), 1)
        let placed = b.maps.placed
        expect(b.read(id) === map, "the same map")
        expectEqual(b.maps.placed, placed, "placed once")
        b.frame()
        b.settle()
        expectEqual(b.asked.count, 1, "asked once")
        let copy = b.box(at: 200)
        expectEqual(b.quotes(b.read(copy)), ["sum", "every item", "over ten dollars"], "the same texts on another shape")
        b.frame()
        b.settle()
        expectEqual(b.asked.count, 1)
    },
    test("a pair is asked about only while its reader says it may be, which is asked only of a pair with no answer") {
        let b = try MapBench()
        let id = b.box()
        var asks = 0
        _ = b.maps.map(Snippet.self, of: id, prose: menuProse, target: menuCode) {
            asks += 1
            return false
        }
        b.frame()
        b.settle()
        expectEqual(b.asked.count, 0, "not while it says no")
        expectEqual(asks, 1)
        _ = b.read(id)
        b.frame()
        b.settle()
        expectEqual(b.asked.count, 1)
        _ = b.maps.map(Snippet.self, of: id, prose: menuProse, target: menuCode) {
            asks += 1
            return true
        }
        expectEqual(asks, 1, "not asked of a pair with an answer")
    },
    test("nothing is asked for blank prose, a shape being edited, a shape not on the board shown, or without a model") {
        let b = try MapBench()
        _ = b.read(b.box(), " \n ")
        let card = b.h.add(Card(CGRect(x: 0, y: 100, width: 100, height: 60)))
        expect(b.editor.beginEditing(card))
        _ = b.read(card, "its words, being typed")
        _ = b.read(ShapeID(), "a shape that isn't here")
        b.frame()
        b.settle()
        expectEqual(b.asked.count, 0)
        b.editor.endEditing()
        _ = b.read(card, "its words, being typed")
        b.frame()
        b.settle()
        expectEqual(b.asked.count, 1, "once editing ends")
        let bare = try MapBench(model: false)
        _ = bare.read(bare.box())
        bare.frame()
        expectEqual(bare.maps.callsOut + bare.maps.callsWaiting, 0)
    },
    test("while words are typed, the shape's last answer stands in, found in them as they are: words kept keep their links, words typed over lose theirs") {
        let b = try MapBench()
        b.answer = .success(ModelResponse(text: pastaAnswer))
        let id = b.box()
        @MainActor func read(_ prose: String, _ recipe: String = pastaRecipe) -> [String] {
            b.quotes(b.maps.map(Steps.self, of: id, prose: prose, target: recipe))
        }
        _ = read(pastaProse)
        b.frame()
        b.settle()
        expectEqual(read(pastaProse), ["boil", "add the pasta", "stir if it sticks"])
        expectEqual(Steps.located, 1)
        b.model.holdsAnswers = true
        expectEqual(read("first " + pastaProse), ["boil", "add the pasta", "stir if it sticks"], "in their new places")
        expectEqual(Steps.located, 1, "the recipe the same: its steps aren't found again")
        expectEqual(read("boil the water, then drain"), ["boil"], "words typed over")
        expectEqual(read(pastaProse, "boil water\nadd pasta"), ["boil", "add the pasta"], "a step taken out")
        expectEqual(Steps.located, 2, "found again in the recipe as it is")
        b.frame()
        spinRunLoop(until: { b.model.waiting == 1 })
        expectEqual(b.asked.count, 2, "the pair read last: one asked as the frame ends")
        b.model.holdsAnswers = false
        b.model.release()
        b.settle()
    },
    test("an answer is kept for the pair it was asked of, whatever the shape says by the time it lands") {
        let b = try MapBench()
        b.model.holdsAnswers = true
        let id = b.box()
        _ = b.read(id)
        b.frame()
        spinRunLoop(until: { b.model.waiting == 1 })
        _ = b.read(id, "the sum of the prices of every item")
        b.model.holdsAnswers = false
        b.model.release()
        b.settle()
        expectEqual(b.quotes(b.read(id, "the sum of the prices of every item")), ["sum", "every item"], "its last answer, on what it says now")
        let other = b.box(at: 200)
        expectEqual(b.quotes(b.read(other)), ["sum", "every item", "over ten dollars"], "the pair it was asked of")
    },
    test("an answer a shape reads for its pair is its last too: a copy's words, typed into, keep their links") {
        let b = try MapBench()
        let id = b.box()
        _ = b.read(id)
        b.frame()
        b.settle()
        let copy = b.box(at: 200)
        expectEqual(b.quotes(b.read(copy)), ["sum", "every item", "over ten dollars"], "its pair's answer")
        expectEqual(b.quotes(b.read(copy, "sum the prices of every item")), ["sum", "every item"], "the words still there, as it's typed")
    },
    test("the same words written another way (an accent as two scalars, then one) are another map, its ranges of its own text") {
        let b = try MapBench()
        let id = b.box()
        let decomposed = menuProse + ", the cafe\u{301}'s", composed = menuProse + ", the caf\u{E9}'s"
        expect(decomposed == composed && decomposed.utf8.count != composed.utf8.count, "equal to Swift, written apart")
        _ = b.read(id, decomposed)
        b.frame()
        b.settle()
        let first = try require(b.read(id, decomposed)), second = try require(b.read(id, composed))
        expect(first !== second, "placed again")
        expectEqual(second.links.map { String(composed[$0.inProse]) }, ["sum", "every item", "over ten dollars"])
        expectEqual(second.links.map { NSRange($0.inProse, in: composed).location }, [0, 18, 29])
    },
    test("a pair that failed, or whose answer can't be read, isn't asked about again, but once a key is saved; one cancelled is, when it's next read") {
        let b = try MapBench()
        b.answer = .failure(.notSignedIn)
        let id = b.box()
        for _ in 0..<2 {
            _ = b.read(id)
            b.frame()
            b.settle()
        }
        expectEqual(b.asked.count, 1, "asked once")
        b.answer = .success(ModelResponse(text: "Sorry, I can't."))
        b.keySaved()
        for _ in 0..<2 {
            _ = b.read(id)
            b.frame()
            b.settle()
        }
        expectEqual(b.asked.count, 2, "once after the key; unreadable, then not again")
        b.answer = .failure(.cancelled)
        _ = b.read(id, "the prices")
        b.frame()
        b.settle()
        b.answer = .success(ModelResponse(text: menuAnswer))
        _ = b.read(id, "the prices")
        b.frame()
        b.settle()
        expectEqual(b.asked.count, 4, "cancelled, then asked again")
        expect(b.read(id, "the prices") != nil)
    },
    test("a call that failed for a reason that may pass (rate limited, overloaded, the network, a timeout) is asked again after a while, when next read; a refused one never") {
        let b = try MapBench()
        b.answer = .failure(.rateLimited)
        let id = b.box()
        _ = b.read(id)
        b.frame()
        b.settle()
        expectEqual(b.asked.count, 1)
        // Not at once.
        for _ in 0..<2 {
            _ = b.read(id)
            b.frame()
            b.settle()
        }
        expectEqual(b.asked.count, 1, "cooling")
        b.h.scheduler.advance(by: ProseMapService.retryDelay)
        b.answer = .success(ModelResponse(text: menuAnswer))
        _ = b.read(id)
        b.frame()
        b.settle()
        expectEqual(b.asked.count, 2, "asked again")
        expect(b.read(id) != nil, "and answered")
        for error in [LanguageModelError.overloaded, .network("down"), .timedOut, .server(status: 503, message: "down")] {
            let other = b.box(at: 300)
            b.answer = .failure(error)
            _ = b.read(other, "the prices of \(error)")
            b.frame()
            b.settle()
            let before = b.asked.count
            b.h.scheduler.advance(by: ProseMapService.retryDelay)
            b.answer = .success(ModelResponse(text: menuAnswer))
            _ = b.read(other, "the prices of \(error)")
            b.frame()
            b.settle()
            expectEqual(b.asked.count, before + 1, "\(error) is asked again")
        }
        let refused = b.box(at: 600)
        b.answer = .failure(.unauthorized)
        _ = b.read(refused, "the unauthorized")
        b.frame()
        b.settle()
        let before = b.asked.count
        b.h.scheduler.advance(by: ProseMapService.retryDelay)
        b.answer = .success(ModelResponse(text: menuAnswer))
        _ = b.read(refused, "the unauthorized")
        b.frame()
        b.settle()
        expectEqual(b.asked.count, before, "unauthorized waits for a key")
    },
    test("at most 4 calls are out at once, the rest waiting their turn; another board shown drops those waiting for shapes not on it") {
        let b = try MapBench()
        b.model.holdsAnswers = true
        for n in 0..<6 { _ = b.read(b.box(at: CGFloat(n) * 50), "\(menuProse) (\(n))") }
        b.frame()
        spinRunLoop(until: { b.model.waiting == 4 })
        expectEqual(b.maps.callsOut, 4)
        expectEqual(b.maps.callsWaiting, 2)
        let pocket = b.h.add(Pocket(CGRect(x: 0, y: 200, width: 100, height: 60)))
        expect(b.h.enter(pocket))
        expectEqual(b.maps.callsWaiting, 0)
        b.model.holdsAnswers = false
        b.model.release()
        b.settle()
        expectEqual(b.asked.count, 4, "the calls out land; those that waited, never asked")
    },
    test("a shape deleted keeps nothing: no last answer stands in for what a shape of its id says, and its revision starts over") {
        let b = try MapBench()
        let id = b.box()
        _ = b.read(id)
        b.frame()
        b.settle()
        expectEqual(b.maps.revision(of: id), 1)
        b.editor.transact { $0.delete([id]) }
        expectEqual(b.maps.revision(of: id), 0)
        expect(b.read(id, "the sum of every item") == nil, "no last answer")
        expectEqual(b.quotes(b.read(id)), ["sum", "every item", "over ten dollars"], "its pair's answer, kept by its texts")
    },
    test("a call out when the file closes is cancelled, not left running on an answer nothing lands") {
        var b: MapBench? = try MapBench()
        let model = try require(b?.model)
        model.holdsAnswers = true
        weak var closing = b?.editor
        let id = try require(b?.box())
        _ = b?.read(id)
        b?.frame()
        spinRunLoop(until: { model.waiting == 1 })
        expectEqual(b?.maps.callsOut, 1, "the call is out")
        b = nil
        spinRunLoop(until: { model.waiting == 0 && model.answered == 1 })
        expect(closing == nil, "the editor went as its file closed")
        expectEqual(model.waiting, 0, "the call isn't left holding")
        expectEqual(model.answered, 1, "it ended: cancelled")
    },
])
