import Foundation

/// Retries transient URLSession failures (connection lost / timeout) once
/// after a short delay. VPN handoffs and flaky proxies commonly cause these.
enum HTTPRetry {
    private static let retryableCodes: [Int] = [
        NSURLErrorNetworkConnectionLost,   // -1005
        NSURLErrorTimedOut,                // -1001
        NSURLErrorCannotConnectToHost,     // -1004
    ]

    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await run { try await URLSession.shared.data(for: request) }
    }

    static func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        try await run { try await URLSession.shared.bytes(for: request) }
    }

    private static func run<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as NSError {
            guard retryableCodes.contains(error.code), !Task.isCancelled else { throw error }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            return try await operation()
        }
    }
}
