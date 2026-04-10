import Foundation
import NaturalLanguage

/// OpenAI-compatible model provider — vision-language model with JSON-structured responses.
/// Works with any OpenAI-compatible API endpoint. Uses structured JSON response format.
struct OpenAIModelProvider: AIModelProvider {
    static let id = "openai"
    static let displayName = "OpenAI"
    static let summary =
        "OpenAI-compatible vision-language model. JSON response mode."
    static let defaultModelName = "gpt-4o"
    static let builtInModels = ["gpt-4o", "gpt-4o-mini"]
    static let hiddenModels: Set<String> = []

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
        let languageName = detectedLanguage ?? AutoGLMModelProvider.inferredLanguageName(from: userTask)
        let thinkingMode = Self.selectThinkingMode(for: userTask)
        let personaText =
            devicePersona.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Careful, context-aware assistant who matches the user's language naturally."
            : devicePersona.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferredAppsText =
            preferredApps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "No preferred apps were specified for this device."
            : preferredApps.trimmingCharacters(in: .whitespacesAndNewlines)
        let notesText =
            deviceNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "No extra device notes or safety rules were provided for this device."
            : deviceNotes.trimmingCharacters(in: .whitespacesAndNewlines)

        return """
            The current date: \(formattedDate)
            # Setup
            You are an intelligent Android phone assistant with exceptional visual perception. You can see and understand screenshots of the phone screen with high accuracy. Given a screenshot at each step, you MUST first describe everything you see in thorough detail, then decide the best action.

            Your "thinking" field serves as your visual memory — since you cannot see previous screenshots, your detailed descriptions from past steps are your only record of what happened before. Be as descriptive as possible.

            User request language to keep: \(languageName)
            Thinking mode: \(thinkingMode == .deep ? "Deep (complex reasoning)" : "Fast (quick response)")
            Device persona for this run: \(personaText)
            Preferred apps for this device: \(preferredAppsText)
            Device notes and safety rules: \(notesText)

            # How to describe what you see (MANDATORY in "thinking")
            Every response MUST begin the "thinking" field with a detailed visual inventory of the current screenshot. Describe:
            - **Status bar**: time, battery level/icon, WiFi/signal bars, notification icons, any indicators
            - **Current app/screen**: which app is open, what screen or page within it
            - **All visible text**: read every piece of text on screen — titles, labels, buttons, captions, usernames, timestamps, counters, error messages, toast messages, placeholder text
            - **UI elements**: buttons (with their labels and states — enabled/disabled/highlighted), input fields (empty or filled, what text is in them), toggles, checkboxes, tabs (which is active), navigation bars, floating action buttons
            - **Images/media**: describe any photos, thumbnails, video players (playing/paused, progress), avatars, icons
            - **Layout**: top-to-bottom scan of the screen, noting the spatial arrangement and approximate coordinates of key elements
            - **Pop-ups/overlays**: any dialogs, permission requests, keyboard visible, dropdown menus, loading spinners
            - **Changes from previous step**: what changed since your last observation (if this is not the first step)

            After the visual description, explain your reasoning for the chosen action.

            Your response format must be structured as follows:
            {
                "thinking": "[DETAILED VISUAL DESCRIPTION + REASONING]",
                "action": { YOUR OPERATION CODE }
            }

            **tap** on a screen element:
            {"thinking": "...", "action": {"type": "tap", "element": [x, y]}}

            **tap** with a message/note:
            {"thinking": "...", "action": {"type": "tap", "element": [x, y], "message": "..."}}

            **type** text into a field:
            {"thinking": "...", "action": {"type": "type", "text": "hello world"}}

            \(hasLanguageEnhancer ? """
            **type** with language enhancer refinement:
            {"thinking": "...", "action": {"type": "type", "text": "draft text", "enhance": true}}
            """ : "")
            **swipe** from one point to another:
            {"thinking": "...", "action": {"type": "swipe", "start": [x1, y1], "end": [x2, y2]}}

            **long press** on a screen element:
            {"thinking": "...", "action": {"type": "long press", "element": [x, y]}}

            **double tap** on a screen element:
            {"thinking": "...", "action": {"type": "double tap", "element": [x, y]}}

            **list installed apps** (optionally filter by query):
            {"thinking": "...", "action": {"type": "listapp", "query": "instagram"}}

            **launch** a specific app:
            {"thinking": "...", "action": {"type": "launch", "app": "settings"}}

            **back** button:
            {"thinking": "...", "action": {"type": "back"}}

            **home** button:
            {"thinking": "...", "action": {"type": "home"}}

            **wait** for a duration:
            {"thinking": "...", "action": {"type": "wait", "duration": 2}}

            **manual takeover** (for login, captcha, payment):
            {"thinking": "...", "action": {"type": "take_over", "message": "please enter your password"}}

            **finish** (task completed or direct answer):
            {"thinking": "...", "action": {"type": "finish", "message": "task completed."}}

            REMEMBER:
            - ALWAYS start "thinking" with a complete visual description of the screenshot. This is your memory — skip nothing.
            - Read every piece of text you can see, no matter how small (timestamps, counters, labels, watermarks, error text).
            - Note the state of interactive elements: is a button grayed out? Is a toggle on or off? Is a field focused?
            - Action field is mandatory and must contain exactly one action to perform.
            - If the user only needs a direct answer with no phone interaction, respond with `"action": {"type": "finish", "message": "..."}` in the user's language.
            - Use coordinates on a 0-1000 scale, not raw pixels.
            - Keep the same language as the user's request for your reasoning and any generated text.
            - Treat the device persona as required context for tone, depth, and interaction style, but never change the user's core goal.
            - Prefer apps listed in the device preferences when multiple app choices can satisfy the task.
            - Respect the device notes, account context, and any safety rules whenever they are relevant.
            - Never switch to Chinese unless the user's request is explicitly written in Chinese.
            - If the user's request is in Indonesian, stay in Indonesian.
            - When you call `launch(app="AppName")`, the system will automatically search installed apps and resolve the correct package. If multiple matches are found you will receive a list — pick the correct package and call `launch(app="com.example.package")` with the exact package name.
            - If the system reports no match for a launch, try a different app name or inform the user via finish.
            - NEVER call launch with an empty "app" field. Always provide the app name or package name.
            - For text entry, provide the exact final text whenever it is already known.
            \(hasLanguageEnhancer ? "- For every `type` action, the Language Enhancer will verify whether to keep or refine the text so it matches the user's language and intent." : "")
            - For every `tap`, {"type": "tap", "element": [x, y]} is usually sufficient. Only use "message" field for important notes that the user should see.
            - Before finishing, observe the screenshot carefully — check if the task is actually completed, and watch for unexpected pop-ups, error messages, or permission requests.
            - "action" is mandatory, never miss it.

            Example response:
            {
                "thinking": "Visual inventory: Status bar shows 14:32, battery at 67%, WiFi connected (full bars), mobile data icon present. I'm on the Android home screen. Top section: Google search bar with 'G' logo and microphone icon at ~[500, 60]. Below that, a row of 4 app icons: Phone (~[125, 200]), Messages (~[375, 200]), Chrome (~[625, 200]), Camera (~[875, 200]). Middle area: a 4x4 grid of app icons including Instagram (~[125, 400]), YouTube (~[375, 400]), Settings gear icon (~[625, 400]), Maps (~[875, 400]), WhatsApp (~[125, 550]), Spotify (~[375, 550]), Gmail (~[625, 550]), Calendar (~[875, 550]). Bottom dock: Phone, Contacts, Chrome, Messages icons. No pop-ups, no notifications panel open. The user wants to open Instagram, which I can see at approximately [125, 400].",
                "action": {"type": "tap", "element": [125, 400]}
            }

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
        let effectivePreferredApps =
            preferredApps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "No preferred apps were specified for this device."
            : preferredApps.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveDeviceNotes =
            deviceNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "No extra device notes or safety rules were provided for this device."
            : deviceNotes.trimmingCharacters(in: .whitespacesAndNewlines)

        if step == 1 {
            return """
                User request (respond in the same language as this request):
                \(task)

                ** Device Preferences **

                Preferred apps: \(effectivePreferredApps)
                Device notes: \(effectiveDeviceNotes)

                ** Screen Info **

                \(screenInfo)

                Analyze the screenshot carefully using your OCR and vision capabilities. Respond with a single JSON object containing "thinking" and "action" fields.
                """
        } else {
            return """
                ** Screen Info **

                \(screenInfo)

                Analyze the updated screenshot and respond with a single JSON object containing "thinking" and "action" fields.
                """
        }
    }

    // MARK: - Response Parsing (JSON)

    func parseResponse(content: String) -> AIModelParsedResponse {
        let cleaned = Self.stripCodeFences(content)

        // Try full JSON parse first
        if let parsed = Self.parseJSONResponse(cleaned) {
            return parsed
        }

        // Fallback: try to find a JSON object in the raw content
        if let jsonRange = Self.findFirstJSONObject(in: cleaned),
            let parsed = Self.parseJSONResponse(String(cleaned[jsonRange]))
        {
            return parsed
        }

        // Last resort: fall back to <think>/<answer> parsing for compatibility
        if let thinkStart = content.range(of: "<think>"),
            let thinkEnd = content.range(of: "</think>"),
            let answerStart = content.range(of: "<answer>")
        {
            let thinking = String(content[thinkStart.upperBound..<thinkEnd.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let actionEnd = content.range(of: "</answer>")?.lowerBound ?? content.endIndex
            let action = String(content[answerStart.upperBound..<actionEnd]).trimmingCharacters(
                in: .whitespacesAndNewlines)
            return AIModelParsedResponse(thinking: thinking, action: action)
        }

        return AIModelParsedResponse(
            thinking: "", action: cleaned.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Action Parsing (JSON)

    func parseAction(from actionText: String) -> AIModelAction {
        let trimmed = actionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .unknown(name: "empty", raw: "Model returned thinking but no action.")
        }

        // If actionText is already JSON (from parseResponse), parse the action object
        if let data = trimmed.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            return Self.actionFromJSON(json)
        } 

        return .finish(message: trimmed)
    }

    // MARK: - Stream Markers

    var streamsReadableThinking: Bool { false }

    func firstActionMarkerRange(in text: String) -> Range<String.Index>? {
        // For JSON mode, the "action" key signals the transition from thinking to action.
        // We also keep the pseudo-code markers as fallback.
        let markers = ["\"action\"", "finish(message=", "do(action="]
        for marker in markers {
            if let range = text.range(of: marker) {
                return range
            }
        }
        return nil
    }

    func endsWithPartialActionMarker(_ text: String) -> Bool {
        let markers = ["\"action\"", "finish(message=", "do(action="]
        for marker in markers {
            for length in 1..<marker.count where text.hasSuffix(String(marker.prefix(length))) {
                return true
            }
        }
        return false
    }

    // MARK: - Assistant Context Format

    func formatAssistantContext(thinking: String, action: String) -> String {
        // Preserve the full JSON format so the model sees its visual description
        // from previous turns, giving it memory of what was on screen.
        let thinkingEscaped = thinking
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        // action is already a JSON string from parseResponse, embed it directly
        return "{\"thinking\":\"\(thinkingEscaped)\",\"action\":\(action)}"
    }

    // MARK: - Request Parameters

    func requestParameters(
        modelName: String, maxTokens: Int, temperature: Double, topP: Double,
        frequencyPenalty: Double
    ) -> [String: Any] {
        [
            "model": modelName,
            "max_tokens": maxTokens,
            "temperature": max(temperature, 0.1),
            "top_p": topP,
            "frequency_penalty": max(0, frequencyPenalty - 0.1),
            "stream": true,
            "response_format": ["type": "json_object"],
        ]
    }

    // MARK: - Thinking Mode

    enum ThinkingMode {
        case fast
        case deep
    }

    static func selectThinkingMode(for task: String) -> ThinkingMode {
        let lower = task.lowercased()
        let deepKeywords = [
            "compare", "difference", "analyze", "calculate", "math",
            "reason", "explain why", "step by step", "spatial",
            "multi-step", "chain", "complex",
        ]
        for keyword in deepKeywords {
            if lower.contains(keyword) { return .deep }
        }
        return .fast
    }

    // MARK: - JSON Helpers

    /// Strip optional ```json ... ``` code fences that the model may emit despite instructions.
    private static func stripCodeFences(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```json") {
            s = String(s.dropFirst(7))
        } else if s.hasPrefix("```") {
            s = String(s.dropFirst(3))
        }
        if s.hasSuffix("```") {
            s = String(s.dropLast(3))
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Find the first balanced `{ ... }` range in the text.
    private static func findFirstJSONObject(in text: String) -> Range<String.Index>? {
        guard let openIndex = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var i = openIndex
        while i < text.endIndex {
            let ch = text[i]
            if escaped {
                escaped = false
            } else if ch == "\\" && inString {
                escaped = true
            } else if ch == "\"" {
                inString.toggle()
            } else if !inString {
                if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        return openIndex..<text.index(after: i)
                    }
                }
            }
            i = text.index(after: i)
        }
        return nil
    }

    /// Parse a JSON string into a thinking + action pair.
    private static func parseJSONResponse(_ json: String) -> AIModelParsedResponse? {
        guard let data = json.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        let thinking = obj["thinking"] as? String ?? ""

        // Standard format: {"thinking": "...", "action": {...}}
        if let actionDict = obj["action"] as? [String: Any],
            let actionData = try? JSONSerialization.data(withJSONObject: actionDict),
            let actionString = String(data: actionData, encoding: .utf8)
        {
            return AIModelParsedResponse(thinking: thinking, action: actionString)
        }

        if let actionString = obj["action"] as? String {
            // Flat format: action type is a string at root level alongside other params.
            // e.g. {"thinking": "...", "action": "tap", "element": "<point>706 912</point>"}
            // Rebuild as {"type": "tap", "element": ...} so actionFromJSON can parse it.
            var actionDict: [String: Any] = ["type": actionString]
            for (key, value) in obj where key != "thinking" && key != "action" {
                actionDict[key] = value
            }
            if let actionData = try? JSONSerialization.data(withJSONObject: actionDict),
                let rebuilt = String(data: actionData, encoding: .utf8)
            {
                return AIModelParsedResponse(thinking: thinking, action: rebuilt)
            }
            return AIModelParsedResponse(thinking: thinking, action: actionString)
        }

        // Flat format: {"type": "Tap", "element": [x, y], "thinking": "..."}
        // Model put everything at the root level instead of nesting under "action".
        if obj["type"] as? String != nil {
            var actionDict = obj
            actionDict.removeValue(forKey: "thinking")
            if let actionData = try? JSONSerialization.data(withJSONObject: actionDict),
                let actionString = String(data: actionData, encoding: .utf8)
            {
                return AIModelParsedResponse(thinking: thinking, action: actionString)
            }
        }

        // Model returned thinking but no action at all — surface thinking and leave action empty
        // so the retry mechanism can reprompt.
        if !thinking.isEmpty {
            return AIModelParsedResponse(thinking: thinking, action: "")
        }

        return nil
    }

    /// Convert a JSON action dictionary into an `AIModelAction`.
    private static func actionFromJSON(_ json: [String: Any]) -> AIModelAction {
        guard let actionType = json["type"] as? String else {
            if let message = json["message"] as? String {
                return .finish(message: message)
            }
            return .finish(message: "Unknown action format.")
        }

        switch actionType.lowercased().replacingOccurrences(of: "_", with: " ").trimmingCharacters(
            in: .whitespaces)
        {
        case "tap":
            if let (x, y) = intPair(from: json["element"]) {
                return .tap(x: x, y: y, message: json["message"] as? String)
            }
        case "double tap":
            if let (x, y) = intPair(from: json["element"]) {
                return .doubleTap(x: x, y: y)
            }
        case "long press":
            if let (x, y) = intPair(from: json["element"]) {
                return .longPress(x: x, y: y)
            }
        case "swipe":
            if let (sx, sy) = intPair(from: json["start"]),
                let (ex, ey) = intPair(from: json["end"])
            {
                return .swipe(startX: sx, startY: sy, endX: ex, endY: ey)
            }
        case "type":
            let text = json["text"] as? String ?? ""
            return .type(text: text, enhance: true)
        case "listapp", "listapps", "list app", "list apps":
            return .listApp(query: json["query"] as? String ?? json["app"] as? String)
        case "launch":
            return .launch(app: json["app"] as? String ?? "")
        case "back":
            return .back
        case "home":
            return .home
        case "wait":
            return .wait(seconds: doubleValue(from: json["duration"]) ?? 1.0)
        case "take over", "takeover":
            return .takeOver(message: json["message"] as? String)
        case "finish":
            return .finish(message: json["message"] as? String)
        default:
            break
        }

        if let raw = try? JSONSerialization.data(withJSONObject: json),
            let rawString = String(data: raw, encoding: .utf8)
        {
            return .unknown(name: actionType, raw: rawString)
        }
        return .unknown(name: actionType, raw: "\(json)")
    }

    /// Extract an (Int, Int) pair from a JSON value.
    /// Handles: [x, y] arrays, "<point>x y</point>" XML strings, "x, y" / "x y" strings.
    private static func intPair(from value: Any?) -> (Int, Int)? {
        // Array format: [891, 376]
        if let array = value as? [Any], array.count == 2,
            let a = (array[0] as? NSNumber)?.intValue,
            let b = (array[1] as? NSNumber)?.intValue
        {
            return (a, b)
        }
        // String format: "<point>891 376</point>" or "891, 376" or "891 376"
        if let str = value as? String {
            var cleaned = str
            // Strip <point>...</point> tags
            if let start = cleaned.range(of: "<point>"), let end = cleaned.range(of: "</point>") {
                cleaned = String(cleaned[start.upperBound..<end.lowerBound])
            }
            // Strip brackets [...]
            cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "[]() "))
            // Split by comma, space, or both
            let parts = cleaned.components(separatedBy: CharacterSet(charactersIn: ", "))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]) {
                return (a, b)
            }
        }
        return nil
    }

    /// Extract a Double from a JSON value that may be Int, Double, or String.
    private static func doubleValue(from value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

}
