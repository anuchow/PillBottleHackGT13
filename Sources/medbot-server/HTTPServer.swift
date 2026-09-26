import Foundation
import Network

/// A minimal HTTP/1.1 server for the app's JSON API. One request per connection.
final class HTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        var method: String
        var path: String
        /// Header names are lowercased.
        var headers: [String: String]
        var body: Data
    }

    struct Response: Sendable {
        var status: Int
        var body: Data

        static func json(_ status: Int, _ object: Any) -> Response {
            Response(status: status, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8))
        }
    }

    typealias Handler = @Sendable (Request) async -> Response

    private let listener: NWListener
    private let queue = DispatchQueue(label: "HTTPServer")
    private let handler: Handler

    init(port: UInt16, handler: @escaping Handler) throws {
        self.handler = handler
        listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receive(on: connection, buffer: Data())
        }
        listener.start(queue: queue)
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let request = Self.parse(buffer) {
                Task {
                    let response = await self.handler(request)
                    self.send(response, on: connection)
                }
            } else if error != nil || isComplete || buffer.count > 1_000_000 {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    /// Returns the request once the headers and the full body have arrived.
    private static func parse(_ buffer: Data) -> Request? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let bodyStart = headerEnd.upperBound
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard buffer.count - bodyStart >= length else { return nil }

        let path = String(requestLine[1]).split(separator: "?").first.map(String.init) ?? "/"
        return Request(method: String(requestLine[0]), path: path, headers: headers,
                       body: buffer.subdata(in: bodyStart..<bodyStart + length))
    }

    private func send(_ response: Response, on connection: NWConnection) {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized",
                      404: "Not Found", 409: "Conflict", 500: "Internal Server Error"][response.status] ?? "OK"
        var data = Data("""
        HTTP/1.1 \(response.status) \(reason)\r
        Content-Type: application/json\r
        Content-Length: \(response.body.count)\r
        Connection: close\r
        \r

        """.utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}
