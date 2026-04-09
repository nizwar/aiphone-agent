import SwiftUI
import AppKit

private enum SettingsPage: String, CaseIterable, Identifiable {
    case aiModels = "AI Models"
    case deviceConnectivity = "Device Connectivity"
    case about = "About"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .aiModels:
            return "brain.head.profile"
        case .deviceConnectivity:
            return "cable.connector"
        case .about:
            return "info.circle"
        }
    }

    var iconColor: Color {
        switch self {
        case .aiModels:
            return .purple
        case .deviceConnectivity:
            return .blue
        case .about:
            return .gray
        }
    }
}

struct AISettingsWindowView: View {
    @EnvironmentObject private var settings: AISettingsStore
    @State private var selection: SettingsPage? = .aiModels
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Text("Settings")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                VStack(spacing: 2) {
                    ForEach(SettingsPage.allCases) { page in
                        let isSelected = selection == page
                        Button {
                            selection = page
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: page.systemImage)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(isSelected ? .white : page.iconColor)
                                    .frame(width: 26, height: 26)
                                    .background(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .fill(isSelected
                                                ? page.iconColor
                                                : page.iconColor.opacity(colorScheme == .dark ? 0.15 : 0.12))
                                    )

                                Text(page.rawValue)
                                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                                    .foregroundStyle(isSelected ? .primary : .secondary)
                                    .lineLimit(1)

                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(isSelected
                                        ? (colorScheme == .dark
                                            ? Color.white.opacity(0.08)
                                            : Color.black.opacity(0.06))
                                        : Color.clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)

                Spacer()
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 190, max: 210)
        } detail: {
            Group {
                switch selection ?? .aiModels {
                case .aiModels:
                    AIModelsPane()
                case .deviceConnectivity:
                    DeviceConnectivityPane()
                case .about:
                    AboutPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 760, height: 500)
        .background(
            VisualEffectBackground(material: .sidebar, blendingMode: .behindWindow)
        )
        .background(SettingsWindowChromeConfigurator())
    }
}

private struct AIModelsPane: View {
    @EnvironmentObject private var settings: AISettingsStore

    private enum CustomModelTarget: String, Identifiable {
        case openGLM
        case languageEnhancer

        var id: String { rawValue }

        var title: String {
            switch self {
            case .openGLM:
                return "Custom OpenGLM Model"
            case .languageEnhancer:
                return "Custom Language Enhancer Model"
            }
        }

        var placeholder: String {
            switch self {
            case .openGLM:
                return "Enter an OpenGLM model name"
            case .languageEnhancer:
                return "Enter a Language Enhancer model name"
            }
        }
    }

    @State private var customModelSheet: CustomModelTarget?
    @State private var customModelDraft = ""

    private let customOpenGLMToken = "__custom_openglm_model__"
    private let customLanguageEnhancerToken = "__custom_language_enhancer_model__"

    private var openGLMSelection: Binding<String> {
        Binding(
            get: { settings.openGLMModel },
            set: { newValue in
                handleModelSelection(newValue, for: .openGLM)
            }
        )
    }

    private var languageEnhancerSelection: Binding<String> {
        Binding(
            get: { settings.languageEnhancerModel },
            set: { newValue in
                handleModelSelection(newValue, for: .languageEnhancer)
            }
        )
    }

    private var openGLMStatus: (String, Color) {
        if settings.openGLMFetchState.isValidating {
            return ("Fetching", .orange)
        }

        switch settings.openGLMValidation {
        case .validating:
            return ("Checking", .orange)
        case .success:
            return ("Success", .green)
        case .failure:
            return ("Failed", .red)
        case .idle:
            if case .failure = settings.openGLMFetchState {
                return ("Failed", .red)
            }
            if case .success = settings.openGLMFetchState {
                return ("Fetched", .green)
            }
            return ("Ready", .secondary)
        }
    }

    private var uniqueOpenGLMModels: [String] {
        uniqueModels(
            from: OpenGLMModelOption.allCases.map(\.rawValue) + settings.availableOpenGLMModels,
            current: settings.openGLMModel
        )
    }

    private var uniqueLanguageEnhancerModels: [String] {
        uniqueModels(from: settings.availableLanguageEnhancerModels, current: settings.languageEnhancerModel)
    }

    private func uniqueModels(from candidates: [String], current: String) -> [String] {
        var seen = Set<String>()
        let values = ([current] + candidates)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return values.filter { seen.insert($0).inserted }
    }

    private func handleModelSelection(_ value: String, for target: CustomModelTarget) {
        let customToken = target == .openGLM ? customOpenGLMToken : customLanguageEnhancerToken
        guard value != customToken else {
            presentCustomModelSheet(for: target)
            return
        }

        switch target {
        case .openGLM:
            settings.openGLMModel = value
        case .languageEnhancer:
            settings.languageEnhancerModel = value
        }
    }

    private func presentCustomModelSheet(for target: CustomModelTarget) {
        switch target {
        case .openGLM:
            customModelDraft = settings.openGLMModel
        case .languageEnhancer:
            customModelDraft = settings.languageEnhancerModel
        }

        customModelSheet = target
    }

    private func applyCustomModel(for target: CustomModelTarget) {
        let trimmed = customModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        switch target {
        case .openGLM:
            settings.openGLMModel = trimmed
        case .languageEnhancer:
            settings.languageEnhancerModel = trimmed
        }

        customModelSheet = nil
    }

    private var languageStatus: (String, Color) {
        if settings.languageEnhancerFetchState.isValidating {
            return ("Fetching", .orange)
        }

        switch settings.languageEnhancerValidation {
        case .validating:
            return ("Checking", .orange)
        case .success:
            return ("Success", .green)
        case .failure:
            return ("Failed", .red)
        case .idle:
            if case .failure = settings.languageEnhancerFetchState {
                return ("Failed", .red)
            }
            if case .success = settings.languageEnhancerFetchState {
                return ("Fetched", .green)
            }
            return ("", .clear)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AI Models")
                            .font(.system(size: 17, weight: .semibold))

                        Text("Configure your model endpoints.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    SettingsGlassButton(
                        title: settings.hasUnsavedChanges ? "Save" : "Saved",
                        isAccent: true,
                        action: { settings.save() }
                    )
                    .disabled(!settings.hasUnsavedChanges)
                }

                if let message = settings.saveMessage {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(settings.hasUnsavedChanges ? .orange : .secondary)
                }

                SettingsSectionCard(
                    title: "OpenGLM",
                    statusText: openGLMStatus.0,
                    statusColor: openGLMStatus.1,
                    actionTitle: settings.openGLMValidation.isValidating ? "Checking..." : "Validate",
                    isActionDisabled: settings.openGLMValidation.isValidating,
                    action: settings.validateOpenGLM
                ) {
                    SettingsRow(title: "Server") {
                        SettingsTextField(text: $settings.openGLMServer, placeholder: "https://api.z.ai/api/paas/v4")
                    }

                    SettingsRow(title: "Key") {
                        SettingsSecureField(text: $settings.openGLMKey, placeholder: "EMPTY or your API key")
                    }

                    SettingsRow(title: "Model") {
                        HStack(spacing: 10) {
                            Picker("", selection: openGLMSelection) {
                                if settings.openGLMModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text("Select or enter a model").tag("")
                                }

                                ForEach(uniqueOpenGLMModels, id: \.self) { model in
                                    Text(model).tag(model)
                                }

                                Text("Custom").tag(customOpenGLMToken)
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity, alignment: .leading)

                            SettingsGlassButton(
                                title: settings.openGLMFetchState.isValidating ? "Fetching..." : "Fetch",
                                action: { settings.fetchOpenGLMModels() }
                            )
                            .disabled(settings.openGLMFetchState.isValidating)
                        }
                    }
                }

                SettingsSectionCard(
                    title: "Language Enhancer",
                    subtitle: "Optional",
                    statusText: languageStatus.0,
                    statusColor: languageStatus.1,
                    actionTitle: settings.languageEnhancerValidation.isValidating ? "Checking..." : "Validate",
                    isActionDisabled: settings.languageEnhancerValidation.isValidating,
                    action: settings.validateLanguageEnhancer
                ) {
                    SettingsRow(title: "Server") {
                        SettingsTextField(text: $settings.languageEnhancerServer, placeholder: "https://localhost:11434/")
                    }

                    SettingsRow(title: "Key") {
                        SettingsSecureField(text: $settings.languageEnhancerKey, placeholder: "Bearer token or API key")
                    }

                    SettingsRow(title: "Model") {
                        HStack(spacing: 10) {
                            Picker("", selection: languageEnhancerSelection) {
                                if settings.languageEnhancerModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text("Select or fetch a model").tag("")
                                }

                                ForEach(uniqueLanguageEnhancerModels, id: \.self) { model in
                                    Text(model).tag(model)
                                }

                                Text("Custom").tag(customLanguageEnhancerToken)
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity, alignment: .leading)

                            SettingsGlassButton(
                                title: settings.languageEnhancerFetchState.isValidating ? "Fetching..." : "Fetch",
                                action: { settings.fetchLanguageEnhancerModels() }
                            )
                            .disabled(settings.languageEnhancerFetchState.isValidating)
                        }
                    }
                }
            }
            .padding(20)
        }
        .sheet(item: $customModelSheet) { target in
            CustomModelEntrySheet(
                title: target.title,
                placeholder: target.placeholder,
                text: $customModelDraft
            ) {
                applyCustomModel(for: target)
            }
        }
    }
}

// DeviceConnectivitySection removed — settings are now shown inline

private struct DeviceConnectivityPane: View {
    @EnvironmentObject private var settings: AISettingsStore

    @State private var isScrcpyWindowExpanded = true
    @State private var isScrcpyVideoExpanded = false
    @State private var isScrcpyControlsExpanded = false
    @State private var isScrcpyAdvancedExpanded = false

    private var adbStatus: (String, Color) {
        settings.hasCustomADBPath ? ("Custom", .green) : ("System PATH", .secondary)
    }

    private var scrcpyStatus: (String, Color) {
        settings.hasCustomScrcpySettings ? ("Customized", .green) : ("Default", .secondary)
    }

    private let maxSizeOptions: [(label: String, value: String)] = [
        ("Automatic", ""),
        ("720", "720"),
        ("1080", "1080"),
        ("1440", "1440"),
        ("1920", "1920")
    ]

    private let maxFPSOptions: [(label: String, value: String)] = [
        ("System Default", ""),
        ("30 fps", "30"),
        ("60 fps", "60"),
        ("90 fps", "90"),
        ("120 fps", "120")
    ]

    private let videoBitRateOptions: [(label: String, value: String)] = [
        ("4M", "4M"),
        ("8M (Default)", "8M"),
        ("12M", "12M"),
        ("16M", "16M")
    ]

    private let audioBitRateOptions: [(label: String, value: String)] = [
        ("64K", "64K"),
        ("128K (Default)", "128K"),
        ("192K", "192K"),
        ("256K", "256K")
    ]

    private let renderDriverOptions: [(label: String, value: String)] = [
        ("System Default", ""),
        ("Metal", "metal"),
        ("OpenGL", "opengl"),
        ("OpenGL ES 2", "opengles2"),
        ("Software", "software")
    ]

    private let tunnelPortOptions: [(label: String, value: String)] = [
        ("Automatic", ""),
        ("0", "0"),
        ("27183", "27183"),
        ("27199", "27199")
    ]

    private let shortcutModOptions: [(label: String, value: String)] = [
        ("LAlt + LSuper (Default)", "lalt,lsuper"),
        ("LCtrl + LSuper", "lctrl,lsuper"),
        ("Only LSuper", "lsuper"),
        ("Only LAlt", "lalt")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Device Connectivity")
                            .font(.system(size: 17, weight: .semibold))

                        Text("Configure ADB and scrcpy settings.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    SettingsGlassButton(
                        title: settings.hasUnsavedChanges ? "Save" : "Saved",
                        isAccent: true,
                        action: { settings.save() }
                    )
                    .disabled(!settings.hasUnsavedChanges)
                }

                if let message = settings.saveMessage {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(settings.hasUnsavedChanges ? .orange : .secondary)
                }

                // MARK: ADB Section
                SettingsSectionCard(
                    title: "ADB",
                    subtitle: "Optional",
                    statusText: adbStatus.0,
                    statusColor: adbStatus.1,
                    actionTitle: "Reset",
                    isActionDisabled: false,
                    action: settings.resetADBPath
                ) {
                    SettingsRow(title: "Path", description: "ADB executable location") {
                        SettingsTextField(text: $settings.adbExecutablePath, placeholder: "/opt/homebrew/bin/adb or leave empty")
                    }

                    Text("Used for device discovery and control. Leave this empty to use `adb` from your system PATH.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }

                // MARK: Scrcpy Section
                SettingsSectionCard(
                    title: "Scrcpy",
                    subtitle: "Optional",
                    statusText: scrcpyStatus.0,
                    statusColor: scrcpyStatus.1,
                    actionTitle: "Reset",
                    isActionDisabled: false,
                    action: settings.resetScrcpySettings
                ) {
                    SettingsRow(title: "Path", description: "scrcpy executable location") {
                        SettingsTextField(text: $settings.scrcpyExecutablePath, placeholder: "/opt/homebrew/bin/scrcpy or leave empty")
                    }

                    // Launch & Window
                    SettingsCollapsibleGroup(title: "Launch & Window", systemImage: "macwindow", isExpanded: $isScrcpyWindowExpanded) {
                        SettingsRow(title: "Title", description: "Custom mirror window name") {
                            SettingsTextField(text: $settings.scrcpyWindowTitle, placeholder: "Optional custom window title")
                        }

                        SettingsToggleRow(title: "On Top", description: "Keep the window above others", isOn: $settings.scrcpyAlwaysOnTop)
                        SettingsToggleRow(title: "Fullscreen", description: "Open in fullscreen mode", isOn: $settings.scrcpyFullscreen)
                        SettingsToggleRow(title: "Borderless", description: "Hide the window frame", isOn: $settings.scrcpyWindowBorderless)
                        SettingsToggleRow(title: "Stay Awake", description: "Keep the device from sleeping", isOn: $settings.scrcpyStayAwake)
                        SettingsToggleRow(title: "No Sleep", description: "Disable macOS screensaver", isOn: $settings.scrcpyDisableScreensaver)
                        SettingsToggleRow(title: "Screen Off", description: "Turn off the phone screen on start", isOn: $settings.scrcpyTurnScreenOff)
                        SettingsToggleRow(title: "Touches", description: "Show physical touches on device", isOn: $settings.scrcpyShowTouches)
                    }

                    // Video & Audio
                    SettingsCollapsibleGroup(title: "Video & Audio", systemImage: "film", isExpanded: $isScrcpyVideoExpanded) {
                        SettingsRow(title: "Max Size", description: "Limit mirror resolution") {
                            SettingsStringMenuField(text: $settings.scrcpyMaxSize, options: maxSizeOptions)
                        }

                        SettingsRow(title: "Max FPS", description: "Cap the frame rate") {
                            SettingsStringMenuField(text: $settings.scrcpyMaxFPS, options: maxFPSOptions)
                        }

                        SettingsRow(title: "Video Rate", description: "Video encoding bitrate") {
                            SettingsStringMenuField(text: $settings.scrcpyVideoBitRate, options: videoBitRateOptions)
                        }

                        SettingsRow(title: "Video Codec", description: "Preferred video codec") {
                            SettingsMenuField(selection: $settings.scrcpyVideoCodec) {
                                ForEach(ScrcpyVideoCodecOption.allCases) { option in
                                    Text(option.rawValue.uppercased()).tag(option)
                                }
                            }
                        }

                        SettingsRow(title: "Audio Rate", description: "Audio encoding bitrate") {
                            SettingsStringMenuField(text: $settings.scrcpyAudioBitRate, options: audioBitRateOptions)
                        }

                        SettingsRow(title: "Audio Codec", description: "Preferred audio codec") {
                            SettingsMenuField(selection: $settings.scrcpyAudioCodec) {
                                ForEach(ScrcpyAudioCodecOption.allCases) { option in
                                    Text(option.rawValue.uppercased()).tag(option)
                                }
                            }
                        }

                        SettingsRow(title: "Audio Source", description: "Where captured audio comes from") {
                            SettingsMenuField(selection: $settings.scrcpyAudioSource) {
                                ForEach(ScrcpyAudioSourceOption.allCases) { option in
                                    Text(option.rawValue).tag(option)
                                }
                            }
                        }

                        SettingsToggleRow(title: "No Audio", description: "Disable audio forwarding", isOn: $settings.scrcpyNoAudio)
                    }

                    // Controls
                    SettingsCollapsibleGroup(title: "Controls", systemImage: "gamecontroller", isExpanded: $isScrcpyControlsExpanded) {
                        SettingsToggleRow(title: "Read Only", description: "Mirror without device control", isOn: $settings.scrcpyNoControl)
                        SettingsToggleRow(title: "Prefer Text", description: "Send characters as text events", isOn: $settings.scrcpyPreferText)
                        SettingsToggleRow(title: "Clipboard", description: "Disable clipboard auto-sync", isOn: $settings.scrcpyNoClipboardAutosync)

                        SettingsRow(title: "Keyboard", description: "Keyboard input mode") {
                            SettingsMenuField(selection: $settings.scrcpyKeyboardMode) {
                                ForEach(ScrcpyInputModeOption.allCases) { option in
                                    Text(option.rawValue).tag(option)
                                }
                            }
                        }

                        SettingsRow(title: "Mouse", description: "Mouse input mode") {
                            SettingsMenuField(selection: $settings.scrcpyMouseMode) {
                                ForEach(ScrcpyInputModeOption.allCases) { option in
                                    Text(option.rawValue).tag(option)
                                }
                            }
                        }

                        SettingsRow(title: "Gamepad", description: "Gamepad input mode") {
                            SettingsMenuField(selection: $settings.scrcpyGamepadMode) {
                                ForEach(ScrcpyGamepadModeOption.allCases) { option in
                                    Text(option.rawValue).tag(option)
                                }
                            }
                        }
                    }

                    // Advanced
                    SettingsCollapsibleGroup(title: "Advanced", systemImage: "gearshape.2", isExpanded: $isScrcpyAdvancedExpanded) {
                        SettingsRow(title: "Record", description: "Save the session to a file") {
                            SettingsTextField(text: $settings.scrcpyRecordPath, placeholder: "/tmp/session.mp4")
                        }

                        SettingsRow(title: "Render", description: "Preferred render backend") {
                            SettingsStringMenuField(text: $settings.scrcpyRenderDriver, options: renderDriverOptions)
                        }

                        SettingsRow(title: "Tunnel Host", description: "ADB tunnel host override") {
                            SettingsTextField(text: $settings.scrcpyTunnelHost, placeholder: "Optional host override")
                        }

                        SettingsRow(title: "Tunnel Port", description: "ADB tunnel port override") {
                            SettingsStringMenuField(text: $settings.scrcpyTunnelPort, options: tunnelPortOptions)
                        }

                        SettingsRow(title: "Shortcut", description: "Modifier keys for scrcpy shortcuts") {
                            SettingsStringMenuField(text: $settings.scrcpyShortcutMod, options: shortcutModOptions)
                        }

                        SettingsRow(title: "Extra Args", description: "Any additional raw scrcpy flags") {
                            SettingsTextArea(text: $settings.scrcpyAdditionalArgs, placeholder: "--print-fps --window-x=100 --window-y=80")
                        }

                        Text("Put any remaining raw scrcpy CLI flags into `Extra Args`.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }

                    Text(verbatim: settings.scrcpyCommandPreview)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.primary.opacity(0.03))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                                )
                        )
                }
            }
            .padding(20)
        }
    }
}

private struct AboutPane: View {
    @Environment(\.colorScheme) private var colorScheme

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("About")
                .font(.system(size: 17, weight: .semibold))

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    if let url = Bundle.main.url(forResource: "BrandMark", withExtension: "png"),
                       let nsImage = NSImage(contentsOf: url) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .shadow(color: .black.opacity(0.10), radius: 6, x: 0, y: 3)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("AIPhone")
                            .font(.system(size: 14, weight: .semibold))

                        Text("A macOS companion for Open-AutoGLM device automation.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }

                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 0.5)

                LabeledContent("Version", value: appVersion)
                    .font(.system(size: 12))
                LabeledContent("Platform", value: "macOS · SwiftUI")
                    .font(.system(size: 12))
                LabeledContent("Author", value: "Mochamad Nizwar Syafuan")
                    .font(.system(size: 12))
                LabeledContent("Reference") {
                    Link("zai-org/Open-AutoGLM", destination: URL(string: "https://github.com/zai-org/Open-AutoGLM")!)
                        .font(.system(size: 12))
                }
            }
            .padding(16)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(colorScheme == .dark
                            ? Color.white.opacity(0.05)
                            : Color.white.opacity(0.50))

                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    colorScheme == .dark ? Color.white.opacity(0.03) : Color.white.opacity(0.40),
                                    Color.clear
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    colorScheme == .dark ? Color.white.opacity(0.10) : Color.white.opacity(0.70),
                                    colorScheme == .dark ? Color.white.opacity(0.03) : Color.black.opacity(0.04)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.5
                        )
                }
            )

            Spacer()
        }
        .padding(20)
    }
}

private struct SettingsSectionCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    let statusText: String
    let statusColor: Color
    let actionTitle: String
    let isActionDisabled: Bool
    let action: () -> Void
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }

                StatusBadge(text: statusText, color: statusColor)

                Spacer()

                ValidateButton(
                    title: actionTitle,
                    isValidating: isActionDisabled,
                    action: action
                )
            }

            VStack(alignment: .leading, spacing: 12) {
                content
            }
        }
        .padding(16)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(colorScheme == .dark
                        ? Color.white.opacity(0.05)
                        : Color.white.opacity(0.50))

                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                colorScheme == .dark ? Color.white.opacity(0.03) : Color.white.opacity(0.40),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                colorScheme == .dark ? Color.white.opacity(0.10) : Color.white.opacity(0.70),
                                colorScheme == .dark ? Color.white.opacity(0.03) : Color.black.opacity(0.04)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            }
        )
    }
}

// Submenu components removed — replaced by inline collapsible groups

private struct SettingsCollapsibleGroup<Content: View>: View {
    let title: String
    let systemImage: String
    @Binding var isExpanded: Bool
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)

                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .textCase(.uppercase)
                        .tracking(0.3)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.quaternary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    content
                }
                .padding(.top, 6)
                .padding(.bottom, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.top, 4)
    }
}

private struct SettingsRow<Content: View>: View {
    let title: String
    var description: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)

                if let description {
                    Text(description)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(width: 150, alignment: .leading)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}

private struct SettingsMenuField<SelectionValue: Hashable, Content: View>: View {
    @Binding var selection: SelectionValue
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Picker("", selection: $selection) {
            content()
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsStringMenuField: View {
    @Binding var text: String
    let options: [(label: String, value: String)]

    var body: some View {
        SettingsMenuField(selection: $text) {
            ForEach(options, id: \.value) { option in
                Text(option.label).tag(option.value)
            }
        }
    }
}

private struct CustomModelEntrySheet: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private var isConfirmDisabled: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))

            Text("Enter the exact model identifier you want to use.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            TextField("Model", text: $text, prompt: Text(placeholder))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(colorScheme == .dark
                            ? Color.white.opacity(0.04)
                            : Color.black.opacity(0.025))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            colorScheme == .dark
                                ? Color.white.opacity(0.08)
                                : Color.black.opacity(0.06),
                            lineWidth: 0.5
                        )
                )

            HStack {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(Color.primary.opacity(0.05))
                )

                Button("Use Model") {
                    onConfirm()
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(Color.accentColor.opacity(0.12))
                        .overlay(
                            Capsule()
                                .stroke(Color.accentColor.opacity(0.20), lineWidth: 0.5)
                        )
                )
                .disabled(isConfirmDisabled)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let description: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)

                Text(description)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.vertical, 2)
    }
}

private struct SettingsTextField: View {
    @Binding var text: String
    let placeholder: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TextField(text: $text, prompt: Text(placeholder)) {
            EmptyView()
        }
        .labelsHidden()
        .textFieldStyle(.plain)
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(colorScheme == .dark
                    ? Color.white.opacity(0.04)
                    : Color.black.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    colorScheme == .dark
                        ? Color.white.opacity(0.08)
                        : Color.black.opacity(0.06),
                    lineWidth: 0.5
                )
        )
    }
}

private struct SettingsSecureField: View {
    @Binding var text: String
    let placeholder: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SecureField(text: $text, prompt: Text(placeholder)) {
            EmptyView()
        }
        .labelsHidden()
        .textFieldStyle(.plain)
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(colorScheme == .dark
                    ? Color.white.opacity(0.04)
                    : Color.black.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    colorScheme == .dark
                        ? Color.white.opacity(0.08)
                        : Color.black.opacity(0.06),
                    lineWidth: 0.5
                )
        )
    }
}

private struct SettingsTextArea: View {
    @Binding var text: String
    let placeholder: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(placeholder)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }

            TextEditor(text: $text)
                .font(.system(size: 11, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 68)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color.clear)
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(colorScheme == .dark
                    ? Color.white.opacity(0.04)
                    : Color.black.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    colorScheme == .dark
                        ? Color.white.opacity(0.08)
                        : Color.black.opacity(0.06),
                    lineWidth: 0.5
                )
        )
    }
}

private struct ValidateButton: View {
    let title: String
    let isValidating: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isValidating {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .frame(minWidth: 80)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(Color.accentColor.opacity(0.10))
                .overlay(
                    Capsule()
                        .stroke(Color.accentColor.opacity(0.18), lineWidth: 0.5)
                )
        )
        .disabled(isValidating)
    }
}

private struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(color.opacity(0.10))
            )
    }
}

private struct SettingsGlassButton: View {
    let title: String
    var isAccent: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isAccent ? Color.accentColor : Color.primary.opacity(0.70))
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(isAccent
                    ? Color.accentColor.opacity(0.12)
                    : Color.primary.opacity(0.05))
                .overlay(
                    Capsule()
                        .stroke(
                            isAccent
                                ? Color.accentColor.opacity(0.20)
                                : Color.primary.opacity(0.08),
                            lineWidth: 0.5
                        )
                )
        )
    }
}

private struct SettingsWindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()

        DispatchQueue.main.async {
            guard let window = view.window else { return }
            configure(window: window)
        }

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            configure(window: window)
        }
    }

    private func configure(window: NSWindow) {
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.titleVisibility = .visible
    }
}
