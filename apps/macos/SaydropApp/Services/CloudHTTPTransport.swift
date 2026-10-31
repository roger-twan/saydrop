import Foundation

/// A deliberately small foreground transport for the fixed Saydrop product API.
/// It keeps response accumulation bounded and rejects every redirect.
struct CloudHTTPResponse {
    let statusCode: Int
    let data: Data
}

private final class CloudHTTPTaskHandle {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false
    private var expired = false
    var didExpire: Bool { lock.lock(); defer { lock.unlock() }; return expired }
    func expire() { lock.lock(); expired = true; lock.unlock(); cancel() }

    func set(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

private final class CloudHTTPState {
    let continuation: CheckedContinuation<CloudHTTPResponse, Error>
    var response: HTTPURLResponse?
    var body = Data()
    var failure: Error?

    init(_ continuation: CheckedContinuation<CloudHTTPResponse, Error>) {
        self.continuation = continuation
    }
}

final class CloudHTTPTransport: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    static let maximumResponseBytes = 1_024 * 1_024

    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var states: [Int: CloudHTTPState] = [:]
    private var invalidated = false
    private var session: URLSession!

    init(protocolClasses: [AnyClass]? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        self.configuration = configuration
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func execute(_ request: URLRequest) async throws -> CloudHTTPResponse {
        try Task.checkCancellation()
        let handle = CloudHTTPTaskHandle()
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(min(60, request.timeoutInterval))); handle.expire() } catch { }
        }
        defer { watchdog.cancel() }
        do { return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                let isInvalidated = invalidated
                lock.unlock()
                guard !isInvalidated else {
                    continuation.resume(throwing: CloudClientError.unavailable)
                    return
                }

                let task = session.dataTask(with: request)
                let state = CloudHTTPState(continuation)
                lock.lock()
                states[task.taskIdentifier] = state
                lock.unlock()
                handle.set(task)
                task.resume()
            }
        }, onCancel: {
            handle.cancel()
        }) } catch {
            if Task.isCancelled { throw CancellationError() }
            if handle.didExpire { throw CloudClientError.timeout }
            throw error
        }
    }

    func cancelAll() {
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
    }

    func invalidate() {
        lock.lock()
        invalidated = true
        lock.unlock()
        session.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        let state = states[dataTask.taskIdentifier]
        if let response = response as? HTTPURLResponse {
            state?.response = response
            if response.expectedContentLength > Int64(Self.maximumResponseBytes) { state?.failure = CloudClientError.invalidResponse }
        } else {
            state?.failure = CloudClientError.invalidResponse
        }
        let reject = state?.failure != nil
        lock.unlock()
        completionHandler(reject ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var shouldCancel = false
        lock.lock()
        if let state = states[dataTask.taskIdentifier], state.failure == nil {
            if data.count > Self.maximumResponseBytes - state.body.count {
                state.failure = CloudClientError.invalidResponse
                shouldCancel = true
            } else {
                state.body.append(data)
            }
        }
        lock.unlock()
        if shouldCancel { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let state = states.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let state else { return }

        if let failure = state.failure {
            state.continuation.resume(throwing: failure)
        } else if let error {
            state.continuation.resume(throwing: error)
        } else if let response = state.response {
            state.continuation.resume(returning: CloudHTTPResponse(statusCode: response.statusCode, data: state.body))
        } else {
            state.continuation.resume(throwing: CloudClientError.invalidResponse)
        }
    }

    /// A cloud disclosure is consent for one fixed endpoint, never for a redirect target.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
