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
    var screenshotsByStep: [Int: Data] = [:]

    var id: String { deviceID }
    var tabTitle: String { "[\(deviceID) \(personaEmoji)]" }

    static func == (lhs: DeviceAgentRunSnapshot, rhs: DeviceAgentRunSnapshot) -> Bool {
        lhs.deviceID == rhs.deviceID &&
        lhs.statusMessage == rhs.statusMessage &&
        lhs.logText == rhs.logText &&
        lhs.lastCommand == rhs.lastCommand &&
        lhs.lastExitCode == rhs.lastExitCode &&
        lhs.lastTask == rhs.lastTask &&
        lhs.isRunning == rhs.isRunning &&
        lhs.screenshotsByStep.count == rhs.screenshotsByStep.count
    }
}

@MainActor
final class AgentRunStore: ObservableObject {
    @Published private(set) var isRunning = false
    @Published var statusMessage: String = "Ready to run AI Automation."
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
    private var cancelledDeviceIDs: Set<String> = []

    var selectedRun: DeviceAgentRunSnapshot? {
        if let selectedDeviceRunID,
            let run = deviceRuns.first(where: { $0.deviceID == selectedDeviceRunID })
        {
            return run
        }
        return deviceRuns.first
    }

    @discardableResult
    func run(task: String, deviceID: String?, settings: AISettingsStore, devicePersona: String = "")
        -> Bool
    {
        guard let deviceID, !deviceID.isEmpty else {
            statusMessage = "No ready devices found. Connect a device and refresh the list first."
            return false
        }

        var profile = ADBDeviceProfile()
        profile.persona = devicePersona
        return run(
            task: task, deviceIDs: [deviceID], settings: settings,
            deviceProfiles: [deviceID: profile])
    }

    @discardableResult
    func run(
        task: String, deviceIDs: [String], settings: AISettingsStore,
        deviceProfiles: [String: ADBDeviceProfile]
    ) -> Bool {
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

        let configurations = Dictionary(
            uniqueKeysWithValues: uniqueDeviceIDs.map { deviceID in
                let profile = deviceProfiles[deviceID] ?? ADBDeviceProfile()
                return (deviceID, NativeAgentConfiguration(settings: settings, profile: profile))
            })

        guard configurations.values.allSatisfy({ !$0.baseURL.isEmpty }) else {
            statusMessage = "AI server URL is empty. Update it in Settings → AI Models."
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
                lastCommand:
                    "Native Swift agent · model=\(configuration.modelName) · device=\(deviceID)",
                lastExitCode: nil,
                lastTask: trimmedTask,
                isRunning: true
            )
        }

        selectedDeviceRunID = uniqueDeviceIDs.first
        didRequestCancel = false
        cancelledDeviceIDs = []
        isRunning = true
        statusMessage =
            uniqueDeviceIDs.count == 1
            ? "Running AI Automation on \(uniqueDeviceIDs[0])…"
            : "Running AI Automation across \(uniqueDeviceIDs.count) devices…"
        syncSelectedRunProjection()

        runTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            await withTaskGroup(of: Void.self) { group in
                for deviceID in uniqueDeviceIDs {
                    guard let configuration = configurations[deviceID] else { continue }

                    group.addTask { [weak self] in
                        guard let self else { return }

                        await MainActor.run {
                            let providerName = type(of: configuration.modelProvider).displayName
                            self.appendLog("Starting \(providerName) agent\n", for: deviceID)
                            self.appendLog("Device: \(deviceID)\n", for: deviceID)
                            self.appendLog(
                                "Device persona: \(configuration.devicePersona.isEmpty ? "None" : configuration.devicePersona)\n",
                                for: deviceID)
                            self.appendLog(
                                "Preferred apps: \(configuration.preferredApps.isEmpty ? "None" : configuration.preferredApps)\n",
                                for: deviceID)
                            self.appendLog(
                                "Device notes: \(configuration.deviceNotes.isEmpty ? "None" : configuration.deviceNotes)\n",
                                for: deviceID)
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
                            screenshotHandler: { data, step in
                                await MainActor.run {
                                    self.updateScreenshot(data, step: step, for: deviceID)
                                }
                            },
                            cancellationChecker: {
                                await MainActor.run {
                                    self.didRequestCancel || self.cancelledDeviceIDs.contains(deviceID)
                                }
                            }
                        )

                        do {
                            let finalMessage = try await agent.run(
                                task: trimmedTask, deviceID: deviceID)
                            await MainActor.run {
                                self.finishRun(for: deviceID, success: true, message: finalMessage)
                            }
                        } catch is CancellationError {
                            await MainActor.run {
                                self.finishCancelled(for: deviceID)
                            }
                        } catch {
                            await MainActor.run {
                                self.finishRun(
                                    for: deviceID, success: false,
                                    message: error.localizedDescription)
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

    func cancelDevice(_ deviceID: String) {
        guard deviceRuns.first(where: { $0.deviceID == deviceID })?.isRunning == true else { return }
        cancelledDeviceIDs.insert(deviceID)
        appendLog("\nCancel requested by user.\n", for: deviceID)
        updateStatus("Cancelling…", for: deviceID)
    }

    func clearLog() {
        guard !isRunning else { return }
        deviceRuns = []
        selectedDeviceRunID = nil
        logText = ""
        lastCommand = ""
        lastExitCode = nil
        lastTask = ""
        statusMessage = "Ready to run AI Automation."
    }

    func presentIssue(_ message: String) {
        statusMessage = message
        if let selectedDeviceRunID,
            deviceRuns.contains(where: { $0.deviceID == selectedDeviceRunID })
        {
            appendLog("Warning: \(message)\n", for: selectedDeviceRunID)
        } else {
            logText += "Warning: \(message)\n"
        }
    }

    private func finishRun(for deviceID: String, success: Bool, message: String) {
        let cleanMessage = AIModelParsingUtils.stripFinishWrapper(message)
        updateRun(for: deviceID) { run in
            run.isRunning = false
            run.lastExitCode = success ? 0 : 1
            run.statusMessage = success ? "Task completed." : cleanMessage
            run.logText += success ? "\nSuccess: \(cleanMessage)\n" : "\nError: \(cleanMessage)\n"
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

    private func updateScreenshot(_ data: Data, step: Int, for deviceID: String) {
        updateRun(for: deviceID) { run in
            run.screenshotsByStep[step] = data
            // Keep only the last 20 step screenshots to limit memory
            if run.screenshotsByStep.count > 20 {
                let keysToRemove = run.screenshotsByStep.keys.sorted().prefix(run.screenshotsByStep.count - 20)
                for key in keysToRemove {
                    run.screenshotsByStep.removeValue(forKey: key)
                }
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
        let failedCount = deviceRuns.filter {
            ($0.lastExitCode ?? 0) != 0 && $0.lastExitCode != nil
        }.count

        if runningCount > 1 {
            statusMessage = "Running across \(runningCount) devices…"
        } else if let activeRun = deviceRuns.first(where: { $0.isRunning }) {
            statusMessage = "\(activeRun.deviceID): \(activeRun.statusMessage)"
        } else if !deviceRuns.isEmpty {
            if failedCount > 0 {
                statusMessage =
                    failedCount == deviceRuns.count
                    ? "All device runs ended with issues."
                    : "Completed with issues on \(failedCount) device(s)."
            } else {
                statusMessage =
                    deviceRuns.count == 1
                    ? "Task completed."
                    : "Completed on \(deviceRuns.count) devices."
            }
        } else {
            statusMessage = "Ready to run AI Automation."
        }

        syncSelectedRunProjection()
    }

    private func syncSelectedRunProjection() {
        if let selectedDeviceRunID,
            !deviceRuns.contains(where: { $0.deviceID == selectedDeviceRunID })
        {
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
    let modelProvider: any AIModelProvider
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
        return trimmed.isEmpty
            ? "No extra device notes or safety rules were provided for this device." : trimmed
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

    var languageEnhancerRequestTargets:
        [(label: String, baseURL: String, apiKey: String, model: String)]
    {
        var targets: [(label: String, baseURL: String, apiKey: String, model: String)] = []

        func appendTarget(label: String, baseURL: String, apiKey: String, model: String) {
            let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedBaseURL.isEmpty, !trimmedModel.isEmpty else { return }
            guard
                !targets.contains(where: {
                    $0.baseURL == trimmedBaseURL && $0.model == trimmedModel
                        && $0.apiKey == apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                })
            else {
                return
            }

            targets.append(
                (
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
    init(
        settings: AISettingsStore, devicePersona: String = "", preferredApps: String = "",
        deviceNotes: String = ""
    ) {
        self.modelProvider = settings.resolvedModelProvider
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
        self.languageEnhancerBaseURL = settings.languageEnhancerServer.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let enhancerKey = settings.languageEnhancerKey.trimmingCharacters(
            in: .whitespacesAndNewlines)
        self.languageEnhancerAPIKey = enhancerKey.isEmpty ? "EMPTY" : enhancerKey
        self.languageEnhancerModel = settings.languageEnhancerModel.trimmingCharacters(
            in: .whitespacesAndNewlines)
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
    let screenshotHandler: @Sendable (Data, Int) async -> Void
    let cancellationChecker: @Sendable () async -> Bool

    func run(task: String, deviceID: String?) async throws -> String {
        let modelClient = NativeOpenAIModelClient(configuration: configuration)
        var preparedTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
        if preparedTask.isEmpty {
            preparedTask = task
        }

        // Detect the user's language via the Language Enhancer LLM if available,
        // otherwise fall back to the NLP heuristic inside each provider's systemPrompt.
        var detectedLanguage: String?
        if configuration.hasLanguageEnhancer {
            let enhancer = NativeLanguageEnhancerClient(configuration: configuration)
            do {
                let detected = try await enhancer.detectLanguage(task: preparedTask)
                let trimmed = detected.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    detectedLanguage = trimmed
                    await logger("Language detected by enhancer: \(trimmed)\n")
                }
            } catch {
                await logger("Language detection fallback to NLP: \(error.localizedDescription)\n")
            }
        }

        var context: [NativeAgentMessage] = [
            .system(
                text: configuration.modelProvider.systemPrompt(
                    userTask: preparedTask,
                    devicePersona: configuration.effectiveDevicePersona,
                    preferredApps: configuration.effectivePreferredApps,
                    deviceNotes: configuration.effectiveDeviceNotes,
                    hasLanguageEnhancer: configuration.hasLanguageEnhancer,
                    detectedLanguage: detectedLanguage
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
            if !screenshot.imageData.isEmpty {
                await screenshotHandler(screenshot.imageData, step)
            }
            await logger("Info: Screenshot \(screenshot.compressionSummary)\n")
            let currentApp = (try? provider.getCurrentApp(deviceID: deviceID)) ?? "Unknown"
            let runtime = ADBDeviceRuntimeStatus(
                batteryLevel: nil,
                wifiStatus: nil,
                dataStatus: nil,
                currentApp: currentApp
            )
            let screenInfo = AIModelParsingUtils.screenInfo(currentApp: currentApp)

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

            let textContent = configuration.modelProvider.userMessage(
                step: step,
                task: effectiveTask,
                screenInfo: screenInfo,
                devicePersona: configuration.effectiveDevicePersona,
                preferredApps: configuration.effectivePreferredApps,
                deviceNotes: configuration.effectiveDeviceNotes
            )

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

            // // Debug: print input context sent to model
            // do {
            //     var lines: [String] = [
            //         "[Input Context · Step \(step) · \(context.count) messages]"
            //     ]
            //     for (i, msg) in context.enumerated() {
            //         let text = msg.text
            //         let preview = text.count > 500 ? String(text.prefix(500)) + "…" : text
            //         var line = "  [\(i)] \(msg.role): \(preview)"
            //         if let img = msg.imageBase64 {
            //             line += " [image: \(img.count) chars]"
            //         }
            //         lines.append(line)
            //     }
            //     print(lines.joined(separator: "\n"))
            // }

            let streamsReadable = configuration.modelProvider.streamsReadableThinking
            let maxRetries = 2
            var response: NativeModelResponse!
            var action: NativeAgentAction!

            for attempt in 0...maxRetries {
                try Task.checkCancellation()

                if attempt > 0 {
                    await logger("Reprompting (attempt \(attempt + 1)/\(maxRetries + 1))...\n")
                    await statusHandler("Reprompting... attempt \(attempt + 1)")
                }

                response = try await modelClient.request(messages: context) { chunk in
                    if streamsReadable {
                        await logger(chunk)
                    }
                }

                // For providers that don't stream readable text (JSON-mode like OpenAI),
                // log the fully-parsed thinking text in one clean block.
                if !streamsReadable && !response.thinking.isEmpty {
                    await logger(response.thinking)
                }
                await logger("\n")

                let modelAction = configuration.modelProvider.parseAction(from: response.action)
                action = NativeActionParser.fromModelAction(modelAction)
                await logger("Action: \(action.logDescription)\n")

                do {
                    let debugLog = """
                        [Step \(step) · Attempt \(attempt + 1)]
                        raw_response: \(response.rawContent)
                        thinking: \(response.thinking)
                        action: \(response.action)
                        resolved: \(action.logDescription)
                        """
                    print(debugLog)
                }

                // If action parsed successfully, break out of retry loop
                if case .unknown = action! {} else {
                    break
                }

                // On unknown action: append the bad response + correction, then retry
                if attempt < maxRetries {
                    if let lastIndex = context.indices.last {
                        context[lastIndex] = context[lastIndex].removingImage()
                    }
                    context.append(.assistant(text: response.rawContent))
                    context.append(.user(
                        text: """
                            Your last response could not be parsed into a valid action. \
                            Please respond again with a valid JSON object containing "thinking" and "action" fields. \
                            The "action" field must have a "type" key with one of: tap, swipe, type, long press, double tap, listapp, launch, back, home, wait, take_over, finish. \
                            Example: {"thinking": "...", "action": {"type": "tap", "element": [500, 300]}}
                            """,
                        imageBase64: nil
                    ))
                    await logger("⚠ Could not parse action, reprompting model...\n")
                } else {
                    await logger("⚠ Failed to parse action after \(maxRetries + 1) attempts, proceeding with unknown action.\n")
                }
            }

            if let lastIndex = context.indices.last {
                context[lastIndex] = context[lastIndex].removingImage()
            }
            let assistantText = configuration.modelProvider.formatAssistantContext(
                thinking: response.thinking, action: response.action)
            context.append(.assistant(text: assistantText))

            await statusHandler("Executing \(action.shortLabel)...")
            let conversationSummary = Self.buildConversationSummary(from: context)
            let result = try await execute(
                action: action,
                screenshot: screenshot,
                deviceID: deviceID,
                task: task,
                runtime: runtime,
                screenInfo: screenInfo,
                modelThinking: response.thinking,
                conversationContext: conversationSummary
            )

            if let message = result.message, !message.isEmpty {
                await logger("Info: \(message)\n")
                context.append(
                    .user(text: "** Last action result **\n\n\(message)", imageBase64: nil))
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
        modelThinking: String,
        conversationContext: String = ""
    ) async throws -> NativeActionResult {
        switch action {
        case .finish(let message):
            let finalMessage = try await resolvedFinishMessage(
                from: message,
                task: task,
                runtime: runtime,
                screenInfo: screenInfo,
                modelThinking: modelThinking
            )
            return NativeActionResult(finished: true, message: finalMessage)

        case .listApp(let query):
            return NativeActionResult(
                finished: false,
                message: installedAppsSummary(query: query, deviceID: deviceID)
            )

        case .launch(let app):
            guard !app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return NativeActionResult(
                    finished: false,
                    message: "No app name or package was provided to Launch. Use Launch with an app name and the system will find the matching package.")
            }

            let trimmedApp = app.trimmingCharacters(in: .whitespacesAndNewlines)

            // If it looks like a resolved package name (contains dots), launch directly.
            if trimmedApp.contains(".") {
                let launchResult = try provider.launchApp(trimmedApp, deviceID: deviceID, delay: nil)
                return NativeActionResult(finished: false, message: launchResult.message)
            }

            // Otherwise, auto-resolve: list installed apps and send candidates back to the AI.
            await logger("Auto-resolving app name: \(trimmedApp)\n")
            let candidates = installedAppCandidates(query: trimmedApp, deviceID: deviceID)

            if candidates.count == 1 {
                // Exact single match — launch directly without another AI round-trip.
                let pkg = candidates[0].package
                let name = candidates[0].display
                await logger("Single match found: \(name) — launching directly.\n")
                let launchResult = try provider.launchApp(pkg, deviceID: deviceID, delay: nil)
                return NativeActionResult(finished: false, message: launchResult.message)
            }

            if candidates.isEmpty {
                return NativeActionResult(
                    finished: false,
                    message: "No installed app matched \"\(trimmedApp)\". You can try a different name, or use Launch(app=\"\(trimmedApp)\") with the exact package name if you know it.")
            }

            // Multiple matches — send back to the AI to pick the right one.
            let listing = candidates.prefix(15).map { "- \($0.display) (\($0.package))" }.joined(separator: "\n")
            return NativeActionResult(
                finished: false,
                message: "Multiple apps match \"\(trimmedApp)\". Pick the correct package and call Launch(app=\"package.name\") with the exact package:\n\(listing)"
            )

        case .tap(let point, let message):
            let resolved = resolve(point: point, screenshot: screenshot)
            try provider.tap(x: resolved.x, y: resolved.y, deviceID: deviceID, delay: nil)
            return NativeActionResult(finished: false, message: message)

        case .doubleTap(let point):
            let resolved = resolve(point: point, screenshot: screenshot)
            try provider.doubleTap(x: resolved.x, y: resolved.y, deviceID: deviceID, delay: nil)
            return NativeActionResult(finished: false, message: nil)

        case .longPress(let point):
            let resolved = resolve(point: point, screenshot: screenshot)
            try provider.longPress(
                x: resolved.x, y: resolved.y, durationMS: 3000, deviceID: deviceID, delay: nil)
            return NativeActionResult(finished: false, message: nil)

        case .swipe(let start, let end):
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

        case .type(let text, let enhance):
            let finalText = try await resolvedTextInput(
                from: text,
                shouldEnhance: enhance,
                task: task,
                runtime: runtime,
                screenInfo: screenInfo,
                modelThinking: modelThinking,
                conversationContext: conversationContext
            )
            let sanitizedText = stripActionWrapper(from: finalText)
            let trimmedText = sanitizedText.trimmingCharacters(in: .whitespacesAndNewlines)

            if sanitizedText != finalText.trimmingCharacters(in: .whitespacesAndNewlines) {
                await logger("Stripped leaked action wrapper from text input.\n")
            }

            guard !trimmedText.isEmpty else {
                return NativeActionResult(
                    finished: false, message: "Skipped typing because no text input was generated.")
            }

            try provider.clearText(deviceID: deviceID)
            try await pause(seconds: ADBTiming.textClearDelay)
            try provider.typeText(trimmedText, deviceID: deviceID)
            try await pause(seconds: ADBTiming.textInputDelay)
            return NativeActionResult(
                finished: false, message: "Typed text input: \(textPreview(trimmedText))")

        case .back:
            try provider.back(deviceID: deviceID, delay: nil)
            return NativeActionResult(finished: false, message: nil)

        case .home:
            try provider.home(deviceID: deviceID, delay: nil)
            return NativeActionResult(finished: false, message: nil)

        case .wait(let seconds):
            let clampedWait = max(0.5, min(seconds, 120))
            await logger("Waiting for \(String(format: "%.1f", clampedWait))s...\n")
            try await pause(seconds: clampedWait)
            return NativeActionResult(
                finished: false, message: "Waited for \(String(format: "%.1f", clampedWait))s")

        case .takeOver(let message):
            return NativeActionResult(
                finished: true, message: message ?? "Manual takeover requested.")

        case .unknown(let name, let raw):
            let fallbackSummary = try await resolvedUnsupportedActionMessage(
                name: name,
                raw: raw,
                task: task,
                runtime: runtime,
                screenInfo: screenInfo,
                modelThinking: modelThinking
            )
            print("Unsupported action '\(name)' with raw content: \(raw)")
            return NativeActionResult(finished: false, message: fallbackSummary)
        }
    }

    private func resolve(point: NativeRelativePoint, screenshot: ADBScreenshot) -> (x: Int, y: Int)
    {
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
            return
                "No installed app matched \(trimmedQuery.debugDescription) in the ADB package list (\(installedPackages.count) packages scanned). If still needed, use Launch(app=\"\(trimmedQuery)\") to open Google Play."
        }

        let preview =
            matches
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
            header =
                "Installed apps on the device (showing \(min(15, matches.count)) of \(matches.count)):"
        } else {
            header =
                "Installed apps matching \(trimmedQuery.debugDescription) (showing \(min(15, matches.count)) of \(matches.count)):"
        }

        let lines = preview.map { "- \($0)" }.joined(separator: "\n")
        return
            "\(header)\n\(lines)\nUse Launch(app=\"exact app name or package\") for the one you want."
    }

    private func normalizedLookupKey(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "", options: .regularExpression)
    }

    /// Returns structured app candidates matching a query, used by the auto-resolve launch flow.
    private func installedAppCandidates(query: String, deviceID: String?) -> [(display: String, package: String)] {
        let installedPackages = provider.listInstalledPackages(deviceID: deviceID)
        guard !installedPackages.isEmpty else { return [] }

        let normalizedQuery = normalizedLookupKey(query)
        guard !normalizedQuery.isEmpty else { return [] }

        return installedPackages.compactMap { package in
            let packageKey = normalizedLookupKey(package)
            let appName = ADBAppCatalog.appName(for: package)
            let appNameKey = normalizedLookupKey(appName ?? "")
            guard packageKey.contains(normalizedQuery) || appNameKey.contains(normalizedQuery) else {
                return nil
            }
            let display = appName ?? package
            return (display: display, package: package)
        }
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
            let rewrittenTask = try await enhancer.enhanceUserTask(
                task: trimmedTask,
                currentApp: runtime.currentApp,
                screenInfo: screenInfo,
                devicePersona: configuration.effectiveDevicePersona,
                preferredApps: configuration.effectivePreferredApps,
                deviceNotes: configuration.effectiveDeviceNotes
            )
            let finalTask = rewrittenTask.trimmingCharacters(in: .whitespacesAndNewlines)

            // if !finalTask.isEmpty {
            //     if finalTask != trimmedTask {
            //         await logger("Language enhancer rewrote the task using persona context.\n")
            //     } else {
            //         await logger("Language enhancer kept the original task.\n")
            //     }
            //     return finalTask
            // }
            return finalTask
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
        let baseMessage =
            draftMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
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
            await logger(
                "Language enhancer unsupported-action fallback: \(error.localizedDescription)\n")
            return baseMessage
        }
    }

    private func resolvedTextInput(
        from rawText: String,
        shouldEnhance: Bool,
        task: String,
        runtime: ADBDeviceRuntimeStatus,
        screenInfo: String,
        modelThinking: String,
        conversationContext: String = ""
    ) async throws -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard configuration.hasLanguageEnhancer else {
            await logger("Language enhancer not configured — typing raw text as-is.\n")
            return trimmed
        }

        let enhancer = NativeLanguageEnhancerClient(configuration: configuration)

        do {
            await logger(
                "Invoking language enhancer model: \(configuration.resolvedLanguageEnhancerModel) @ \(configuration.resolvedLanguageEnhancerBaseURL) (always refining before typing)\n"
            )
            let generatedText = try await enhancer.generateTextInput(
                task: task,
                requestedText: trimmed,
                currentApp: runtime.currentApp,
                screenInfo: screenInfo,
                devicePersona: configuration.effectiveDevicePersona,
                preferredApps: configuration.effectivePreferredApps,
                deviceNotes: configuration.effectiveDeviceNotes,
                modelThinking: modelThinking,
                conversationContext: conversationContext
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

    /// Detects and strips raw action wrappers that leak from the model or language enhancer.
    /// e.g. `do(action="Type", text="hello")` → `hello`
    private func stripActionWrapper(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip do(action="Type", text="...") wrapper
        if trimmed.hasPrefix("do(") || trimmed.hasPrefix("Do(") {
            if let extracted = AIModelParsingUtils.quotedValue(named: "text", in: trimmed),
               !extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return extracted
            }
        }

        // Strip finish(message="...") wrapper
        if trimmed.hasPrefix("finish(") || trimmed.hasPrefix("Finish(") {
            if let extracted = AIModelParsingUtils.quotedValue(named: "message", in: trimmed),
               !extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return extracted
            }
        }

        return trimmed
    }

    private func pause(seconds: TimeInterval) async throws {
        let clampedSeconds = max(0, seconds)
        guard clampedSeconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(clampedSeconds * 1_000_000_000))
    }

    /// Builds a compact summary of the conversation history for the language enhancer.
    /// Skips system messages and images, keeping only text from user/assistant turns.
    private static func buildConversationSummary(from context: [NativeAgentMessage], maxChars: Int = 2000) -> String {
        // Skip the system message (index 0) and collect user/assistant text turns
        let turns = context.dropFirst().compactMap { msg -> String? in
            let text = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let prefix = msg.role == "assistant" ? "Agent" : "Step"
            let preview = text.count > 300 ? String(text.prefix(300)) + "…" : text
            return "[\(prefix)] \(preview)"
        }

        guard !turns.isEmpty else { return "" }

        // Take most recent turns, trimmed to fit within maxChars
        var result: [String] = []
        var totalLength = 0
        for turn in turns.reversed() {
            if totalLength + turn.count > maxChars { break }
            result.insert(turn, at: 0)
            totalLength += turn.count
        }

        return result.joined(separator: "\n")
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
            throw NativeAgentError.invalidConfiguration(
                "Please enter a valid OpenGLM server URL in Settings → AI Models.")
        }

        var lastError: Error = NativeAgentError.invalidConfiguration(
            "No usable OpenAI-compatible endpoint was found.")

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
                    throw NativeAgentError.server(
                        "Authentication failed. Check the API key in Settings → AI Models.")
                }

                guard (200...299).contains(httpResponse.statusCode) else {
                    let errorData = try await collect(bytes: bytes)
                    let errorMessage =
                        Self.extractErrorMessage(from: errorData)
                        ?? "Server returned HTTP \(httpResponse.statusCode)."
                    throw NativeAgentError.server(errorMessage)
                }

                return try await parseStreamingResponse(
                    from: bytes, onThinkingChunk: onThinkingChunk)
            } catch {
                lastError = error
            }
        }

        throw lastError
    }

    private func requestBody(for messages: [NativeAgentMessage]) throws -> Data {
        var payload = configuration.modelProvider.requestParameters(
            modelName: configuration.modelName,
            maxTokens: configuration.maxTokens,
            temperature: configuration.temperature,
            topP: configuration.topP,
            frequencyPenalty: configuration.frequencyPenalty
        )
        payload["messages"] = messages.map(\.jsonValue)

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
                !content.isEmpty
            else {
                continue
            }

            rawContent += content

            if enteredActionPhase {
                continue
            }

            buffer += content

            if let markerRange = configuration.modelProvider.firstActionMarkerRange(in: buffer) {
                let thinkingPart = String(buffer[..<markerRange.lowerBound])
                if !thinkingPart.isEmpty {
                    await onThinkingChunk(thinkingPart)
                }
                enteredActionPhase = true
                buffer = ""
                continue
            }

            if configuration.modelProvider.endsWithPartialActionMarker(buffer) {
                continue
            }

            await onThinkingChunk(buffer)
            buffer = ""
        }

        if !buffer.isEmpty && !enteredActionPhase {
            await onThinkingChunk(buffer)
        }

        let parsed = configuration.modelProvider.parseResponse(content: rawContent)
        return NativeModelResponse(
            thinking: parsed.thinking, action: parsed.action, rawContent: rawContent)
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
            candidates.append(
                baseURL.appendingPathComponent("v1").appendingPathComponent(cleanPath))
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
        let looksLikeIPAddress =
            value.range(of: #"^\d{1,3}(\.\d{1,3}){3}(:\d+)?/?$"#, options: .regularExpression)
            != nil

        return (isLocalHost || looksLikeIPAddress ? "http://" : "https://") + value
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8)?.trimmingCharacters(
                in: .whitespacesAndNewlines)
        }

        if let errorObject = object["error"] as? [String: Any],
            let message = errorObject["message"] as? String
        {
            return message
        }

        if let message = object["message"] as? String {
            return message
        }

        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
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

    func detectLanguage(task: String) async throws -> String {
        let systemPrompt = """
            You are a language detection tool. Given a user's text, identify the language it is written in.
            Return ONLY the language name in English (e.g. "Indonesian", "English", "Chinese", "Japanese", "Korean", "Spanish", "French", etc.).
            No explanations, no labels, no punctuation — just the single language name.
            If the text mixes languages, return the dominant/primary language.
            """

        let userPrompt = """
            Detect the language of this text:
            \(task)
            """

        return try await requestPlainText(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            maxTokens: 10
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
        let requestedFormat =
            format.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "md" : format.trimmingCharacters(in: .whitespacesAndNewlines)
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
        modelThinking: String,
        conversationContext: String = ""
    ) async throws -> String {
        let personaText = normalizedPersonaText(from: devicePersona)
        let preferredAppsText = normalizedPreferredAppsText(from: preferredApps)
        let notesText = normalizedDeviceNotesText(from: deviceNotes)
        let draftText =
            requestedText.isEmpty
            ? "[AutoGLM did not provide explicit text. Generate the final text from the user prompt and visual context.]"
            : requestedText
        // Sanitize modelThinking: strip raw action lines (do(...), finish(...)) that confuse the LLM
        // into regurgitating the action wrapper as the typing text.
        let sanitizedThinking = modelThinking
            .components(separatedBy: "\n")
            .filter { line in
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                return !trimmedLine.hasPrefix("do(") && !trimmedLine.hasPrefix("finish(")
            }
            .joined(separator: "\n")
        let systemPrompt = """
            You are the Language Enhancer for an Android phone agent.
            Your only job is to generate the exact final text that should be typed into the current input field.

            Hard rules:
            - Return ONLY the final text.
            - No explanations.
            - No markdown.
            - No labels such as USER PROMPT, CONTEXT, RESULT, or IMPORTANT.
            - No surrounding quotes unless the text itself truly requires quotes.
            - NEVER return action syntax like do(action=...) or finish(message=...). Only return the plain text to type.
            - Keep the output grounded in the user's request and the AutoGLM screen context.
            - Use the device persona as required context to deepen wording and tone checks while staying faithful to the user's intent.
            - Preserve exact usernames, emails, URLs, OTP codes, numbers, hashtags, and search terms when they are already provided.
            - Decide yourself whether the draft text should be kept exactly or improved; if it is already correct, return it unchanged.
            - Always keep the same language as the user's request.
            - Never return Chinese unless the user's request is explicitly in Chinese.
            - If the AutoGLM draft mixes languages, rewrite it so the final text matches the user's request language.
            - If the user asked for a caption, reply, search query, or short message, generate a concise natural result in the requested or implied language.
            """

        let conversationSection = conversationContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "[No prior conversation steps available.]"
            : conversationContext
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

            Conversation history (previous steps taken by the agent):
            \(conversationSection)

            AutoGLM reasoning (current step):
            \(sanitizedThinking)

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
        return trimmed.isEmpty
            ? "No extra device notes or safety rules were provided for this device." : trimmed
    }

    private func requestPlainText(
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int,
        preserveMultiline: Bool = false
    ) async throws -> String {
        let requestTargets = configuration.languageEnhancerRequestTargets
        guard !requestTargets.isEmpty else {
            throw NativeAgentError.invalidConfiguration(
                "Please enter a valid Language Enhancer server URL in Settings → AI Models.")
        }

        var lastError: Error = NativeAgentError.invalidConfiguration(
            "No usable Language Enhancer endpoint was found.")

        for target in requestTargets {
            let endpoints = candidateURLs(from: target.baseURL, path: "chat/completions")
            guard !endpoints.isEmpty else { continue }

            let payload: [String: Any] = [
                "model": target.model,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": userPrompt],
                ],
                "max_tokens": maxTokens,
                "temperature": 0.2,
                "top_p": 0.7,
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
                        throw NativeAgentError.server(
                            "The \(target.label) returned an invalid response.")
                    }

                    if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                        throw NativeAgentError.server(
                            "Authentication failed for \(target.label). Check the API key in Settings → AI Models."
                        )
                    }

                    guard (200...299).contains(httpResponse.statusCode) else {
                        let errorMessage =
                            Self.extractErrorMessage(from: data)
                            ?? "\(target.label) returned HTTP \(httpResponse.statusCode)."
                        throw NativeAgentError.server(errorMessage)
                    }

                    if let content = Self.extractContent(from: data), !content.isEmpty {
                        return preserveMultiline
                            ? Self.cleanedRichText(content) : Self.cleanedText(content)
                    }

                    throw NativeAgentError.server(
                        "The \(target.label) returned an empty completion.")
                } catch {
                    lastError = NativeAgentError.server(
                        "\(target.label) failed at \(endpoint.absoluteString): \(error.localizedDescription)"
                    )
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
            let looksLikeIPAddress =
                trimmed.range(of: #"^\d{1,3}(\.\d{1,3}){3}(:\d+)?/?$"#, options: .regularExpression)
                != nil
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
            candidates.append(
                baseURL.appendingPathComponent("v1").appendingPathComponent(cleanPath))
            candidates.append(baseURL.appendingPathComponent(cleanPath))
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0.absoluteString).inserted }
    }

    private static func extractContent(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = object["choices"] as? [[String: Any]],
            let first = choices.first
        else {
            return String(data: data, encoding: .utf8)?.trimmingCharacters(
                in: .whitespacesAndNewlines)
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

        text =
            text
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
            #"(?i)^rewritten\s*(task|prompt)\s*:\s*"#,
        ]

        for pattern in cleanupPatterns {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if text.contains("\n") {
            let lines =
                text
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            if let bestLine = lines.last(where: {
                let lower = $0.lowercased()
                return !lower.hasPrefix("important") && !lower.hasPrefix("text result")
                    && !lower.hasPrefix("result")
            }) {
                text = bestLine
            }
        }

        if (text.hasPrefix("\"") && text.hasSuffix("\""))
            || (text.hasPrefix("'") && text.hasSuffix("'"))
        {
            text.removeFirst()
            text.removeLast()
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8)?.trimmingCharacters(
                in: .whitespacesAndNewlines)
        }

        if let errorObject = object["error"] as? [String: Any],
            let message = errorObject["message"] as? String
        {
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
                    "image_url": [
                        "url": "data:\(mimeType);base64,\(imageBase64)",
                        "detail": "high",
                    ],
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
        case .unknown(let name, _):
            return name
        }
    }

    var logDescription: String {
        switch self {
        case .finish(let message):
            return "finish(\(message ?? "done"))"
        case .listApp(let query):
            return "ListApp(\(query ?? "all"))"
        case .launch(let app):
            return "Launch \(app)"
        case .tap(let point, _):
            return "Tap [\(point.x), \(point.y)]"
        case .doubleTap(let point):
            return "Double Tap [\(point.x), \(point.y)]"
        case .longPress(let point):
            return "Long Press [\(point.x), \(point.y)]"
        case .swipe(let start, let end):
            return "Swipe [\(start.x), \(start.y)] → [\(end.x), \(end.y)]"
        case .type(let text, let enhance):
            return enhance
                ? "Type \(text.debugDescription) [enhance]" : "Type \(text.debugDescription)"
        case .back:
            return "Back"
        case .home:
            return "Home"
        case .wait(let seconds):
            return "Wait \(String(format: "%.1f", seconds))s"
        case .takeOver(let message):
            return "Take over: \(message ?? "manual action required")"
        case .unknown(let name, let raw):
            return "\(name) → \(raw)"
        }
    }
}

private struct NativeRelativePoint {
    let x: Int
    let y: Int
}

private enum NativeActionParser {
    /// Convert from the shared `AIModelAction` to the internal `NativeAgentAction`.
    static func fromModelAction(_ action: AIModelAction) -> NativeAgentAction {
        switch action {
        case .finish(let message): return .finish(message: message)
        case .listApp(let query): return .listApp(query: query)
        case .launch(let app): return .launch(app: app)
        case .tap(let x, let y, let message):
            return .tap(point: NativeRelativePoint(x: x, y: y), message: message)
        case .doubleTap(let x, let y): return .doubleTap(point: NativeRelativePoint(x: x, y: y))
        case .longPress(let x, let y): return .longPress(point: NativeRelativePoint(x: x, y: y))
        case .swipe(let sx, let sy, let ex, let ey):
            return .swipe(
                start: NativeRelativePoint(x: sx, y: sy), end: NativeRelativePoint(x: ex, y: ey))
        case .type(let text, let enhance): return .type(text: text, enhance: enhance)
        case .back: return .back
        case .home: return .home
        case .wait(let seconds): return .wait(seconds: seconds)
        case .takeOver(let message): return .takeOver(message: message)
        case .unknown(let name, let raw): return .unknown(name: name, raw: raw)
        }
    }

    static func parse(_ rawResponse: String) -> NativeAgentAction {
        let trimmed = extractAnswer(from: rawResponse).trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .finish(message: "The model returned an empty response.")
        }

        if trimmed.hasPrefix("finish") {
            return .finish(message: AIModelParsingUtils.extractFinishMessage(from: trimmed))
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
                let end = point(named: "end", in: trimmed)
            {
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
            let y = Int(text[yRange])
        else {
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
            let captureRange = Range(match.range(at: 1), in: text)
        else {
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

private enum NativeAgentError: LocalizedError {
    case invalidConfiguration(String)
    case server(String)
    case maxStepsReached

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return message
        case .server(let message):
            return message
        case .maxStepsReached:
            return "The task stopped after reaching the maximum number of agent steps."
        }
    }
}

// MARK: - Agent Chat Log Components

private enum AgentChatEntryKind {
    case setup  // initial setup lines
    case aiResponse  // the AI thinking text (bubble)
    case actionToast  // "Triggering Action Tap [897,897]"
    case infoToast  // "Info: Opened Instagram..."
    case finishBubble  // the finish message shown as a bubble
    case success
    case error
    case warning
    case cancelled
}

private struct AgentChatEntry: Identifiable {
    let id = UUID()
    let kind: AgentChatEntryKind
    let text: String
    let appName: String?  // e.g. "Instagram"
    let actionLabel: String?  // e.g. "Tapping"
    let stepNumber: Int?
    let screenshotData: Data?  // screenshot captured at this step
    let compressionInfo: String?  // e.g. "1.20 MB → 198.5 KB"
}

private func parseLogIntoChatEntries(_ logText: String, screenshotsByStep: [Int: Data] = [:]) -> [AgentChatEntry] {
    let lines = logText.components(separatedBy: "\n")
    var entries: [AgentChatEntry] = []
    var setupBuffer = ""
    var thinkingBuffer = ""
    var currentApp: String? = nil
    var currentAction: String? = nil
    var currentStep: Int? = nil
    var currentCompressionInfo: String? = nil
    var inThinking = false
    var didEmitSetup = false

    func flushSetup() {
        let trimmed = setupBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries.append(
            AgentChatEntry(
                kind: .setup, text: trimmed, appName: nil, actionLabel: nil, stepNumber: nil, screenshotData: nil, compressionInfo: nil))
        setupBuffer = ""
        didEmitSetup = true
    }

    func flushThinking() {
        let trimmed = thinkingBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Strip leading "Thinking:\n" or "Thinking:" prefix
        var cleanText = trimmed
        if cleanText.hasPrefix("Thinking:") {
            cleanText = String(cleanText.dropFirst(9)).trimmingCharacters(
                in: .whitespacesAndNewlines)
        }
        if cleanText.hasPrefix("Think:") {
            cleanText = String(cleanText.dropFirst(6)).trimmingCharacters(
                in: .whitespacesAndNewlines)
        }
        // Strip XML-style thinking tags from AutoGLM-style responses
        cleanText =
            cleanText
            .replacingOccurrences(of: "<think>", with: "")
            .replacingOccurrences(of: "</think>", with: "")
            .replacingOccurrences(of: "<answer>", with: "")
            .replacingOccurrences(of: "</answer>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else {
            thinkingBuffer = ""
            inThinking = false
            return
        }
        let appLabel = friendlyAppName(currentApp)
        let stepScreenshot = currentStep.flatMap { screenshotsByStep[$0] }
        entries.append(
            AgentChatEntry(
                kind: .aiResponse,
                text: cleanText,
                appName: appLabel,
                actionLabel: currentAction,
                stepNumber: currentStep,
                screenshotData: stepScreenshot,
                compressionInfo: currentCompressionInfo
            ))
        thinkingBuffer = ""
        inThinking = false
        currentAction = nil
        currentCompressionInfo = nil
    }

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Separator line
        if trimmed.hasPrefix("=====") {
            if inThinking { flushThinking() }
            if !didEmitSetup { flushSetup() }
            continue
        }

        // Step line
        if trimmed.hasPrefix("Step "), trimmed.contains("/") {
            if inThinking { flushThinking() }
            if !didEmitSetup { flushSetup() }
            // Extract step number
            let parts = trimmed.dropFirst(5).components(separatedBy: "/")
            currentStep = Int(parts.first ?? "")
            continue
        }

        // Current app line
        if trimmed.hasPrefix("Current app:") {
            let app = String(trimmed.dropFirst(12)).trimmingCharacters(in: .whitespacesAndNewlines)
            currentApp = app.isEmpty ? nil : app
            continue
        }

        // Thinking start
        if trimmed.hasPrefix("Thinking:") || trimmed.hasPrefix("Think:") {
            if inThinking { flushThinking() }
            inThinking = true
            thinkingBuffer = trimmed
            continue
        }

        // Action line
        if trimmed.hasPrefix("Action:") || trimmed.hasPrefix("action:") {
            if inThinking { flushThinking() }
            let rawAction = String(trimmed.dropFirst(7)).trimmingCharacters(
                in: .whitespacesAndNewlines)
            currentAction = friendlyActionVerb(rawAction)
            // For finish actions, show the clean message instead of the raw format
            let toastText: String
            if rawAction.lowercased().hasPrefix("finish") {
                let cleanMsg = AIModelParsingUtils.stripFinishWrapper(rawAction)
                toastText = "Triggering finish(\(cleanMsg))"
            } else {
                toastText = "Triggering \(rawAction)"
            }
            entries.append(
                AgentChatEntry(
                    kind: .actionToast, text: toastText, appName: friendlyAppName(currentApp),
                    actionLabel: nil, stepNumber: currentStep, screenshotData: nil, compressionInfo: nil))
            continue
        }

        // Info line
        if trimmed.hasPrefix("Info:") {
            let msg = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !msg.isEmpty {
                // Capture screenshot compression info for the next AI response bubble
                if msg.hasPrefix("Screenshot ") {
                    currentCompressionInfo = String(msg.dropFirst(11))
                    continue
                }
                entries.append(
                    AgentChatEntry(
                        kind: .infoToast, text: msg, appName: nil, actionLabel: nil,
                        stepNumber: currentStep, screenshotData: nil, compressionInfo: nil))
            }
            continue
        }

        // Success
        if trimmed.hasPrefix("Success:") {
            if inThinking { flushThinking() }
            let finishText = String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
            entries.append(
                AgentChatEntry(
                    kind: .finishBubble,
                    text: finishText, appName: nil, actionLabel: nil,
                    stepNumber: nil, screenshotData: nil, compressionInfo: nil))
            continue
        }

        // Error
        if trimmed.hasPrefix("Error:") {
            if inThinking { flushThinking() }
            entries.append(
                AgentChatEntry(
                    kind: .error,
                    text: String(trimmed.dropFirst(6)).trimmingCharacters(
                        in: .whitespacesAndNewlines), appName: nil, actionLabel: nil,
                    stepNumber: nil, screenshotData: nil, compressionInfo: nil))
            continue
        }

        // Warning
        if trimmed.hasPrefix("Warning:") {
            if inThinking { flushThinking() }
            entries.append(
                AgentChatEntry(
                    kind: .warning,
                    text: String(trimmed.dropFirst(8)).trimmingCharacters(
                        in: .whitespacesAndNewlines), appName: nil, actionLabel: nil,
                    stepNumber: nil, screenshotData: nil, compressionInfo: nil))
            continue
        }

        // Cancelled
        if trimmed == "Run cancelled." || trimmed == "Cancel requested by user." {
            if inThinking { flushThinking() }
            entries.append(
                AgentChatEntry(
                    kind: .cancelled, text: trimmed, appName: nil, actionLabel: nil, stepNumber: nil,
                    screenshotData: nil, compressionInfo: nil
                ))
            continue
        }

        // Accumulate into appropriate buffer
        if inThinking {
            thinkingBuffer += "\n" + line
        } else if !didEmitSetup {
            if !setupBuffer.isEmpty { setupBuffer += "\n" }
            setupBuffer += line
        }
    }

    if inThinking { flushThinking() }
    if !didEmitSetup { flushSetup() }

    return entries
}

private func friendlyAppName(_ packageName: String?) -> String? {
    guard let pkg = packageName, !pkg.isEmpty, pkg != "Unknown" else { return nil }
    // Extract last meaningful part: com.instagram.android → Instagram
    let parts = pkg.components(separatedBy: ".")
    let candidates = parts.filter {
        $0 != "com" && $0 != "android" && $0 != "app" && $0 != "mobile" && $0 != "org"
            && $0 != "net"
    }
    if let name = candidates.first {
        return name.prefix(1).uppercased() + name.dropFirst()
    }
    return pkg
}

private func friendlyActionVerb(_ rawAction: String) -> String {
    let lower = rawAction.lowercased()
    if lower.contains("tap") { return "Tapping" }
    if lower.contains("swipe") || lower.contains("scroll") { return "Scrolling" }
    if lower.contains("type") || lower.contains("input") { return "Typing" }
    if lower.contains("launch") || lower.contains("open") { return "Launching" }
    if lower.contains("back") { return "Going Back" }
    if lower.contains("home") { return "Going Home" }
    if lower.contains("long") { return "Long Pressing" }
    if lower.contains("double") { return "Double Tapping" }
    if lower.contains("wait") { return "Waiting" }
    if lower.contains("list") { return "Listing Apps" }
    if lower.contains("finish") { return "Finishing" }
    return "Acting"
}

private struct AgentChatLogView: View {
    let logText: String
    let screenshotsByStep: [Int: Data]

    private var entries: [AgentChatEntry] {
        parseLogIntoChatEntries(logText, screenshotsByStep: screenshotsByStep)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(entries) { entry in
                switch entry.kind {
                case .setup:
                    AgentSetupEntry(text: entry.text)
                case .aiResponse:
                    AgentResponseBubble(entry: entry)
                case .actionToast:
                    AgentActionToast(text: entry.text, appName: entry.appName)
                case .infoToast:
                    AgentInfoToast(text: entry.text)
                case .finishBubble:
                    AgentFinishBubble(text: entry.text)
                case .success:
                    AgentStatusEntry(text: entry.text, icon: "checkmark.circle.fill", color: .green)
                case .error:
                    AgentStatusEntry(
                        text: entry.text, icon: "exclamationmark.triangle.fill", color: .red)
                case .warning:
                    AgentStatusEntry(
                        text: entry.text, icon: "exclamationmark.triangle", color: .orange)
                case .cancelled:
                    AgentStatusEntry(text: entry.text, icon: "stop.circle", color: .secondary)
                }
            }
        }
        .padding(16)
    }
}

// MARK: - Setup entry (small muted text)

private struct AgentSetupEntry: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        colorScheme == .dark ? Color.white.opacity(0.03) : Color.black.opacity(0.02)
                    )
            )
    }
}

// MARK: - AI Response bubble

private struct AgentResponseBubble: View {
    let entry: AgentChatEntry
    @Environment(\.colorScheme) private var colorScheme
    @State private var isScreenshotExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header: App · Action · Step
            HStack(spacing: 6) {
                if let app = entry.appName {
                    Text(app)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                if let action = entry.actionLabel {
                    if entry.appName != nil {
                        Text("·")
                            .font(.system(size: 10))
                            .foregroundStyle(.quaternary)
                    }

                    Text(action)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.accentColor.opacity(0.80))
                }

                if let step = entry.stepNumber {
                    Spacer()
                    Text("Step \(step)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.quaternary)
                }
            }
            .padding(.horizontal, 4)

            // Screenshot + Bubble
            HStack(alignment: .top, spacing: 8) {
                // Screenshot thumbnail
                if let screenshotData = entry.screenshotData,
                   let nsImage = NSImage(data: screenshotData) {
                    VStack(spacing: 3) {
                        Button {
                            isScreenshotExpanded.toggle()
                        } label: {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: isScreenshotExpanded ? 240 : 64, height: isScreenshotExpanded ? 480 : 114)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(
                                            colorScheme == .dark
                                                ? Color.white.opacity(0.10)
                                                : Color.black.opacity(0.08),
                                            lineWidth: 0.5
                                        )
                                )
                                .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)
                        }
                        .buttonStyle(.plain)
                        .animation(.easeInOut(duration: 0.2), value: isScreenshotExpanded)

                        if let info = entry.compressionInfo {
                            Text(info)
                                .font(.system(size: 8, weight: .medium, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                // Text bubble
                Text(entry.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(responseBubbleBackground)

                Spacer(minLength: 40)
            }
        }
    }

    @ViewBuilder
    private var responseBubbleBackground: some View {
        let cr: CGFloat = 14
        ZStack {
            RoundedRectangle(cornerRadius: cr, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.05) : Color.white.opacity(0.55))

            RoundedRectangle(cornerRadius: cr, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            colorScheme == .dark
                                ? Color.white.opacity(0.03) : Color.white.opacity(0.40),
                            Color.clear,
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            RoundedRectangle(cornerRadius: cr, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            colorScheme == .dark
                                ? Color.white.opacity(0.12) : Color.white.opacity(0.80),
                            colorScheme == .dark
                                ? Color.white.opacity(0.03) : Color.black.opacity(0.04),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        }
    }
}

// MARK: - Action toast

private struct AgentActionToast: View {
    let text: String
    let appName: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.blue)

            Text(text)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(colorScheme == .dark ? Color.blue.opacity(0.08) : Color.blue.opacity(0.06))
                .overlay(
                    Capsule()
                        .stroke(Color.blue.opacity(0.15), lineWidth: 0.5)
                )
        )
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 2)
    }
}

// MARK: - Info toast

private struct AgentInfoToast: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.cyan)

            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(colorScheme == .dark ? Color.cyan.opacity(0.06) : Color.cyan.opacity(0.04))
                .overlay(
                    Capsule()
                        .stroke(Color.cyan.opacity(0.12), lineWidth: 0.5)
                )
        )
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 1)
    }
}

// MARK: - Finish message bubble

private struct AgentFinishBubble: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.green)
                .padding(.top, 10)

            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(colorScheme == .dark
                                ? Color.green.opacity(0.08)
                                : Color.green.opacity(0.06))

                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(
                                colorScheme == .dark
                                    ? Color.green.opacity(0.15)
                                    : Color.green.opacity(0.20),
                                lineWidth: 0.5
                            )
                    }
                )

            Spacer(minLength: 40)
        }
    }
}

// MARK: - Status entry (success/error/warning/cancelled)

private struct AgentStatusEntry: View {
    let text: String
    let icon: String
    let color: Color
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(color)

            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(color)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(color.opacity(colorScheme == .dark ? 0.06 : 0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(color.opacity(0.12), lineWidth: 0.5)
                )
        )
        .padding(.vertical, 2)
    }
}

private struct AgentDeviceTab: View {
    let title: String
    let isSelected: Bool
    let run: DeviceAgentRunSnapshot
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var tabColor: Color {
        if run.isRunning { return .orange }
        if let exitCode = run.lastExitCode, exitCode != 0 { return .red }
        if run.lastExitCode == 0 { return .green }
        return .secondary
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(
                    .system(
                        size: 11, weight: isSelected ? .semibold : .regular, design: .monospaced)
                )
                .foregroundStyle(isSelected ? .primary : .secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    ZStack {
                        Capsule()
                            .fill(tabColor.opacity(isSelected ? 0.20 : 0.08))
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        colorScheme == .dark
                                            ? Color.white.opacity(0.04) : Color.white.opacity(0.30),
                                        Color.clear,
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                        Capsule()
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        tabColor.opacity(isSelected ? 0.30 : 0.12),
                                        tabColor.opacity(0.06),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.5
                            )
                    }
                )
        }
        .buttonStyle(.plain)
    }
}

private struct AgentEmptyState: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 60)

            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 34, weight: .ultraLight))
                .foregroundStyle(.quaternary)

            VStack(spacing: 4) {
                Text("No AI Activity Yet")
                    .font(.system(size: 14, weight: .medium))

                Text("Agent logs will appear here as chat messages when a task runs.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            guard let scrollView = enclosingScrollView ?? superview?.enclosingScrollView else {
                return
            }

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
                let documentView = scrollView.documentView
            else { return }

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
        if let lastExitCode = currentRun?.lastExitCode ?? runner.lastExitCode, lastExitCode != 0 {
            return .red
        }
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

    private var displayedScreenshotsByStep: [Int: Data] {
        currentRun?.screenshotsByStep ?? [:]
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

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Status bar
            HStack(alignment: .center, spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusColor.opacity(0.50), radius: 4, x: 0, y: 0)

                Text(runner.statusMessage)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if runner.isRunning {
                    Button(runner.deviceRuns.count > 1 ? "Stop All" : "Stop") {
                        runner.cancel()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(Color.red.opacity(0.10))
                            .overlay(
                                Capsule()
                                    .stroke(Color.red.opacity(0.18), lineWidth: 0.5)
                            )
                    )
                }

                Button("Clear") {
                    runner.clearLog()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(
                            colorScheme == .dark
                                ? Color.white.opacity(0.06) : Color.black.opacity(0.04)
                        )
                        .overlay(
                            Capsule()
                                .stroke(
                                    colorScheme == .dark
                                        ? Color.white.opacity(0.08) : Color.black.opacity(0.06),
                                    lineWidth: 0.5)
                        )
                )
                .disabled(runner.isRunning)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                statusColor.opacity(0.06)
                    .background(
                        colorScheme == .dark ? Color.white.opacity(0.02) : Color.white.opacity(0.30)
                    )
            )

            Rectangle()
                .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.06))
                .frame(height: 0.5)

            // Device tabs
            if runner.deviceRuns.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(runner.deviceRuns) { run in
                            let isSelected = runner.selectedDeviceRunID == run.deviceID
                            AgentDeviceTab(
                                title: tabTitle(for: run),
                                isSelected: isSelected,
                                run: run
                            ) {
                                runner.selectedDeviceRunID = run.deviceID
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }

                Rectangle()
                    .fill(
                        colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.06)
                    )
                    .frame(height: 0.5)
            }

            // Per-device header (only when multiple devices)
            if let currentRun, runner.deviceRuns.count > 1 {
                HStack(spacing: 8) {
                    Text("Viewing \(tabTitle(for: currentRun))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)

                    Spacer()

                    if currentRun.isRunning {
                        Button("Stop") {
                            runner.cancelDevice(currentRun.deviceID)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Rectangle()
                    .fill(
                        colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.06)
                    )
                    .frame(height: 0.5)
            }

            // Engine command
            if !(currentRun?.lastCommand ?? runner.lastCommand).isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ENGINE")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .tracking(0.5)

                    Text(verbatim: currentRun?.lastCommand ?? runner.lastCommand)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(
                                        colorScheme == .dark
                                            ? Color.white.opacity(0.04) : Color.white.opacity(0.50))

                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(
                                        LinearGradient(
                                            colors: [
                                                colorScheme == .dark
                                                    ? Color.white.opacity(0.10)
                                                    : Color.white.opacity(0.70),
                                                colorScheme == .dark
                                                    ? Color.white.opacity(0.03)
                                                    : Color.black.opacity(0.04),
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        lineWidth: 0.5
                                    )
                            }
                        )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Rectangle()
                    .fill(
                        colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.06)
                    )
                    .frame(height: 0.5)
            }

            // User prompt
            if !(currentRun?.lastTask ?? runner.lastTask).isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PROMPT")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .tracking(0.5)

                    Text(verbatim: currentRun?.lastTask ?? runner.lastTask)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(
                                        colorScheme == .dark
                                            ? Color.white.opacity(0.04) : Color.white.opacity(0.50))

                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(
                                        LinearGradient(
                                            colors: [
                                                colorScheme == .dark
                                                    ? Color.white.opacity(0.10)
                                                    : Color.white.opacity(0.70),
                                                colorScheme == .dark
                                                    ? Color.white.opacity(0.03)
                                                    : Color.black.opacity(0.04),
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        lineWidth: 0.5
                                    )
                            }
                        )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Rectangle()
                    .fill(
                        colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.06)
                    )
                    .frame(height: 0.5)
            }

            // Chat-style log view
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if displayedLogText == "No AI activity yet." {
                            AgentEmptyState()
                        } else {
                            AgentChatLogView(logText: displayedLogText, screenshotsByStep: displayedScreenshotsByStep)
                        }

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
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .background(
            VisualEffectBackground(material: .sidebar, blendingMode: .behindWindow)
        )
    }
}
