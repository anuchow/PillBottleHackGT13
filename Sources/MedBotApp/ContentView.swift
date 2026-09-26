import MedBot
import SwiftUI

struct ContentView: View {
    @StateObject private var model = ChatModel()

    var body: some View {
        HStack(spacing: 0) {
            PatientChatView(model: model)
                .frame(minWidth: 380, maxWidth: .infinity)
            Divider()
            ProviderCallView(model: model)
                .frame(minWidth: 340, idealWidth: 380, maxWidth: 440)
        }
        .frame(minWidth: 760, minHeight: 560)
    }
}

// MARK: - Patient chat

struct PatientChatView: View {
    @ObservedObject var model: ChatModel
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let setupError = model.setupError {
                ContentUnavailableMessage(icon: "key", title: "Setup needed", message: setupError)
            } else {
                messageList
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Ask about your medications…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || model.isThinking)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding(12)
            .disabled(model.setupError != nil)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "pills.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 2) {
                Text("MedBot").font(.headline)
                Text("\(model.patient.name) · \(model.patient.medications.map(\.name).joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.messages.isEmpty {
                        Text("Try “When did I last take my Metformin?” or “I need a Metformin refill.”")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    ForEach(model.messages) { message in
                        MessageBubble(message: message).id(message.id)
                    }
                    if model.isThinking {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(model.callStatus.isInCall ? "On a call with \(model.patient.providerName)…" : "Thinking…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .id("thinking")
                    }
                }
                .padding(12)
            }
            .onChange(of: model.messages.count) { _ in
                withAnimation { proxy.scrollTo(model.messages.last?.id, anchor: .bottom) }
            }
        }
    }

    private func send() {
        model.send(draft)
        draft = ""
    }
}

struct MessageBubble: View {
    let message: ChatModel.Message

    var body: some View {
        HStack {
            if message.role == .patient { Spacer(minLength: 60) }
            Text(message.text)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(background, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(message.role == .patient ? Color.white : Color.primary)
            if message.role != .patient { Spacer(minLength: 60) }
        }
    }

    private var background: Color {
        switch message.role {
        case .patient: .accentColor
        case .bot: Color(nsColor: .controlBackgroundColor)
        case .error: .red.opacity(0.15)
        }
    }
}

// MARK: - Provider call

struct ProviderCallView: View {
    @ObservedObject var model: ChatModel
    @State private var draft = ""

    private let callGreen = Color(red: 0.15, green: 0.68, blue: 0.38)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.callStatus == .idle {
                ContentUnavailableMessage(
                    icon: "phone",
                    title: "No call yet",
                    message: "When the patient asks for a refill or agrees to a call, MedBot calls \(model.patient.providerName) and the conversation appears here."
                )
            } else {
                transcript
            }
            if model.callMode == .typed {
                Divider()
                HStack(spacing: 8) {
                    TextField(model.waitingForProvider ? "Reply as \(model.patient.providerName)'s office, or type 1/2/3/9…" : "Waiting for MedBot…", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(reply)
                    Button("Reply", action: reply)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(12)
                .disabled(!model.waitingForProvider)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.4))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.callStatus.isInCall ? "phone.fill.arrow.up.right" : "phone.fill")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Circle().fill(model.callStatus.isInCall ? callGreen : .gray))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.patient.providerName)'s office").font(.headline)
                Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Text(model.callMode.rawValue)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
        }
        .padding(12)
    }

    private var statusText: String {
        switch model.callStatus {
        case .idle: "Not in a call"
        case .inCall(let reason): "In call · \(reason)"
        case .ended(let status): status
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.callLines) { line in
                        if line.speaker == .status {
                            Text(line.text)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .id(line.id)
                        } else {
                            VStack(alignment: line.speaker == .assistant ? .leading : .trailing, spacing: 3) {
                                Text(line.speaker == .assistant ? "MedBot" : "Provider")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(line.text)
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(
                                        line.speaker == .assistant ? callGreen.opacity(0.18) : Color(nsColor: .controlBackgroundColor),
                                        in: RoundedRectangle(cornerRadius: 14)
                                    )
                            }
                            .frame(maxWidth: .infinity, alignment: line.speaker == .assistant ? .leading : .trailing)
                            .id(line.id)
                        }
                    }
                    if model.waitingForProvider {
                        Label("Waiting for the provider to answer…", systemImage: "ellipsis.bubble")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
            }
            .onChange(of: model.callLines.count) { _ in
                withAnimation { proxy.scrollTo(model.callLines.last?.id, anchor: .bottom) }
            }
        }
    }

    private func reply() {
        model.submitProviderReply(draft)
        draft = ""
    }
}

struct ContentUnavailableMessage: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension ChatModel.CallStatus {
    var isInCall: Bool {
        if case .inCall = self { return true }
        return false
    }
}
