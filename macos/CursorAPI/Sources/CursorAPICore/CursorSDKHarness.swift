import Foundation

public protocol CursorSDKHarness: Sendable {
    func stream(prepared: PreparedChatRequest, settings: CursorAPISettings, authorization: String?) -> AsyncThrowingStream<CursorSDKStreamEvent, any Error>
}

public enum CursorSDKStreamEvent: Sendable, Equatable {
    case text(String)
    case toolCall(CursorToolCall)
    case done(CursorSDKOutput)
}

public extension CursorSDKHarness {
    func complete(prepared: PreparedChatRequest, settings: CursorAPISettings, authorization: String?) async throws -> CursorSDKOutput {
        var text = ""
        var toolCalls: [CursorToolCall] = []
        var finalOutput: CursorSDKOutput?
        for try await event in stream(prepared: prepared, settings: settings, authorization: authorization) {
            switch event {
            case .text(let delta):
                text += delta
            case .toolCall(let toolCall):
                toolCalls.append(toolCall)
            case .done(let final):
                finalOutput = final
            }
        }
        if var output = finalOutput {
            if output.text.isEmpty, !text.isEmpty {
                output.text = text
            }
            if output.toolCalls.isEmpty, !toolCalls.isEmpty {
                output.toolCalls = toolCalls
            }
            return output
        }
        return CursorSDKOutput(text: text, toolCalls: toolCalls, agentID: "", runID: "")
    }
}

public struct LocalCursorSDKHarness: CursorSDKHarness {
    private static let sessionStore = CursorSDKSessionStore()

    public init() {}

    public func stream(prepared: PreparedChatRequest, settings: CursorAPISettings, authorization: String?) -> AsyncThrowingStream<CursorSDKStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard settings.hasCursorSDKConfiguration else {
                        throw CursorAPIError.invalidConfiguration("CursorAPI could not find the local transport configuration. Open Settings > Advanced Transport to inspect the bridge settings.")
                    }

                    let apiKey = cursorAPIKey(from: authorization, settings: settings)
                    guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw CursorAPIError.unauthorized
                    }
                    let accessToken = try await exchangeCursorAPIKey(apiKey, settings: settings)

                    let agentID = await Self.sessionStore.agentID(for: prepared.sessionKey)
                    let runID = "msg-\(UUID().uuidString.lowercased())"
                    let requestID = UUID().uuidString.lowercased()
                    let request = CursorSDKProto.runRequest(
                        agentID: agentID,
                        messageID: runID,
                        modelID: prepared.cursorModelID,
                        prompt: prepared.prompt
                    )
                    let framed = ConnectProto.frame(request)
                    let decoder = CursorSDKFrameDecoderBox()
                    _ = try await runRawSDKRequest(
                        framedBody: framed,
                        accessToken: accessToken,
                        requestID: requestID,
                        settings: settings
                    ) { payload in
                        let events = decoder.push(payload)
                        for event in events {
                            continuation.yield(event)
                        }
                    }
                    let output = decoder.output(agentID: agentID, runID: runID)
                    continuation.yield(.done(output))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func exchangeCursorAPIKey(_ apiKey: String, settings: CursorAPISettings) async throws -> String {
        guard let base = URL(string: settings.cursorAPIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CursorAPIError.invalidConfiguration("Cursor public API origin is not a valid URL.")
        }
        let url = base.appending(path: "/auth/exchange_user_api_key")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("sdk", forHTTPHeaderField: "x-cursor-client-type")
        request.setValue("composer-api-macos-0.1.0", forHTTPHeaderField: "x-cursor-client-version")
        request.setValue("true", forHTTPHeaderField: "x-ghost-mode")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CursorAPIError.transport("Cursor API did not return an HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? "status \(http.statusCode)"
            throw http.statusCode == 401 ? CursorAPIError.unauthorized : CursorAPIError.upstream(text)
        }
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = payload["accessToken"] as? String,
              !accessToken.isEmpty else {
            throw CursorAPIError.upstream("Cursor did not return an internal access token.")
        }
        return accessToken
    }

    private func runRawSDKRequest(
        framedBody: Data,
        accessToken: String,
        requestID: String,
        settings: CursorAPISettings,
        onFrame: @escaping @Sendable (Data) -> Void
    ) async throws -> Data {
        let endpoint = try endpointURL(settings: settings)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = framedBody
        request.timeoutInterval = 180
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("application/connect+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("connect-es/1.6.1", forHTTPHeaderField: "User-Agent")
        request.setValue("sdk", forHTTPHeaderField: "x-cursor-client-type")
        request.setValue(settings.clientVersion.isEmpty ? "sdk-1.0.13" : settings.clientVersion, forHTTPHeaderField: "x-cursor-client-version")
        request.setValue("true", forHTTPHeaderField: "x-ghost-mode")
        request.setValue(requestID, forHTTPHeaderField: "x-original-request-id")
        request.setValue(requestID, forHTTPHeaderField: "x-request-id")

        return try await CursorSDKHTTP2Transport().runStreaming(request: request, initialFrame: framedBody, onFrame: onFrame)
    }

    private func endpointURL(settings: CursorAPISettings) throws -> URL {
        let endpoint = settings.localAgentEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if endpoint.hasPrefix("http://") || endpoint.hasPrefix("https://") {
            guard let url = URL(string: endpoint) else {
                throw CursorAPIError.invalidConfiguration("Cursor local-agent endpoint is not a valid URL.")
            }
            return url
        }
        guard let base = URL(string: settings.backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CursorAPIError.invalidConfiguration("Cursor backend origin is not a valid URL.")
        }
        var normalized = endpoint
        if !normalized.hasPrefix("/") {
            normalized = "/" + normalized
        }
        return base.appending(path: normalized)
    }

    private func bearerToken(_ authorization: String?) -> String? {
        guard let authorization else { return nil }
        let pieces = authorization.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard pieces.count == 2, pieces[0].lowercased() == "bearer" else { return nil }
        return String(pieces[1])
    }

    private func cursorAPIKey(from authorization: String?, settings: CursorAPISettings) -> String {
        guard let token = bearerToken(authorization), !isLocalPlaceholderToken(token) else {
            return settings.cursorAPIKey
        }
        return token
    }

    private func isLocalPlaceholderToken(_ token: String) -> Bool {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty
            || normalized == "cursor-local"
            || normalized == "CURSOR_API_KEY"
            || normalized == "{env:CURSOR_API_KEY}"
    }
}

private actor CursorSDKSessionStore {
    private var agents: [String: String] = [:]

    func agentID(for sessionKey: String?) -> String {
        guard let sessionKey, !sessionKey.isEmpty else {
            return "agent-\(UUID().uuidString.lowercased())"
        }
        if let existing = agents[sessionKey] {
            return existing
        }
        let created = "agent-\(UUID().uuidString.lowercased())"
        agents[sessionKey] = created
        return created
    }
}

private final class CursorSDKFrameDecoderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var decoder = CursorSDKFrameDecoder()

    func push(_ payload: Data) -> [CursorSDKStreamEvent] {
        lock.withLock {
            decoder.push(payload)
        }
    }

    func output(agentID: String, runID: String) -> CursorSDKOutput {
        lock.withLock {
            decoder.output(agentID: agentID, runID: runID)
        }
    }
}

public struct CursorSDKFrameDecoder: Sendable {
    public var text: String = ""
    public var toolCalls: [CursorToolCall] = []

    public static func decode(data: Data) -> CursorSDKFrameDecoder {
        var decoder = CursorSDKFrameDecoder()
        for frame in ConnectProto.frames(from: data) {
            _ = decoder.push(frame)
        }
        return decoder
    }

    public func output(agentID: String, runID: String) -> CursorSDKOutput {
        CursorSDKOutput(text: text, toolCalls: toolCalls, agentID: agentID, runID: runID)
    }

    @discardableResult
    public mutating func push(_ payload: Data) -> [CursorSDKStreamEvent] {
        var output: [CursorSDKStreamEvent] = []
        for field in Proto.decodeFields(payload) {
            switch field.value {
            case .bytes(let bytes) where field.number == 1:
                output.append(contentsOf: decodeInteractionUpdate(bytes))
            case .bytes(let bytes) where field.number == 2:
                if let event = decodeExecServerMessage(bytes) {
                    output.append(event)
                }
            default:
                continue
            }
        }
        return output
    }

    private mutating func decodeInteractionUpdate(_ payload: Data) -> [CursorSDKStreamEvent] {
        var output: [CursorSDKStreamEvent] = []
        for field in Proto.decodeFields(payload) {
            guard case .bytes(let bytes) = field.value else { continue }
            if field.number == 1 {
                let textFields = Proto.decodeFields(bytes)
                if let value = Proto.stringField(textFields, 1) {
                    text += value
                    output.append(.text(value))
                }
            } else if field.number == 2 || field.number == 3 || field.number == 7 {
                if let toolCall = decodeToolCallUpdate(bytes, completed: field.number == 3) {
                    toolCalls.append(toolCall)
                    output.append(.toolCall(toolCall))
                }
            }
        }
        return output
    }

    private mutating func decodeExecServerMessage(_ payload: Data) -> CursorSDKStreamEvent? {
        let fields = Proto.decodeFields(payload)
        if fields.contains(where: { $0.number == 10 }) {
            return nil
        }
        for field in fields {
            guard case .bytes(let bytes) = field.value,
                  let spec = CursorSDKToolSpec.exec[field.number] else {
                continue
            }
            var args = CursorSDKToolSpec.decodeArgs(kind: spec.kind, payload: bytes)
            args.removeValue(forKey: "toolCallId")
            let toolCall = CursorToolCall(name: spec.name, arguments: args)
            toolCalls.append(toolCall)
            return .toolCall(toolCall)
        }
        return nil
    }

    private func decodeToolCallUpdate(_ payload: Data, completed: Bool) -> CursorToolCall? {
        let fields = Proto.decodeFields(payload)
        guard let toolCallBytes = Proto.dataField(fields, 2) else { return nil }
        return decodeSDKToolCall(toolCallBytes, completed: completed)
    }

    private func decodeSDKToolCall(_ payload: Data, completed: Bool) -> CursorToolCall? {
        for field in Proto.decodeFields(payload) {
            guard case .bytes(let bytes) = field.value,
                  let spec = CursorSDKToolSpec.interaction[field.number] else {
                continue
            }
            let toolFields = Proto.decodeFields(bytes)
            let hasResult = toolFields.contains(where: { $0.number == 2 })
            if completed && hasResult {
                return nil
            }
            let argsPayload = Proto.dataField(toolFields, 1)
            var toolCall = CursorToolCall(name: spec.name, arguments: argsPayload.map { CursorSDKToolSpec.decodeArgs(kind: spec.kind, payload: $0) } ?? [:])
            if toolCall.name.lowercased() == "edit",
               let path = toolCall.arguments["path"]?.stringValue,
               let streamContent = toolCall.arguments["streamContent"]?.stringValue {
                toolCall = CursorToolCall(name: "write", arguments: ["path": .string(path), "fileText": .string(streamContent)])
            }
            return CursorSDKToolSpec.isEmittable(toolCall) ? toolCall : nil
        }
        return nil
    }
}

private struct CursorSDKToolSpec {
    enum Kind {
        case delete
        case edit
        case glob
        case grep
        case ls
        case mcp
        case readExec
        case readLints
        case readTool
        case semSearch
        case shell
        case write
    }

    var name: String
    var kind: Kind

    static let interaction: [Int: CursorSDKToolSpec] = [
        1: CursorSDKToolSpec(name: "shell", kind: .shell),
        3: CursorSDKToolSpec(name: "delete", kind: .delete),
        4: CursorSDKToolSpec(name: "glob", kind: .glob),
        5: CursorSDKToolSpec(name: "grep", kind: .grep),
        8: CursorSDKToolSpec(name: "read", kind: .readTool),
        12: CursorSDKToolSpec(name: "edit", kind: .edit),
        13: CursorSDKToolSpec(name: "ls", kind: .ls),
        14: CursorSDKToolSpec(name: "readLints", kind: .readLints),
        15: CursorSDKToolSpec(name: "mcp", kind: .mcp),
        16: CursorSDKToolSpec(name: "semSearch", kind: .semSearch)
    ]

    static let exec: [Int: CursorSDKToolSpec] = [
        2: CursorSDKToolSpec(name: "shell", kind: .shell),
        3: CursorSDKToolSpec(name: "write", kind: .write),
        4: CursorSDKToolSpec(name: "delete", kind: .delete),
        5: CursorSDKToolSpec(name: "grep", kind: .grep),
        7: CursorSDKToolSpec(name: "read", kind: .readExec),
        8: CursorSDKToolSpec(name: "ls", kind: .ls),
        9: CursorSDKToolSpec(name: "readLints", kind: .readLints),
        11: CursorSDKToolSpec(name: "mcp", kind: .mcp),
        14: CursorSDKToolSpec(name: "shell", kind: .shell)
    ]

    static func decodeArgs(kind: Kind, payload: Data) -> [String: JSONValue] {
        let fields = Proto.decodeFields(payload)
        func string(_ number: Int) -> JSONValue? { Proto.stringField(fields, number).map(JSONValue.string) }
        func number(_ number: Int) -> JSONValue? { Proto.numberField(fields, number).map { .number(Double($0)) } }
        func bool(_ number: Int) -> JSONValue? { Proto.numberField(fields, number).map { .bool($0 != 0) } }
        func strings(_ number: Int) -> JSONValue? {
            let values = Proto.stringFields(fields, number)
            return values.isEmpty ? nil : .array(values.map(JSONValue.string))
        }
        switch kind {
        case .shell:
            return compact(["command": string(1), "workingDirectory": string(2), "timeout": number(3), "toolCallId": string(4)])
        case .write:
            return compact(["path": string(1), "fileText": string(2), "toolCallId": string(3), "returnFileContentAfterWrite": bool(4)])
        case .delete:
            return compact(["path": string(1), "toolCallId": string(2)])
        case .glob:
            return compact(["targetDirectory": string(1), "globPattern": string(2)])
        case .grep:
            return compact([
                "pattern": string(1), "path": string(2), "glob": string(3), "outputMode": string(4),
                "contextBefore": number(5), "contextAfter": number(6), "context": number(7),
                "caseInsensitive": bool(8), "type": string(9), "headLimit": number(10),
                "multiline": bool(11), "sort": string(12), "sortAscending": bool(13),
                "toolCallId": string(14), "offset": number(16)
            ])
        case .readTool:
            return compact(["path": string(1), "offset": number(2), "limit": number(3), "includeLineNumbers": bool(5)])
        case .readExec:
            return compact(["path": string(1), "toolCallId": string(2), "offset": number(4), "limit": number(5)])
        case .edit:
            return compact(["path": string(1), "streamContent": string(6)])
        case .ls:
            return compact(["path": string(1), "ignore": strings(2), "toolCallId": string(3)])
        case .readLints:
            return compact(["paths": strings(1)])
        case .mcp:
            return compact(["providerIdentifier": string(1), "toolName": string(2), "toolCallId": string(4)])
        case .semSearch:
            return compact(["query": string(1), "targetDirectories": strings(2), "explanation": string(3)])
        }
    }

    static func isEmittable(_ toolCall: CursorToolCall) -> Bool {
        let name = toolCall.name.lowercased()
        let args = toolCall.arguments
        if name == "glob" || name == "ls" { return true }
        if name == "shell" { return args["command"]?.stringValue?.isEmpty == false }
        if name == "write" { return args["path"]?.stringValue?.isEmpty == false && args["fileText"]?.stringValue != nil }
        if name == "edit" { return args["path"]?.stringValue?.isEmpty == false && args.keys.contains { ["patchContent", "oldText", "newText", "streamContent"].contains($0) } }
        if name == "read" || name == "delete" { return args["path"]?.stringValue?.isEmpty == false }
        if name == "grep" { return args["pattern"]?.stringValue?.isEmpty == false }
        if name == "semSearch" { return args["query"]?.stringValue?.isEmpty == false }
        if name == "readLints" { return args["paths"]?.arrayValue?.isEmpty == false }
        if name == "mcp" { return args["toolName"]?.stringValue?.isEmpty == false || args["providerIdentifier"]?.stringValue?.isEmpty == false }
        return !args.isEmpty
    }

    static func compact(_ input: [String: JSONValue?]) -> [String: JSONValue] {
        input.compactMapValues { value in
            guard let value else { return nil }
            if case .null = value { return nil }
            return value
        }
    }
}
