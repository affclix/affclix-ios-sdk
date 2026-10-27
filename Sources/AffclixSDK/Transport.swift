import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A request built — and signed — once, so retries and offline replays resend
/// exactly the bytes first sent: same event_id, same signature.
struct PreparedRequest: Codable, Equatable {
    let url: URL
    let body: Data
}

enum DeliveryError: Error, Equatable {
    /// No connection, timeout, 429 or 5xx: worth retrying later.
    case transient(String)
    /// Any other HTTP status: retrying will not help.
    case rejected(Int)
}

protocol Transport {
    func post(_ request: PreparedRequest, completion: @escaping (Result<Data, DeliveryError>) -> Void)
}

struct URLSessionTransport: Transport {
    let session: URLSession

    init(timeout: TimeInterval) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.httpCookieStorage = nil
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    func post(_ request: PreparedRequest, completion: @escaping (Result<Data, DeliveryError>) -> Void) {
        var r = URLRequest(url: request.url)
        r.httpMethod = "POST"
        r.httpBody = request.body
        r.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        r.setValue("AffclixSDK/\(Affclix.sdkVersion) (iOS)", forHTTPHeaderField: "User-Agent")
        r.setValue(Affclix.sdkVersion, forHTTPHeaderField: "X-SDK-Version")
        r.setValue("ios", forHTTPHeaderField: "X-SDK-Platform")
        session.dataTask(with: r) { data, response, error in
            if let error = error {
                completion(.failure(.transient(error.localizedDescription)))
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200..<300: completion(.success(data ?? Data()))
            case 429, 500...: completion(.failure(.transient("HTTP \(code)")))
            default: completion(.failure(.rejected(code)))
            }
        }.resume()
    }
}

/// Retries transient failures with exponential backoff and jitter, then hands
/// the last failure back (the caller queues it offline).
final class RetryingSender {
    private let transport: Transport
    private let maxRetries: Int
    private let baseDelay: TimeInterval
    private let maxDelay: TimeInterval
    private let queue: DispatchQueue

    init(transport: Transport, maxRetries: Int, baseDelay: TimeInterval = 1, maxDelay: TimeInterval = 30, queue: DispatchQueue) {
        self.transport = transport
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.queue = queue
    }

    func send(_ request: PreparedRequest, completion: @escaping (Result<Data, DeliveryError>) -> Void) {
        attempt(request, 0, completion)
    }

    private func attempt(_ request: PreparedRequest, _ n: Int, _ completion: @escaping (Result<Data, DeliveryError>) -> Void) {
        transport.post(request) { [self] result in
            guard case .failure(.transient) = result, n < maxRetries else {
                completion(result)
                return
            }
            let delay = min(baseDelay * pow(2, Double(n)) + Double.random(in: 0...(baseDelay / 2)), maxDelay)
            queue.asyncAfter(deadline: .now() + delay) { self.attempt(request, n + 1, completion) }
        }
    }
}
