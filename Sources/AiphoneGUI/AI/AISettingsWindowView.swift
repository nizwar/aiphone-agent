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
}

struct AISettingsWindowView: View {
    @EnvironmentObject private var settings: AISettingsStore
    @State private var selection: SettingsPage? = .aiModels

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $selection) { page in
                Label(page.rawValue, systemImage: page.systemImage)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .tag(page)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 200)
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
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 760, height: 500)
        .background(SettingsWindowChromeConfigurator())
    }
}

private struct AIModelsPane: View {
    @EnvironmentObject private var settings: AISettingsStore

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
        var seen = Set<String>()
        let candidates = ([settings.openGLMModel] + OpenGLMModelOption.allCases.map(\.rawValue) + settings.availableOpenGLMModels)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return candidates.filter { seen.insert($0).inserted }
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
            return ("Optional", .secondary)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AI Models")
                            .font(.title2.weight(.semibold))

                        Text("Configure your model endpoints.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button(settings.hasUnsavedChanges ? "Save" : "Saved") {
                        settings.save()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
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
                            Picker("", selection: $settings.openGLMModel) {
                                ForEach(uniqueOpenGLMModels, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(nsColor: .textBackgroundColor))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(Color.black.opacity(0.08), lineWidth: 1)
                                    )
                            )

                            Button(settings.openGLMFetchState.isValidating ? "Fetching..." : "Fetch") {
                                settings.fetchOpenGLMModels()
                            }
                            .buttonStyle(.bordered)
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
                            Picker("", selection: $settings.languageEnhancerModel) {
                                if settings.availableLanguageEnhancerModels.isEmpty {
                                    Text(settings.languageEnhancerModel.isEmpty ? "Select or fetch a model" : settings.languageEnhancerModel)
                                        .tag(settings.languageEnhancerModel)
                                } else {
                                    ForEach(settings.availableLanguageEnhancerModels, id: \.self) { model in
                                        Text(model).tag(model)
                                    }
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(nsColor: .textBackgroundColor))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(Color.black.opacity(0.08), lineWidth: 1)
                                    )
                            )

                            Button(settings.languageEnhancerFetchState.isValidating ? "Fetching..." : "Fetch") {
                                settings.fetchLanguageEnhancerModels()
                            }
                            .buttonStyle(.bordered)
                            .disabled(settings.languageEnhancerFetchState.isValidating)
                        }
                    }
                }
            }
            .padding(20)
        }
    }
}

private enum DeviceConnectivitySection: String, CaseIterable, Identifiable {
    case adb = "ADB"
    case scrcpy = "Scrcpy"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .adb:
            return "terminal"
        case .scrcpy:
            return "rectangle.on.rectangle"
        }
    }

    var subtitle: String {
        switch self {
        case .adb:
            return "Device discovery and control"
        case .scrcpy:
            return "Screen mirroring and upcoming features"
        }
    }
}

private struct DeviceConnectivityPane: View {
    @EnvironmentObject private var settings: AISettingsStore
    @State private var selection: DeviceConnectivitySection?

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
                if let selection {
                    HStack(spacing: 10) {
                        Button {
                            self.selection = nil
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)
                                .frame(width: 30, height: 30)
                                .background(
                                    Circle()
                                        .fill(Color(nsColor: .controlBackgroundColor))
                                )
                        }
                        .buttonStyle(.plain)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(selection.rawValue)
                                .font(.title2.weight(.semibold))

                            Text(selection.subtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button(settings.hasUnsavedChanges ? "Save" : "Saved") {
                            settings.save()
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!settings.hasUnsavedChanges)
                    }

                    if let message = settings.saveMessage {
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(settings.hasUnsavedChanges ? .orange : .secondary)
                    }

                    switch selection {
                    case .adb:
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

                    case .scrcpy:
                        SettingsSectionCard(
                            title: "Scrcpy",
                            subtitle: "Optional",
                            statusText: scrcpyStatus.0,
                            statusColor: scrcpyStatus.1,
                            actionTitle: "Reset",
                            isActionDisabled: false,
                            action: settings.resetScrcpySettings
                        ) {
                            SettingsSubsectionHeader(title: "Launch & Window")

                            SettingsRow(title: "Path", description: "scrcpy executable location") {
                                SettingsTextField(text: $settings.scrcpyExecutablePath, placeholder: "/opt/homebrew/bin/scrcpy or leave empty")
                            }

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

                            Divider()

                            SettingsSubsectionHeader(title: "Video & Audio")

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

                            Divider()

                            SettingsSubsectionHeader(title: "Controls")

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

                            Divider()

                            SettingsSubsectionHeader(title: "Advanced")

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

                            Text("Preset values now use dropdowns. Put any remaining raw scrcpy CLI flags into `Extra Args`.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)

                            Text(verbatim: settings.scrcpyCommandPreview)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color(nsColor: .textBackgroundColor))
                                )
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Device Connectivity")
                            .font(.title2.weight(.semibold))

                        Text("Choose a submenu below to open its dedicated settings page.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    SettingsSubmenuCard {
                        ForEach(Array(DeviceConnectivitySection.allCases.enumerated()), id: \.element.id) { index, section in
                            SettingsSubmenuRow(
                                systemImage: section.systemImage,
                                title: section.rawValue,
                                subtitle: section.subtitle
                            ) {
                                selection = section
                            }

                            if index < DeviceConnectivitySection.allCases.count - 1 {
                                Divider()
                                    .padding(.leading, 54)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
    }
}

private struct AboutPane: View {
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("About")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    // Image("BrandMark", bundle: .module)
                    //     .resizable()
                    //     .interpolation(.high)
                    //     .frame(width: 64, height: 64)
                    //     .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    //     .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("AIPhone")
                            .font(.headline)

                        Text("A macOS Swift companion UI for Open-AutoGLM.")
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                LabeledContent("Version", value: appVersion)
                LabeledContent("Platform", value: "macOS · SwiftUI")
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                Text(title)
                    .font(.headline)

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
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
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                )
        )
    }
}

private struct SettingsSubmenuCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct SettingsSubmenuRow: View {
    let systemImage: String
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsSubsectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.top, 2)
    }
}

private struct SettingsRow<Content: View>: View {
    let title: String
    var description: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                if let description {
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
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

    var body: some View {
        Picker("", selection: $selection) {
            content()
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )
        )
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

private struct SettingsToggleRow: View {
    let title: String
    let description: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
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

    var body: some View {
        TextField(text: $text, prompt: Text(placeholder)) {
            EmptyView()
        }
        .labelsHidden()
        .textFieldStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )
        )
    }
}

private struct SettingsSecureField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        SecureField(text: $text, prompt: Text(placeholder)) {
            EmptyView()
        }
        .labelsHidden()
        .textFieldStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )
        )
    }
}

private struct SettingsTextArea: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(placeholder)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            }

            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 72)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.clear)
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
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
            HStack(spacing: 8) {
                if isValidating {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(title)
            }
            .frame(minWidth: 92)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isValidating)
    }
}

private struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(color.opacity(0.12))
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
