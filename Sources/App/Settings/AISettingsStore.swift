import Foundation
import SwiftUI

private enum DeprecatedModelCatalog {
    static var hiddenValues: Set<String> {
        var hidden = Set<String>()
        for provider in AIModelProviderRegistry.allProviders {
            hidden.formUnion(provider.type.hiddenModels)
        }
        return hidden
    }

    static func sanitized(_ models: [String]) -> [String] {
        models
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !hiddenValues.contains($0) }
    }

    static func normalizedOpenGLMSelection(_ value: String?, providerType: any AIModelProvider.Type = AutoGLMModelProvider.self) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, !hiddenValues.contains(trimmed) else {
            return providerType.defaultModelName
        }
        return trimmed
    }

    static func normalizedOptionalSelection(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return hiddenValues.contains(trimmed) ? "" : trimmed
    }
}

enum EndpointValidationState: Equatable {
    case idle
    case validating
    case success(String)
    case failure(String)

    var isValidating: Bool {
        if case .validating = self { return true }
        return false
    }

    var message: String? {
        switch self {
        case .idle, .validating:
            return nil
        case let .success(message), let .failure(message):
            return message
        }
    }

    var iconName: String {
        switch self {
        case .idle:
            return "circle.dashed"
        case .validating:
            return "hourglass"
        case .success:
            return "checkmark.circle.fill"
        case .failure:
            return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .idle:
            return .secondary
        case .validating:
            return .orange
        case .success:
            return .green
        case .failure:
            return .red
        }
    }
}

enum AppSettingsKeys {
    static let openGLMServer = "ai.settings.openGLM.server"
    static let openGLMKey = "ai.settings.openGLM.key"
    static let openGLMModel = "ai.settings.openGLM.model"
    static let languageEnhancerServer = "ai.settings.languageEnhancer.server"
    static let languageEnhancerKey = "ai.settings.languageEnhancer.key"
    static let languageEnhancerModel = "ai.settings.languageEnhancer.model"
    static let selectedModelProvider = "ai.settings.modelProvider"
    static let adbExecutablePath = "app.settings.adb.path"
    static let scrcpyExecutablePath = "app.settings.scrcpy.path"
    static let scrcpyAlwaysOnTop = "app.settings.scrcpy.alwaysOnTop"
    static let scrcpyFullscreen = "app.settings.scrcpy.fullscreen"
    static let scrcpyWindowBorderless = "app.settings.scrcpy.windowBorderless"
    static let scrcpyStayAwake = "app.settings.scrcpy.stayAwake"
    static let scrcpyDisableScreensaver = "app.settings.scrcpy.disableScreensaver"
    static let scrcpyTurnScreenOff = "app.settings.scrcpy.turnScreenOff"
    static let scrcpyShowTouches = "app.settings.scrcpy.showTouches"
    static let scrcpyNoControl = "app.settings.scrcpy.noControl"
    static let scrcpyNoAudio = "app.settings.scrcpy.noAudio"
    static let scrcpyPreferText = "app.settings.scrcpy.preferText"
    static let scrcpyNoClipboardAutosync = "app.settings.scrcpy.noClipboardAutosync"
    static let scrcpyMaxSize = "app.settings.scrcpy.maxSize"
    static let scrcpyMaxFPS = "app.settings.scrcpy.maxFPS"
    static let scrcpyVideoBitRate = "app.settings.scrcpy.videoBitRate"
    static let scrcpyAudioBitRate = "app.settings.scrcpy.audioBitRate"
    static let scrcpyVideoCodec = "app.settings.scrcpy.videoCodec"
    static let scrcpyAudioCodec = "app.settings.scrcpy.audioCodec"
    static let scrcpyAudioSource = "app.settings.scrcpy.audioSource"
    static let scrcpyKeyboardMode = "app.settings.scrcpy.keyboardMode"
    static let scrcpyMouseMode = "app.settings.scrcpy.mouseMode"
    static let scrcpyGamepadMode = "app.settings.scrcpy.gamepadMode"
    static let scrcpyWindowTitle = "app.settings.scrcpy.windowTitle"
    static let scrcpyRecordPath = "app.settings.scrcpy.recordPath"
    static let scrcpyRenderDriver = "app.settings.scrcpy.renderDriver"
    static let scrcpyTunnelHost = "app.settings.scrcpy.tunnelHost"
    static let scrcpyTunnelPort = "app.settings.scrcpy.tunnelPort"
    static let scrcpyShortcutMod = "app.settings.scrcpy.shortcutMod"
    static let scrcpyAdditionalArgs = "app.settings.scrcpy.additionalArgs"
}

enum ToolPathResolver {
    static func adbPath(defaults: UserDefaults = .standard) -> String {
        let configuredPath = defaults.string(forKey: AppSettingsKeys.adbExecutablePath)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return configuredPath.isEmpty ? "adb" : configuredPath
    }

    static func scrcpyPath(defaults: UserDefaults = .standard) -> String {
        let configuredPath = defaults.string(forKey: AppSettingsKeys.scrcpyExecutablePath)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return configuredPath.isEmpty ? "scrcpy" : configuredPath
    }

    static func resolveExecutable(_ commandOrPath: String, env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let trimmed = commandOrPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let expandedPath = NSString(string: trimmed).expandingTildeInPath
        if expandedPath.contains("/") {
            return FileManager.default.isExecutableFile(atPath: expandedPath) ? expandedPath : nil
        }

        let envPaths = (env["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let androidPlatformTools = NSString(string: "~/Library/Android/sdk/platform-tools").expandingTildeInPath
        let fallbackPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            androidPlatformTools
        ]

        let searchPaths = Array(NSOrderedSet(array: envPaths + fallbackPaths)) as? [String] ?? fallbackPaths
        for directory in searchPaths {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(trimmed).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    static func isScrcpyAvailable(defaults: UserDefaults = .standard) -> Bool {
        resolveExecutable(scrcpyPath(defaults: defaults)) != nil
    }
}

enum ScrcpyVideoCodecOption: String, CaseIterable, Identifiable {
    case h264
    case h265
    case av1

    var id: String { rawValue }
}

enum ScrcpyAudioCodecOption: String, CaseIterable, Identifiable {
    case opus
    case aac
    case flac
    case raw

    var id: String { rawValue }
}

enum ScrcpyAudioSourceOption: String, CaseIterable, Identifiable {
    case output
    case playback
    case mic
    case micVoiceCommunication = "mic-voice-communication"

    var id: String { rawValue }
}

enum ScrcpyInputModeOption: String, CaseIterable, Identifiable {
    case disabled
    case sdk
    case uhid
    case aoa

    var id: String { rawValue }
}

enum ScrcpyGamepadModeOption: String, CaseIterable, Identifiable {
    case disabled
    case uhid
    case aoa

    var id: String { rawValue }
}

@MainActor
final class AISettingsStore: ObservableObject {
    static let shared = AISettingsStore()

    @Published var selectedModelProvider: String {
        didSet { defaults.set(selectedModelProvider, forKey: AppSettingsKeys.selectedModelProvider) }
    }

    @Published var openGLMServer: String {
        didSet { defaults.set(openGLMServer, forKey: AppSettingsKeys.openGLMServer) }
    }

    @Published var openGLMKey: String {
        didSet { defaults.set(openGLMKey, forKey: AppSettingsKeys.openGLMKey) }
    }

    @Published var openGLMModel: String {
        didSet { defaults.set(openGLMModel, forKey: AppSettingsKeys.openGLMModel) }
    }

    @Published var languageEnhancerServer: String {
        didSet { defaults.set(languageEnhancerServer, forKey: AppSettingsKeys.languageEnhancerServer) }
    }

    @Published var languageEnhancerKey: String {
        didSet { defaults.set(languageEnhancerKey, forKey: AppSettingsKeys.languageEnhancerKey) }
    }

    @Published var languageEnhancerModel: String {
        didSet { defaults.set(languageEnhancerModel, forKey: AppSettingsKeys.languageEnhancerModel) }
    }

    @Published var adbExecutablePath: String {
        didSet { defaults.set(adbExecutablePath, forKey: AppSettingsKeys.adbExecutablePath) }
    }

    @Published var scrcpyExecutablePath: String {
        didSet { defaults.set(scrcpyExecutablePath, forKey: AppSettingsKeys.scrcpyExecutablePath) }
    }

    @Published var scrcpyAlwaysOnTop: Bool {
        didSet { defaults.set(scrcpyAlwaysOnTop, forKey: AppSettingsKeys.scrcpyAlwaysOnTop) }
    }

    @Published var scrcpyFullscreen: Bool {
        didSet { defaults.set(scrcpyFullscreen, forKey: AppSettingsKeys.scrcpyFullscreen) }
    }

    @Published var scrcpyWindowBorderless: Bool {
        didSet { defaults.set(scrcpyWindowBorderless, forKey: AppSettingsKeys.scrcpyWindowBorderless) }
    }

    @Published var scrcpyStayAwake: Bool {
        didSet { defaults.set(scrcpyStayAwake, forKey: AppSettingsKeys.scrcpyStayAwake) }
    }

    @Published var scrcpyDisableScreensaver: Bool {
        didSet { defaults.set(scrcpyDisableScreensaver, forKey: AppSettingsKeys.scrcpyDisableScreensaver) }
    }

    @Published var scrcpyTurnScreenOff: Bool {
        didSet { defaults.set(scrcpyTurnScreenOff, forKey: AppSettingsKeys.scrcpyTurnScreenOff) }
    }

    @Published var scrcpyShowTouches: Bool {
        didSet { defaults.set(scrcpyShowTouches, forKey: AppSettingsKeys.scrcpyShowTouches) }
    }

    @Published var scrcpyNoControl: Bool {
        didSet { defaults.set(scrcpyNoControl, forKey: AppSettingsKeys.scrcpyNoControl) }
    }

    @Published var scrcpyNoAudio: Bool {
        didSet { defaults.set(scrcpyNoAudio, forKey: AppSettingsKeys.scrcpyNoAudio) }
    }

    @Published var scrcpyPreferText: Bool {
        didSet { defaults.set(scrcpyPreferText, forKey: AppSettingsKeys.scrcpyPreferText) }
    }

    @Published var scrcpyNoClipboardAutosync: Bool {
        didSet { defaults.set(scrcpyNoClipboardAutosync, forKey: AppSettingsKeys.scrcpyNoClipboardAutosync) }
    }

    @Published var scrcpyMaxSize: String {
        didSet { defaults.set(scrcpyMaxSize, forKey: AppSettingsKeys.scrcpyMaxSize) }
    }

    @Published var scrcpyMaxFPS: String {
        didSet { defaults.set(scrcpyMaxFPS, forKey: AppSettingsKeys.scrcpyMaxFPS) }
    }

    @Published var scrcpyVideoBitRate: String {
        didSet { defaults.set(scrcpyVideoBitRate, forKey: AppSettingsKeys.scrcpyVideoBitRate) }
    }

    @Published var scrcpyAudioBitRate: String {
        didSet { defaults.set(scrcpyAudioBitRate, forKey: AppSettingsKeys.scrcpyAudioBitRate) }
    }

    @Published var scrcpyVideoCodec: ScrcpyVideoCodecOption {
        didSet { defaults.set(scrcpyVideoCodec.rawValue, forKey: AppSettingsKeys.scrcpyVideoCodec) }
    }

    @Published var scrcpyAudioCodec: ScrcpyAudioCodecOption {
        didSet { defaults.set(scrcpyAudioCodec.rawValue, forKey: AppSettingsKeys.scrcpyAudioCodec) }
    }

    @Published var scrcpyAudioSource: ScrcpyAudioSourceOption {
        didSet { defaults.set(scrcpyAudioSource.rawValue, forKey: AppSettingsKeys.scrcpyAudioSource) }
    }

    @Published var scrcpyKeyboardMode: ScrcpyInputModeOption {
        didSet { defaults.set(scrcpyKeyboardMode.rawValue, forKey: AppSettingsKeys.scrcpyKeyboardMode) }
    }

    @Published var scrcpyMouseMode: ScrcpyInputModeOption {
        didSet { defaults.set(scrcpyMouseMode.rawValue, forKey: AppSettingsKeys.scrcpyMouseMode) }
    }

    @Published var scrcpyGamepadMode: ScrcpyGamepadModeOption {
        didSet { defaults.set(scrcpyGamepadMode.rawValue, forKey: AppSettingsKeys.scrcpyGamepadMode) }
    }

    @Published var scrcpyWindowTitle: String {
        didSet { defaults.set(scrcpyWindowTitle, forKey: AppSettingsKeys.scrcpyWindowTitle) }
    }

    @Published var scrcpyRecordPath: String {
        didSet { defaults.set(scrcpyRecordPath, forKey: AppSettingsKeys.scrcpyRecordPath) }
    }

    @Published var scrcpyRenderDriver: String {
        didSet { defaults.set(scrcpyRenderDriver, forKey: AppSettingsKeys.scrcpyRenderDriver) }
    }

    @Published var scrcpyTunnelHost: String {
        didSet { defaults.set(scrcpyTunnelHost, forKey: AppSettingsKeys.scrcpyTunnelHost) }
    }

    @Published var scrcpyTunnelPort: String {
        didSet { defaults.set(scrcpyTunnelPort, forKey: AppSettingsKeys.scrcpyTunnelPort) }
    }

    @Published var scrcpyShortcutMod: String {
        didSet { defaults.set(scrcpyShortcutMod, forKey: AppSettingsKeys.scrcpyShortcutMod) }
    }

    @Published var scrcpyAdditionalArgs: String {
        didSet { defaults.set(scrcpyAdditionalArgs, forKey: AppSettingsKeys.scrcpyAdditionalArgs) }
    }

    @Published var availableOpenGLMModels: [String]
    @Published var availableLanguageEnhancerModels: [String]

    @Published var openGLMValidation: EndpointValidationState = .idle
    @Published var openGLMFetchState: EndpointValidationState = .idle
    @Published var languageEnhancerValidation: EndpointValidationState = .idle
    @Published var languageEnhancerFetchState: EndpointValidationState = .idle
    @Published var saveMessage: String?

    var hasUnsavedChanges: Bool {
        false
    }

    var hasCustomADBPath: Bool {
        !adbExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasCustomScrcpyPath: Bool {
        !scrcpyExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasCustomScrcpySettings: Bool {
        hasCustomScrcpyPath ||
        scrcpyAlwaysOnTop ||
        scrcpyFullscreen ||
        scrcpyWindowBorderless ||
        scrcpyStayAwake ||
        scrcpyDisableScreensaver ||
        scrcpyTurnScreenOff ||
        scrcpyShowTouches ||
        scrcpyNoControl ||
        scrcpyNoAudio ||
        scrcpyPreferText ||
        scrcpyNoClipboardAutosync ||
        !scrcpyMaxSize.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !scrcpyMaxFPS.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        scrcpyVideoBitRate.trimmingCharacters(in: .whitespacesAndNewlines) != "8M" ||
        scrcpyAudioBitRate.trimmingCharacters(in: .whitespacesAndNewlines) != "128K" ||
        scrcpyVideoCodec != .h264 ||
        scrcpyAudioCodec != .opus ||
        scrcpyAudioSource != .output ||
        scrcpyKeyboardMode != .sdk ||
        scrcpyMouseMode != .sdk ||
        scrcpyGamepadMode != .disabled ||
        !scrcpyWindowTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !scrcpyRecordPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !scrcpyRenderDriver.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !scrcpyTunnelHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        !scrcpyTunnelPort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        scrcpyShortcutMod.trimmingCharacters(in: .whitespacesAndNewlines) != "lalt,lsuper" ||
        !scrcpyAdditionalArgs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasCustomADBToolPaths: Bool {
        hasCustomADBPath || hasCustomScrcpyPath
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let selectedProvider = defaults.string(forKey: AppSettingsKeys.selectedModelProvider) ?? AIModelProviderRegistry.defaultProviderID()
        self.selectedModelProvider = selectedProvider
        let providerType = AIModelProviderRegistry.providerType(for: selectedProvider) ?? AutoGLMModelProvider.self
        self.openGLMServer = defaults.string(forKey: AppSettingsKeys.openGLMServer) ?? "http://localhost:8000/v1"
        self.openGLMKey = defaults.string(forKey: AppSettingsKeys.openGLMKey) ?? ""
        self.openGLMModel = DeprecatedModelCatalog.normalizedOpenGLMSelection(
            defaults.string(forKey: AppSettingsKeys.openGLMModel),
            providerType: providerType
        )
        self.languageEnhancerServer = defaults.string(forKey: AppSettingsKeys.languageEnhancerServer) ?? "https://localhost:11434/"
        self.languageEnhancerKey = defaults.string(forKey: AppSettingsKeys.languageEnhancerKey) ?? ""
        self.languageEnhancerModel = DeprecatedModelCatalog.normalizedOptionalSelection(
            defaults.string(forKey: AppSettingsKeys.languageEnhancerModel)
        )
        self.adbExecutablePath = defaults.string(forKey: AppSettingsKeys.adbExecutablePath) ?? ""
        self.scrcpyExecutablePath = defaults.string(forKey: AppSettingsKeys.scrcpyExecutablePath) ?? ""
        self.scrcpyAlwaysOnTop = defaults.object(forKey: AppSettingsKeys.scrcpyAlwaysOnTop) as? Bool ?? false
        self.scrcpyFullscreen = defaults.object(forKey: AppSettingsKeys.scrcpyFullscreen) as? Bool ?? false
        self.scrcpyWindowBorderless = defaults.object(forKey: AppSettingsKeys.scrcpyWindowBorderless) as? Bool ?? false
        self.scrcpyStayAwake = defaults.object(forKey: AppSettingsKeys.scrcpyStayAwake) as? Bool ?? false
        self.scrcpyDisableScreensaver = defaults.object(forKey: AppSettingsKeys.scrcpyDisableScreensaver) as? Bool ?? false
        self.scrcpyTurnScreenOff = defaults.object(forKey: AppSettingsKeys.scrcpyTurnScreenOff) as? Bool ?? false
        self.scrcpyShowTouches = defaults.object(forKey: AppSettingsKeys.scrcpyShowTouches) as? Bool ?? false
        self.scrcpyNoControl = defaults.object(forKey: AppSettingsKeys.scrcpyNoControl) as? Bool ?? false
        self.scrcpyNoAudio = defaults.object(forKey: AppSettingsKeys.scrcpyNoAudio) as? Bool ?? false
        self.scrcpyPreferText = defaults.object(forKey: AppSettingsKeys.scrcpyPreferText) as? Bool ?? false
        self.scrcpyNoClipboardAutosync = defaults.object(forKey: AppSettingsKeys.scrcpyNoClipboardAutosync) as? Bool ?? false
        self.scrcpyMaxSize = defaults.string(forKey: AppSettingsKeys.scrcpyMaxSize) ?? ""
        self.scrcpyMaxFPS = defaults.string(forKey: AppSettingsKeys.scrcpyMaxFPS) ?? ""
        self.scrcpyVideoBitRate = defaults.string(forKey: AppSettingsKeys.scrcpyVideoBitRate) ?? "8M"
        self.scrcpyAudioBitRate = defaults.string(forKey: AppSettingsKeys.scrcpyAudioBitRate) ?? "128K"
        self.scrcpyVideoCodec = ScrcpyVideoCodecOption(rawValue: defaults.string(forKey: AppSettingsKeys.scrcpyVideoCodec) ?? ScrcpyVideoCodecOption.h264.rawValue) ?? .h264
        self.scrcpyAudioCodec = ScrcpyAudioCodecOption(rawValue: defaults.string(forKey: AppSettingsKeys.scrcpyAudioCodec) ?? ScrcpyAudioCodecOption.opus.rawValue) ?? .opus
        self.scrcpyAudioSource = ScrcpyAudioSourceOption(rawValue: defaults.string(forKey: AppSettingsKeys.scrcpyAudioSource) ?? ScrcpyAudioSourceOption.output.rawValue) ?? .output
        self.scrcpyKeyboardMode = ScrcpyInputModeOption(rawValue: defaults.string(forKey: AppSettingsKeys.scrcpyKeyboardMode) ?? ScrcpyInputModeOption.sdk.rawValue) ?? .sdk
        self.scrcpyMouseMode = ScrcpyInputModeOption(rawValue: defaults.string(forKey: AppSettingsKeys.scrcpyMouseMode) ?? ScrcpyInputModeOption.sdk.rawValue) ?? .sdk
        self.scrcpyGamepadMode = ScrcpyGamepadModeOption(rawValue: defaults.string(forKey: AppSettingsKeys.scrcpyGamepadMode) ?? ScrcpyGamepadModeOption.disabled.rawValue) ?? .disabled
        self.scrcpyWindowTitle = defaults.string(forKey: AppSettingsKeys.scrcpyWindowTitle) ?? ""
        self.scrcpyRecordPath = defaults.string(forKey: AppSettingsKeys.scrcpyRecordPath) ?? ""
        self.scrcpyRenderDriver = defaults.string(forKey: AppSettingsKeys.scrcpyRenderDriver) ?? ""
        self.scrcpyTunnelHost = defaults.string(forKey: AppSettingsKeys.scrcpyTunnelHost) ?? ""
        self.scrcpyTunnelPort = defaults.string(forKey: AppSettingsKeys.scrcpyTunnelPort) ?? ""
        self.scrcpyShortcutMod = defaults.string(forKey: AppSettingsKeys.scrcpyShortcutMod) ?? "lalt,lsuper"
        self.scrcpyAdditionalArgs = defaults.string(forKey: AppSettingsKeys.scrcpyAdditionalArgs) ?? ""
        self.availableOpenGLMModels = []
        self.availableLanguageEnhancerModels = []
    }

    var resolvedModelProvider: any AIModelProvider {
        AIModelProviderRegistry.provider(for: selectedModelProvider) ?? AutoGLMModelProvider()
    }

    var resolvedModelProviderType: any AIModelProvider.Type {
        AIModelProviderRegistry.providerType(for: selectedModelProvider) ?? AutoGLMModelProvider.self
    }

    func save() {
        defaults.set(selectedModelProvider, forKey: AppSettingsKeys.selectedModelProvider)
        defaults.set(openGLMServer, forKey: AppSettingsKeys.openGLMServer)
        defaults.set(openGLMKey, forKey: AppSettingsKeys.openGLMKey)
        defaults.set(openGLMModel, forKey: AppSettingsKeys.openGLMModel)
        defaults.set(languageEnhancerServer, forKey: AppSettingsKeys.languageEnhancerServer)
        defaults.set(languageEnhancerKey, forKey: AppSettingsKeys.languageEnhancerKey)
        defaults.set(languageEnhancerModel, forKey: AppSettingsKeys.languageEnhancerModel)
        defaults.set(adbExecutablePath, forKey: AppSettingsKeys.adbExecutablePath)
        defaults.set(scrcpyExecutablePath, forKey: AppSettingsKeys.scrcpyExecutablePath)
        defaults.set(scrcpyAlwaysOnTop, forKey: AppSettingsKeys.scrcpyAlwaysOnTop)
        defaults.set(scrcpyFullscreen, forKey: AppSettingsKeys.scrcpyFullscreen)
        defaults.set(scrcpyWindowBorderless, forKey: AppSettingsKeys.scrcpyWindowBorderless)
        defaults.set(scrcpyStayAwake, forKey: AppSettingsKeys.scrcpyStayAwake)
        defaults.set(scrcpyDisableScreensaver, forKey: AppSettingsKeys.scrcpyDisableScreensaver)
        defaults.set(scrcpyTurnScreenOff, forKey: AppSettingsKeys.scrcpyTurnScreenOff)
        defaults.set(scrcpyShowTouches, forKey: AppSettingsKeys.scrcpyShowTouches)
        defaults.set(scrcpyNoControl, forKey: AppSettingsKeys.scrcpyNoControl)
        defaults.set(scrcpyNoAudio, forKey: AppSettingsKeys.scrcpyNoAudio)
        defaults.set(scrcpyPreferText, forKey: AppSettingsKeys.scrcpyPreferText)
        defaults.set(scrcpyNoClipboardAutosync, forKey: AppSettingsKeys.scrcpyNoClipboardAutosync)
        defaults.set(scrcpyMaxSize, forKey: AppSettingsKeys.scrcpyMaxSize)
        defaults.set(scrcpyMaxFPS, forKey: AppSettingsKeys.scrcpyMaxFPS)
        defaults.set(scrcpyVideoBitRate, forKey: AppSettingsKeys.scrcpyVideoBitRate)
        defaults.set(scrcpyAudioBitRate, forKey: AppSettingsKeys.scrcpyAudioBitRate)
        defaults.set(scrcpyVideoCodec.rawValue, forKey: AppSettingsKeys.scrcpyVideoCodec)
        defaults.set(scrcpyAudioCodec.rawValue, forKey: AppSettingsKeys.scrcpyAudioCodec)
        defaults.set(scrcpyAudioSource.rawValue, forKey: AppSettingsKeys.scrcpyAudioSource)
        defaults.set(scrcpyKeyboardMode.rawValue, forKey: AppSettingsKeys.scrcpyKeyboardMode)
        defaults.set(scrcpyMouseMode.rawValue, forKey: AppSettingsKeys.scrcpyMouseMode)
        defaults.set(scrcpyGamepadMode.rawValue, forKey: AppSettingsKeys.scrcpyGamepadMode)
        defaults.set(scrcpyWindowTitle, forKey: AppSettingsKeys.scrcpyWindowTitle)
        defaults.set(scrcpyRecordPath, forKey: AppSettingsKeys.scrcpyRecordPath)
        defaults.set(scrcpyRenderDriver, forKey: AppSettingsKeys.scrcpyRenderDriver)
        defaults.set(scrcpyTunnelHost, forKey: AppSettingsKeys.scrcpyTunnelHost)
        defaults.set(scrcpyTunnelPort, forKey: AppSettingsKeys.scrcpyTunnelPort)
        defaults.set(scrcpyShortcutMod, forKey: AppSettingsKeys.scrcpyShortcutMod)
        defaults.set(scrcpyAdditionalArgs, forKey: AppSettingsKeys.scrcpyAdditionalArgs)
        saveMessage = "Settings saved."
    }

    func resetADBPath() {
        adbExecutablePath = ""
        saveMessage = "ADB path reset to system default."
    }

    func resetScrcpyPath() {
        scrcpyExecutablePath = ""
        saveMessage = "scrcpy path reset to system default."
    }

    func resetScrcpySettings() {
        scrcpyExecutablePath = ""
        scrcpyAlwaysOnTop = false
        scrcpyFullscreen = false
        scrcpyWindowBorderless = false
        scrcpyStayAwake = false
        scrcpyDisableScreensaver = false
        scrcpyTurnScreenOff = false
        scrcpyShowTouches = false
        scrcpyNoControl = false
        scrcpyNoAudio = false
        scrcpyPreferText = false
        scrcpyNoClipboardAutosync = false
        scrcpyMaxSize = ""
        scrcpyMaxFPS = ""
        scrcpyVideoBitRate = "8M"
        scrcpyAudioBitRate = "128K"
        scrcpyVideoCodec = .h264
        scrcpyAudioCodec = .opus
        scrcpyAudioSource = .output
        scrcpyKeyboardMode = .sdk
        scrcpyMouseMode = .sdk
        scrcpyGamepadMode = .disabled
        scrcpyWindowTitle = ""
        scrcpyRecordPath = ""
        scrcpyRenderDriver = ""
        scrcpyTunnelHost = ""
        scrcpyTunnelPort = ""
        scrcpyShortcutMod = "lalt,lsuper"
        scrcpyAdditionalArgs = ""
        saveMessage = "Scrcpy settings reset to defaults."
    }

    var scrcpyCommandPreview: String {
        let command = scrcpyLaunchConfiguration()
        return ([command.executable] + command.arguments).joined(separator: " ")
    }

    func scrcpyLaunchConfiguration(
        deviceID: String? = nil,
        profile: ADBDeviceProfile? = nil,
        windowPosition: CGPoint? = nil,
        windowSize: CGSize? = nil,
        forceAlwaysOnTop: Bool = false,
        forceWindowBorderless: Bool = false
    ) -> (executable: String, arguments: [String]) {
        let executable = ToolPathResolver.resolveExecutable(ToolPathResolver.scrcpyPath(defaults: defaults))
            ?? ToolPathResolver.scrcpyPath(defaults: defaults)
        let arguments = buildScrcpyArguments(
            deviceID: deviceID,
            profile: profile?.hasCustomScrcpyOverrides == true ? profile : nil,
            windowPosition: windowPosition,
            windowSize: windowSize,
            forceAlwaysOnTop: forceAlwaysOnTop,
            forceWindowBorderless: forceWindowBorderless
        )
        return (executable, arguments)
    }

    private func buildScrcpyArguments(
        deviceID: String? = nil,
        profile: ADBDeviceProfile? = nil,
        windowPosition: CGPoint? = nil,
        windowSize: CGSize? = nil,
        forceAlwaysOnTop: Bool = false,
        forceWindowBorderless: Bool = false
    ) -> [String] {
        var arguments: [String] = []

        if let deviceID {
            appendArgument("--serial", value: deviceID, to: &arguments)
        }

        let alwaysOnTop = resolvedScrcpyBool(deviceValue: profile?.scrcpyAlwaysOnTop, fallback: scrcpyAlwaysOnTop)
        let fullscreen = resolvedScrcpyBool(deviceValue: profile?.scrcpyFullscreen, fallback: scrcpyFullscreen)
        let stayAwake = resolvedScrcpyBool(deviceValue: profile?.scrcpyStayAwake, fallback: scrcpyStayAwake)
        let turnScreenOff = resolvedScrcpyBool(deviceValue: profile?.scrcpyTurnScreenOff, fallback: scrcpyTurnScreenOff)
        let configuredMaxSize = resolvedScrcpyString(deviceValue: profile?.scrcpyMaxSize, fallback: scrcpyMaxSize)
        let runtimeMaxSize = windowSize.map { size in
            String(max(1, Int(max(size.width, size.height).rounded())))
        } ?? configuredMaxSize
        let maxFPS = resolvedScrcpyString(deviceValue: profile?.scrcpyMaxFPS, fallback: scrcpyMaxFPS)
        let videoBitRate = resolvedScrcpyString(deviceValue: profile?.scrcpyVideoBitRate, fallback: scrcpyVideoBitRate)
        let windowTitle = resolvedScrcpyString(deviceValue: profile?.scrcpyWindowTitle, fallback: scrcpyWindowTitle)

        if alwaysOnTop || forceAlwaysOnTop { arguments.append("--always-on-top") }
        if fullscreen { arguments.append("--fullscreen") }
        if scrcpyWindowBorderless || forceWindowBorderless { arguments.append("--window-borderless") }
        if stayAwake { arguments.append("--stay-awake") }
        if scrcpyDisableScreensaver { arguments.append("--disable-screensaver") }
        if turnScreenOff { arguments.append("--turn-screen-off") }
        if scrcpyShowTouches { arguments.append("--show-touches") }
        if scrcpyNoControl { arguments.append("--no-control") }
        if scrcpyNoAudio { arguments.append("--no-audio") }
        if scrcpyPreferText { arguments.append("--prefer-text") }
        if scrcpyNoClipboardAutosync { arguments.append("--no-clipboard-autosync") }

        appendArgumentPair("-m", value: runtimeMaxSize, to: &arguments)
        appendArgument("--max-fps", value: maxFPS, to: &arguments)
        appendArgument("--video-bit-rate", value: videoBitRate, to: &arguments, skipping: "8M")
        appendArgument("--audio-bit-rate", value: scrcpyAudioBitRate, to: &arguments, skipping: "128K")

        if scrcpyVideoCodec != .h264 { arguments.append("--video-codec=\(scrcpyVideoCodec.rawValue)") }
        if scrcpyAudioCodec != .opus { arguments.append("--audio-codec=\(scrcpyAudioCodec.rawValue)") }
        if scrcpyAudioSource != .output { arguments.append("--audio-source=\(scrcpyAudioSource.rawValue)") }
        if scrcpyKeyboardMode != .sdk { arguments.append("--keyboard=\(scrcpyKeyboardMode.rawValue)") }
        if scrcpyMouseMode != .sdk { arguments.append("--mouse=\(scrcpyMouseMode.rawValue)") }
        if scrcpyGamepadMode != .disabled { arguments.append("--gamepad=\(scrcpyGamepadMode.rawValue)") }

        appendArgument("--window-title", value: windowTitle, to: &arguments)
        appendArgument("--record", value: scrcpyRecordPath, to: &arguments)
        appendArgument("--render-driver", value: scrcpyRenderDriver, to: &arguments)
        appendArgument("--tunnel-host", value: scrcpyTunnelHost, to: &arguments)
        appendArgument("--tunnel-port", value: scrcpyTunnelPort, to: &arguments)
        appendArgument("--shortcut-mod", value: scrcpyShortcutMod, to: &arguments, skipping: "lalt,lsuper")

        if let windowPosition {
            arguments.append("--window-x=\(Int(windowPosition.x.rounded()))")
            arguments.append("--window-y=\(Int(windowPosition.y.rounded()))")
        }

        if let windowSize {
            arguments.append("--window-width=\(Int(windowSize.width.rounded()))")
            arguments.append("--window-height=\(Int(windowSize.height.rounded()))")
        }

        arguments.append(contentsOf: splitArguments(scrcpyAdditionalArgs))
        return arguments
    }

    private func resolvedScrcpyString(deviceValue: String?, fallback: String) -> String {
        let trimmed = deviceValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func resolvedScrcpyBool(deviceValue: Bool?, fallback: Bool) -> Bool {
        (deviceValue == true) || fallback
    }

    private func splitArguments(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var arguments: [String] = []
        var current = ""
        var quote: Character?

        for character in trimmed {
            if character == "\"" || character == "'" {
                if quote == nil {
                    quote = character
                    continue
                } else if quote == character {
                    quote = nil
                    continue
                }
            }

            if character.isWhitespace && quote == nil {
                appendArgumentToken(current, to: &arguments)
                current = ""
            } else {
                current.append(character)
            }
        }

        appendArgumentToken(current, to: &arguments)
        return arguments
    }

    private func appendArgumentToken(_ token: String, to arguments: inout [String]) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        arguments.append(trimmed)
    }

    private func appendArgument(_ flag: String, value: String, to arguments: inout [String], skipping defaultValue: String? = nil) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let defaultValue, trimmed == defaultValue { return }
        arguments.append("\(flag)=\(trimmed)")
    }

    private func appendArgumentPair(_ flag: String, value: String, to arguments: inout [String], skipping defaultValue: String? = nil) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let defaultValue, trimmed == defaultValue { return }
        arguments.append(flag)
        arguments.append(trimmed)
    }

    func resetADBToolPaths() {
        resetADBPath()
        resetScrcpyPath()
        saveMessage = "ADB and scrcpy paths reset to system defaults."
    }

    func validateOpenGLM() {
        openGLMValidation = .validating

        Task {
            do {
                let message = try await AIEndpointValidator.validateOpenGLM(
                    baseURL: openGLMServer,
                    apiKey: openGLMKey,
                    model: openGLMModel
                )
                openGLMValidation = .success(message)
            } catch {
                openGLMValidation = .failure(error.localizedDescription)
            }
        }
    }

    func fetchOpenGLMModels() {
        openGLMFetchState = .validating

        Task {
            do {
                let models = DeprecatedModelCatalog.sanitized(
                    try await AIEndpointValidator.fetchModels(
                        baseURL: openGLMServer,
                        apiKey: openGLMKey
                    )
                )

                availableOpenGLMModels = models
                if openGLMModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    openGLMModel = models.first ?? resolvedModelProviderType.defaultModelName
                }

                if models.isEmpty {
                    openGLMFetchState = .success("No models were listed, but the server is responding.")
                } else {
                    openGLMFetchState = .success("Loaded \(models.count) models.")
                }
            } catch {
                openGLMFetchState = .failure(error.localizedDescription)
            }
        }
    }

    func validateLanguageEnhancer() {
        languageEnhancerValidation = .validating

        Task {
            do {
                let message = try await AIEndpointValidator.validateLanguageEnhancer(
                    baseURL: languageEnhancerServer,
                    apiKey: languageEnhancerKey,
                    model: languageEnhancerModel
                )
                languageEnhancerValidation = .success(message)
            } catch {
                languageEnhancerValidation = .failure(error.localizedDescription)
            }
        }
    }

    func fetchLanguageEnhancerModels() {
        languageEnhancerFetchState = .validating

        Task {
            do {
                let models = DeprecatedModelCatalog.sanitized(
                    try await AIEndpointValidator.fetchModels(
                        baseURL: languageEnhancerServer,
                        apiKey: languageEnhancerKey
                    )
                )

                availableLanguageEnhancerModels = models
                if languageEnhancerModel.isEmpty {
                    languageEnhancerModel = models.first ?? ""
                }

                if models.isEmpty {
                    languageEnhancerFetchState = .success("No models were listed, but the server is responding.")
                } else {
                    languageEnhancerFetchState = .success("Loaded \(models.count) models.")
                }
            } catch {
                languageEnhancerFetchState = .failure(error.localizedDescription)
            }
        }
    }
}
