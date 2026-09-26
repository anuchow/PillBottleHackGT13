import Foundation
import MedBot

/// The patient's conversation with MedBot and the state of any call to their provider,
/// shared with the app, which shows it and polls it for updates.
actor Session {
    private let config: Config
    private let geminiKey: String
    private let patientName: String
    private let providerName: String
    private let line: any ProviderLine

    private var patient: Patient
    private var assistant: MedicationAssistant
    private var providerCall: ProviderCall

    private var busy = false
    private var nextID = 1
    private var messages: [[String: Any]] = []
    private var callStatus = "idle"
    private var callDetail = ""
    private var callLines: [[String: Any]] = []

    init(config: Config, geminiKey: String, line: any ProviderLine) {
        self.config = config
        self.geminiKey = geminiKey
        self.line = line
        patientName = config["PATIENT_NAME"] ?? Patient.sample.name
        providerName = config["PROVIDER_NAME"] ?? Patient.sample.providerName
        patient = Patient(name: patientName, providerName: providerName, medications: Patient.sample.medications)
        (assistant, providerCall) = Self.makeBots(geminiKey: geminiKey, patient: patient)
    }

    private static func makeBots(geminiKey: String, patient: Patient) -> (MedicationAssistant, ProviderCall) {
        let assistant = MedicationAssistant(gemini: GeminiClient(apiKey: geminiKey, timeout: 8), patient: patient)
        let call = ProviderCall(gemini: GeminiClient(apiKey: geminiKey, models: GeminiClient.fastModels, timeout: 6), patient: patient)
        return (assistant, call)
    }

    /// Starts answering a message in the background. Returns false if MedBot is still busy with the last one.
    /// `medications` come from the app's scanned bottles; when they change, MedBot starts a fresh conversation.
    func chat(_ message: String, medications: [Medication]?) -> Bool {
        guard !busy else { return false }
        if let medications, !medications.isEmpty, medications != patient.medications {
            patient = Patient(name: patientName, providerName: providerName, medications: medications)
            (assistant, providerCall) = Self.makeBots(geminiKey: geminiKey, patient: patient)
        }
        busy = true
        append(to: &messages, ["role": "patient", "text": message])
        Task { await answer(message) }
        return true
    }

    func reset() {
        guard !busy else { return }
        messages = []
        callLines = []
        callStatus = "idle"
        callDetail = ""
        (assistant, providerCall) = Self.makeBots(geminiKey: geminiKey, patient: patient)
    }

    /// The state as JSON, for `GET /state`.
    func stateJSON() -> Data {
        let state: [String: Any] = [
            "busy": busy,
            "patientName": patient.name,
            "providerName": patient.providerName,
            "messages": messages,
            "call": ["status": callStatus, "detail": callDetail, "lines": callLines],
        ]
        return (try? JSONSerialization.data(withJSONObject: state)) ?? Data("{}".utf8)
    }

    private func answer(_ message: String) async {
        let providerCall = self.providerCall
        let line = self.line
        do {
            let reply = try await assistant.send(message) { request in
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
            append(to: &messages, ["role": "bot", "text": reply])
        } catch {
            append(to: &messages, ["role": "error", "text": "Couldn't reach MedBot: \(error.localizedDescription)"])
        }
        busy = false
    }

    private func startCall(_ request: ProviderRequest) {
        callLines = []
        callStatus = "inCall"
        callDetail = request.details
    }

    private func addCallLine(_ speaker: CallSpeaker, _ text: String) {
        let name = switch speaker {
        case .assistant: "assistant"
        case .provider: "provider"
        case .status: "status"
        }
        append(to: &callLines, ["speaker": name, "text": text])
    }

    private func endCall(_ status: String) {
        callStatus = "ended"
        callDetail = status
    }

    private func append(to list: inout [[String: Any]], _ item: [String: Any]) {
        var item = item
        item["id"] = nextID
        nextID += 1
        list.append(item)
    }
}
