import Foundation
import MedBot

// Usage: swift run medbot-cli [--text-call]
//   --text-call  type the provider's side of the call instead of phoning them or using the speaker and mic.

let config = Config.load()
guard let geminiKey = config["GEMINI_API_KEY"] else {
    print("Missing GEMINI_API_KEY. Add it to .env (see .env.example).")
    exit(1)
}

let gemini = GeminiClient(apiKey: geminiKey)
let patient = Patient.sample
let assistant = MedicationAssistant(gemini: gemini, patient: patient)
let providerCall = ProviderCall(gemini: GeminiClient(apiKey: geminiKey, models: GeminiClient.fastModels, timeout: 6), patient: patient)

let line: any ProviderLine
if !CommandLine.arguments.contains("--text-call"), let configured = ProviderCall.configuredLine(config, patient: patient) {
    line = configured.line
    print(configured.mode == .phone
        ? "Provider calls go to their phone through Twilio."
        : "Provider calls use the speaker and microphone.")
} else {
    line = TerminalProviderLine()
    print("Provider calls are typed (see .env.example for voice and phone setup).")
}

while true {
    print("Patient: ", terminator: "")
    guard let input = readLine()?.trimmingCharacters(in: .whitespaces),
          !input.isEmpty, !["quit", "exit"].contains(input.lowercased())
    else { break }

    do {
        let reply = try await assistant.send(input) { request in
            print("📞 Calling \(patient.providerName) (\(request.reason)): \(request.details)")
            do {
                let summary = try await providerCall.run(request, over: line) { speaker, text in
                    switch speaker {
                    case .assistant: print("   Assistant: \(text)")
                    case .provider: print("   Provider: \(text)")
                    case .status: print("   · \(text)")
                    }
                }
                print("📞 Call ended.")
                return summary
            } catch {
                print("📞 Call failed: \(error.localizedDescription)")
                return "The call could not be completed."
            }
        }
        print("Bot:", reply)
    } catch {
        print("Bot: Sorry, I couldn't reach the assistant right now. Please try again.")
        FileHandle.standardError.write(Data("   (\(error.localizedDescription))\n".utf8))
    }
}
