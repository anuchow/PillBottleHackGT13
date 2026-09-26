import Foundation
import MedBot

/// Drives the app: the patient's chat with the bot, and the bot's call with the provider.
@MainActor
final class ChatModel: ObservableObject {
    struct Message: Identifiable {
        enum Role { case patient, bot, error }
        let id = UUID()
        var role: Role
        var text: String
    }

    struct CallLine: Identifiable {
        let id = UUID()
        var speaker: CallSpeaker
        var text: String
    }

    enum CallStatus: Equatable {
        case idle
        case inCall(reason: String)
        case ended(String)
    }

    let patient = Patient.sample
    let setupError: String?
    let callMode: CallMode

    @Published private(set) var messages: [Message] = []
    @Published private(set) var callLines: [CallLine] = []
    @Published private(set) var callStatus = CallStatus.idle
    @Published private(set) var isThinking = false
    @Published private(set) var waitingForProvider = false

    private let assistant: MedicationAssistant?
    private let providerCall: ProviderCall?
    private let configuredLine: (any ProviderLine)?
    private var providerReply: CheckedContinuation<ProviderInput, Never>?

    init() {
        let config = Config.load()
        guard let geminiKey = config["GEMINI_API_KEY"] else {
            setupError = "Missing GEMINI_API_KEY. Add it to .env and run the app from the project folder."
            assistant = nil
            providerCall = nil
            configuredLine = nil
            callMode = .typed
            return
        }
        let gemini = GeminiClient(apiKey: geminiKey)
        setupError = nil
        assistant = MedicationAssistant(gemini: gemini, patient: patient)
        providerCall = ProviderCall(gemini: GeminiClient(apiKey: geminiKey, models: GeminiClient.fastModels, timeout: 6), patient: patient)

        let configured = ProviderCall.configuredLine(config, patient: patient)
        configuredLine = configured?.line
        callMode = configured?.mode ?? .typed
    }

    var providerLine: any ProviderLine {
        configuredLine ?? TypedProviderLine(model: self)
    }

    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let assistant, let providerCall, !text.isEmpty, !isThinking else { return }

        messages.append(Message(role: .patient, text: text))
        isThinking = true
        let line = providerLine
        Task {
            do {
                let reply = try await assistant.send(text) { request in
                    await self.startCall(request)
                    do {
                        let summary = try await providerCall.run(request, over: line) { speaker, text in
                            await self.addCallLine(speaker, text)
                        }
                        await self.endCall("Call ended")
                        return summary
                    } catch {
                        await self.endCall("Call failed: \(error.localizedDescription)")
                        return "The call could not be completed."
                    }
                }
                messages.append(Message(role: .bot, text: reply))
            } catch {
                messages.append(Message(role: .error, text: "Couldn't reach the assistant: \(error.localizedDescription)"))
            }
            isThinking = false
        }
    }

    /// Typed-call mode: suspends the call until someone answers as the provider in the call panel.
    func awaitProviderReply() async -> ProviderInput {
        waitingForProvider = true
        return await withCheckedContinuation { providerReply = $0 }
    }

    func submitProviderReply(_ text: String) {
        guard let providerReply else { return }
        self.providerReply = nil
        waitingForProvider = false
        providerReply.resume(returning: .typed(text))
    }

    private func startCall(_ request: ProviderRequest) {
        callLines = []
        callStatus = .inCall(reason: request.details)
    }

    private func addCallLine(_ speaker: CallSpeaker, _ text: String) {
        callLines.append(CallLine(speaker: speaker, text: text))
    }

    private func endCall(_ status: String) {
        if providerReply != nil { submitProviderReply("") }
        callStatus = .ended(status)
    }
}

/// Provider side typed into the app's call panel.
struct TypedProviderLine: ProviderLine {
    let model: ChatModel

    var supportsKeypad: Bool { true }

    func say(_ text: String) async throws {}

    func listen() async throws -> ProviderInput {
        await model.awaitProviderReply()
    }
}
