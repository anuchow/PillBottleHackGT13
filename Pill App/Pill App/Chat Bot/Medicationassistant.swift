import Foundation

/// What the patient wants from their provider, as decided by the assistant.
public struct ProviderRequest: Sendable {
    public var reason: String
    public var details: String
}

/// A medication chatbot for one patient. Keeps the conversation history across messages.
public actor MedicationAssistant {
    static let contactProvider = FunctionDeclaration(
        name: "contact_provider",
        description: "Place a phone call to the patient's healthcare provider and return what the provider said.",
        parameters: [
            "reason": "Either \"refill\" or \"question\".",
            "details": "Exactly what to ask the provider, including the medication name and dose.",
        ]
    )

    private let gemini: GeminiClient
    private let systemPrompt: String
    private var history: [Content] = []

    public init(gemini: GeminiClient, patient: Patient) {
        self.gemini = gemini
        self.systemPrompt = Self.systemPrompt(for: patient)
    }

    public static func systemPrompt(for patient: Patient) -> String {
        """
        You are a medication assistant for \(patient.name). Their provider is \(patient.providerName).
        Their current medications: \(patient.medicationsJSON)
        Answer questions about dosage/timing only from this data.
        For anything requiring medical judgment, tell them to contact their provider, and offer to call the provider for them.
        For refills, confirm which medication they mean, then use contact_provider.
        Only use contact_provider once the patient has asked for a refill or agreed to a call.
        After a call, tell the patient plainly what the provider said.
        """
    }

    /// Sends a message and returns the reply. `contactProvider` runs the call when the assistant decides to
    /// place one, and returns what the provider said. Only completed turns are added to the history.
    public func send(
        _ message: String,
        contactProvider: @Sendable (ProviderRequest) async throws -> String
    ) async throws -> String {
        var contents = history + [Content(role: "user", text: message)]
        for _ in 0..<3 {
            let reply = try await gemini.generate(
                systemInstruction: systemPrompt, contents: contents, functions: [Self.contactProvider]
            )
            contents.append(reply)
            guard let call = reply.functionCall(named: Self.contactProvider.name) else {
                history = contents
                return reply.text
            }
            let request = ProviderRequest(reason: call.args?["reason"] ?? "question", details: call.args?["details"] ?? "")
            let outcome = try await contactProvider(request)
            contents.append(Content(functionResponse: Self.contactProvider.name, result: outcome))
        }
        throw APIError(service: "Gemini", statusCode: 0, message: "Too many provider calls in one turn")
    }

    public func reset() {
        history = []
    }
}
