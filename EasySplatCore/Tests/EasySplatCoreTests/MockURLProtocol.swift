import Foundation

final class MockURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let tokenQueryItem = "easysplat_test_token"
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    private static let lock = NSLock()

    static func register(token: String, handler: @escaping Handler) {
        lock.lock()
        handlers[token] = handler
        lock.unlock()
    }

    static func unregister(token: String) {
        lock.lock()
        handlers.removeValue(forKey: token)
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        return token(for: request) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
    }

    private static func handler(for request: URLRequest) -> Handler? {
        guard let token = token(for: request) else {
            return nil
        }
        lock.lock()
        let handler = handlers[token]
        lock.unlock()
        return handler
    }

    private static func token(for request: URLRequest) -> String? {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        return components.queryItems?.first(where: { $0.name == tokenQueryItem })?.value
    }
}
