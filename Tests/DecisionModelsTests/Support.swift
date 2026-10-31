import CanvasRPC
import DecisionModels
import Foundation
import LanguageModels
import os
import TestKit

/// The network, stubbed: a session whose every request goes to `StubProtocol`, which keeps it and
/// answers what the test said to (a status and a body, a transport error, or nothing, until the
/// request is cancelled). Nothing leaves the machine.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    enum Answer: Sendable {
        case http(status: Int, body: String)
        case failure(URLError.Code)
        /// Never answers: the request waits until it's cancelled.
        case hang
    }

    /// A request as it arrived, its body read out of its stream.
    struct Received: Sendable {
        let request: URLRequest
        let body: Data
    }

    private struct State {
        var answer: Answer = .failure(.notConnectedToInternet)
        var received: [Received] = []
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// A session that reaches only this stub, answering `answer` from now on.
    static func session(answering answer: Answer) -> URLSession {
        state.withLock { $0 = State(answer: answer) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    static var received: [Received] { state.withLock { $0.received } }

    /// Every request any session makes, the shared one too, goes to the stub while `body` runs,
    /// answering `answer`: for a model made without a session of the test's.
    @MainActor
    static func intercepting(_ answer: Answer, _ body: () throws -> Void) rethrows {
        state.withLock { $0 = State(answer: answer) }
        URLProtocol.registerClass(StubProtocol.self)
        defer { URLProtocol.unregisterClass(StubProtocol.self) }
        try body()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.readAll) ?? Data()
        let answer = Self.state.withLock { state in
            state.received.append(Received(request: request, body: body))
            return state.answer
        }
        switch answer {
        case let .http(status, text):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["content-type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .hang:
            break
        }
    }

    override func stopLoading() {}

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// A fake key: what the tests save, and expect in the header.
let testKey = "ts-test-0123456789"

/// A key store in a new temporary directory, which `body` may fill; removed after.
@MainActor
func withTemporaryStore(_ body: (TypeSafeKeyStore) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "DecisionModelsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(TypeSafeKeyStore(url: directory.appending(path: "InfiniteCanvas/typesafe-api-key", directoryHint: .notDirectory)))
}

/// Jev, with `testKey` saved in a temporary store, over a session that reaches only the stub.
@MainActor
func withStubbedJev(answering answer: StubProtocol.Answer, _ body: (JevModel) throws -> Void) throws {
    try withTemporaryStore { keys in
        try keys.write(testKey)
        try body(JevModel(keys: keys, session: StubProtocol.session(answering: answer)))
    }
}

/// Two questions about a car, as a rule would ask them.
let carRequest = DecisionRequest(
    state: ["shape": ["title": "1990 Mercedes-Benz 300D", "values": ["year": 1990, "mileage": 2_900_000]]],
    preface: "These rules come from the car's types.",
    questions: [DecisionQuestion(id: "all", asks: "Read together, should this car be flagged?", yes: "Flag it", no: "Don't flag it"),
                DecisionQuestion(id: "r0", asks: "Does rule 1 flag it?")])

/// What `model` answers `request`, or the error it throws.
@MainActor
func outcome(of model: any DecisionModel, _ request: DecisionRequest = carRequest) throws -> Result<DecisionAnswers, DecisionModelError> {
    try awaitResult {
        do throws(DecisionModelError) {
            return .success(try await model.decide(request))
        } catch {
            return .failure(error)
        }
    }
}

/// A reply from Jev's API.
func jevReply(_ answers: [String: Double], model: String = "jev-1.14.0") -> String {
    let listed = answers.keys.sorted().map { #""\#($0)":{"type":"noul","noul":\#(answers[$0]!)}"# }.joined(separator: ",")
    return #"{"model":"\#(model)","usage":{"input_tokens":3603,"output_tokens":38},"answers":{\#(listed)}}"#
}
