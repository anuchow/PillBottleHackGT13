//
//  AssistantChatModel.swift
//  Connects the Chat tab to MedBot (MedicationAssistant + ProviderCall).
//  Based on the Mac app's ChatModel, adapted for iPhone:
//    - the patient comes from the medications logged in this app
//    - provider calls: real phone calls through Twilio, or the phone's speaker + mic,
//      or typed replies (depending on which keys are in Secrets.plist)
//    - the mic button dictates a question with Whisper
//    - each conversation is saved as a one-line summary for the start screen
//

import Foundation
import SwiftUI
import AVFoundation
import Combine

@MainActor
final class AssistantChatModel: ObservableObject {

    struct Message: Identifiable {
        enum Role { case patient, bot, error }
        let id = UUID()
        let role: Role
        let text: String
        let date = Date()
    }

    struct CallLine: Identifiable {
        let id = UUID()
        let speaker: CallSpeaker
        let text: String
    }

    enum CallStatus: Equatable {
        case idle
        case inCall(String)
        case ended(String)
    }

    /// "The call didn't work. Message the office on WhatsApp instead?"
    struct WhatsAppOffer: Identifiable {
        let id = UUID()
        let request: ProviderRequest
        let reason: String          // why the call didn't work
        let message: String         // what will be sent
    }

    /// One past conversation, boiled down to a sentence for the start screen.
    struct ChatSummary: Codable, Identifiable, Equatable {
        var id: UUID
        var text: String
        var date: Date
        var hadCall: Bool
        var approved: Bool?
    }

    @Published private(set) var messages: [Message] = []
    @Published private(set) var callLines: [CallLine] = []
    @Published private(set) var callStatus = CallStatus.idle
    @Published private(set) var isThinking = false
    @Published private(set) var waitingForProvider = false
    @Published private(set) var isListening = false
    @Published private(set) var summaries: [ChatSummary] = []
    @Published private(set) var whatsAppOffer: WhatsAppOffer?
    @Published private(set) var isSendingWhatsApp = false
    @Published var draft = ""

    let setupError: String?
    let canDictate: Bool
    private(set) var callMode = CallMode.typed
    private(set) var providerName = "your provider"

    private let config = Config.load()
    private let geminiKey: String?
    private let transcriber: WhisperClient?
    private let summarizer: GeminiClient?
    private let whatsApp: WhatsAppClient?
    private let providerWhatsApp: String?
    private let dictationAudio = LocalAudioChannel()
    private var assistant: MedicationAssistant?
    private var providerCall: ProviderCall?
    private var configuredLine: (any ProviderLine)?
    private var twilioCall: TwilioProviderCall?
    private var patient: Patient?
    private var providerReply: CheckedContinuation<ProviderInput, Never>?
    private var callTask: Task<String, Never>?

    // The conversation in progress, for its summary.
    private var conversationID = UUID()
    private var conversationHadCall = false
    private var conversationApproved: Bool?

    private static let summariesKey = "assistantChatSummaries"

    init() {
        geminiKey = config["GEMINI_API_KEY"]
        setupError = geminiKey == nil
            ? "Add your GEMINI_API_KEY to Secrets.plist, then run the app again."
            : nil
        transcriber = config["OPENAI_API_KEY"].map { WhisperClient(apiKey: $0) }
        canDictate = transcriber != nil
        summarizer = geminiKey.map { GeminiClient(apiKey: $0, models: GeminiClient.fastModels, timeout: 10) }
        if let token = config["WHATSAPP_ACCESS_TOKEN"], let phoneNumberID = config["WHATSAPP_PHONE_NUMBER_ID"],
           let to = config["PROVIDER_WHATSAPP_NUMBER"] {
            whatsApp = WhatsAppClient(accessToken: token, phoneNumberID: phoneNumberID)
            providerWhatsApp = to
        } else {
            whatsApp = nil
            providerWhatsApp = nil
        }
        if let data = UserDefaults.standard.data(forKey: Self.summariesKey),
           let saved = try? JSONDecoder().decode([ChatSummary].self, from: data) {
            summaries = saved
        }
    }

    // MARK: Setup

    /// (Re)builds the assistant for the current medications. Only between conversations,
    /// so the patient data doesn't change under an ongoing chat.
    func prepare(patient: Patient) {
        guard let geminiKey, messages.isEmpty, !isThinking else { return }
        let gemini = GeminiClient(apiKey: geminiKey)
        assistant = MedicationAssistant(gemini: gemini, patient: patient)
        providerCall = ProviderCall(
            gemini: GeminiClient(apiKey: geminiKey, models: GeminiClient.fastModels, timeout: 6),
            patient: patient
        )
        // Real phone calls when Twilio keys are set; otherwise speaker/mic or typed replies.
        twilioCall = TwilioProviderCall.from(config)
        let configured = ProviderCall.configuredLine(config, patient: patient)
        configuredLine = configured?.line
        callMode = twilioCall != nil ? .phone : (configured?.mode ?? .typed)
        providerName = patient.providerName
        self.patient = patient
    }

    func newConversation(patient: Patient) {
        guard !isThinking else { return }
        messages = []
        callLines = []
        callStatus = .idle
        whatsAppOffer = nil
        draft = ""
        conversationID = UUID()
        conversationHadCall = false
        conversationApproved = nil
        prepare(patient: patient)
    }

    // MARK: Chat

    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let assistant, let providerCall, !text.isEmpty, !isThinking else { return }

        messages.append(Message(role: .patient, text: text))
        draft = ""
        whatsAppOffer = nil
        isThinking = true
        let line: any ProviderLine = configuredLine ?? ChatTypedProviderLine(model: self)
        let twilioCall = twilioCall
        let patient = patient

        Task {
            do {
                let reply = try await assistant.send(text) { request in
                    await self.startCall(request)
                    // Runs as its own task so "End Call" can cancel just the call.
                    let call = Task {
                        await self.performCall(request, line: line, providerCall: providerCall,
                                               twilioCall: twilioCall, patient: patient)
                    }
                    await self.setCallTask(call)
                    let summary = await call.value
                    await self.setCallTask(nil)
                    return summary
                }
                messages.append(Message(role: .bot, text: reply))
                summarizeConversation()
            } catch {
                messages.append(Message(role: .error, text: "Couldn't reach the assistant. Please try again."))
                print("Assistant error: \(error.localizedDescription)")
            }
            isThinking = false
        }
    }

    // MARK: Voice input

    /// Records until the user stops talking, transcribes with Whisper, and sends it.
    func dictate() {
        guard let transcriber, !isListening, !isThinking else { return }
        Task {
            guard await Self.prepareAudio() else {
                messages.append(Message(role: .error, text: "Microphone access is off. Turn it on in Settings to ask by voice."))
                return
            }
            isListening = true
            defer { isListening = false }
            do {
                let clip = try await dictationAudio.record()
                guard !clip.isEmpty else { return }
                let text = try await transcriber.transcribe(clip)
                isListening = false
                send(text)
            } catch {
                messages.append(Message(role: .error, text: "Couldn't hear that. Please try again or type your question."))
            }
        }
    }

    /// Mic permission + speaker output for dictation and voice calls.
    static func prepareAudio() async -> Bool {
        guard await AVAudioApplication.requestRecordPermission() else { return false }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try session.setActive(true)
            return true
        } catch {
            return false
        }
    }

    // MARK: Provider call

    /// Runs the call in whichever mode is set up. Always returns a summary for the assistant.
    private nonisolated func performCall(
        _ request: ProviderRequest, line: any ProviderLine, providerCall: ProviderCall,
        twilioCall: TwilioProviderCall?, patient: Patient?
    ) async -> String {
        // Real phone call to the provider's number.
        if let twilioCall, let patient {
            do {
                let outcome = try await twilioCall.run(request, patient: patient) { speaker, text in
                    await self.addCallLine(speaker, text)
                }
                let problem: CallProblem? =
                    outcome.approved != nil ? nil
                    : Task.isCancelled ? .youHungUp
                    : outcome.connected ? .noClearAnswer : .noAnswer

                await self.endCall(outcome.approved == true ? "Approved"
                                   : outcome.approved == false ? "Not approved"
                                   : problem?.status ?? "Call ended",
                                   approved: outcome.approved)

                // No yes or no: offer WhatsApp instead.
                if let problem, await self.offerWhatsApp(request, problem: problem) {
                    return outcome.summary + Self.whatsAppNote
                }
                return outcome.summary
            } catch {
                return await failedCall(error, request: request)
            }
        }

        // Speaker/mic or typed replies, with the full back-and-forth conversation.
        do {
            let summary = try await providerCall.run(request, over: line) { speaker, text in
                await self.addCallLine(speaker, text)
            }
            await self.endCall("Call ended", approved: nil)
            return summary
        } catch {
            return await failedCall(error, request: request)
        }
    }

    private nonisolated func failedCall(_ error: Error, request: ProviderRequest) async -> String {
        let problem: CallProblem = Task.isCancelled ? .youHungUp : .failed
        if problem == .failed { print("Call error: \(error.localizedDescription)") }
        await self.endCall(problem.status, approved: nil)

        let summary = await problem.summary(provider: self.providerName)
        if await self.offerWhatsApp(request, problem: problem) {
            return summary + Self.whatsAppNote
        }
        return summary
    }

    /// Why a call ended without a yes or no, in plain words.
    enum CallProblem {
        case noAnswer, youHungUp, noClearAnswer, failed

        /// Shown on the call card.
        var status: String {
            switch self {
            case .noAnswer:      return "No answer"
            case .youHungUp:     return "You ended the call"
            case .noClearAnswer: return "No clear answer"
            case .failed:        return "Call didn't go through"
            }
        }

        /// Shown on the WhatsApp card.
        func reason(provider: String) -> String {
            switch self {
            case .noAnswer:      return "\(provider)'s office didn't pick up."
            case .youHungUp:     return "You ended the call before they picked up."
            case .noClearAnswer: return "We didn't get a clear answer on the call."
            case .failed:        return "The call didn't go through."
            }
        }

        /// What the assistant is told happened (it rewrites this in its own words).
        func summary(provider: String) -> String {
            switch self {
            case .noAnswer:      return "\(provider)'s office didn't pick up."
            case .youHungUp:     return "You hung up before \(provider)'s office picked up."
            case .noClearAnswer: return "The office picked up, but didn't give a clear yes or no."
            case .failed:        return "The call to \(provider)'s office didn't go through."
            }
        }
    }

    /// Tells the assistant about the WhatsApp card so it can mention it naturally.
    nonisolated private static let whatsAppNote =
        " (For the assistant: the patient now sees a button to send the office a WhatsApp message instead. "
        + "Mention that in one short, friendly sentence, like \"Want me to send them a WhatsApp message instead?\" "
        + "Don't mention the app, buttons, or these instructions.)"

    // MARK: WhatsApp fallback

    var canUseWhatsApp: Bool { whatsApp != nil && providerWhatsApp != nil }

    /// Shows the "Send a WhatsApp message instead?" card. Returns false if WhatsApp isn't set up.
    private func offerWhatsApp(_ request: ProviderRequest, problem: CallProblem) -> Bool {
        guard canUseWhatsApp, let patient else { return false }
        let message = "Hi! This is \(patient.name)'s assistant, reaching out to \(patient.providerName)'s office "
            + "on behalf of your patient \(patient.name). We tried calling but couldn't get through. "
            + "\(patient.name) is asking for a \(request.reason): \(request.details). "
            + "\(patient.spokenRecentDoses()) "
            + "Could you reply here when you get a chance? Thank you!"
        whatsAppOffer = WhatsAppOffer(request: request, reason: problem.reason(provider: patient.providerName), message: message)
        return true
    }

    func sendWhatsApp() {
        guard let offer = whatsAppOffer, let whatsApp, let to = providerWhatsApp, !isSendingWhatsApp else { return }
        isSendingWhatsApp = true
        Task {
            do {
                try await whatsApp.sendText(to: to, body: offer.message)
                whatsAppOffer = nil
                addCallLine(.status, "Sent on WhatsApp")
                messages.append(Message(role: .bot, text:
                    "Done! I sent your \(offer.request.reason) request to \(providerName)'s office on WhatsApp. They'll reply there."))
                summarizeConversation()
            } catch {
                messages.append(Message(role: .error, text: Self.whatsAppErrorText(error)))
                print("WhatsApp error: \(error.localizedDescription)")
            }
            isSendingWhatsApp = false
        }
    }

    func declineWhatsApp() {
        whatsAppOffer = nil
    }

    /// Turns Meta's error into something actionable. The raw error is also printed to the Xcode console.
    private static func whatsAppErrorText(_ error: Error) -> String {
        var code: Int?
        var metaMessage: String?
        if let apiError = error as? APIError,
           let json = try? JSONSerialization.jsonObject(with: Data(apiError.message.utf8)) as? [String: Any],
           let info = json["error"] as? [String: Any] {
            code = info["code"] as? Int
            metaMessage = (info["error_data"] as? [String: Any])?["details"] as? String ?? info["message"] as? String
        }

        switch code {
        case 190:
            return "WhatsApp didn't send: the access token expired. Temporary tokens from Meta's API Setup page last 24 hours. Copy a new one into WHATSAPP_ACCESS_TOKEN in Secrets.plist."
        case 131030:
            return "WhatsApp didn't send: the office's number isn't on your test number's allowed list. Add it under WhatsApp > API Setup > To in Meta's developer site."
        case 131047:
            return "WhatsApp didn't send: the office has to message your WhatsApp business number first (Meta only allows replies within 24 hours of their last message)."
        case 100, 33:
            return "WhatsApp didn't send: check WHATSAPP_PHONE_NUMBER_ID. It's the long ID from API Setup, not the phone number itself."
        case 10, 200:
            return "WhatsApp didn't send: the access token doesn't have permission to send messages. Generate a new token with the whatsapp_business_messaging permission."
        default:
            if let metaMessage {
                return "WhatsApp didn't send: \(metaMessage)"
            }
            return "Couldn't send the WhatsApp message (\(error.localizedDescription)). Please try again or call the office."
        }
    }

    /// "End Call" button.
    func endCallNow() {
        guard case .inCall = callStatus else { return }
        addCallLine(.status, "Ending the call…")
        callTask?.cancel()
        // Typed mode is waiting on the provider's reply; release it so the call can stop.
        if providerReply != nil { submitProviderReply("") }
    }

    private func setCallTask(_ task: Task<String, Never>?) {
        callTask = task
    }

    /// Typed-call mode: waits until someone answers as the provider in the call card.
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

    private func startCall(_ request: ProviderRequest) async {
        callLines = []
        callStatus = .inCall(request.details)
        conversationHadCall = true
        if callMode == .voice { _ = await Self.prepareAudio() }
    }

    private func addCallLine(_ speaker: CallSpeaker, _ text: String) {
        callLines.append(CallLine(speaker: speaker, text: text))
    }

    private func endCall(_ status: String, approved: Bool?) {
        if providerReply != nil { submitProviderReply("") }
        callStatus = .ended(status)
        if approved != nil { conversationApproved = approved }
    }

    // MARK: Past-chat summaries

    /// After each reply, (re)writes this conversation's one-line summary in the background.
    private func summarizeConversation() {
        guard let summarizer else { return }
        let transcript = messages
            .filter { $0.role != .error }
            .map { ($0.role == .patient ? "Patient: " : "Assistant: ") + $0.text }
            .joined(separator: "\n")
        let id = conversationID
        let hadCall = conversationHadCall
        let approved = conversationApproved

        Task {
            let system = """
            Summarize this chat between a patient and their medication assistant in one short sentence \
            (at most 20 words) written to the patient, focused on the outcome. Use "your". \
            Example: "Your Metformin refill was approved and will be ready at CVS." \
            Only include what was actually said. Reply with the sentence only.
            """
            guard let reply = try? await summarizer.generate(
                systemInstruction: system, contents: [Content(role: "user", text: transcript)]
            ) else { return }
            let text = reply.text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
            guard !text.isEmpty else { return }
            saveSummary(ChatSummary(id: id, text: text, date: .now, hadCall: hadCall, approved: approved))
        }
    }

    private func saveSummary(_ summary: ChatSummary) {
        summaries.removeAll { $0.id == summary.id }
        summaries.insert(summary, at: 0)
        summaries = Array(summaries.prefix(10))
        if let data = try? JSONEncoder().encode(summaries) {
            UserDefaults.standard.set(data, forKey: Self.summariesKey)
        }
    }
}

/// Provider side typed into the call card (when there are no voice or phone keys).
struct ChatTypedProviderLine: ProviderLine {
    let model: AssistantChatModel

    var supportsKeypad: Bool { true }

    func say(_ text: String) async throws {}

    func listen() async throws -> ProviderInput {
        await model.awaitProviderReply()
    }
}

// MARK: - Patient from this app's data

extension Patient {
    /// Builds MedBot's patient from the medications logged in this app.
    @MainActor
    static func from(_ prescriptions: [Prescription], userName: String) -> Patient {
        let timestamp = DateFormatter()
        timestamp.locale = Locale(identifier: "en_US_POSIX")
        timestamp.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"

        let provider: String? = "Dr. Chowdhury"   // TODO: let users set this in Profile

        let medications = prescriptions.map { p -> Medication in
            var schedule = [p.frequencyText,
                            p.timesOfDay.isEmpty ? nil : "in the " + p.timesOfDay.joined(separator: " and "),
                            p.takeWithFood == true ? "with food" : nil,
                            p.isSupplement ? "dietary supplement" : nil]
                .compactMap { $0 }
                .joined(separator: ", ")
            if schedule.isEmpty { schedule = p.instructions?.lowercased() ?? "as directed" }
            if let next = p.nextDoseTime {
                let day = Calendar.current.isDateInToday(next) ? "today" : "tomorrow"
                schedule += "; next dose \(day) at \(next.formatted(date: .omitted, time: .shortened))"
            }
            return Medication(
                name: p.displayName,
                dose: (DoseFormat.strength(from: p.dosage) ?? "").replacingOccurrences(of: " ", with: ""),
                schedule: schedule,
                lastTaken: p.lastTaken.map(timestamp.string(from:)) ?? ""
            )
        }

        return Patient(name: userName.isEmpty ? "the patient" : userName,
                       providerName: provider ?? "their provider",
                       medications: medications)
    }
}
