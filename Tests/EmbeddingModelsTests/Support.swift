import EmbeddingModels
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
        /// Answers each request by what it said: a status and a body.
        case computed(@Sendable (Received) -> (status: Int, body: String))
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
        case let .computed(answer):
            let (status, text) = answer(Received(request: request, body: body))
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["content-type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
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
let testKey = "sk-test-0123456789abcdef"

/// A key store in a new temporary directory, which `body` may fill; removed after.
@MainActor
func withTemporaryStore(_ body: (OpenAIKeyStore) throws -> Void) throws {
    try withTemporaryDirectory { directory in
        try body(OpenAIKeyStore(url: directory.appending(path: "InfiniteCanvas/openai-api-key", directoryHint: .notDirectory)))
    }
}

/// OpenAI's model, with `testKey` saved in a temporary store, over a session that reaches only the stub.
@MainActor
func withStubbedModel(answering answer: StubProtocol.Answer, textsPerRequest: Int = 256, _ body: (OpenAIEmbeddingModel) throws -> Void) throws {
    try withTemporaryStore { keys in
        try keys.write(testKey)
        try body(OpenAIEmbeddingModel(keys: keys, textsPerRequest: textsPerRequest, session: StubProtocol.session(answering: answer)))
    }
}

/// The base64 of `vector` as little-endian Float32, as OpenAI's `encoding_format: base64` sends it.
func base64(_ vector: [Float]) -> String {
    var bytes: [UInt8] = []
    for value in vector {
        let bits = value.bitPattern
        bytes += (0..<4).map { UInt8(truncatingIfNeeded: bits >> (8 * $0)) }
    }
    return Data(bytes).base64EncodedString()
}

/// A reply from OpenAI's API: each vector with its `index`, in the order given (not necessarily the index's).
func embeddingReply(_ items: [(index: Int, vector: [Float])], model: String = "text-embedding-3-large") -> String {
    let data = items.map { #"{"object":"embedding","index":\#($0.index),"embedding":"\#(base64($0.vector))"}"# }.joined(separator: ",")
    return #"{"object":"list","data":[\#(data)],"model":"\#(model)","usage":{"prompt_tokens":8,"total_tokens":8}}"#
}

/// A reply with the vectors of `vectors`, indexed in order.
func embeddingReply(_ vectors: [[Float]]) -> String {
    embeddingReply(vectors.enumerated().map { (index: $0.offset, vector: $0.element) })
}

/// The texts a request asked for.
func inputs(of received: StubProtocol.Received) -> [String] {
    guard let object = try? JSONSerialization.jsonObject(with: received.body) as? [String: Any] else { return [] }
    return object["input"] as? [String] ?? []
}

/// A new temporary directory, removed after `body`.
@MainActor
func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "EmbeddingModelsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

/// The file a memory keeps its vectors in, in a new temporary directory (not made yet: the memory makes it).
@MainActor
func withVectorFile(_ body: (URL) throws -> Void) throws {
    try withTemporaryDirectory { directory in
        try body(directory.appending(path: "InfiniteCanvas/embedding-vectors.bin", directoryHint: .notDirectory))
    }
}

/// What `model` answers `texts`, or the error it throws.
@MainActor
func outcome(of model: any EmbeddingModel, _ texts: [String]) throws -> Result<[[Float]], EmbeddingModelError> {
    try awaitResult {
        do throws(EmbeddingModelError) {
            return .success(try await model.embed(texts))
        } catch {
            return .failure(error)
        }
    }
}

/// What `embeddings` answers `texts`, or the error it throws.
@MainActor
func outcome(of embeddings: Embeddings, _ texts: [String]) throws -> Result<EmbeddedTexts, EmbeddingModelError> {
    try awaitResult {
        do throws(EmbeddingModelError) {
            return .success(try await embeddings.vectors(of: texts))
        } catch {
            return .failure(error)
        }
    }
}

extension Result {
    var successValue: Success? { if case .success(let value) = self { value } else { nil } }
    var failureValue: Failure? { if case .failure(let error) = self { error } else { nil } }
}
