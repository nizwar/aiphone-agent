import Foundation
import NaturalLanguage
import SwiftUI

struct DeviceAgentRunSnapshot: Identifiable, Equatable {
    let deviceID: String
    let personaEmoji: String
    var statusMessage: String
    var logText: String
    var lastCommand: String
    var lastExitCode: Int32?
    var lastTask: String
    var isRunning: Bool

    var id: String { deviceID }
    var tabTitle: String { "[\(deviceID) \(personaEmoji)]" }
}

@MainActor
final class AgentRunStore: ObservableObject {
    @Published private(set) var isRunning = false
    @Published var statusMessage: String = "Ready to run Open-AutoGLM."
    @Published var logText: String = ""
    @Published var lastCommand: String = ""
    @Published var lastExitCode: Int32?
    @Published var lastTask: String = ""
    @Published private(set) var deviceRuns: [DeviceAgentRunSnapshot] = []
    @Published var selectedDeviceRunID: String? {
        didSet { syncSelectedRunProjection() }
    }

    private var runTask: Task<Void, Never>?
    private var didRequestCancel = false

    var selectedRun: DeviceAgentRunSnapshot? {
        if let selectedDeviceRunID,
           let run = deviceRuns.first(where: { $0.deviceID == selectedDeviceRunID }) {
            return run
        }
        return deviceRuns.first
    }

    @discardableResult
    func run(task: String, deviceID: String?, settings: AISettingsStore, devicePersona: String = "") -> Bool {
        guard let deviceID, !deviceID.isEmpty else {
            statusMessage = "No ready devices found. Connect a device and refresh the list first."
            return false
        }

        var profile = ADBDeviceProfile()
        profile.persona = devicePersona
        return run(task: task, deviceIDs: [deviceID], settings: settings, deviceProfiles: [deviceID: profile])
    }

    @discardableResult
    func run(task: String, deviceIDs: [String], settings: AISettingsStore, deviceProfiles: [String: ADBDeviceProfile]) -> Bool {
        let trimmedTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTask.isEmpty else {
            statusMessage = "Enter a task before sending."
            return false
        }

        let uniqueDeviceIDs = Array(NSOrderedSet(array: deviceIDs))
            .compactMap { $0 as? String }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        guard !uniqueDeviceIDs.isEmpty else {
            statusMessage = "No ready devices found. Connect a device and refresh the list first."
            return false
        }

        guard !isRunning else {
            statusMessage = "An AI task is already running."
            return false
        }

        let configurations = Dictionary(uniqueKeysWithValues: uniqueDeviceIDs.map { deviceID in
            let profile = deviceProfiles[deviceID] ?? ADBDeviceProfile()
            return (deviceID, NativeAgentConfiguration(settings: settings, profile: profile))
        })

        guard configurations.values.allSatisfy({ !$0.baseURL.isEmpty }) else {
            statusMessage = "OpenGLM server URL is empty. Update it in Settings → AI Models."
            return false
        }

        deviceRuns = uniqueDeviceIDs.map { deviceID in
            let profile = deviceProfiles[deviceID] ?? ADBDeviceProfile()
            let configuration = configurations[deviceID]!
            return DeviceAgentRunSnapshot(
                deviceID: deviceID,
                personaEmoji: profile.personaEmoji,
                statusMessage: "Queued…",
                logText: "",
                lastCommand: "Native Swift agent · model=\(configuration.modelName) · device=\(deviceID)",
                lastExitCode: nil,
                lastTask: trimmedTask,
                isRunning: true
            )
        }

        selectedDeviceRunID = uniqueDeviceIDs.first
        didRequestCancel = false
        isRunning = true
        statusMessage = uniqueDeviceIDs.count == 1
            ? "Running natively on \(uniqueDeviceIDs[0])…"
            : "Running across \(uniqueDeviceIDs.count) devices…"
        syncSelectedRunProjection()

        runTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            await withTaskGroup(of: Void.self) { group in
                for deviceID in uniqueDeviceIDs {
                    guard let configuration = configurations[deviceID] else { continue }

                    group.addTask { [weak self] in
                        guard let self else { return }

                        await MainActor.run {
                            self.appendLog("Starting native Open-AutoGLM agent\n", for: deviceID)
                            self.appendLog("Device: \(deviceID)\n", for: deviceID)
                            self.appendLog("Device persona: \(configuration.devicePersona.isEmpty ? "None" : configuration.devicePersona)\n", for: deviceID)
                            self.appendLog("Preferred apps: \(configuration.preferredApps.isEmpty ? "None" : configuration.preferredApps)\n", for: deviceID)
                            self.appendLog("Device notes: \(configuration.deviceNotes.isEmpty ? "None" : configuration.deviceNotes)\n", for: deviceID)
                        }

                        let agent = NativePhoneAgent(
                            configuration: configuration,
                            provider: ADBProvider.shared,
                            logger: { text in
                                await MainActor.run {
                                    self.appendLog(text, for: deviceID)
                                }
                            },
                            statusHandler: { text in
                                await MainActor.run {
                                    self.updateStatus(text, for: deviceID)
                                }
                            },
                            cancellationChecker: {
                                await MainActor.run {
                                    self.didRequestCancel
                                }
                            }
                        )

                        do {
                            let finalMessage = try await agent.run(task: trimmedTask, deviceID: deviceID)
                            await MainActor.run {
                                self.finishRun(for: deviceID, success: true, message: finalMessage)
                            }
                        } catch is CancellationError {
                            await MainActor.run {
                                self.finishCancelled(for: deviceID)
                            }
                        } catch {
                            await MainActor.run {
                                self.finishRun(for: deviceID, success: false, message: error.localizedDescription)
                            }
                        }
                    }
                }

                await group.waitForAll()
            }

            await MainActor.run {
                self.runTask = nil
                self.didRequestCancel = false
                self.isRunning = self.deviceRuns.contains(where: { $0.isRunning })
                self.refreshSummaryState()
            }
        }

        return true
    }

    func cancel() {
        guard isRunning else { return }
        didRequestCancel = true
        statusMessage = deviceRuns.count > 1 ? "Cancelling all device runs..." : "Cancelling..."

        for run in deviceRuns where run.isRunning {
            appendLog("\nCancel requested by user.\n", for: run.deviceID)
        }

        runTask?.cancel()
    }

    func clearLog() {
        guard !isRunning else { return }
        deviceRuns = []
        selectedDeviceRunID = nil
        logText = ""
        lastCommand = ""
        lastExitCode = nil
        lastTask = ""
        statusMessage = "Ready to run Open-AutoGLM."
    }

    func presentIssue(_ message: String) {
        statusMessage = message
        if let selectedDeviceRunID, deviceRuns.contains(where: { $0.deviceID == selectedDeviceRunID }) {
            appendLog("Warning: \(message)\n", for: selectedDeviceRunID)
        } else {
            logText += "Warning: \(message)\n"
        }
    }

    private func finishRun(for deviceID: String, success: Bool, message: String) {
        updateRun(for: deviceID) { run in
            run.isRunning = false
            run.lastExitCode = success ? 0 : 1
            run.statusMessage = message
            run.logText += success ? "\nSuccess: \(message)\n" : "\nError: \(message)\n"
            if run.logText.count > 120_000 {
                run.logText.removeFirst(run.logText.count - 100_000)
            }
        }
        refreshSummaryState()
    }

    private func finishCancelled(for deviceID: String) {
        updateRun(for: deviceID) { run in
            run.isRunning = false
            run.lastExitCode = 130
            run.statusMessage = "Run cancelled."
            run.logText += "\nRun cancelled.\n"
            if run.logText.count > 120_000 {
                run.logText.removeFirst(run.logText.count - 100_000)
            }
        }
        refreshSummaryState()
    }

    private func appendLog(_ text: String, for deviceID: String) {
        updateRun(for: deviceID) { run in
            run.logText += text
            if run.logText.count > 120_000 {
                run.logText.removeFirst(run.logText.count - 100_000)
            }
        }
    }

    private func updateStatus(_ text: String, for deviceID: String) {
        updateRun(for: deviceID) { run in
            run.statusMessage = text
        }
        refreshSummaryState()
    }

    private func updateRun(for deviceID: String, mutate: (inout DeviceAgentRunSnapshot) -> Void) {
        guard let index = deviceRuns.firstIndex(where: { $0.deviceID == deviceID }) else { return }
        mutate(&deviceRuns[index])
        syncSelectedRunProjection()
    }

    private func refreshSummaryState() {
        isRunning = deviceRuns.contains(where: { $0.isRunning })

        let runningCount = deviceRuns.filter { $0.isRunning }.count
        let failedCount = deviceRuns.filter { ($0.lastExitCode ?? 0) != 0 && $0.lastExitCode != nil }.count

        if runningCount > 1 {
            statusMessage = "Running across \(runningCount) devices…"
        } else if let activeRun = deviceRuns.first(where: { $0.isRunning }) {
            statusMessage = "\(activeRun.deviceID): \(activeRun.statusMessage)"
        } else if !deviceRuns.isEmpty {
            if failedCount > 0 {
                statusMessage = failedCount == deviceRuns.count
                    ? "All device runs ended with issues."
                    : "Completed with issues on \(failedCount) device(s)."
            } else {
                statusMessage = deviceRuns.count == 1
                    ? (deviceRuns.first?.statusMessage ?? "Task completed successfully.")
                    : "Completed on \(deviceRuns.count) devices."
            }
        } else {
            statusMessage = "Ready to run Open-AutoGLM."
        }

        syncSelectedRunProjection()
    }

    private func syncSelectedRunProjection() {
        if let selectedDeviceRunID, !deviceRuns.contains(where: { $0.deviceID == selectedDeviceRunID }) {
            self.selectedDeviceRunID = deviceRuns.first?.deviceID
            return
        }

        if selectedDeviceRunID == nil, !deviceRuns.isEmpty {
            self.selectedDeviceRunID = deviceRuns.first?.deviceID
            return
        }

        guard let selectedRun else {
            logText = ""
            lastCommand = ""
            lastExitCode = nil
            lastTask = ""
            return
        }

        logText = selectedRun.logText
        lastCommand = selectedRun.lastCommand
        lastExitCode = selectedRun.lastExitCode
        lastTask = selectedRun.lastTask
    }
}

private struct NativeAgentConfiguration: Sendable {
    let baseURL: String
    let apiKey: String
    let modelName: String
    let maxSteps: Int
    let maxTokens: Int
    let temperature: Double
    let topP: Double
    let frequencyPenalty: Double
    let languageCode: String
    let devicePersona: String
    let preferredApps: String
    let deviceNotes: String
    let languageEnhancerBaseURL: String
    let languageEnhancerAPIKey: String
    let languageEnhancerModel: String

    var effectiveDevicePersona: String {
        let trimmed = devicePersona.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? "Careful, context-aware, detail-oriented assistant who matches the user's language naturally and double-checks tone before replying."
            : trimmed
    }

    var effectivePreferredApps: String {
        let trimmed = preferredApps.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "No preferred apps were specified for this device." : trimmed
    }

    var effectiveDeviceNotes: String {
        let trimmed = deviceNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "No extra device notes or safety rules were provided for this device." : trimmed
    }

    var resolvedLanguageEnhancerBaseURL: String {
        languageEnhancerBaseURL.isEmpty ? baseURL : languageEnhancerBaseURL
    }

    var resolvedLanguageEnhancerAPIKey: String {
        let trimmed = languageEnhancerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty || trimmed == "EMPTY") ? apiKey : trimmed
    }

    var resolvedLanguageEnhancerModel: String {
        languageEnhancerModel.isEmpty ? modelName : languageEnhancerModel
    }

    var hasLanguageEnhancer: Bool {
        !resolvedLanguageEnhancerBaseURL.isEmpty && !resolvedLanguageEnhancerModel.isEmpty
    }

    var languageEnhancerRequestTargets: [(label: String, baseURL: String, apiKey: String, model: String)] {
        var targets: [(label: String, baseURL: String, apiKey: String, model: String)] = []

        func appendTarget(label: String, baseURL: String, apiKey: String, model: String) {
            let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedBaseURL.isEmpty, !trimmedModel.isEmpty else { return }
            guard !targets.contains(where: { $0.baseURL == trimmedBaseURL && $0.model == trimmedModel && $0.apiKey == apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }) else {
                return
            }

            targets.append((
                label: label,
                baseURL: trimmedBaseURL,
                apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                model: trimmedModel
            ))
        }

        appendTarget(
            label: "Language Enhancer",
            baseURL: resolvedLanguageEnhancerBaseURL,
            apiKey: resolvedLanguageEnhancerAPIKey,
            model: resolvedLanguageEnhancerModel
        )
        appendTarget(
            label: "Primary OpenGLM fallback",
            baseURL: baseURL,
            apiKey: apiKey,
            model: modelName
        )

        return targets
    }

    @MainActor
    init(settings: AISettingsStore, devicePersona: String = "", preferredApps: String = "", deviceNotes: String = "") {
        self.baseURL = settings.openGLMServer.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = settings.openGLMKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = trimmedKey.isEmpty ? "EMPTY" : trimmedKey
        self.modelName = settings.openGLMModel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.maxSteps = 100
        self.maxTokens = 3000
        self.temperature = 0.0
        self.topP = 0.85
        self.frequencyPenalty = 0.2
        self.languageCode = "en"
        self.devicePersona = devicePersona.trimmingCharacters(in: .whitespacesAndNewlines)
        self.preferredApps = preferredApps.trimmingCharacters(in: .whitespacesAndNewlines)
        self.deviceNotes = deviceNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        self.languageEnhancerBaseURL = settings.languageEnhancerServer.trimmingCharacters(in: .whitespacesAndNewlines)
        let enhancerKey = settings.languageEnhancerKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.languageEnhancerAPIKey = enhancerKey.isEmpty ? "EMPTY" : enhancerKey
        self.languageEnhancerModel = settings.languageEnhancerModel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    init(settings: AISettingsStore, profile: ADBDeviceProfile) {
        self.init(
            settings: settings,
            devicePersona: profile.persona,
            preferredApps: profile.preferredApps,
            deviceNotes: profile.notes
        )
    }
}

private struct NativePhoneAgent: Sendable {
    let configuration: NativeAgentConfiguration
    let provider: any ADBProviding
    let logger: @Sendable (String) async -> Void
    let statusHandler: @Sendable (String) async -> Void
    let cancellationChecker: @Sendable () async -> Bool

    func run(task: String, deviceID: String?) async throws -> String {
        let modelClient = NativeOpenAIModelClient(configuration: configuration)
        var preparedTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
        if preparedTask.isEmpty {
            preparedTask = task
        }

        var context: [NativeAgentMessage] = [
            .system(
                text: NativeAgentPromptBuilder.systemPrompt(
                    userTask: preparedTask,
                    devicePersona: configuration.effectiveDevicePersona,
                    preferredApps: configuration.effectivePreferredApps,
                    deviceNotes: configuration.effectiveDeviceNotes
                )
            )
        ]

        for step in 1...configuration.maxSteps {
            try Task.checkCancellation()
            if await cancellationChecker() {
                throw CancellationError()
            }

            if step == 1 {
                await statusHandler("Starting the agent…")
            } else {
                await statusHandler("Capturing screen... step \(step)/\(configuration.maxSteps)")
            }

            let screenshot = try provider.getScreenshot(deviceID: deviceID)
            let currentApp = (try? provider.getCurrentApp(deviceID: deviceID)) ?? "Unknown"
            let runtime = ADBDeviceRuntimeStatus(
                batteryLevel: nil,
                wifiStatus: nil,
                dataStatus: nil,
                currentApp: currentApp
            )
            let screenInfo = NativeAgentPromptBuilder.screenInfo(currentApp: currentApp)

            let effectiveTask: String
            if step == 1 {
                effectiveTask = await resolvedUserTask(
                    from: preparedTask,
                    runtime: runtime,
                    screenInfo: screenInfo
                )
                preparedTask = effectiveTask
            } else {
                effectiveTask = preparedTask
            }

            let textContent: String
            if step == 1 {
                textContent = """
                User request (keep the same language as this request; never switch to Chinese unless the request itself is Chinese):
                \(effectiveTask)

                ** Device Preferences **

                Preferred apps: \(configuration.effectivePreferredApps)
                Device notes: \(configuration.effectiveDeviceNotes)

                ** Screen Info **

                \(screenInfo)
                """
            } else {
                textContent = "** Screen Info **\n\n\(screenInfo)"
            }

            context.append(
                .user(
                    text: textContent,
                    imageBase64: screenshot.base64Data,
                    imageMimeType: screenshot.imageMimeType
                )
            )

            await logger("\n\(String(repeating: "=", count: 56))\n")
            await logger("Step \(step)/\(configuration.maxSteps)\n")
            await logger("Current app: \(runtime.currentApp ?? "Unknown")\n")
            await logger("Thinking:\n")

            let response = try await modelClient.request(messages: context) { chunk in
                await logger(chunk)
            }

            await logger("\n")

            let action = NativeActionParser.parse(response.action)
            await logger("Action: \(action.logDescription)\n")

            if let lastIndex = context.indices.last {
                context[lastIndex] = context[lastIndex].removingImage()
            }
            context.append(.assistant(text: "<think>\(response.thinking)</think><answer>\(response.action)</answer>"))

            await statusHandler("Executing \(action.shortLabel)...")
            let result = try await execute(
                action: action,
                screenshot: screenshot,
                deviceID: deviceID,
                task: task,
                runtime: runtime,
                screenInfo: screenInfo,
                modelThinking: response.thinking
            )

            if let message = result.message, !message.isEmpty {
                await logger("Info: \(message)\n")
                context.append(.user(text: "** Last action result **\n\n\(message)", imageBase64: nil))
            }

            if result.finished {
                return result.message ?? "Task completed successfully."
            }
        }

        throw NativeAgentError.maxStepsReached
    }

    private func execute(
        action: NativeAgentAction,
        screenshot: ADBScreenshot,
        deviceID: String?,
        task: String,
        runtime: ADBDeviceRuntimeStatus,
        screenInfo: String,
        modelThinking: String
    ) async throws -> NativeActionResult {
        switch action {
        case let .finish(message):
            let finalMessage = try await resolvedFinishMessage(
                from: message,
                task: task,
                runtime: runtime,
                screenInfo: screenInfo,
                modelThinking: modelThinking
            )
            return NativeActionResult(finished: true, message: finalMessage)

        case let .listApp(query):
            return NativeActionResult(
                finished: false,
                message: installedAppsSummary(query: query, deviceID: deviceID)
            )

        case let .launch(app):
            let launchResult = try provider.launchApp(app, deviceID: deviceID, delay: nil)
            return NativeActionResult(finished: !launchResult.succeeded, message: launchResult.message)

        case let .tap(point, message):
            let resolved = resolve(point: point, screenshot: screenshot)
            try provider.tap(x: resolved.x, y: resolved.y, deviceID: deviceID, delay: nil)
            return NativeActionResult(finished: false, message: message)

        case let .doubleTap(point):
            let resolved = resolve(point: point, screenshot: screenshot)
            try provider.doubleTap(x: resolved.x, y: resolved.y, deviceID: deviceID, delay: nil)
            return NativeActionResult(finished: false, message: nil)

        case let .longPress(point):
            let resolved = resolve(point: point, screenshot: screenshot)
            try provider.longPress(x: resolved.x, y: resolved.y, durationMS: 3000, deviceID: deviceID, delay: nil)
            return NativeActionResult(finished: false, message: nil)

        case let .swipe(start, end):
            let resolvedStart = resolve(point: start, screenshot: screenshot)
            let resolvedEnd = resolve(point: end, screenshot: screenshot)
            try provider.swipe(
                startX: resolvedStart.x,
                startY: resolvedStart.y,
                endX: resolvedEnd.x,
                endY: resolvedEnd.y,
                durationMS: nil,
                deviceID: deviceID,
                delay: nil
            )
            return NativeActionResult(finished: false, message: nil)

        case let .type(text, enhance):
            let finalText = try await resolvedTextInput(
                from: text,
                shouldEnhance: enhance,
                task: task,
                runtime: runtime,
                screenInfo: screenInfo,
                modelThinking: modelThinking
            )
            let trimmedText = finalText.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !trimmedText.isEmpty else {
                return NativeActionResult(finished: false, message: "Skipped typing because no text input was generated.")
            }

            try provider.clearText(deviceID: deviceID)
            try await pause(seconds: ADBTiming.textClearDelay)
            try provider.typeText(trimmedText, deviceID: deviceID)
            try await pause(seconds: ADBTiming.textInputDelay)
            return NativeActionResult(finished: false, message: "Typed text input: \(textPreview(trimmedText))")

        case .back:
            try provider.back(deviceID: deviceID, delay: nil)
            return NativeActionResult(finished: false, message: nil)

        case .home:
            try provider.home(deviceID: deviceID, delay: nil)
            return NativeActionResult(finished: false, message: nil)

        case let .wait(seconds):
            try await pause(seconds: max(0.2, min(seconds, 10)))
            return NativeActionResult(finished: false, message: "Waited for \(String(format: "%.1f", seconds))s")

        case let .takeOver(message):
            return NativeActionResult(finished: true, message: message ?? "Manual takeover requested.")

        case let .unknown(name, raw):
            let fallbackSummary = try await resolvedUnsupportedActionMessage(
                name: name,
                raw: raw,
                task: task,
                runtime: runtime,
                screenInfo: screenInfo,
                modelThinking: modelThinking
            )
            return NativeActionResult(finished: true, message: fallbackSummary)
        }
    }

    private func resolve(point: NativeRelativePoint, screenshot: ADBScreenshot) -> (x: Int, y: Int) {
        let x = Int((Double(point.x) / 1000.0) * Double(screenshot.width))
        let y = Int((Double(point.y) / 1000.0) * Double(screenshot.height))
        return (max(0, x), max(0, y))
    }

    private func installedAppsSummary(query: String?, deviceID: String?) -> String {
        let installedPackages = provider.listInstalledPackages(deviceID: deviceID)
        guard !installedPackages.isEmpty else {
            return "ADB could not list installed apps on this device."
        }

        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedQuery = normalizedLookupKey(trimmedQuery)

        let matches: [String]
        if normalizedQuery.isEmpty {
            matches = installedPackages
        } else {
            matches = installedPackages.filter { package in
                let packageKey = normalizedLookupKey(package)
                let appNameKey = normalizedLookupKey(ADBAppCatalog.appName(for: package) ?? "")
                return packageKey.contains(normalizedQuery) || appNameKey.contains(normalizedQuery)
            }
        }

        if !normalizedQuery.isEmpty && matches.isEmpty {
            return "No installed app matched \(trimmedQuery.debugDescription) in the ADB package list (\(installedPackages.count) packages scanned). If still needed, use Launch(app=\"\(trimmedQuery)\") to open Google Play."
        }

        let preview = matches
            .map { package in
                if let appName = ADBAppCatalog.appName(for: package) {
                    return "\(appName) (\(package))"
                }
                return package
            }
            .sorted()
            .prefix(15)

        let header: String
        if normalizedQuery.isEmpty {
            header = "Installed apps on the device (showing \(min(15, matches.count)) of \(matches.count)):"
        } else {
            header = "Installed apps matching \(trimmedQuery.debugDescription) (showing \(min(15, matches.count)) of \(matches.count)):"
        }

        let lines = preview.map { "- \($0)" }.joined(separator: "\n")
        return "\(header)\n\(lines)\nUse Launch(app=\"exact app name or package\") for the one you want."
    }

    private func normalizedLookupKey(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "", options: .regularExpression)
    }

    private func resolvedUserTask(
        from rawTask: String,
        runtime: ADBDeviceRuntimeStatus,
        screenInfo: String
    ) async -> String {
        let trimmedTask = rawTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTask.isEmpty, configuration.hasLanguageEnhancer else { return rawTask }

        let enhancer = NativeLanguageEnhancerClient(configuration: configuration)

        do {
            await logger("Invoking language enhancer to refine the user task with persona context.\n")
            let rewrittenTask = try await enhancer.enhanceUserTask(
                task: trimmedTask,
                currentApp: runtime.currentApp,
                screenInfo: screenInfo,
                devicePersona: configuration.effectiveDevicePersona,
                preferredApps: configuration.effectivePreferredApps,
                deviceNotes: configuration.effectiveDeviceNotes
            )
            let finalTask = rewrittenTask.trimmingCharacters(in: .whitespacesAndNewlines)

            if !finalTask.isEmpty {
                if finalTask != trimmedTask {
                    await logger("Language enhancer rewrote the task using persona context.\n")
                } else {
                    await logger("Language enhancer kept the original task.\n")
                }
                return finalTask
            }
        } catch {
            await logger("Language enhancer task fallback: \(error.localizedDescription)\n")
        }

        return trimmedTask
    }

    private func resolvedFinishMessage(
        from draftMessage: String?,
        task: String,
        runtime: ADBDeviceRuntimeStatus,
        screenInfo: String,
        modelThinking: String
    ) async throws -> String {
        let baseMessage = draftMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? draftMessage!.trimmingCharacters(in: .whitespacesAndNewlines)
            : "Task completed successfully."
        guard configuration.hasLanguageEnhancer else { return baseMessage }

        let enhancer = NativeLanguageEnhancerClient(configuration: configuration)

        do {
            await logger("Invoking language enhancer to polish the final answer.\n")
            let summary = try await enhancer.refineDirectAnswer(
                task: task,
                draftAnswer: baseMessage,
                currentApp: runtime.currentApp,
                screenInfo: screenInfo,
                devicePersona: configuration.effectiveDevicePersona,
                preferredApps: configuration.effectivePreferredApps,
                deviceNotes: configuration.effectiveDeviceNotes,
                modelThinking: modelThinking,
                format: "text"
            )
            let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? baseMessage : trimmed
        } catch {
            await logger("Language enhancer finish fallback: \(error.localizedDescription)\n")
            return baseMessage
        }
    }

    private func resolvedUnsupportedActionMessage(
        name: String,
        raw: String,
        task: String,
        runtime: ADBDeviceRuntimeStatus,
        screenInfo: String,
        modelThinking: String
    ) async throws -> String {
        let baseMessage = "The model returned an unsupported action `\(name)`. Raw output: \(raw)"
        guard configuration.hasLanguageEnhancer else { return baseMessage }

        let enhancer = NativeLanguageEnhancerClient(configuration: configuration)

        do {
            await logger("Invoking language enhancer to summarize unsupported action output.\n")
            let summary = try await enhancer.refineDirectAnswer(
                task: task,
                draftAnswer: baseMessage,
                currentApp: runtime.currentApp,
                screenInfo: screenInfo,
                devicePersona: configuration.effectiveDevicePersona,
                preferredApps: configuration.effectivePreferredApps,
                deviceNotes: configuration.effectiveDeviceNotes,
                modelThinking: modelThinking,
                format: "md"
            )
            let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? baseMessage : trimmed
        } catch {
            await logger("Language enhancer unsupported-action fallback: \(error.localizedDescription)\n")
            return baseMessage
        }
    }

    private func resolvedTextInput(
        from rawText: String,
        shouldEnhance: Bool,
        task: String,
        runtime: ADBDeviceRuntimeStatus,
        screenInfo: String,
        modelThinking: String
    ) async throws -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard configuration.hasLanguageEnhancer else { return trimmed }

        let enhancer = NativeLanguageEnhancerClient(configuration: configuration)

        do {
            let reason = shouldEnhance
                ? "model requested refinement"
                : "verifying text stays in the user's language"
            await logger("Invoking language enhancer model: \(configuration.resolvedLanguageEnhancerModel) @ \(configuration.resolvedLanguageEnhancerBaseURL) (\(reason))\n")
            let generatedText = try await enhancer.generateTextInput(
                task: task,
                requestedText: trimmed,
                currentApp: runtime.currentApp,
                screenInfo: screenInfo,
                devicePersona: configuration.effectiveDevicePersona,
                preferredApps: configuration.effectivePreferredApps,
                deviceNotes: configuration.effectiveDeviceNotes,
                modelThinking: modelThinking
            )
            let finalText = generatedText.trimmingCharacters(in: .whitespacesAndNewlines)

            if !finalText.isEmpty {
                if finalText != trimmed {
                    await logger("Language enhancer generated text: \(textPreview(finalText))\n")
                } else {
                    await logger("Language enhancer kept the original text input.\n")
                }
                return finalText
            }
        } catch {
            await logger("Language enhancer fallback: \(error.localizedDescription)\n")
        }

        return trimmed
    }

    private func textPreview(_ text: String, limit: Int = 120) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
        if flattened.count > limit {
            return "\"\(String(flattened.prefix(limit)))…\""
        }
        return "\"\(flattened)\""
    }

    private func pause(seconds: TimeInterval) async throws {
        let clampedSeconds = max(0, seconds)
        guard clampedSeconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(clampedSeconds * 1_000_000_000))
    }
}

private struct NativeActionResult {
    let finished: Bool
    let message: String?
}

private struct NativeOpenAIModelClient: Sendable {
    let configuration: NativeAgentConfiguration

    func request(
        messages: [NativeAgentMessage],
        onThinkingChunk: @escaping @Sendable (String) async -> Void
    ) async throws -> NativeModelResponse {
        let endpoints = candidateURLs(from: configuration.baseURL, path: "chat/completions")
        guard !endpoints.isEmpty else {
            throw NativeAgentError.invalidConfiguration("Please enter a valid OpenGLM server URL in Settings → AI Models.")
        }

        var lastError: Error = NativeAgentError.invalidConfiguration("No usable OpenAI-compatible endpoint was found.")

        for endpoint in endpoints {
            do {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.timeoutInterval = 120
                request.httpBody = try requestBody(for: messages)
                applyHeaders(to: &request, apiKey: configuration.apiKey)

                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NativeAgentError.server("The model server returned an invalid response.")
                }

                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    throw NativeAgentError.server("Authentication failed. Check the API key in Settings → AI Models.")
                }

                guard (200...299).contains(httpResponse.statusCode) else {
                    let errorData = try await collect(bytes: bytes)
                    let errorMessage = Self.extractErrorMessage(from: errorData) ?? "Server returned HTTP \(httpResponse.statusCode)."
                    throw NativeAgentError.server(errorMessage)
                }

                return try await parseStreamingResponse(from: bytes, onThinkingChunk: onThinkingChunk)
            } catch {
                lastError = error
            }
        }

        throw lastError
    }

    private func requestBody(for messages: [NativeAgentMessage]) throws -> Data {
        let payload: [String: Any] = [
            "model": configuration.modelName,
            "messages": messages.map(\.jsonValue),
            "max_tokens": configuration.maxTokens,
            "temperature": configuration.temperature,
            "top_p": configuration.topP,
            "frequency_penalty": configuration.frequencyPenalty,
            "stream": true
        ]

        return try JSONSerialization.data(withJSONObject: payload, options: [])
    }

    private func parseStreamingResponse(
        from bytes: URLSession.AsyncBytes,
        onThinkingChunk: @escaping @Sendable (String) async -> Void
    ) async throws -> NativeModelResponse {
        var rawContent = ""
        var buffer = ""
        var enteredActionPhase = false
        let decoder = JSONDecoder()

        for try await line in bytes.lines {
            try Task.checkCancellation()

            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty else { continue }
            if payload == "[DONE]" { break }

            guard let data = payload.data(using: .utf8),
                  let chunk = try? decoder.decode(NativeStreamingChunk.self, from: data),
                  let content = chunk.choices.first?.delta.content,
                  !content.isEmpty else {
                continue
            }

            rawContent += content

            if enteredActionPhase {
                continue
            }

            buffer += content

            if let markerRange = Self.firstActionMarkerRange(in: buffer) {
                let thinkingPart = String(buffer[..<markerRange.lowerBound])
                if !thinkingPart.isEmpty {
                    await onThinkingChunk(thinkingPart)
                }
                enteredActionPhase = true
                buffer = ""
                continue
            }

            if Self.endsWithPotentialActionPrefix(buffer) {
                continue
            }

            await onThinkingChunk(buffer)
            buffer = ""
        }

        if !buffer.isEmpty && !enteredActionPhase {
            await onThinkingChunk(buffer)
        }

        let parsed = NativeResponseParser.parse(content: rawContent)
        return NativeModelResponse(thinking: parsed.thinking, action: parsed.action, rawContent: rawContent)
    }

    private func collect(bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        return data
    }

    private func applyHeaders(to request: inout URLRequest, apiKey: String) {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if trimmedKey.isEmpty {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
        } else {
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        }
    }

    private func candidateURLs(from rawBaseURL: String, path: String) -> [URL] {
        let trimmed = rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let normalized = Self.normalizedBaseURL(from: trimmed)
        guard let baseURL = URL(string: normalized) else { return [] }

        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedPath = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var candidates: [URL] = []

        if normalizedPath == cleanPath || normalizedPath.hasSuffix("/\(cleanPath)") {
            candidates.append(baseURL)
        } else if normalizedPath == "chat", cleanPath == "chat/completions" {
            candidates.append(baseURL.appendingPathComponent("completions"))
        } else if normalizedPath == "v1" || normalizedPath.hasSuffix("/v1") {
            candidates.append(baseURL.appendingPathComponent(cleanPath))
        } else {
            candidates.append(baseURL.appendingPathComponent("v1").appendingPathComponent(cleanPath))
            candidates.append(baseURL.appendingPathComponent(cleanPath))
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0.absoluteString).inserted }
    }

    private static func normalizedBaseURL(from value: String) -> String {
        if value.hasPrefix("http://") || value.hasPrefix("https://") {
            return value
        }

        let isLocalHost = value.hasPrefix("localhost") || value.hasPrefix("127.")
        let looksLikeIPAddress = value.range(of: #"^\d{1,3}(\.\d{1,3}){3}(:\d+)?/?$"#, options: .regularExpression) != nil

        return (isLocalHost || looksLikeIPAddress ? "http://" : "https://") + value
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let errorObject = object["error"] as? [String: Any],
           let message = errorObject["message"] as? String {
            return message
        }

        if let message = object["message"] as? String {
            return message
        }

        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstActionMarkerRange(in text: String) -> Range<String.Index>? {
        let markers = ["finish(message=", "do(action="]
        for marker in markers {
            if let range = text.range(of: marker) {
                return range
            }
        }
        return nil
    }

    private static func endsWithPotentialActionPrefix(_ text: String) -> Bool {
        let markers = ["finish(message=", "do(action="]
        for marker in markers {
            for length in 1..<marker.count where text.hasSuffix(String(marker.prefix(length))) {
                return true
            }
        }
        return false
    }
}

private struct NativeLanguageEnhancerClient: Sendable {
    let configuration: NativeAgentConfiguration

    func enhanceUserTask(
        task: String,
        currentApp: String?,
        screenInfo: String,
        devicePersona: String,
        preferredApps: String = "",
        deviceNotes: String = ""
    ) async throws -> String {
        let personaText = normalizedPersonaText(from: devicePersona)
        let preferredAppsText = normalizedPreferredAppsText(from: preferredApps)
        let notesText = normalizedDeviceNotesText(from: deviceNotes)

        let systemPrompt = """
        You rewrite a user's phone-assistant request into a clearer, more explicit task instruction for another Android automation model.

        Hard rules:
        - Preserve the original intent exactly.
        - Keep the same language as the user unless the prompt explicitly asks for another language.
        - Make the task easier for a phone-control agent to understand and execute.
        - Use the device persona as required context to deepen tone/style checks without changing the user's goal.
        - Mention the visible app/context only when it helps clarify the action.
        - Return ONLY the rewritten task prompt.
        - No markdown, no bullets, no explanations, no labels.
        """

        let userPrompt = """
        USER PROMPT :
        \(task)

        CONTEXT :
        Current app: \(currentApp ?? "Unknown")
        Device persona: \(personaText)
        Preferred apps: \(preferredAppsText)
        Device notes: \(notesText)
        Screen context:
        \(screenInfo)

        Rewrite the prompt so AutoGLM can better understand and execute the task on the phone.

        Expected result :
        IMPORTANT :
        TEXT RESULT WITHOUT ANY UNRELATED TEXT
        """

        return try await requestPlainText(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            maxTokens: 220
        )
    }

    func refineDirectAnswer(
        task: String,
        draftAnswer: String,
        currentApp: String?,
        screenInfo: String,
        devicePersona: String,
        preferredApps: String = "",
        deviceNotes: String = "",
        modelThinking: String,
        format: String
    ) async throws -> String {
        let personaText = normalizedPersonaText(from: devicePersona)
        let preferredAppsText = normalizedPreferredAppsText(from: preferredApps)
        let notesText = normalizedDeviceNotesText(from: deviceNotes)
        let requestedFormat = format.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "md" : format.trimmingCharacters(in: .whitespacesAndNewlines)
        let systemPrompt = """
        You are the Language Enhancer for an Android phone agent.
        Your job is to polish a direct answer that will be shown to the user.

        Hard rules:
        - Preserve the original intent exactly.
        - Keep the same language as the user's request.
        - Never switch to Chinese unless the user's request is explicitly in Chinese.
        - Use the device persona as required context to deepen the response quality and tone check, without changing the facts.
        - Respect the requested output format.
        - If format is `md`, return concise, readable Markdown.
        - If the draft answer is already good, keep it unchanged.
        - Return ONLY the final answer text, with no labels or explanations about your process.
        """

        let userPrompt = """
        USER PROMPT:
        \(task)

        REQUESTED FORMAT:
        \(requestedFormat)

        DRAFT ANSWER:
        \(draftAnswer.isEmpty ? "[No draft answer was provided. Generate the final answer from context.]" : draftAnswer)

        CONTEXT:
        Current app: \(currentApp ?? "Unknown")
        Device persona: \(personaText)
        Preferred apps: \(preferredAppsText)
        Device notes: \(notesText)
        AutoGLM reasoning:
        \(modelThinking)
        Screen context:
        \(screenInfo)

        Rewrite or keep the answer so it is clear, natural, and in the correct language.
        Return ONLY the final answer.
        """

        return try await requestPlainText(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            maxTokens: 320,
            preserveMultiline: true
        )
    }

    func generateTextInput(
        task: String,
        requestedText: String,
        currentApp: String?,
        screenInfo: String,
        devicePersona: String,
        preferredApps: String = "",
        deviceNotes: String = "",
        modelThinking: String
    ) async throws -> String {
        let personaText = normalizedPersonaText(from: devicePersona)
        let preferredAppsText = normalizedPreferredAppsText(from: preferredApps)
        let notesText = normalizedDeviceNotesText(from: deviceNotes)
        let draftText = requestedText.isEmpty
            ? "[AutoGLM did not provide explicit text. Generate the final text from the user prompt and visual context.]"
            : requestedText
        let systemPrompt = """
        You are the Language Enhancer for an Android phone agent.
        Your only job is to generate the exact final text that should be typed into the current input field.

        Hard rules:
        - Return ONLY the final text.
        - No explanations.
        - No markdown.
        - No labels such as USER PROMPT, CONTEXT, RESULT, or IMPORTANT.
        - No surrounding quotes unless the text itself truly requires quotes.
        - Keep the output grounded in the user's request and the AutoGLM screen context.
        - Use the device persona as required context to deepen wording and tone checks while staying faithful to the user's intent.
        - Preserve exact usernames, emails, URLs, OTP codes, numbers, hashtags, and search terms when they are already provided.
        - Decide yourself whether the draft text should be kept exactly or improved; if it is already correct, return it unchanged.
        - Always keep the same language as the user's request.
        - Never return Chinese unless the user's request is explicitly in Chinese.
        - If the AutoGLM draft mixes languages, rewrite it so the final text matches the user's request language.
        - If the user asked for a caption, reply, search query, or short message, generate a concise natural result in the requested or implied language.
        """

        let userPrompt = """
        USER PROMPT :
        \(task)

        CONTEXT :
        Based on image that seen by AutoGLM, and the current screen/app state below.

        Current app:
        \(currentApp ?? "Unknown")

        AutoGLM draft text:
        \(draftText)

        Device persona:
        \(personaText)

        Preferred apps:
        \(preferredAppsText)

        Device notes:
        \(notesText)

        AutoGLM reasoning:
        \(modelThinking)

        Screen context:
        \(screenInfo)

        Please generate text caption with language based on user prompt, make sure you're under the context.

        Expected result :
        IMPORTANT :
        TEXT RESULT WITHOUT ANY UNRELATED TEXT
        """

        return try await requestPlainText(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            maxTokens: 160
        )
    }

    private func normalizedPersonaText(from devicePersona: String) -> String {
        let trimmed = devicePersona.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? "Careful, context-aware, detail-oriented assistant who matches the user's language naturally and double-checks tone before replying."
            : trimmed
    }

    private func normalizedPreferredAppsText(from preferredApps: String) -> String {
        let trimmed = preferredApps.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "No preferred apps were specified for this device." : trimmed
    }

    private func normalizedDeviceNotesText(from deviceNotes: String) -> String {
        let trimmed = deviceNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "No extra device notes or safety rules were provided for this device." : trimmed
    }

    private func requestPlainText(
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int,
        preserveMultiline: Bool = false
    ) async throws -> String {
        let requestTargets = configuration.languageEnhancerRequestTargets
        guard !requestTargets.isEmpty else {
            throw NativeAgentError.invalidConfiguration("Please enter a valid Language Enhancer server URL in Settings → AI Models.")
        }

        var lastError: Error = NativeAgentError.invalidConfiguration("No usable Language Enhancer endpoint was found.")

        for target in requestTargets {
            let endpoints = candidateURLs(from: target.baseURL, path: "chat/completions")
            guard !endpoints.isEmpty else { continue }

            let payload: [String: Any] = [
                "model": target.model,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": userPrompt]
                ],
                "max_tokens": maxTokens,
                "temperature": 0.2,
                "top_p": 0.7
            ]

            let body = try JSONSerialization.data(withJSONObject: payload, options: [])

            for endpoint in endpoints {
                do {
                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 60
                    request.httpBody = body
                    applyHeaders(to: &request, apiKey: target.apiKey)

                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw NativeAgentError.server("The \(target.label) returned an invalid response.")
                    }

                    if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                        throw NativeAgentError.server("Authentication failed for \(target.label). Check the API key in Settings → AI Models.")
                    }

                    guard (200...299).contains(httpResponse.statusCode) else {
                        let errorMessage = Self.extractErrorMessage(from: data) ?? "\(target.label) returned HTTP \(httpResponse.statusCode)."
                        throw NativeAgentError.server(errorMessage)
                    }

                    if let content = Self.extractContent(from: data), !content.isEmpty {
                        return preserveMultiline ? Self.cleanedRichText(content) : Self.cleanedText(content)
                    }

                    throw NativeAgentError.server("The \(target.label) returned an empty completion.")
                } catch {
                    lastError = NativeAgentError.server("\(target.label) failed at \(endpoint.absoluteString): \(error.localizedDescription)")
                }
            }
        }

        throw lastError
    }

    private func applyHeaders(to request: inout URLRequest, apiKey: String) {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if trimmedKey.isEmpty {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
        } else {
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        }
    }

    private func candidateURLs(from rawBaseURL: String, path: String) -> [URL] {
        let trimmed = rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let normalized: String
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            normalized = trimmed
        } else {
            let isLocalHost = trimmed.hasPrefix("localhost") || trimmed.hasPrefix("127.")
            let looksLikeIPAddress = trimmed.range(of: #"^\d{1,3}(\.\d{1,3}){3}(:\d+)?/?$"#, options: .regularExpression) != nil
            normalized = (isLocalHost || looksLikeIPAddress ? "http://" : "https://") + trimmed
        }

        guard let baseURL = URL(string: normalized) else { return [] }
        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedPath = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var candidates: [URL] = []

        if normalizedPath == cleanPath || normalizedPath.hasSuffix("/\(cleanPath)") {
            candidates.append(baseURL)
        } else if normalizedPath == "chat", cleanPath == "chat/completions" {
            candidates.append(baseURL.appendingPathComponent("completions"))
        } else if normalizedPath == "v1" || normalizedPath.hasSuffix("/v1") {
            candidates.append(baseURL.appendingPathComponent(cleanPath))
        } else {
            candidates.append(baseURL.appendingPathComponent("v1").appendingPathComponent(cleanPath))
            candidates.append(baseURL.appendingPathComponent(cleanPath))
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0.absoluteString).inserted }
    }

    private static func extractContent(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let first = choices.first else {
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let message = first["message"] as? [String: Any] {
            if let content = message["content"] as? String {
                return content.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            if let contentParts = message["content"] as? [[String: Any]] {
                let joined = contentParts.compactMap { $0["text"] as? String }.joined(separator: "")
                return joined.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        if let text = first["text"] as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

    private static func cleanedRichText(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.hasPrefix("```markdown") {
            text = text.replacingOccurrences(of: "```markdown", with: "")
        } else if text.hasPrefix("```md") {
            text = text.replacingOccurrences(of: "```md", with: "")
        } else if text.hasPrefix("```text") {
            text = text.replacingOccurrences(of: "```text", with: "")
        }

        text = text
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return text
    }

    private static func cleanedText(_ value: String) -> String {
        var text = cleanedRichText(value)

        let cleanupPatterns = [
            #"(?i)^important\s*:\s*"#,
            #"(?i)^text\s*result\s*:\s*"#,
            #"(?i)^result\s*:\s*"#,
            #"(?i)^caption\s*:\s*"#,
            #"(?i)^enhanced\s*(task|prompt)\s*:\s*"#,
            #"(?i)^rewritten\s*(task|prompt)\s*:\s*"#
        ]

        for pattern in cleanupPatterns {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if text.contains("\n") {
            let lines = text
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            if let bestLine = lines.last(where: {
                let lower = $0.lowercased()
                return !lower.hasPrefix("important") && !lower.hasPrefix("text result") && !lower.hasPrefix("result")
            }) {
                text = bestLine
            }
        }

        if (text.hasPrefix("\"") && text.hasSuffix("\"")) || (text.hasPrefix("'") && text.hasSuffix("'")) {
            text.removeFirst()
            text.removeLast()
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let errorObject = object["error"] as? [String: Any],
           let message = errorObject["message"] as? String {
            return message
        }

        if let message = object["message"] as? String {
            return message
        }

        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct NativeModelResponse {
    let thinking: String
    let action: String
    let rawContent: String
}

private struct NativeStreamingChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
        }

        let delta: Delta
    }

    let choices: [Choice]
}

private struct NativeAgentMessage {
    let role: String
    let text: String
    let imageBase64: String?
    let imageMimeType: String?

    static func system(text: String) -> Self {
        Self(role: "system", text: text, imageBase64: nil, imageMimeType: nil)
    }

    static func user(text: String, imageBase64: String?, imageMimeType: String? = nil) -> Self {
        Self(role: "user", text: text, imageBase64: imageBase64, imageMimeType: imageMimeType)
    }

    static func assistant(text: String) -> Self {
        Self(role: "assistant", text: text, imageBase64: nil, imageMimeType: nil)
    }

    func removingImage() -> Self {
        Self(role: role, text: text, imageBase64: nil, imageMimeType: nil)
    }

    var jsonValue: [String: Any] {
        switch role {
        case "system", "assistant":
            return ["role": role, "content": text]
        default:
            var content: [[String: Any]] = []
            if let imageBase64 {
                let mimeType = imageMimeType ?? "image/png"
                content.append([
                    "type": "image_url",
                    "image_url": ["url": "data:\(mimeType);base64,\(imageBase64)"]
                ])
            }
            content.append(["type": "text", "text": text])
            return ["role": role, "content": content]
        }
    }
}

private enum NativeAgentAction {
    case finish(message: String?)
    case listApp(query: String?)
    case launch(app: String)
    case tap(point: NativeRelativePoint, message: String?)
    case doubleTap(point: NativeRelativePoint)
    case longPress(point: NativeRelativePoint)
    case swipe(start: NativeRelativePoint, end: NativeRelativePoint)
    case type(text: String, enhance: Bool)
    case back
    case home
    case wait(seconds: Double)
    case takeOver(message: String?)
    case unknown(name: String, raw: String)

    var shortLabel: String {
        switch self {
        case .finish:
            return "finish"
        case .listApp:
            return "list apps"
        case .launch:
            return "launch"
        case .tap:
            return "tap"
        case .doubleTap:
            return "double tap"
        case .longPress:
            return "long press"
        case .swipe:
            return "swipe"
        case .type:
            return "type"
        case .back:
            return "back"
        case .home:
            return "home"
        case .wait:
            return "wait"
        case .takeOver:
            return "take over"
        case let .unknown(name, _):
            return name
        }
    }

    var logDescription: String {
        switch self {
        case let .finish(message):
            return "finish(\(message ?? "done"))"
        case let .listApp(query):
            return "ListApp(\(query ?? "all"))"
        case let .launch(app):
            return "Launch \(app)"
        case let .tap(point, _):
            return "Tap [\(point.x), \(point.y)]"
        case let .doubleTap(point):
            return "Double Tap [\(point.x), \(point.y)]"
        case let .longPress(point):
            return "Long Press [\(point.x), \(point.y)]"
        case let .swipe(start, end):
            return "Swipe [\(start.x), \(start.y)] → [\(end.x), \(end.y)]"
        case let .type(text, enhance):
            return enhance ? "Type \(text.debugDescription) [enhance]" : "Type \(text.debugDescription)"
        case .back:
            return "Back"
        case .home:
            return "Home"
        case let .wait(seconds):
            return "Wait \(String(format: "%.1f", seconds))s"
        case let .takeOver(message):
            return "Take over: \(message ?? "manual action required")"
        case let .unknown(name, raw):
            return "\(name) → \(raw)"
        }
    }
}

private struct NativeRelativePoint {
    let x: Int
    let y: Int
}

private enum NativeActionParser {
    static func parse(_ rawResponse: String) -> NativeAgentAction {
        let trimmed = extractAnswer(from: rawResponse).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .finish(message: "The model returned an empty response.")
        }

        if trimmed.hasPrefix("finish") {
            return .finish(message: quotedValue(named: "message", in: trimmed))
        }

        guard trimmed.hasPrefix("do") else {
            return .finish(message: trimmed)
        }

        let actionName = quotedValue(named: "action", in: trimmed) ?? "Unknown"

        switch actionName {
        case "ListApp", "ListApps", "List_App":
            return .listApp(
                query: quotedValue(named: "query", in: trimmed)
                    ?? quotedValue(named: "app", in: trimmed)
                    ?? quotedValue(named: "text", in: trimmed)
            )
        case "Tap":
            if let point = point(named: "element", in: trimmed) {
                return .tap(point: point, message: quotedValue(named: "message", in: trimmed))
            }
        case "Double Tap":
            if let point = point(named: "element", in: trimmed) {
                return .doubleTap(point: point)
            }
        case "Long Press":
            if let point = point(named: "element", in: trimmed) {
                return .longPress(point: point)
            }
        case "Swipe":
            if let start = point(named: "start", in: trimmed),
               let end = point(named: "end", in: trimmed) {
                return .swipe(start: start, end: end)
            }
        case "Type", "Type_Name":
            return .type(
                text: quotedValue(named: "text", in: trimmed) ?? "",
                enhance: booleanValue(named: "enhance", in: trimmed) ?? false
            )
        case "Launch":
            return .launch(app: quotedValue(named: "app", in: trimmed) ?? "")
        case "Back":
            return .back
        case "Home":
            return .home
        case "Wait":
            let seconds = waitDuration(from: quotedValue(named: "duration", in: trimmed))
            return .wait(seconds: seconds)
        case "Take_over":
            return .takeOver(message: quotedValue(named: "message", in: trimmed))
        default:
            break
        }

        return .unknown(name: actionName, raw: trimmed)
    }

    private static func extractAnswer(from response: String) -> String {
        if let answerRange = response.range(of: "<answer>") {
            let afterAnswer = response[answerRange.upperBound...]
            if let endRange = afterAnswer.range(of: "</answer>") {
                return String(afterAnswer[..<endRange.lowerBound])
            }
            return String(afterAnswer)
        }
        return response
    }

    private static func quotedValue(named name: String, in text: String) -> String? {
        let doubleQuotedPattern = #"\#(name)\s*[:=]\s*\"((?:\\.|[^\"])*)\""#
        if let value = firstMatch(pattern: doubleQuotedPattern, in: text) {
            return unescape(value)
        }

        let singleQuotedPattern = #"\#(name)\s*[:=]\s*'((?:\\.|[^'])*)'"#
        if let value = firstMatch(pattern: singleQuotedPattern, in: text) {
            return unescape(value)
        }

        return nil
    }

    private static func point(named name: String, in text: String) -> NativeRelativePoint? {
        let pattern = #"\#(name)\s*[:=]\s*\[(\d+)\s*,\s*(\d+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges == 3,
              let xRange = Range(match.range(at: 1), in: text),
              let yRange = Range(match.range(at: 2), in: text),
              let x = Int(text[xRange]),
              let y = Int(text[yRange]) else {
            return nil
        }
        return NativeRelativePoint(x: x, y: y)
    }

    private static func waitDuration(from raw: String?) -> Double {
        guard let raw else { return 1.0 }
        let cleaned = raw.replacingOccurrences(of: "seconds", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(cleaned) ?? 1.0
    }

    private static func booleanValue(named name: String, in text: String) -> Bool? {
        if let quoted = quotedValue(named: name, in: text) {
            return parseBoolean(quoted)
        }

        let pattern = #"(?i)\#(name)\s*[:=]\s*(true|false|yes|no|1|0)"#
        guard let match = firstMatch(pattern: pattern, in: text) else {
            return nil
        }
        return parseBoolean(match)
    }

    private static func parseBoolean(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "1":
            return true
        case "false", "no", "0":
            return false
        default:
            return nil
        }
    }

    private static func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captureRange])
    }

    private static func unescape(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\\n"#, with: "\n")
            .replacingOccurrences(of: #"\\r"#, with: "\r")
            .replacingOccurrences(of: #"\\t"#, with: "\t")
            .replacingOccurrences(of: #"\\\""#, with: #"\""#)
            .replacingOccurrences(of: #"\\'"#, with: "'")
    }
}

private enum NativeResponseParser {
    static func parse(content: String) -> (thinking: String, action: String) {
        if let range = content.range(of: "finish(message=") {
            return (String(content[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines),
                    String(content[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if let range = content.range(of: "do(action=") {
            return (String(content[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines),
                    String(content[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if let thinkStart = content.range(of: "<think>"),
           let thinkEnd = content.range(of: "</think>"),
           let answerStart = content.range(of: "<answer>") {
            let thinking = String(content[thinkStart.upperBound..<thinkEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let actionEnd = content.range(of: "</answer>")?.lowerBound ?? content.endIndex
            let action = String(content[answerStart.upperBound..<actionEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (thinking, action)
        }

        return ("", content.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

private enum NativeAgentPromptBuilder {
    static func systemPrompt(
        userTask: String,
        devicePersona: String = "",
        preferredApps: String = "",
        deviceNotes: String = ""
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd, EEEE"
        let formattedDate = formatter.string(from: Date())
        let languageName = inferredLanguageName(from: userTask)
        let personaText = devicePersona.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Careful, context-aware, detail-oriented assistant who matches the user's language naturally and double-checks tone before replying."
            : devicePersona.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferredAppsText = preferredApps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "No preferred apps were specified for this device."
            : preferredApps.trimmingCharacters(in: .whitespacesAndNewlines)
        let notesText = deviceNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "No extra device notes or safety rules were provided for this device."
            : deviceNotes.trimmingCharacters(in: .whitespacesAndNewlines)

        return """
        The current date: \(formattedDate)
        # Setup
        You are a professional Android operation agent assistant that can fulfill the user's high-level instructions. Given a screenshot of the Android interface at each step, you first analyze the situation, then plan the best course of action using Python-style pseudo-code.

        User request language to keep: \(languageName)
        Device persona for this run: \(personaText)
        Preferred apps for this device: \(preferredAppsText)
        Device notes and safety rules: \(notesText)

        Your response format must be structured as follows:
        <think>
        [Your thought]
        </think>
        <answer>
        [Your operation code]
        </answer>

        - Tap: <answer>do(action="Tap", element=[x,y])</answer>
        - Type: <answer>do(action="Type", text="Hello World")</answer>
        - Type with optional refinement: <answer>do(action="Type", text="short draft or intent", enhance=true)</answer>
        - Swipe: <answer>do(action="Swipe", start=[x1,y1], end=[x2,y2])</answer>
        - Long Press: <answer>do(action="Long Press", element=[x,y])</answer>
        - List installed apps: <answer>do(action="ListApp", query="Instagram")</answer>
        - Launch: <answer>do(action="Launch", app="Settings")</answer>
        - Back: <answer>do(action="Back")</answer>
        - Home: <answer>do(action="Home")</answer>
        - Finish: <answer>finish(message="Task completed.")</answer>

        REMEMBER:
        - Think before you act.
        - Return exactly one action line in <answer>.
        - If the user only needs a direct answer with no phone interaction, respond with `finish(message="...")` in the user's language.
        - Use coordinates on a 0-1000 scale, not raw pixels.
        - Keep the same language as the user's request for your reasoning and any generated text.
        - The user's request language for this run is \(languageName).
        - Treat the device persona as required context for tone, depth, and interaction style, but never change the user's core goal.
        - Prefer apps listed in the device preferences when multiple app choices can satisfy the task.
        - Respect the device notes, account context, and any safety rules whenever they are relevant.
        - Never switch to Chinese unless the user's request is explicitly written in Chinese.
        - If the user's request is in Indonesian, stay in Indonesian.
        - If you want to open an app and you are not fully sure which package or exact app is installed, call `ListApp` first.
        - `ListApp` gives you installed apps and package names from ADB. Use that result to decide the next `Launch(app="...")` call.
        - `Launch` should be used after `ListApp` when app availability matters; if the requested app is not installed, it may open Google Play.
        - For text entry, provide the exact final text whenever it is already known.
        - For every `Type(...)` action, the Language Enhancer will verify whether to keep or refine the text so it matches the user's language and intent.
        - NEVER REPLY WITH CHINESE UNLESS THE USER'S REQUEST IS IN CHINESE. If the user's request is in Indonesian, reply in Indonesian. Otherwise, reply in English.
        """
    }

    private static func inferredLanguageName(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "English" }

        if trimmed.range(of: #"\p{Han}"#, options: .regularExpression) != nil {
            return "Chinese"
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 4)

        let indonesianConfidence = (hypotheses[.indonesian] ?? 0) + (hypotheses[.malay] ?? 0)
        let englishConfidence = hypotheses[.english] ?? 0

        if indonesianConfidence >= 0.60 || (indonesianConfidence >= 0.35 && indonesianConfidence > englishConfidence + 0.10) {
            return "Indonesian"
        }

        if englishConfidence >= 0.60 {
            return "English"
        }

        let lowercased = " \(trimmed.lowercased()) "
        let indonesianHints = [
            " yang ", " dan ", " untuk ", " dengan ", " tidak ", " saya ", " kamu ",
            " buka ", " cari ", " komentar ", " komen ", " postingan ", " gambar ",
            " deskripsi ", " akun ", " tolong ", " apakah ", " bagaimana "
        ]
        let englishHints = [
            " the ", " and ", " for ", " with ", " open ", " search ",
            " comment ", " caption ", " image ", " account ", " please "
        ]

        let indonesianMatches = indonesianHints.reduce(into: 0) { count, hint in
            if lowercased.contains(hint) { count += 1 }
        }
        let englishMatches = englishHints.reduce(into: 0) { count, hint in
            if lowercased.contains(hint) { count += 1 }
        }

        if indonesianMatches >= 2 && indonesianMatches > englishMatches {
            return "Indonesian"
        }

        return "English"
    }

    static func screenInfo(currentApp: String?) -> String {
        let payload = ["current_app": currentApp ?? "Unknown"]

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"current_app\":\"\(currentApp ?? "Unknown")\"}"
        }

        return string
    }
}

private enum NativeAgentError: LocalizedError {
    case invalidConfiguration(String)
    case server(String)
    case maxStepsReached

    var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message):
            return message
        case let .server(message):
            return message
        case .maxStepsReached:
            return "The task stopped after reaching the maximum number of agent steps."
        }
    }
}

private struct AgentLogScrollObserver: NSViewRepresentable {
    let threshold: CGFloat
    let onScrollStateChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.threshold = threshold
        view.onScrollStateChange = onScrollStateChange
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.threshold = threshold
        nsView.onScrollStateChange = onScrollStateChange

        DispatchQueue.main.async {
            nsView.attachIfNeeded()
        }
    }

    final class ObserverView: NSView {
        var threshold: CGFloat = 24
        var onScrollStateChange: ((Bool) -> Void)?

        private weak var observedScrollView: NSScrollView?
        private var boundsObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attachIfNeeded()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            attachIfNeeded()
        }

        func attachIfNeeded() {
            guard let scrollView = enclosingScrollView ?? superview?.enclosingScrollView else { return }

            if scrollView === observedScrollView {
                notifyScrollState()
                return
            }

            detachObserver()
            observedScrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true

            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.notifyScrollState()
            }

            notifyScrollState()
        }

        private func notifyScrollState() {
            guard let scrollView = observedScrollView,
                  let documentView = scrollView.documentView else { return }

            let visibleMaxY = scrollView.contentView.bounds.maxY
            let remainingDistance = documentView.bounds.maxY - visibleMaxY
            onScrollStateChange?(remainingDistance <= threshold)
        }

        private func detachObserver() {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
                self.boundsObserver = nil
            }
            observedScrollView = nil
        }

        deinit {
            detachObserver()
        }
    }
}

struct AgentLogWindowView: View {
    @EnvironmentObject private var runner: AgentRunStore
    @State private var shouldAutoScroll = true
    @State private var isProgrammaticScroll = false
    @State private var autoScrollRequestID = UUID()

    private let logBottomAnchorID = "agent-log-bottom-anchor"
    private let logBottomThreshold: CGFloat = 24

    private var currentRun: DeviceAgentRunSnapshot? {
        runner.selectedRun
    }

    private var statusColor: Color {
        if runner.isRunning { return .orange }
        if let lastExitCode = currentRun?.lastExitCode ?? runner.lastExitCode, lastExitCode != 0 { return .red }
        return .green
    }

    private func tabTitle(for run: DeviceAgentRunSnapshot) -> String {
        run.isRunning ? "\(run.tabTitle) (Loading)" : run.tabTitle
    }

    private func tabBackground(for run: DeviceAgentRunSnapshot, isSelected: Bool) -> Color {
        let baseColor: Color
        if run.isRunning {
            baseColor = .orange
        } else if let exitCode = run.lastExitCode, exitCode != 0 {
            baseColor = .red
        } else if run.lastExitCode == 0 {
            baseColor = .green
        } else {
            baseColor = .secondary
        }

        return baseColor.opacity(isSelected ? 0.28 : 0.16)
    }

    private var displayedLogText: String {
        let text = currentRun?.logText ?? runner.logText
        return text.isEmpty ? "No AI activity yet." : text
    }

    private func scrollToBottom(using proxy: ScrollViewProxy, animated: Bool = false) {
        let action = {
            proxy.scrollTo(logBottomAnchorID, anchor: .bottom)
        }

        if animated {
            withAnimation(.easeOut(duration: 0.18)) {
                action()
            }
        } else {
            action()
        }
    }

    private func requestAutoScroll(using proxy: ScrollViewProxy, animated: Bool = false) {
        guard shouldAutoScroll else { return }

        let requestID = UUID()
        autoScrollRequestID = requestID
        isProgrammaticScroll = true

        let delays: [TimeInterval] = [0.0, 0.03, 0.08, 0.16, 0.28]

        for (index, delay) in delays.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard autoScrollRequestID == requestID else { return }
                scrollToBottom(using: proxy, animated: animated && index == 0)

                if index == delays.count - 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        if autoScrollRequestID == requestID {
                            isProgrammaticScroll = false
                        }
                    }
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                    .padding(.top, 4)

                Text(runner.statusMessage)
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()

                if runner.isRunning {
                    Button(runner.deviceRuns.count > 1 ? "Stop All" : "Stop") {
                        runner.cancel()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }

                Button("Clear") {
                    runner.clearLog()
                }
                .buttonStyle(.bordered)
                .disabled(runner.isRunning)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(statusColor.opacity(0.14))
            )

            if runner.deviceRuns.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(runner.deviceRuns) { run in
                            Button {
                                runner.selectedDeviceRunID = run.deviceID
                            } label: {
                                Text(tabTitle(for: run))
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        Capsule()
                                            .fill(tabBackground(for: run, isSelected: runner.selectedDeviceRunID == run.deviceID))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if let currentRun {
                HStack(spacing: 8) {
                    Text("Viewing \(tabTitle(for: currentRun))")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    Spacer()

                    if currentRun.isRunning {
                        Button("Stop") {
                            runner.cancel()
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                }
            }

            if !(currentRun?.lastCommand ?? runner.lastCommand).isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Engine")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Text(verbatim: currentRun?.lastCommand ?? runner.lastCommand)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(nsColor: .textBackgroundColor))
                        )
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(displayedLogText)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(12)

                        Color.clear
                            .frame(height: 1)
                            .id(logBottomAnchorID)
                    }
                }
                .background(
                    AgentLogScrollObserver(threshold: logBottomThreshold) { isAtBottom in
                        if isProgrammaticScroll {
                            if isAtBottom {
                                isProgrammaticScroll = false
                            }
                            return
                        }

                        if shouldAutoScroll != isAtBottom {
                            shouldAutoScroll = isAtBottom
                        }
                    }
                )
                .onAppear {
                    shouldAutoScroll = true
                    requestAutoScroll(using: proxy)
                }
                .onChange(of: displayedLogText) { _ in
                    requestAutoScroll(using: proxy, animated: true)
                }
                .onChange(of: runner.selectedDeviceRunID) { _ in
                    shouldAutoScroll = true
                    requestAutoScroll(using: proxy)
                }
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
            }
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
