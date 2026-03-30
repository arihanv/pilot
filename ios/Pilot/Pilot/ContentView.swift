import SwiftUI

struct ContentView: View {
    @Bindable var manager: LiveModeManager
    @State private var showSettings = false
    @State private var showModelPicker = false
    @State private var inputText = ""

    private static let models: [(id: String, name: String)] = [
        ("google/gemini-3-flash-preview", "Gemini 3 Flash"),
        ("google/gemini-3-pro-preview", "Gemini 3 Pro"),
        ("google/gemini-3.1-flash-lite-preview", "Gemini 3.1 Flash Lite"),
        ("anthropic/claude-sonnet-4.6", "Claude Sonnet 4.6"),
        ("openai/gpt-5.4", "GPT-5.4"),
        ("openai/gpt-5.4-mini", "GPT-5.4 Mini"),
        ("deepseek/deepseek-v3.2", "DeepSeek V3.2"),
    ]

    private var currentModelName: String {
        Self.models.first(where: { $0.id == manager.selectedModel })?.name
            ?? manager.selectedModel.components(separatedBy: "/").last ?? "Model"
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar

            // Message / empty area
            if hasMessages {
                ScrollViewReader { proxy in
                    ScrollView {
                        messageList
                    }
                    .scrollDismissesKeyboard(.immediately)
                    .onChange(of: manager.lastResponse) {
                        withAnimation { proxy.scrollTo("bottom") }
                    }
                    .onChange(of: manager.speechText) {
                        withAnimation { proxy.scrollTo("bottom") }
                    }
                }
            } else {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { dismissKeyboard() }
                    .overlay { centerLogo }
            }

            // Suggestion chips (only when empty)
            if !hasMessages {
                suggestionChips
            }

            inputBar
        }
        .background(Color(.systemBackground))
        .tint(.primary)
        .sheet(isPresented: $showSettings) {
            SettingsView(manager: manager)
        }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerView(
                models: Self.models,
                selectedModel: $manager.selectedModel
            )
            .presentationDetents([.medium])
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private var hasMessages: Bool {
        !manager.lastResponse.isEmpty || !manager.speechText.isEmpty || manager.isProcessing
    }

    // MARK: - Center Logo

    private var centerLogo: some View {
        Image(systemName: "location.north.fill")
            .font(.system(size: 44, weight: .light))
            .foregroundStyle(Color(.systemGray4))
            .scaleEffect(x: 1.2, y: 1.0)
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 10) {
            // Left: hamburger button (liquid glass)
            Button { showSettings = true } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 38, height: 38)
            }
            .glassEffect(.regular, in: .circle)

            // Model picker pill (liquid glass)
            Button { showModelPicker = true } label: {
                HStack(spacing: 4) {
                    Text(currentModelName)
                        .font(.system(size: 16, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .glassEffect(.regular, in: .capsule)

            Spacer()

            // Right: new session button (liquid glass)
            Button {
                Task {
                    if manager.isActive {
                        await manager.stopLiveMode()
                    } else {
                        await manager.startLiveMode()
                    }
                }
            } label: {
                Image(systemName: manager.isActive ? "stop.fill" : "square.and.pencil")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(.primary)
                    .frame(width: 38, height: 38)
            }
            .glassEffect(.regular, in: .circle)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: - Suggestion Chips

    private var suggestionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                suggestionCard(title: "Text back Sarah", subtitle: "\"Running 10 min late\"")
                suggestionCard(title: "Set a timer", subtitle: "for 25 minutes")
                suggestionCard(title: "Screenshot my screen", subtitle: "and describe what's on it")
                suggestionCard(title: "Turn on Do Not Disturb", subtitle: "until tomorrow morning")
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 8)
    }

    private func suggestionCard(title: String, subtitle: String) -> some View {
        Button {
            inputText = "\(title) \(subtitle)"
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(width: 190, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color(.systemGray3), lineWidth: 0.5)
            )
        }
    }

    // MARK: - Messages

    private var messageList: some View {
        LazyVStack(spacing: 0) {
            if !manager.cuaStatus.isEmpty {
                statusBanner(manager.cuaStatus, icon: "gearshape.2", color: .orange)
            }

            if manager.isActive && manager.isBroadcastActive {
                statusBanner("Screen broadcast active", icon: "record.circle.fill", color: .green)
            }

            if !manager.speechText.isEmpty {
                userBubble(manager.speechText)
            }

            if manager.isProcessing {
                HStack(spacing: 8) {
                    assistantIcon
                    TypingIndicator()
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            if !manager.lastResponse.isEmpty {
                assistantRow(manager.lastResponse)
            }

            if manager.isSpeaking && !manager.isProcessing {
                HStack(spacing: 6) {
                    Image(systemName: "speaker.wave.2.fill")
                        .symbolEffect(.variableColor.iterative, isActive: true)
                        .font(.caption)
                        .foregroundStyle(.blue)
                    Text("Speaking...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }

            if let error = manager.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            Color.clear.frame(height: 1).id("bottom")
        }
        .padding(.vertical, 8)
        .animation(.default, value: manager.speechText)
        .animation(.default, value: manager.lastResponse)
        .animation(.default, value: manager.isProcessing)
        .animation(.default, value: manager.isSpeaking)
        .animation(.default, value: manager.cuaStatus)
    }

    private func statusBanner(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(color)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private func userBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 60)
            Text(text)
                .font(.body)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(.systemGray5))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private var assistantIcon: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(Color.black, in: Circle())
    }

    private func assistantRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            assistantIcon

            Text(text)
                .font(.body)

            Spacer(minLength: 40)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 10) {
            // Plus button — separate element, liquid glass
            Button { } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
            }
            .glassEffect(.regular, in: .circle)

            // Text field + mic + send
            HStack(spacing: 0) {
                TextField("Ask Pilot", text: $inputText, axis: .vertical)
                    .lineLimit(1...5)
                    .font(.body)
                    .padding(.leading, 16)
                    .padding(.vertical, 8)
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") { dismissKeyboard() }
                                .fontWeight(.medium)
                        }
                    }

                // Mic button (push-to-talk)
                if manager.isActive && inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    micButton
                }

                // Send / voice button
                trailingButton
                    .padding(.trailing, 8)
            }
            .frame(minHeight: 48)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(.systemGray6))
            )
        }
        .padding(.leading, 12)
        .padding(.trailing, 12)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private var micButton: some View {
        let isHeld = manager.isRecording
        return Image(systemName: "mic")
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(isHeld ? .red : .secondary)
            .frame(width: 32, height: 32)
            .scaleEffect(isHeld ? 1.2 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: isHeld)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !manager.isRecording { manager.beginRecording() }
                    }
                    .onEnded { _ in
                        manager.endRecording()
                    }
            )
    }

    private var trailingButton: some View {
        let canSend = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return Button {
            if canSend {
                let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                manager.submitShortcutPrompt(text)
                inputText = ""
            } else if !manager.isActive {
                Task { await manager.startLiveMode() }
            }
        } label: {
            ZStack {
                Circle()
                    .fill(canSend ? Color.primary : Color.black)
                    .frame(width: 32, height: 32)
                Image(systemName: canSend ? "arrow.up" : "waveform")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(canSend ? Color(.systemBackground) : .white)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 36, height: 36)
        }
    }
}

// MARK: - Typing Indicator

struct TypingIndicator: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color(.systemGray3))
                    .frame(width: 7, height: 7)
                    .offset(y: phase > 0 ? -4 : 0)
                    .animation(
                        .easeInOut(duration: 0.45)
                        .repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.15),
                        value: phase
                    )
            }
        }
        .onAppear { phase = 1 }
    }
}

// MARK: - Model Picker

struct ModelPickerView: View {
    let models: [(id: String, name: String)]
    @Binding var selectedModel: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(models, id: \.id) { model in
                    Button {
                        selectedModel = model.id
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.name)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(model.id)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selectedModel == model.id {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - Previews

#Preview("Idle") {
    ContentView(manager: LiveModeManager(apiKey: "preview-key"))
}

#Preview("Active") {
    @Previewable @State var manager = LiveModeManager(apiKey: "preview-key")
    ContentView(manager: manager)
        .onAppear {
            manager.isActive = true
            manager.lastResponse = "I opened the Messages app and found your recent conversations. What would you like me to do next?"
        }
}
