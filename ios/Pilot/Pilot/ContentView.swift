import SwiftUI

struct ContentView: View {
    @Bindable var manager: LiveModeManager
    @State private var showSettings = false
    @State private var showModelPicker = false
    @State private var inputText = ""
    @State private var suggestions: [Suggestion] = []
    @State private var loadingSuggestions = false

    private static let models: [ModelInfo] = [
        ModelInfo(id: "google/gemini-3-flash-preview", name: "Gemini 3 Flash", provider: "Google", badge: "Fast", badgeColor: .green),
        ModelInfo(id: "google/gemini-3-pro-preview", name: "Gemini 3 Pro", provider: "Google", badge: "Flagship", badgeColor: .blue),
        ModelInfo(id: "google/gemini-3.1-flash-lite-preview", name: "Gemini 3.1 Flash Lite", provider: "Google", badge: "Cheap", badgeColor: .mint),
        ModelInfo(id: "anthropic/claude-sonnet-4.6", name: "Claude Sonnet 4.6", provider: "Anthropic", badge: "CUA", badgeColor: .orange),
        ModelInfo(id: "anthropic/claude-haiku-4.5", name: "Claude Haiku 4.5", provider: "Anthropic", badge: "CUA", badgeColor: .orange),
        ModelInfo(id: "openai/gpt-5.4", name: "GPT-5.4", provider: "OpenAI", badge: "Vision", badgeColor: .purple),
        ModelInfo(id: "openai/gpt-5.4-mini", name: "GPT-5.4 Mini", provider: "OpenAI", badge: "Fast", badgeColor: .green),
        ModelInfo(id: "qwen/qwen3-vl-30b-a3b-thinking", name: "Qwen3 VL 30B", provider: "Qwen", badge: "Vision", badgeColor: .purple),
        ModelInfo(id: "qwen/qwen3-vl-8b-thinking", name: "Qwen3 VL 8B", provider: "Qwen", badge: "Cheap", badgeColor: .mint),
        ModelInfo(id: "deepseek/deepseek-v3.2", name: "DeepSeek V3.2", provider: "DeepSeek", badge: nil, badgeColor: .gray),
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
            .presentationDetents([.medium, .large])
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
                ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, s in
                    suggestionCard(s)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .opacity
                        ))
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 8)
        .animation(.spring(duration: 0.5, bounce: 0.3), value: suggestions.count)
        .task { await loadSuggestions() }
    }

    private func loadSuggestions() async {
        guard suggestions.isEmpty, !loadingSuggestions else { return }
        loadingSuggestions = true
        print("[Suggestions] Loading...")
        var apps = await MainActor.run { InstalledAppsProvider.shared.getInstalledApps() }
        if apps.isEmpty {
            print("[Suggestions] No installed apps found, skipping generation")
            loadingSuggestions = false
            return
        }

        // Fetch icon URLs from iTunes Search API
        let iconURLs = await AppIconFetcher.shared.fetchIconURLs(for: apps)
        for i in apps.indices {
            apps[i].iconURL = iconURLs[apps[i].name]
        }

        let generator = SuggestionGenerator(apiKey: Config.openRouterAPIKey)
        // Pass apps with icon URLs so suggestions inherit them
        let result = await generator.generateSuggestions(apps: apps)
        print("[Suggestions] Got \(result.count) suggestions, animating in...")
        for (i, suggestion) in result.enumerated() {
            try? await Task.sleep(nanoseconds: UInt64(i) * 120_000_000)
            await MainActor.run {
                withAnimation(.spring(duration: 0.4, bounce: 0.3)) {
                    suggestions.append(suggestion)
                }
            }
        }
        await MainActor.run { loadingSuggestions = false }
    }

    private func suggestionCard(_ s: Suggestion) -> some View {
        Button {
            inputText = "\(s.title) \(s.subtitle)"
        } label: {
            HStack(spacing: 10) {
                // App icon from iTunes Search API
                AsyncImage(url: s.app.iconURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure:
                        letterFallback(s.app.name)
                    case .empty:
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(.systemGray5))
                    @unknown default:
                        letterFallback(s.app.name)
                    }
                }
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(s.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: 210, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.systemGray6).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color(.systemGray4), lineWidth: 0.5)
            )
        }
    }

    private func letterFallback(_ name: String) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(.systemGray5))
            .overlay {
                Text(String(name.prefix(1)))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.secondary)
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

                // Mic button (push-to-talk)
                if manager.isActive && inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    micButton
                }

                // Send / voice button
                trailingButton
                    .padding(.trailing, 8)
            }
            .frame(minHeight: 48)
            .glassEffect(.regular, in: .capsule)
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

// MARK: - Model Info

struct ModelInfo: Identifiable {
    let id: String
    let name: String
    let provider: String
    var badge: String? = nil
    var badgeColor: Color = .gray

    var providerIcon: String {
        switch provider {
        case "Google": return "sparkle"
        case "Anthropic": return "brain.head.profile"
        case "OpenAI": return "circle.hexagongrid"
        case "Qwen": return "cloud"
        case "DeepSeek": return "magnifyingglass.circle"
        default: return "cpu"
        }
    }

    var providerColor: Color {
        switch provider {
        case "Google": return .blue
        case "Anthropic": return .orange
        case "OpenAI": return .green
        case "Qwen": return .indigo
        case "DeepSeek": return .cyan
        default: return .gray
        }
    }
}

// MARK: - Model Picker

struct ModelPickerView: View {
    let models: [ModelInfo]
    @Binding var selectedModel: String
    @Environment(\.dismiss) private var dismiss

    private var grouped: [(provider: String, models: [ModelInfo])] {
        var dict: [String: [ModelInfo]] = [:]
        for m in models { dict[m.provider, default: []].append(m) }
        let order = ["Google", "Anthropic", "OpenAI", "Qwen", "DeepSeek"]
        return order.compactMap { p in
            guard let list = dict[p] else { return nil }
            return (provider: p, models: list)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(grouped, id: \.provider) { group in
                    Section {
                        ForEach(group.models) { model in
                            let isSelected = selectedModel == model.id
                            Button {
                                withAnimation(.snappy(duration: 0.2)) {
                                    selectedModel = model.id
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    // Provider icon
                                    Image(systemName: model.providerIcon)
                                        .font(.system(size: 18, weight: .medium))
                                        .foregroundStyle(model.providerColor)
                                        .frame(width: 32, height: 32)
                                        .background(model.providerColor.opacity(0.12))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))

                                    // Model name + slug
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(model.name)
                                                .font(.body.weight(.semibold))
                                                .foregroundStyle(.primary)
                                            if let badge = model.badge {
                                                Text(badge)
                                                    .font(.system(size: 10, weight: .bold))
                                                    .foregroundStyle(model.badgeColor)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(model.badgeColor.opacity(0.12))
                                                    .clipShape(Capsule())
                                            }
                                        }
                                        Text(model.id)
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }

                                    Spacer()

                                    // Selection indicator
                                    if isSelected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.title3)
                                            .foregroundStyle(.blue)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .listRowBackground(isSelected ? Color.blue.opacity(0.06) : Color.clear)
                        }
                    } header: {
                        Text(group.provider)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Select Model")
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
