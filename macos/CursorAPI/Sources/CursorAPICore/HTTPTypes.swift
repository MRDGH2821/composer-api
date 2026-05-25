import Foundation

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var query: String?
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, query: String?, headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json(_ value: Any, status: Int = 200) throws -> HTTPResponse {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json; charset=utf-8"], body: data)
    }

    public static func data(_ data: Data, status: Int = 200, contentType: String) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": contentType], body: data)
    }
}

public enum HTTPStatusText {
    public static func text(for status: Int) -> String {
        switch status {
        case 200:
            return "OK"
        case 400:
            return "Bad Request"
        case 401:
            return "Unauthorized"
        case 404:
            return "Not Found"
        case 500:
            return "Internal Server Error"
        case 502:
            return "Bad Gateway"
        default:
            return "Status"
        }
    }
}
