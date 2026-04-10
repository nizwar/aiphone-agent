import Foundation

// MARK: - Model Provider Protocol

/// Abstract interface for all AI model providers in AIPhone.
/// Each model (AutoGLM, OpenAI, etc.) implements this protocol to provide
/// its own system prompt, response parsing, and request configuration.
protocol AIModelProvider: Sendable {
    /// Unique identifier for this model provider (e.g. "autoglm", "openai").
    static var id: String { get }

    /// Human-readable display name for the settings UI.
    static var displayName: String { get }

    /// Brief description shown in the model picker.
    static var summary: String { get }

    /// Default model name to pre-fill in settings.
    static var defaultModelName: String { get }

    /// Hardcoded model options for the picker dropdown.
    static var builtInModels: [String] { get }

    /// Hidden/deprecated model names to filter out from fetched lists.
    static var hiddenModels: Set<String> { get }

    /// Build the system prompt for the agent loop.
    func systemPrompt(
        userTask: String,
        devicePersona: String,
        preferredApps: String,
        deviceNotes: String,
        hasLanguageEnhancer: Bool,
        detectedLanguage: String?
    ) -> String

    /// Build the user message text for a given step.
    func userMessage(
        step: Int,
        task: String,
        screenInfo: String,
        devicePersona: String,
        preferredApps: String,
        deviceNotes: String
    ) -> String

    /// Parse the raw model output into thinking + action text.
    func parseResponse(content: String) -> AIModelParsedResponse

    /// Parse a structured action from the action text.
    func parseAction(from actionText: String) -> AIModelAction

    /// Detect stream markers that separate thinking from action output.
    func firstActionMarkerRange(in text: String) -> Range<String.Index>?

    /// Check if the buffer ends with a partial action marker prefix.
    func endsWithPartialActionMarker(_ text: String) -> Bool

    /// Whether this provider's streaming tokens are human-readable.
    /// When `false`, the agent loop will NOT stream thinking chunks to the UI during
    /// generation. Instead, the fully-parsed thinking text is logged once the response
    /// is complete. Providers that wrap output in JSON (OpenAI) return `false`.
    var streamsReadableThinking: Bool { get }

    /// Request body parameters specific to this model provider.
    func requestParameters(modelName: String, maxTokens: Int, temperature: Double, topP: Double, frequencyPenalty: Double) -> [String: Any]

    /// Format the assistant's thinking + action into the context string appended to conversation history.
    /// Each provider defines its own format so the model sees its native format in previous turns.
    func formatAssistantContext(thinking: String, action: String) -> String
}

// MARK: - Parsed Response

struct AIModelParsedResponse: Sendable {
    let thinking: String
    let action: String
}

// MARK: - Model Action

/// Unified action enum shared across all model providers.
enum AIModelAction: Sendable {
    case finish(message: String?)
    case listApp(query: String?)
    case launch(app: String)
    case tap(x: Int, y: Int, message: String?)
    case doubleTap(x: Int, y: Int)
    case longPress(x: Int, y: Int)
    case swipe(startX: Int, startY: Int, endX: Int, endY: Int)
    case type(text: String, enhance: Bool)
    case back
    case home
    case wait(seconds: Double)
    case takeOver(message: String?)
    case unknown(name: String, raw: String)

    var shortLabel: String {
        switch self {
        case .finish: return "finish"
        case .listApp: return "list apps"
        case .launch: return "launch"
        case .tap: return "tap"
        case .doubleTap: return "double tap"
        case .longPress: return "long press"
        case .swipe: return "swipe"
        case .type: return "type"
        case .back: return "back"
        case .home: return "home"
        case .wait: return "wait"
        case .takeOver: return "take over"
        case let .unknown(name, _): return name
        }
    }

    var logDescription: String {
        switch self {
        case let .finish(message): return "finish(\(message ?? "done"))"
        case let .listApp(query): return "ListApp(\(query ?? "all"))"
        case let .launch(app): return "Launch \(app)"
        case let .tap(x, y, _): return "Tap [\(x), \(y)]"
        case let .doubleTap(x, y): return "Double Tap [\(x), \(y)]"
        case let .longPress(x, y): return "Long Press [\(x), \(y)]"
        case let .swipe(sx, sy, ex, ey): return "Swipe [\(sx), \(sy)] → [\(ex), \(ey)]"
        case let .type(text, enhance): return enhance ? "Type \(text.debugDescription) [enhance]" : "Type \(text.debugDescription)"
        case .back: return "Back"
        case .home: return "Home"
        case let .wait(seconds): return "Wait \(String(format: "%.1f", seconds))s"
        case let .takeOver(message): return "Take over: \(message ?? "manual action required")"
        case let .unknown(name, raw): return "\(name) → \(raw)"
        }
    }
}

// MARK: - Model Provider Registry

/// Central registry for all available model providers.
/// Add new providers here to make them available in the app.
enum AIModelProviderRegistry {
    private static var providers: [String: any AIModelProvider.Type] = [
        AutoGLMModelProvider.id: AutoGLMModelProvider.self,
        OpenAIModelProvider.id: OpenAIModelProvider.self,
    ]

    private static var factories: [String: @Sendable () -> any AIModelProvider] = [
        AutoGLMModelProvider.id: { AutoGLMModelProvider() },
        OpenAIModelProvider.id: { OpenAIModelProvider() },
    ]

    static var allProviderIDs: [String] {
        Array(providers.keys).sorted()
    }

    static var allProviders: [(id: String, type: any AIModelProvider.Type)] {
        providers.map { (id: $0.key, type: $0.value) }.sorted { $0.id < $1.id }
    }

    static func provider(for id: String) -> (any AIModelProvider)? {
        factories[id]?()
    }

    static func providerType(for id: String) -> (any AIModelProvider.Type)? {
        providers[id]
    }

    static func defaultProviderID() -> String {
        AutoGLMModelProvider.id
    }
}

// MARK: - Shared Parsing Utilities

enum AIModelParsingUtils {
    static func quotedValue(named name: String, in text: String) -> String? {
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

    static func point(named name: String, in text: String) -> (x: Int, y: Int)? {
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
        return (x: x, y: y)
    }

    static func booleanValue(named name: String, in text: String) -> Bool? {
        if let quoted = quotedValue(named: name, in: text) {
            return parseBoolean(quoted)
        }
        let pattern = #"(?i)\#(name)\s*[:=]\s*(true|false|yes|no|1|0)"#
        guard let match = firstMatch(pattern: pattern, in: text) else { return nil }
        return parseBoolean(match)
    }

    static func waitDuration(from raw: String?) -> Double {
        guard let raw else { return 1.0 }
        let cleaned = raw.replacingOccurrences(of: "seconds", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(cleaned) ?? 1.0
    }

    static func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captureRange])
    }

    static func unescape(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\\n"#, with: "\n")
            .replacingOccurrences(of: #"\\r"#, with: "\r")
            .replacingOccurrences(of: #"\\t"#, with: "\t")
            .replacingOccurrences(of: #"\\\""#, with: #"\""#)
            .replacingOccurrences(of: #"\\'"#, with: "'")
    }

    static func extractAnswer(from response: String) -> String {
        if let answerRange = response.range(of: "<answer>") {
            let afterAnswer = response[answerRange.upperBound...]
            if let endRange = afterAnswer.range(of: "</answer>") {
                return String(afterAnswer[..<endRange.lowerBound])
            }
            return String(afterAnswer)
        }
        return response
    }

    private static func parseBoolean(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: return nil
        }
    }

    /// Extract the message from `finish(message="...")` handling unescaped inner quotes.
    /// Falls back to `quotedValue` for properly escaped quotes, then uses greedy extraction
    /// (first `"` after `message=` to the last `")` in the string) for unescaped inner quotes.
    static func extractFinishMessage(from text: String) -> String? {
        // Try the standard regex-based extraction first (handles escaped quotes)
        if let standard = quotedValue(named: "message", in: text) {
            // Validate: if the standard extraction looks complete (ends near the end of
            // the call), use it. Otherwise fall through to greedy extraction.
            // Check if there's a closing `")` after the extracted value's end.
            let afterStandard = text.range(of: standard).map { text[$0.upperBound...] } ?? text[text.endIndex...]
            let hasCleanClose = afterStandard.hasPrefix("\"") || afterStandard.hasPrefix("\")") || afterStandard.hasPrefix("'")
            if hasCleanClose {
                return standard
            }
        }

        // Greedy extraction: find `message=` followed by a quote, capture everything
        // up to the last `")` or `')` in the string.
        guard let eqRange = text.range(of: "message=", options: .caseInsensitive) else {
            return nil
        }

        let afterEq = text[eqRange.upperBound...]
        let quoteChar: Character
        if afterEq.first == "\"" {
            quoteChar = "\""
        } else if afterEq.first == "'" {
            quoteChar = "'"
        } else {
            return nil
        }

        let contentStart = afterEq.index(after: afterEq.startIndex)
        let closing = "\(quoteChar))"

        // Search backwards for the last `")` or `')`
        if let closingRange = text.range(of: closing, options: .backwards) {
            if closingRange.lowerBound > contentStart {
                let extracted = String(text[contentStart..<closingRange.lowerBound])
                return unescape(extracted)
            }
        }

        // Fallback: take everything after the opening quote to the last matching quote
        if let lastQuote = text.range(of: String(quoteChar), options: .backwards),
           lastQuote.lowerBound > contentStart {
            let extracted = String(text[contentStart..<lastQuote.lowerBound])
            return unescape(extracted)
        }

        return nil
    }

    /// Strip raw `finish(message="...")` wrapper from a string, returning just the inner message.
    /// If the text doesn't match the wrapper pattern, returns the original text unchanged.
    static func stripFinishWrapper(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("finish(") else { return trimmed }
        if let message = extractFinishMessage(from: trimmed) {
            return message
        }
        // Try removing just the `finish(` prefix and trailing `)`
        var inner = String(trimmed.dropFirst(7)) // drop "finish("
        if inner.hasSuffix(")") { inner = String(inner.dropLast()) }
        // Strip surrounding quotes if present
        if (inner.hasPrefix("\"") && inner.hasSuffix("\"")) ||
           (inner.hasPrefix("'") && inner.hasSuffix("'")) {
            inner = String(inner.dropFirst().dropLast())
        }
        return inner.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Build plain-text screen info string from the current app name.
    static func screenInfo(currentApp: String?) -> String {
        "current_app: \(currentApp ?? "Unknown")"
    }
}
