//
//  MedBotView.swift
//  The Chat tab: the patient's conversation with MedBot, and the live view of MedBot's
//  phone call with their provider. The call screen opens by itself when a call starts.
//

import SwiftUI
import SwiftData

struct MedBotView: View {
    enum Screen: String, CaseIterable {
        case chat = "Chat"
        case call = "Provider call"
    }

    @State private var model = MedBotModel()
    @State private var screen = Screen.chat
    @State private var showingSettings = false
    @Query(sort: \Prescription.drugName) private var prescriptions: [Prescription]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Screen", selection: $screen) {
                    ForEach(Screen.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                if !model.isConfigured {
                    ContentUnavailableView {
                        Label("Connect MedBot", systemImage: "antenna.radiowaves.left.and.right")
                    } description: {
                        Text("Enter the server URL and token shown on the demo Mac.")
                    } actions: {
                        Button("Open settings") { showingSettings = true }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.ink)
                    }
                } else {
                    if let error = model.connectionError {
                        Label(error, systemImage: "wifi.exclamationmark")
                            .font(.footnote)
                            .foregroundStyle(Color.warningRed)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .padding(.bottom, 6)
                    }
                    switch screen {
                    case .chat: MedBotChatScreen(model: model, medications: prescriptions.map(\.medBotMedication))
                    case .call: MedBotCallScreen(model: model)
                    }
                }
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("MedBot")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        Task { await model.reset() }
                    } label: {
                        Label("New chat", systemImage: "square.and.pencil")
                    }
                    .disabled(!model.isConfigured || model.state.busy)

                    Button {
                        showingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                MedBotSettingsView(model: model)
            }
        }
        .task { await model.poll() }
        .onChange(of: model.state.call.status) { _, status in
            if status == "inCall" { withAnimation { screen = .call } }
        }
    }
}

// MARK: - Chat screen

struct MedBotChatScreen: View {
    let model: MedBotModel
    let medications: [MedBotMedication]
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if model.state.messages.isEmpty { suggestions }
                        ForEach(model.state.messages) { message in
                            MedBotBubble(message: message).id(message.id)
                        }
                        if model.state.busy {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text(model.state.call.status == "inCall"
                                     ? "On a call with \(model.state.providerName)…"
                                     : "MedBot is thinking…")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .id("typing")
                        }
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.state.messages.count) {
                    withAnimation { proxy.scrollTo(model.state.messages.last?.id, anchor: .bottom) }
                }
            }

            if let sendError = model.sendError {
                Text(sendError)
                    .font(.footnote)
                    .foregroundStyle(Color.warningRed)
                    .padding(.horizontal)
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message MedBot", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 20))
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(canSend ? Color.ink : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.state.busy
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask MedBot about your medications, or have it call your doctor.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ForEach(suggestionTexts, id: \.self) { text in
                Button {
                    draft = text
                    send()
                } label: {
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
    }

    private var suggestionTexts: [String] {
        let name = medications.first?.name ?? "my medication"
        return [
            "What medications am I taking?",
            "When did I last take \(name)?",
            "I need a refill of \(name). Please call my doctor.",
        ]
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !model.state.busy else { return }
        draft = ""
        Task { await model.send(text, medications: medications) }
    }
}

struct MedBotBubble: View {
    let message: MedBotState.Message

    var body: some View {
        let fromPatient = message.role == "patient"
        HStack {
            if fromPatient { Spacer(minLength: 48) }
            Text(message.text)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .foregroundStyle(fromPatient ? Color.white : Color.ink)
                .background(background, in: RoundedRectangle(cornerRadius: 18))
            if !fromPatient { Spacer(minLength: 48) }
        }
    }

    private var background: Color {
        switch message.role {
        case "patient": Color.ink
        case "error": Color.warningRed.opacity(0.12)
        default: Color.white
        }
    }
}

// MARK: - Provider call screen

struct MedBotCallScreen: View {
    let model: MedBotModel

    private var call: MedBotState.Call { model.state.call }
    private var inCall: Bool { call.status == "inCall" }

    var body: some View {
        VStack(spacing: 0) {
            header
            if call.status == "idle" {
                ContentUnavailableView(
                    "No call yet",
                    systemImage: "phone",
                    description: Text("When you ask for a refill or agree to a call, MedBot phones \(model.state.providerName) and the conversation shows up here.")
                )
            } else {
                transcript
                if inCall {
                    Text("Provider keypad: 1 medications · 2 recent doses · 3 repeat request · 9 confirm")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: inCall ? "phone.fill.arrow.up.right" : "phone.fill")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(inCall ? Color.takenGreen : Color.secondary.opacity(0.5)))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.state.providerName)'s office")
                    .font(.headline)
                    .foregroundStyle(Color.ink)
                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if inCall {
                Text("LIVE")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.warningRed))
            }
        }
        .padding()
        .background(Color.white, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal)
    }

    private var statusText: String {
        switch call.status {
        case "inCall": "On a call · \(call.detail)"
        case "ended": call.detail
        default: "Not in a call"
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(call.lines) { line in
                        callLine(line).id(line.id)
                    }
                }
                .padding()
            }
            .onChange(of: call.lines.count) {
                withAnimation { proxy.scrollTo(call.lines.last?.id, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func callLine(_ line: MedBotState.CallLine) -> some View {
        if line.speaker == "status" {
            Text(line.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        } else {
            let fromMedBot = line.speaker == "assistant"
            VStack(alignment: fromMedBot ? .leading : .trailing, spacing: 3) {
                Text(fromMedBot ? "MedBot" : "Provider")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(line.text)
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(fromMedBot ? Color.takenGreen.opacity(0.15) : Color.cardGray,
                                in: RoundedRectangle(cornerRadius: 18))
            }
            .frame(maxWidth: .infinity, alignment: fromMedBot ? .leading : .trailing)
        }
    }
}

// MARK: - Settings

struct MedBotSettingsView: View {
    @Bindable var model: MedBotModel
    @Environment(\.dismiss) private var dismiss
    @State private var testResult: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://….trycloudflare.com", text: $model.serverURL)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                    SecureField("Token", text: $model.token)
                } header: {
                    Text("MedBot server")
                } footer: {
                    Text("Run `swift run medbot-server` on the demo Mac. It prints the URL; the token is MEDBOT_APP_TOKEN in its .env file.")
                }

                Section {
                    Button("Test connection") {
                        Task {
                            await model.refresh()
                            testResult = model.connectionError ?? "Connected ✓"
                        }
                    }
                    .disabled(!model.isConfigured)
                    if let testResult {
                        Text(testResult)
                            .foregroundStyle(testResult.hasPrefix("Connected") ? Color.takenGreen : Color.warningRed)
                    }
                }
            }
            .navigationTitle("MedBot settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
