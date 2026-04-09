import Foundation

@MainActor
final class AudioTranscriptionStore: ObservableObject {
    static let shared = AudioTranscriptionStore()

    @Published private(set) var isListening = false
    @Published private(set) var activeDeviceID: String?
    @Published var statusMessage: String = "Ready for faster-whisper."
    @Published var transcriptText: String = ""
    @Published var inputDeviceHint: String = {
        let stored = UserDefaults.standard.string(forKey: "audio.transcription.inputDeviceHint")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stored.isEmpty { return stored }
        return ProcessInfo.processInfo.environment["AIPHONE_AUDIO_INPUT_DEVICE"] ?? ""
    }() {
        didSet { UserDefaults.standard.set(inputDeviceHint, forKey: "audio.transcription.inputDeviceHint") }
    }
    @Published var whisperModel: String = {
        let stored = UserDefaults.standard.string(forKey: "audio.transcription.whisperModel")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stored.isEmpty { return stored }
        let value = ProcessInfo.processInfo.environment["AIPHONE_FASTER_WHISPER_MODEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "base" : value
    }() {
        didSet { UserDefaults.standard.set(whisperModel, forKey: "audio.transcription.whisperModel") }
    }
    @Published var huggingFaceToken: String = {
        let candidates = [
            UserDefaults.standard.string(forKey: "audio.transcription.hfToken"),
            ProcessInfo.processInfo.environment["AIPHONE_HF_TOKEN"],
            ProcessInfo.processInfo.environment["HF_TOKEN"],
            ProcessInfo.processInfo.environment["HUGGINGFACE_TOKEN"],
            ProcessInfo.processInfo.environment["HF_HUB_TOKEN"]
        ]

        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
    }() {
        didSet { UserDefaults.standard.set(huggingFaceToken, forKey: "audio.transcription.hfToken") }
    }
    @Published private(set) var lastCommand: String = ""

    let recommendedModels = ["tiny", "base", "small", "medium"]

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutBuffer = ""
    private var stderrBuffer = ""

    func toggle(for deviceID: String) {
        if isListening, activeDeviceID == deviceID {
            stopListening(for: deviceID)
        } else {
            startListening(for: deviceID)
        }
    }

    func startListening(for deviceID: String) {
        if isListening, activeDeviceID == deviceID {
            return
        }

        stopListening()

        guard let scriptURL = resolveWorkerScriptURL() else {
            statusMessage = "`faster_whisper_stream.py` was not found in the repo."
            return
        }

        let pythonCommand = resolvePythonCommand(scriptURL: scriptURL)
        let trimmedModel = whisperModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "base"
            : whisperModel.trimmingCharacters(in: .whitespacesAndNewlines)

        var arguments = [
            pythonCommand,
            "-u",
            scriptURL.path,
            "--model", trimmedModel,
            "--compute-type", "int8",
            "--sample-rate", "16000",
            "--phrase-window", "6.0",
            "--transcribe-every", "1.2"
        ]

        let trimmedInputHint = inputDeviceHint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedInputHint.isEmpty {
            arguments.append(contentsOf: ["--input-device", trimmedInputHint])
        }

        let trimmedHFToken = huggingFaceToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHFToken.isEmpty {
            arguments.append(contentsOf: ["--hf-token", trimmedHFToken])
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = scriptURL.deletingLastPathComponent()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        self.process = process
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        self.stdoutBuffer = ""
        self.stderrBuffer = ""
        self.activeDeviceID = deviceID
        self.isListening = true
        self.transcriptText = ""
        self.statusMessage = "Starting faster-whisper…"
        self.lastCommand = (["/usr/bin/env"] + arguments).joined(separator: " ")

        bindReadabilityHandlers(stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)

        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self else { return }
                self.clearReadabilityHandlers()
                self.process = nil
                self.stdoutPipe = nil
                self.stderrPipe = nil
                self.isListening = false
                self.activeDeviceID = nil

                if process.terminationReason == .exit, process.terminationStatus == 0 {
                    if self.statusMessage == "Stopping transcription…" {
                        self.statusMessage = "Transcription stopped."
                    } else {
                        self.statusMessage = "Transcription finished."
                    }
                } else if self.statusMessage == "Stopping transcription…" {
                    self.statusMessage = "Transcription stopped."
                } else if self.statusMessage == "Listening for device audio…" || self.statusMessage == "Starting faster-whisper…" {
                    self.statusMessage = "Transcription exited with code \(process.terminationStatus)."
                }
            }
        }

        do {
            try process.run()
            statusMessage = "Listening for device audio…"
        } catch {
            clearReadabilityHandlers()
            self.process = nil
            self.stdoutPipe = nil
            self.stderrPipe = nil
            self.isListening = false
            self.activeDeviceID = nil
            self.statusMessage = "Failed to start faster-whisper: \(error.localizedDescription)"
        }
    }

    func stopListening(for deviceID: String? = nil) {
        guard let process else { return }
        if let deviceID, activeDeviceID != deviceID {
            return
        }

        statusMessage = "Stopping transcription…"
        clearReadabilityHandlers()

        if process.isRunning {
            process.terminate()
        }

        self.process = nil
        self.stdoutPipe = nil
        self.stderrPipe = nil
        self.isListening = false
        self.activeDeviceID = nil
    }

    private func bindReadabilityHandlers(stdoutPipe: Pipe, stderrPipe: Pipe) {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }

            guard let self, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self.consume(text: text, isError: false)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }

            guard let self, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self.consume(text: text, isError: true)
            }
        }
    }

    private func clearReadabilityHandlers() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
    }

    private func consume(text: String, isError: Bool) {
        if isError {
            stderrBuffer.append(text)
            processBufferedLines(isError: true)
        } else {
            stdoutBuffer.append(text)
            processBufferedLines(isError: false)
        }
    }

    private func processBufferedLines(isError: Bool) {
        if isError {
            while let range = stderrBuffer.range(of: "\n") {
                let line = String(stderrBuffer[..<range.lowerBound])
                stderrBuffer.removeSubrange(stderrBuffer.startIndex..<range.upperBound)
                handleWorkerLine(line, isError: true)
            }
        } else {
            while let range = stdoutBuffer.range(of: "\n") {
                let line = String(stdoutBuffer[..<range.lowerBound])
                stdoutBuffer.removeSubrange(stdoutBuffer.startIndex..<range.upperBound)
                handleWorkerLine(line, isError: false)
            }
        }
    }

    private func handleWorkerLine(_ line: String, isError: Bool) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if isError {
            statusMessage = trimmed
            return
        }

        guard let data = trimmed.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = payload["type"] as? String else {
            statusMessage = trimmed
            return
        }

        switch type {
        case "status":
            statusMessage = payload["message"] as? String ?? statusMessage

        case "partial", "segment":
            let fullText = (payload["full_text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let emittedText = (payload["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

            if let emittedText, !emittedText.isEmpty {
                appendTranscript(emittedText)
            } else if let fullText, !fullText.isEmpty {
                transcriptText = fullText
            }

            if transcriptText.count > 24_000 {
                transcriptText.removeFirst(transcriptText.count - 20_000)
            }

            let language = (payload["language"] as? String)?.uppercased() ?? "AUTO"
            statusMessage = "Transcribing (\(language))…"

        case "error":
            statusMessage = payload["message"] as? String ?? "Audio transcription failed."

        default:
            statusMessage = trimmed
        }
    }

    private func appendTranscript(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if transcriptText.isEmpty {
            transcriptText = trimmed
        } else if transcriptText == trimmed || transcriptText.hasSuffix(trimmed) {
            return
        } else {
            transcriptText += (transcriptText.hasSuffix("\n") ? "" : "\n") + trimmed
        }
    }

    private func resolveWorkerScriptURL() -> URL? {
        let sourceAnchoredRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        let candidates = [
            sourceAnchoredRoot.appendingPathComponent("python/faster_whisper_stream.py"),
            currentDirectory.appendingPathComponent("python/faster_whisper_stream.py").standardizedFileURL,
            currentDirectory.appendingPathComponent("aiphone/python/faster_whisper_stream.py").standardizedFileURL
        ]

        return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }

    private func resolvePythonCommand(scriptURL: URL) -> String {
        if let configured = ProcessInfo.processInfo.environment["AIPHONE_PYTHON"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            return configured
        }

        let helperPython = scriptURL
            .deletingLastPathComponent()
            .appendingPathComponent(".venv/bin/python")
            .path

        if FileManager.default.isExecutableFile(atPath: helperPython) {
            return helperPython
        }

        return "python3"
    }
}
