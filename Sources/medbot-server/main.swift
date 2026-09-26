import Foundation
import MedBot

// MedBot server for the Pill App: runs the chatbot and places provider calls from this Mac,
// and gives the app a small JSON API over a public HTTPS tunnel.
//
// Usage: swift run medbot-server
//
// API (every request except /health needs "Authorization: Bearer <MEDBOT_APP_TOKEN>"):
//   GET  /health  -> {"ok": true}
//   GET  /state   -> conversation, busy flag, and the live call (the app polls this every second)
//   POST /chat    {"message": "...", "medications": [{name, dose, schedule, lastTaken}]} -> 202, or 409 if busy
//   POST /reset   -> starts a new conversation

setvbuf(stdout, nil, _IOLBF, 0)  // print each line right away, even when output goes to a file
let config = Config.load()
guard let geminiKey = config["GEMINI_API_KEY"] else {
    print("Missing GEMINI_API_KEY in .env")
    exit(1)
}
guard let token = config["MEDBOT_APP_TOKEN"], token.count >= 16 else {
    print("Missing MEDBOT_APP_TOKEN in .env (at least 16 characters). The app sends it so strangers can't place calls.")
    exit(1)
}
guard let configured = ProviderCall.configuredLine(config, patient: .sample), configured.mode == .phone else {
    print("Phone calls aren't configured. Set the Twilio, ElevenLabs and OpenAI keys in .env (see .env.example).")
    exit(1)
}

let port = config["MEDBOT_SERVER_PORT"].flatMap(UInt16.init) ?? 8090
let session = Session(config: config, geminiKey: geminiKey, line: configured.line)

let server = try HTTPServer(port: port) { request in
    if request.path == "/health" { return .json(200, ["ok": true]) }
    guard request.headers["authorization"] == "Bearer \(token)" else {
        return .json(401, ["error": "Wrong or missing token"])
    }

    switch (request.method, request.path) {
    case ("GET", "/state"):
        return HTTPServer.Response(status: 200, body: await session.stateJSON())

    case ("POST", "/chat"):
        struct ChatRequest: Decodable {
            var message: String
            var medications: [Medication]?
        }
        guard let body = try? JSONDecoder().decode(ChatRequest.self, from: request.body),
              !body.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .json(400, ["error": "Expected {\"message\": \"...\"}"]) }
        let accepted = await session.chat(body.message, medications: body.medications)
        return accepted ? .json(202, ["accepted": true]) : .json(409, ["error": "MedBot is still answering"])

    case ("POST", "/reset"):
        await session.reset()
        return .json(200, ["ok": true])

    default:
        return .json(404, ["error": "Not found"])
    }
}

let publicURL: URL
if let fixed = config["MEDBOT_SERVER_URL"].flatMap(URL.init(string:)) {
    publicURL = fixed
} else {
    print("Opening a public tunnel for the app…")
    publicURL = try await QuickTunnel.start(port: Int(port))
}

print("""

MedBot server is running. In the Pill App's MedBot tab, tap the gear and enter:
  Server URL: \(publicURL.absoluteString)
  Token:      (MEDBOT_APP_TOKEN from .env)

Keep this window open during the demo. Press Ctrl+C to stop.
""")

// Keep serving until Ctrl+C. (`server` is a global, so it stays alive.)
while true {
    try await Task.sleep(for: .seconds(3600))
}
