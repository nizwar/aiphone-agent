import Foundation
import NaturalLanguage

/// AutoGLM model provider — structured phone automation with <think>/<answer> format.
struct AutoGLMModelProvider: AIModelProvider {
    static let id = "autoglm"
    static let displayName = "AutoGLM"
    static let summary = "Phone automation agent from Open-AutoGLM. Uses structured action format with thinking."
    static let defaultModelName = "autoglm-phone-multilingual"
    static let builtInModels = ["autoglm-phone-multilingual"]
    static let hiddenModels: Set<String> = ["autoglm-phone-9b-multilingual"]

    init() {}

    // MARK: - System Prompt

    func systemPrompt(
        userTask: String,
        devicePersona: String,
        preferredApps: String,
        deviceNotes: String,
        hasLanguageEnhancer: Bool,
        detectedLanguage: String? = nil
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd, EEEE"
        let formattedDate = formatter.string(from: Date())
        let languageName = detectedLanguage ?? Self.inferredLanguageName(from: userTask)
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
        \(hasLanguageEnhancer ? "- Type with optional refinement: <answer>do(action=\"Type\", text=\"short draft or intent\", enhance=true)</answer>" : "")
        - Swipe: <answer>do(action="Swipe", start=[x1,y1], end=[x2,y2])</answer>
        - Long Press: <answer>do(action="Long Press", element=[x,y])</answer>
        - List installed apps: <answer>do(action="ListApp", query="Instagram")</answer>
        - Launch: <answer>do(action="Launch", app="YouTube")</answer>
        - Back: <answer>do(action="Back")</answer>
        - Home: <answer>do(action="Home")</answer>
        - Wait: <answer>do(action="Wait", duration="5")</answer>
        - Finish: <answer>finish(message="Task completed.")</answer>

        REMEMBER:
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
        - When you call `Launch(app="AppName")`, the system will automatically search installed apps and resolve the correct package. If multiple matches are found you will receive a list — pick the correct package and call `Launch(app="com.example.package")` with the exact package name.
        - If the system reports no match for a Launch, try a different app name or inform the user via finish.
        - NEVER call Launch with an empty app field. Always provide the app name or package name.
        - Use `Wait(duration="N")` (N in SECONDS) when you need to wait for content to load, a video to play, or any timed delay (in SECONDS, max 600). Do not use Wait unnecessarily — only when the task requires waiting (e.g. "watch for 3 minutes" → Wait 180 is too long, break into multiple waits).
        - For text entry, provide the exact final text whenever it is already known. The text MUST be in \(languageName) — NEVER use Chinese characters (汉字) in Type actions unless the user wrote in Chinese.
        \(hasLanguageEnhancer ? "- For every `Type(...)` action, the Language Enhancer will verify whether to keep or refine the text so it matches the user's language and intent." : "")
        - NEVER REPLY WITH CHINESE UNLESS THE USER'S REQUEST IS IN CHINESE. If the user's request is in Indonesian, reply in Indonesian. Otherwise, reply in English.
        - CRITICAL: Every piece of text you generate — thinking, finish messages, AND Type text — MUST be in \(languageName). Do NOT mix languages. Do NOT insert Chinese characters into \(languageName) text.
        """
    }

    // MARK: - User Message

    func userMessage(
        step: Int,
        task: String,
        screenInfo: String,
        devicePersona: String,
        preferredApps: String,
        deviceNotes: String
    ) -> String {
        let effectivePreferredApps = preferredApps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "No preferred apps were specified for this device."
            : preferredApps.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveDeviceNotes = deviceNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "No extra device notes or safety rules were provided for this device."
            : deviceNotes.trimmingCharacters(in: .whitespacesAndNewlines)

        if step == 1 {
            return """
            User request (keep the same language as this request; never switch to Chinese unless the request itself is Chinese):
            \(task)

            ** Device Preferences **

            Preferred apps: \(effectivePreferredApps)
            Device notes: \(effectiveDeviceNotes)

            ** Screen Info **

            \(screenInfo)
            """
        } else {
            return "** Screen Info **\n\n\(screenInfo)"
        }
    }

    // MARK: - Response Parsing

    func parseResponse(content: String) -> AIModelParsedResponse {
        // Prefer structured <think>/<answer> tags when present — they are authoritative
        // and avoid false splits when finish(message=) appears inside thinking text.
        if let thinkStart = content.range(of: "<think>"),
           let thinkEnd = content.range(of: "</think>"),
           let answerStart = content.range(of: "<answer>") {
            let thinking = String(content[thinkStart.upperBound..<thinkEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let actionEnd = content.range(of: "</answer>")?.lowerBound ?? content.endIndex
            let action = String(content[answerStart.upperBound..<actionEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            return AIModelParsedResponse(thinking: thinking, action: action)
        }

        if let range = content.range(of: "finish(message=") {
            return AIModelParsedResponse(
                thinking: String(content[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines),
                action: String(content[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        if let range = content.range(of: "do(action=") {
            return AIModelParsedResponse(
                thinking: String(content[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines),
                action: String(content[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        return AIModelParsedResponse(thinking: "", action: content.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Action Parsing

    func parseAction(from actionText: String) -> AIModelAction {
        let trimmed = AIModelParsingUtils.extractAnswer(from: actionText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .finish(message: "The model returned an empty response.")
        }

        if trimmed.hasPrefix("finish") {
            return .finish(message: AIModelParsingUtils.extractFinishMessage(from: trimmed))
        }

        guard trimmed.hasPrefix("do") else {
            return .finish(message: trimmed)
        }

        let actionName = AIModelParsingUtils.quotedValue(named: "action", in: trimmed) ?? "Unknown"

        switch actionName {
        case "ListApp", "ListApps", "List_App":
            return .listApp(
                query: AIModelParsingUtils.quotedValue(named: "query", in: trimmed)
                    ?? AIModelParsingUtils.quotedValue(named: "app", in: trimmed)
                    ?? AIModelParsingUtils.quotedValue(named: "text", in: trimmed)
            )
        case "Tap":
            if let point = AIModelParsingUtils.point(named: "element", in: trimmed) {
                return .tap(x: point.x, y: point.y, message: AIModelParsingUtils.quotedValue(named: "message", in: trimmed))
            }
        case "Double Tap":
            if let point = AIModelParsingUtils.point(named: "element", in: trimmed) {
                return .doubleTap(x: point.x, y: point.y)
            }
        case "Long Press":
            if let point = AIModelParsingUtils.point(named: "element", in: trimmed) {
                return .longPress(x: point.x, y: point.y)
            }
        case "Swipe":
            if let start = AIModelParsingUtils.point(named: "start", in: trimmed),
               let end = AIModelParsingUtils.point(named: "end", in: trimmed) {
                return .swipe(startX: start.x, startY: start.y, endX: end.x, endY: end.y)
            }
        case "Type", "Type_Name":
            return .type(
                text: AIModelParsingUtils.quotedValue(named: "text", in: trimmed) ?? "",
                enhance: true
            )
        case "Launch":
            return .launch(app: AIModelParsingUtils.quotedValue(named: "app", in: trimmed) ?? "")
        case "Back":
            return .back
        case "Home":
            return .home
        case "Wait":
            let seconds = AIModelParsingUtils.waitDuration(from: AIModelParsingUtils.quotedValue(named: "duration", in: trimmed))
            return .wait(seconds: seconds)
        case "Take_over":
            return .takeOver(message: AIModelParsingUtils.quotedValue(named: "message", in: trimmed))
        default:
            break
        }

        return .unknown(name: actionName, raw: trimmed)
    }
 
    // MARK: - Stream Markers

    var streamsReadableThinking: Bool { true }

    func firstActionMarkerRange(in text: String) -> Range<String.Index>? {
        let markers = ["finish(message=", "do(action="]
        for marker in markers {
            if let range = text.range(of: marker) {
                return range
            }
        }
        return nil
    }

    func endsWithPartialActionMarker(_ text: String) -> Bool {
        let markers = ["finish(message=", "do(action="]
        for marker in markers {
            for length in 1..<marker.count where text.hasSuffix(String(marker.prefix(length))) {
                return true
            }
        }
        return false
    }

    // MARK: - Assistant Context Format

    func formatAssistantContext(thinking: String, action: String) -> String {
        "<think>\(thinking)</think><answer>\(action)</answer>"
    }

    // MARK: - Request Parameters

    func requestParameters(modelName: String, maxTokens: Int, temperature: Double, topP: Double, frequencyPenalty: Double) -> [String: Any] {
        [
            "model": modelName,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "top_p": topP,
            "frequency_penalty": frequencyPenalty,
            "stream": true
        ]
    }

    // MARK: - Language Inference

    static func inferredLanguageName(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "English" }

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
}
