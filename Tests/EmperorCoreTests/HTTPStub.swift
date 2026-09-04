import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import EmperorCore

/// A stand-in server at the `URLSession` layer.
///
/// `APIClient` already accepts an injected `URLSession`, so nothing in the client had to change
/// to make this possible — the seam was there and unused. Everything below the seam is real:
/// the request is genuinely built, serialised and dispatched, so what these tests pin is the
/// bytes that would go on the wire rather than an in-memory approximation.
final class HTTPStub: URLProtocol {

    struct Reply {
        var status: Int = 200
        var body: Data = Data()
        var headers: [String: String] = ["Content-Type": "application/json"]

        static func json(_ raw: String, status: Int = 200) -> Reply {
            Reply(status: status, body: Data(raw.utf8))
        }

        static func text(_ raw: String, status: Int = 200) -> Reply {
            Reply(status: status, body: Data(raw.utf8),
                  headers: ["Content-Type": "text/plain"])
        }
    }

    /// Shared mutable state behind a lock: `URLProtocol` is instantiated by `URLSession` on its
    /// own queues, so neither the queue nor the isolation domain is ours to choose.
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _handler: (@Sendable (URLRequest) throws -> Reply)?
        private var _seen: [URLRequest] = []

        var handler: (@Sendable (URLRequest) throws -> Reply)? {
            get { lock.withLock { _handler } }
            set { lock.withLock { _handler = newValue } }
        }

        var seen: [URLRequest] { lock.withLock { _seen } }
        func record(_ request: URLRequest) { lock.withLock { _seen.append(request) } }
        func reset() { lock.withLock { _handler = nil; _seen = [] } }
    }

    private static let box = Box()

    /// Every request that reached the transport, in order.
    static var seen: [URLRequest] { box.seen }
    static var lastRequest: URLRequest? { box.seen.last }

    static func respond(_ handler: @escaping @Sendable (URLRequest) throws -> Reply) {
        box.handler = handler
    }

    static func always(_ reply: Reply) {
        box.handler = { _ in reply }
    }

    static func fail(_ error: Error) {
        let boxed = UncheckedBox(error)
        box.handler = { _ in throw boxed.value }
    }

    /// Clears the handler and the record of what was sent.
    ///
    /// - Important: call this from `setUp`, not only from `tearDown`. The box is one static per
    ///   process, shared by every suite, so a class that cleans up only afterwards leaves its
    ///   **first** test reading whatever the previously-run class left behind. That is not a
    ///   race: XCTest runs classes in a fixed order, so it fails the same way every time — and
    ///   it is invisible in CI, which runs `swift test --parallel` and splits classes across
    ///   processes, so the two suites involved need never meet.
    ///
    ///   `ProjectServiceWireTests.testABlankIdIsRefusedWithoutASingleRequest` asserted
    ///   `seen.isEmpty` and inherited a `/preferred-model` request from the suite before it.
    ///   Seven other suites had the same `tearDown`-only shape and were one alphabetical
    ///   accident away from the same failure.
    static func reset() { box.reset() }

    /// A `URLSession` wired to this stub and nothing else.
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPStub.self]
        return URLSession(configuration: configuration)
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // `httpBody` is dropped in favour of a stream for some request shapes, so read both —
        // otherwise a POST body assertion silently sees nil and the test passes vacuously.
        var recorded = request
        if recorded.httpBody == nil, let stream = recorded.httpBodyStream {
            recorded.httpBody = Self.drain(stream)
        }
        Self.box.record(recorded)

        guard let handler = Self.box.handler else {
            client?.urlProtocol(self, didFailWithError: APIError.transport("No stub configured."))
            return
        }

        do {
            let reply = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: reply.status,
                httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(contentsOf: buffer[0..<read])
        }
        return data
    }
}

/// Carries a non-`Sendable` error into a `@Sendable` closure. Test-only.
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

// MARK: - Request conveniences

extension URLRequest {
    var queryItems: [String: String] {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems
        else { return [:] }
        return items.reduce(into: [:]) { $0[$1.name] = $1.value }
    }

    var path: String { url?.path ?? "" }

    func header(_ name: String) -> String? { value(forHTTPHeaderField: name) }

    var bodyJSON: [String: Any] {
        guard let httpBody,
              let object = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any]
        else { return [:] }
        return object
    }
}
