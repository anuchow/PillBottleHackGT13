//
//  ChatView.swift
//  Chat tab: "Healthcare Assistant" start screen with quick actions and recent
//  questions, then the conversation (including live provider calls).
//

import SwiftUI
import SwiftData

struct ChatView: View {
    @StateObject private var model = AssistantChatModel()
    @Query(sort: \Prescription.drugName) private var prescriptions: [Prescription]
    @AppStorage("userName") private var userName = "Prathithi"
    @FocusState private var composerFocused: Bool

    private var patient: Patient { Patient.from(prescriptions, userName: userName) }

    var body: some View {
        VStack(spacing: 0) {
            header

            if let setupError = model.setupError {
                ContentUnavailableView("Setup needed", systemImage: "key", description: Text(setupError))
            } else if model.messages.isEmpty {
                startScreen
            } else {
                conversation
            }

            composer
        }
        .background(Color.white.ignoresSafeArea())
        .onAppear { model.prepare(patient: patient) }
        .onChange(of: prescriptions.count) { _, _ in model.prepare(patient: patient) }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Healthcare Assistant")
                    .font(.system(size: 26, weight: .bold))
                Text("How can I help you today?")
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(Color.ink)

            Spacer()

            Button { model.newConversation(patient: patient) } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.assistantTint)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.white).shadow(color: .black.opacity(0.08), radius: 6, y: 2))
            }
            .disabled(model.messages.isEmpty || model.isThinking)
            .accessibilityLabel("New conversation")
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    // MARK: Start screen

    private var startScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(spacing: 10) {
                    QuickActionRow(symbol: "pill", title: "I need a refill") {
                        model.send("I need a refill.")
                    }
                    QuickActionRow(symbol: "ellipsis.message", title: "Ask about my medication") {
                        // Starts the sentence; the user finishes it with their question.
                        model.draft = "About my medication: "
                        composerFocused = true
                    }
                    QuickActionRow(symbol: "phone", title: "Contact my provider") {
                        model.send("Can you call my provider for me?")
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Past chats")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if model.summaries.isEmpty {
                        Text("After you chat, a short summary of each conversation shows up here.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(model.summaries) { summary in
                            SummaryRow(summary: summary)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    /// "2m ago", "3h ago", "2d ago"
    static func ago(_ date: Date) -> String {
        let minutes = Int(Date.now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "Just now" }
        if minutes < 60 { return "\(minutes)m ago" }
        if minutes < 60 * 24 { return "\(minutes / 60)h ago" }
        return "\(minutes / (60 * 24))d ago"
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(model.messages) { message in
                        ChatBubble(message: message).id(message.id)
                    }

                    if model.callStatus != .idle {
                        CallCard(model: model).id("call")
                    }

                    if let offer = model.whatsAppOffer {
                        WhatsAppOfferCard(model: model, offer: offer).id("whatsapp")
                    }

                    if model.isThinking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(isInCall ? "On a call with \(model.providerName)…" : "Thinking…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.leading, 44)
                        .id("thinking")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.messages.count) { _, _ in scrollToEnd(proxy) }
            .onChange(of: model.callLines.count) { _, _ in scrollToEnd(proxy) }
            .onChange(of: model.isThinking) { _, _ in scrollToEnd(proxy) }
            .onChange(of: model.whatsAppOffer?.id) { _, id in
                if id != nil { withAnimation { proxy.scrollTo("whatsapp", anchor: .bottom) } }
            }
        }
    }

    private var isInCall: Bool {
        if case .inCall = model.callStatus { return true }
        return false
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation {
            if model.isThinking { proxy.scrollTo("thinking", anchor: .bottom) }
            else if model.callStatus != .idle && model.messages.last?.role != .bot { proxy.scrollTo("call", anchor: .bottom) }
            else { proxy.scrollTo(model.messages.last?.id, anchor: .bottom) }
        }
    }

    // MARK: Composer

    private var composer: some View {
        HStack(spacing: 10) {
            if model.canDictate {
                Button { model.dictate() } label: {
                    Image(systemName: model.isListening ? "waveform.circle.fill" : "waveform")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(model.isListening ? Color.white : Color.assistantTint)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(model.isListening ? Color.assistantTint : Color.assistantTint.opacity(0.12)))
                        .symbolEffect(.pulse, isActive: model.isListening)
                }
                .disabled(model.isThinking || model.setupError != nil)
                .accessibilityLabel(model.isListening ? "Listening" : "Ask by voice")
            }

            TextField(model.isListening ? "Listening…" : "Ask anything...", text: $model.draft, axis: .vertical)
                .lineLimit(1...4)
                .focused($composerFocused)
                .submitLabel(.send)
                .onSubmit { model.send(model.draft) }

            let canSend = !model.draft.trimmingCharacters(in: .whitespaces).isEmpty && !model.isThinking
            Button { model.send(model.draft) } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(canSend ? Color.ink : Color.secondary.opacity(0.3)))
            }
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .padding(.leading, model.canDictate ? 8 : 18)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 26)
                .fill(.white)
                .shadow(color: .black.opacity(0.08), radius: 10, y: 2)
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .disabled(model.setupError != nil)
    }
}

// MARK: - Start screen rows

struct QuickActionRow: View {
    let symbol: String
    let title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(Color.assistantTint)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(.white))
                Text(title)
                    .foregroundStyle(Color.ink)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 20).fill(Color.appBackground))
        }
        .buttonStyle(.plain)
    }
}

/// One past conversation on the start screen.
struct SummaryRow: View {
    let summary: AssistantChatModel.ChatSummary

    private var symbol: String {
        if summary.approved == true { return "checkmark" }
        return summary.hadCall ? "phone" : "ellipsis.message"
    }

    private var tint: Color {
        summary.approved == true ? .takenGreen : .assistantTint
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(Circle().fill(tint.opacity(0.12)))
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.text)
                    .font(.subheadline)
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(ChatView.ago(summary.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color.appBackground))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Messages

struct ChatBubble: View {
    let message: AssistantChatModel.Message

    /// Gemini sometimes uses **bold** or *italics*; render them instead of showing the asterisks.
    static func formatted(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    var body: some View {
        if message.role == .patient {
            VStack(alignment: .trailing, spacing: 4) {
                Text(message.text)
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Color.assistantTint.opacity(0.1)))
                Text("You · \(message.date.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 50)
        } else {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: message.role == .error ? "exclamationmark.triangle" : "stethoscope")
                    .font(.system(size: 14))
                    .foregroundStyle(message.role == .error ? Color.warningRed : Color.assistantTint)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill((message.role == .error ? Color.warningRed : Color.assistantTint).opacity(0.12)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.formatted(message.text))
                        .foregroundStyle(Color.ink)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 18).fill(Color.appBackground))
                    Text(message.date.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 40)
        }
    }
}

// MARK: - WhatsApp fallback card

struct WhatsAppOfferCard: View {
    @ObservedObject var model: AssistantChatModel
    let offer: AssistantChatModel.WhatsAppOffer
    @State private var showMessage = false

    private let whatsAppGreen = Color(red: 0.15, green: 0.68, blue: 0.38)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "message.fill")
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(whatsAppGreen))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Send a WhatsApp message instead?")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.ink)
                    Text("\(offer.reason) I can send them your request on WhatsApp so they can reply when they're free.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            DisclosureGroup("See the message", isExpanded: $showMessage) {
                Text(offer.message)
                    .font(.footnote)
                    .foregroundStyle(Color.ink)
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.footnote.weight(.semibold))
            .tint(Color.assistantTint)

            HStack(spacing: 10) {
                Button { model.sendWhatsApp() } label: {
                    HStack(spacing: 6) {
                        if model.isSendingWhatsApp { ProgressView().tint(.white) }
                        Text(model.isSendingWhatsApp ? "Sending…" : "Send on WhatsApp")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Capsule().fill(whatsAppGreen))
                    .foregroundStyle(.white)
                }
                .disabled(model.isSendingWhatsApp)

                Button { model.declineWhatsApp() } label: {
                    Text("Not now")
                        .font(.subheadline.weight(.medium))
                        .padding(.vertical, 11)
                        .padding(.horizontal, 18)
                        .background(Capsule().fill(Color.appBackground))
                        .foregroundStyle(Color.ink)
                }
                .disabled(model.isSendingWhatsApp)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20).stroke(whatsAppGreen.opacity(0.4)))
    }
}

// MARK: - Provider call card

struct CallCard: View {
    @ObservedObject var model: AssistantChatModel
    @State private var reply = ""
    @State private var showTranscript = false

    private var approved: Bool { model.callStatus == .ended("Approved") }

    /// Newest line, shown while the transcript is collapsed.
    private var latestLine: AssistantChatModel.CallLine? { model.callLines.last }

    private var inCall: Bool {
        if case .inCall = model.callStatus { return true }
        return false
    }

    private var statusText: String {
        switch model.callStatus {
        case .idle: return ""
        case .inCall(let details): return details
        case .ended(let status): return status
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: approved ? "checkmark" : inCall ? "phone.fill.arrow.up.right" : "phone.down.fill")
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(inCall || approved ? Color.takenGreen : Color.secondary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(inCall ? "Calling \(model.providerName)" : model.providerName)
                        .font(.subheadline.weight(.semibold))
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Text(model.callMode.rawValue)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            .foregroundStyle(Color.ink)

            if showTranscript {
                ForEach(model.callLines) { line in
                    transcriptLine(line)
                }
            } else if let latestLine {
                transcriptLine(latestLine)
                    .lineLimit(2)
            }

            if model.callLines.count > 1 {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showTranscript.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(showTranscript ? "Hide transcript" : "Show full transcript")
                        Image(systemName: showTranscript ? "chevron.up" : "chevron.down")
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.assistantTint)
                }
                .buttonStyle(.plain)
            }

            if inCall {
                Button(role: .destructive) { model.endCallNow() } label: {
                    Label("End Call", systemImage: "phone.down.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.warningRed))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }

            // Typed mode: someone plays the provider's office for the demo.
            if model.callMode == .typed && model.waitingForProvider {
                HStack(spacing: 8) {
                    TextField("Reply as the provider, or 1/2/3/9", text: $reply)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(submit)
                    Button("Reply", action: submit)
                        .buttonStyle(.borderedProminent)
                        .tint(Color.ink)
                        .disabled(reply.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20).stroke(Color.secondary.opacity(0.2)))
    }

    @ViewBuilder private func transcriptLine(_ line: AssistantChatModel.CallLine) -> some View {
        if line.speaker == .status {
            Text(line.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(line.speaker == .assistant ? "Assistant" : "Provider")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(line.text)
                    .font(.subheadline)
                    .foregroundStyle(Color.ink)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func submit() {
        model.submitProviderReply(reply)
        reply = ""
    }
}
