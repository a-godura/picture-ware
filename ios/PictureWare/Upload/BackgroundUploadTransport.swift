import Foundation

/// `UploadTransport` on a background `URLSession`: uploads keep going while the app is suspended,
/// and the system relaunches the app in the background when they finish
/// (`UploadAppDelegate` hands us the completion handler).
///
/// Each task's `taskDescription` is the queue item id, which is how results are matched back to
/// items, including after a relaunch. Results that arrive before the queue asks for them
/// (e.g. events delivered during a background relaunch) are kept until `attach` collects them.
final class BackgroundUploadTransport: NSObject, UploadTransport, URLSessionDataDelegate, @unchecked Sendable {
    static let sessionIdentifier = "com.agodura.pictureware.uploads"

    /// One per process: two sessions with the same background identifier aren't allowed.
    static let shared = BackgroundUploadTransport()

    // All mutable state is guarded by `lock`.
    private let lock = NSLock()
    private var waiters: [String: CheckedContinuation<Int, any Error>] = [:]
    private var progressHandlers: [String: @Sendable (Double) -> Void] = [:]
    private var finished: [String: Result<Int, any Error>] = [:]
    private var eventsCompletionHandler: (@Sendable () -> Void)?
    /// The session finished delivering events before the app delegate handed us its handler.
    private var eventsFinishedWithoutHandler = false
    private var session: URLSession!

    init(configuration: URLSessionConfiguration = BackgroundUploadTransport.backgroundConfiguration()) {
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    static func backgroundConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        // User-initiated: start now rather than whenever the system finds convenient.
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.httpMaximumConnectionsPerHost = 4
        return configuration
    }

    /// Called from `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    func setEventsCompletionHandler(_ handler: @escaping @Sendable () -> Void) {
        let callNow = lock.withLock {
            if eventsFinishedWithoutHandler {
                eventsFinishedWithoutHandler = false
                return true
            }
            eventsCompletionHandler = handler
            return false
        }
        if callNow { DispatchQueue.main.async { handler() } }
    }

    // MARK: - UploadTransport

    func attach(itemID: String, progress: @escaping @Sendable (Double) -> Void) async throws -> Int? {
        if let result = lock.withLock({ finished.removeValue(forKey: itemID) }) { return try result.get() }
        let tasks = await session.allTasks
        let isRunning = tasks.contains { $0.taskDescription == itemID && ($0.state == .running || $0.state == .suspended) }
        if !isRunning {
            // It may have completed while we were looking.
            return try lock.withLock({ finished.removeValue(forKey: itemID) })?.get()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let earlier: Result<Int, any Error>? = lock.withLock {
                    if let result = finished.removeValue(forKey: itemID) { return result }
                    waiters[itemID] = continuation
                    progressHandlers[itemID] = progress
                    return nil
                }
                if let earlier { continuation.resume(with: earlier) }
            }
        } onCancel: {
            Task { await self.cancel(itemID: itemID) }
        }
    }

    func upload(itemID: String, bodyFile: URL, contentType: String, to url: URL,
                progress: @escaping @Sendable (Double) -> Void) async throws -> Int {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    finished[itemID] = nil
                    waiters[itemID] = continuation
                    progressHandlers[itemID] = progress
                }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
                let task = session.uploadTask(with: request, fromFile: bodyFile)
                task.taskDescription = itemID
                task.resume()
            }
        } onCancel: {
            Task { await self.cancel(itemID: itemID) }
        }
    }

    func cancel(itemID: String) async {
        for task in await session.allTasks where task.taskDescription == itemID {
            task.cancel()
        }
        lock.withLock { _ = finished.removeValue(forKey: itemID) }
    }

    // MARK: - URLSessionDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard let id = task.taskDescription, totalBytesExpectedToSend > 0,
              let handler = lock.withLock({ progressHandlers[id] }) else { return }
        handler(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let id = task.taskDescription else { return }
        let result: Result<Int, any Error>
        if let error {
            result = .failure(error)
        } else if let response = task.response as? HTTPURLResponse {
            result = .success(response.statusCode)
        } else {
            result = .failure(APIError.invalidResponse)
        }
        let waiter: CheckedContinuation<Int, any Error>? = lock.withLock {
            progressHandlers[id] = nil
            if let waiter = waiters.removeValue(forKey: id) { return waiter }
            finished[id] = result
            return nil
        }
        waiter?.resume(with: result)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = lock.withLock {
            defer { eventsCompletionHandler = nil }
            if eventsCompletionHandler == nil { eventsFinishedWithoutHandler = true }
            return eventsCompletionHandler
        }
        // Must be called on the main thread; lets the system snapshot the UI and suspend us again.
        DispatchQueue.main.async { handler?() }
    }
}
