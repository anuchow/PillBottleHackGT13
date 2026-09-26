import Foundation

/// One turn of conversation, in the shape the Gemini REST API expects.
public struct Content: Codable, Sendable {
    public struct Part: Codable, Sendable {
        public var text: String?
        public var functionCall: FunctionCall?
        public var functionResponse: FunctionResponse?
        /// Gemini 3 models require this to be sent back unchanged with the rest of the turn.
        public var thoughtSignature: String?
        public var thought: Bool?
    }

    public struct FunctionCall: Codable, Sendable {
        public var name: String
        public var args: [String: String]?
    }

    public struct FunctionResponse: Codable, Sendable {
        public var name: String
        public var response: [String: String]
    }

    public var role: String?
    public var parts: [Part]

    public init(role: String?, text: String) {
        self.role = role
        self.parts = [Part(text: text)]
    }

    public init(functionResponse name: String, result: String) {
        self.role = "user"
        self.parts = [Part(functionResponse: FunctionResponse(name: name, response: ["result": result]))]
    }

    public var text: String {
        parts.filter { $0.thought != true }.compactMap(\.text).joined()
    }

    public func functionCall(named name: String) -> FunctionCall? {
        parts.lazy.compactMap(\.functionCall).first { $0.name == name }
    }
}

/// A function Gemini may call. All parameters are strings.
public struct FunctionDeclaration: Encodable, Sendable {
    struct Parameters: Encodable, Sendable {
        struct Property: Encodable, Sendable {
            let type = "string"
            var description: String
        }
        let type = "object"
        var properties: [String: Property]
        var required: [String]
    }

    var name: String
    var description: String
    var parameters: Parameters

    public init(name: String, description: String, parameters: [String: String]) {
        self.name = name
        self.description = description
        self.parameters = Parameters(
            properties: parameters.mapValues { Parameters.Property(description: $0) },
            required: parameters.keys.sorted()
        )
    }
}

public struct APIError: Error, LocalizedError, Sendable {
    public var service: String
    public var statusCode: Int
    public var message: String

    /// 5xx errors (e.g. 503 "high demand") and 429 (quota, which is per model) are worth retrying on another model.
    public var isRetryable: Bool { statusCode >= 500 || statusCode == 429 }

    public var errorDescription: String? { "\(service) error \(statusCode): \(message)" }

    static func check(_ data: Data, _ response: URLResponse, service: String) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard !(200..<300).contains(status) else { return }
        throw APIError(service: service, statusCode: status, message: String(decoding: data, as: UTF8.self))
    }
}

/// Minimal client for the Gemini `generateContent` REST endpoint.
public struct GeminiClient: Sendable {
    /// Tried in order; if one is overloaded (503) or out of quota (429) we fall back to the next.
    public static let defaultModels = ["gemini-3.8-flash", "gemini-3.5-flash-lite", "gemini-3.1-flash-lite"]
    /// For live phone calls, where every second of silence is noticeable: ~0.6s per reply instead of 5–20s.
    public static let fastModels = ["gemini-3.5-flash-lite", "gemini-3.1-flash-lite"]

    private let apiKey: String
    private let models: [String]
    private let timeout: TimeInterval
    private let session: URLSession

    /// `timeout` caps each request: an overloaded model can hang for a minute before failing,
    /// so we give up sooner and move on to the next model.
    public init(apiKey: String, models: [String] = defaultModels, timeout: TimeInterval = 20, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.models = models
        self.timeout = timeout
        self.session = session
    }

    /// Returns the model's turn (text and/or function calls). On server or quota errors it falls back to the next model.
    /// If every model is temporarily overloaded (503) it waits and tries them all again (1s, then 2s, then 4s);
    /// quota errors (429) last until the quota resets, so waiting wouldn't help.
    public func generate(
        systemInstruction: String, contents: [Content], functions: [FunctionDeclaration] = []
    ) async throws -> Content {
        var lastError: Error?
        for attempt in 0..<4 {
            if attempt > 0 {
                try await Task.sleep(for: .seconds(1 << (attempt - 1)))
            }
            var overloaded = false
            for model in models {
                do {
                    return try await generate(model: model, systemInstruction: systemInstruction, contents: contents, functions: functions)
                } catch let error as APIError where error.isRetryable {
                    lastError = error
                    overloaded = overloaded || error.statusCode >= 500
                }
            }
            if !overloaded { break }
        }
        throw lastError ?? APIError(service: "Gemini", statusCode: 0, message: "No models configured")
    }

    private func generate(
        model: String, systemInstruction: String, contents: [Content], functions: [FunctionDeclaration]
    ) async throws -> Content {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONEncoder().encode(RequestBody(
            systemInstruction: Content(role: nil, text: systemInstruction),
            contents: contents,
            tools: functions.isEmpty ? nil : [Tool(functionDeclarations: functions)]
        ))

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw APIError(service: "Gemini", statusCode: 504, message: "\(model) took longer than \(Int(timeout))s")
        }
        try APIError.check(data, response, service: "Gemini")

        let body = try JSONDecoder().decode(ResponseBody.self, from: data)
        guard var reply = body.candidates?.first?.content, !reply.parts.isEmpty else {
            throw APIError(service: "Gemini", statusCode: 200, message: "Empty response")
        }
        reply.role = "model"
        return reply
    }

    private struct Tool: Encodable {
        var functionDeclarations: [FunctionDeclaration]
    }

    private struct RequestBody: Encodable {
        var systemInstruction: Content
        var contents: [Content]
        var tools: [Tool]?

        enum CodingKeys: String, CodingKey {
            case systemInstruction = "system_instruction"
            case contents, tools
        }
    }

    private struct ResponseBody: Decodable {
        struct Candidate: Decodable {
            var content: Content?
        }
        var candidates: [Candidate]?
    }
}
