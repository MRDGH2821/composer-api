import Foundation

public final class CursorSDKHTTP2Transport: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?
    private var outputStream: OutputStream?
    private var inputStream: InputStream?
    private var responseData = Data()
    private var parser = IncrementalConnectFrameParser()
    private var requestContextSent = false
    private var statusCode = 0
    private var contentType = ""
    private var networkProtocolName: String?
    private var frameHandler: (@Sendable (Data) -> Void)?
    private var completed = false
    private var session: URLSession?

    public func run(request originalRequest: URLRequest, initialFrame: Data) async throws -> Data {
        try await runStreaming(request: originalRequest, initialFrame: initialFrame, onFrame: { _ in })
    }

    public func runStreaming(
        request originalRequest: URLRequest,
        initialFrame: Data,
        onFrame: @escaping @Sendable (Data) -> Void
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                self.continuation = continuation
                self.responseData = Data()
                self.parser = IncrementalConnectFrameParser()
                self.requestContextSent = false
                self.statusCode = 0
                self.contentType = ""
                self.networkProtocolName = nil
                self.frameHandler = onFrame
                self.completed = false
            }

            var readStream: InputStream?
            var writeStream: OutputStream?
            Stream.getBoundStreams(withBufferSize: 1024 * 1024, inputStream: &readStream, outputStream: &writeStream)
            guard let readStream, let writeStream else {
                finish(.failure(CursorAPIError.transport("Could not create SDK request stream.")))
                return
            }
            inputStream = readStream
            outputStream = writeStream
            outputStream?.open()

            var request = originalRequest
            request.httpBodyStream = readStream
            request.httpBody = nil

            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 180
            configuration.timeoutIntervalForResource = 180
            configuration.httpShouldUsePipelining = true
            configuration.httpMaximumConnectionsPerHost = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            let task = session.dataTask(with: request)
            task.resume()

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    try self?.write(initialFrame)
                } catch {
                    self?.finish(.failure(error))
                }
            }
        }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        if let http = response as? HTTPURLResponse {
            lock.withLock {
                statusCode = http.statusCode
                contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            }
        }
        return .allow
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock {
            responseData.append(data)
        }
        guard statusCode == 200, contentType.contains("application/connect+proto") else {
            return
        }
        for payload in parser.push(data) {
            frameHandler?(payload)
            if !requestContextSent, let context = CursorSDKRequestContext.decode(payload) {
                requestContextSent = true
                let frame = ConnectProto.frame(CursorSDKProto.requestContextResult(id: context.id, execID: context.execID))
                do {
                    try write(frame)
                    closeUpload()
                } catch {
                    finish(.failure(error))
                }
            }
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, needNewBodyStream completionHandler: @escaping (InputStream?) -> Void) {
        completionHandler(inputStream)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let name = metrics.transactionMetrics.last?.networkProtocolName
        lock.withLock {
            networkProtocolName = name
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            finish(.failure(error))
            return
        }
        let data = lock.withLock { responseData }
        let status = lock.withLock { statusCode }
        guard (200..<300).contains(status) else {
            let text = String(data: data, encoding: .utf8) ?? "status \(status)"
            finish(.failure(status == 401 ? CursorAPIError.unauthorized : CursorAPIError.upstream(text)))
            return
        }
        let protocolName = lock.withLock { networkProtocolName }
        guard protocolName == "h2" else {
            finish(.failure(CursorAPIError.transport("Cursor SDK transport did not negotiate HTTP/2\(protocolName.map { " (got \($0))" } ?? "").")))
            return
        }
        finish(.success(data))
    }

    private func write(_ data: Data) throws {
        guard let outputStream else {
            throw CursorAPIError.transport("SDK upload stream is closed.")
        }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let written = outputStream.write(base.advanced(by: sent), maxLength: data.count - sent)
                if written < 0 {
                    throw outputStream.streamError ?? CursorAPIError.transport("Could not write SDK upload stream.")
                }
                if written == 0 {
                    Thread.sleep(forTimeInterval: 0.005)
                    continue
                }
                sent += written
            }
        }
    }

    private func closeUpload() {
        outputStream?.close()
    }

    private func finish(_ result: Result<Data, any Error>) {
        let continuation: CheckedContinuation<Data, any Error>? = lock.withLock {
            if completed { return nil }
            completed = true
            let current = self.continuation
            self.continuation = nil
            self.frameHandler = nil
            return current
        }
        closeUpload()
        inputStream?.close()
        session?.finishTasksAndInvalidate()
        switch result {
        case .success(let data):
            continuation?.resume(returning: data)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }
}

struct CursorSDKRequestContext: Equatable {
    var id: Int
    var execID: String?

    static func decode(_ payload: Data) -> CursorSDKRequestContext? {
        for field in Proto.decodeFields(payload) {
            guard field.number == 2, case .bytes(let bytes) = field.value else {
                continue
            }
            let fields = Proto.decodeFields(bytes)
            if fields.contains(where: { $0.number == 10 }) {
                return CursorSDKRequestContext(id: Proto.numberField(fields, 1) ?? 0, execID: Proto.stringField(fields, 15))
            }
        }
        return nil
    }
}

struct IncrementalConnectFrameParser {
    private var buffer = Data()

    mutating func push(_ data: Data) -> [Data] {
        buffer.append(data)
        var output: [Data] = []
        while buffer.count >= 5 {
            let length = buffer[1..<5].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let frameLength = 5 + Int(length)
            guard buffer.count >= frameLength else { break }
            output.append(Data(buffer[5..<frameLength]))
            buffer.removeSubrange(0..<frameLength)
        }
        return output
    }
}

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
