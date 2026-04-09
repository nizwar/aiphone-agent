import Foundation

enum AIEndpointValidationError: LocalizedError {
    case invalidURL
    case unauthorized
    case noUsableEndpoint
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Please enter a valid server URL."
        case .unauthorized:
            return "Authentication failed. Please check the API key."
        case .noUsableEndpoint:
            return "The server did not expose a usable OpenAI-compatible endpoint."
        case let .serverError(message):
            return message
        }
    }
}

enum AIEndpointValidator {
    static func validateOpenGLM(baseURL: String, apiKey: String, model: String) async throws -> String {
        let endpoints = candidateURLs(from: baseURL, path: "chat/completions")
        guard !endpoints.isEmpty else {
            throw AIEndpointValidationError.invalidURL
        }

        let payload: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "Hi"]],
            "max_tokens": 5,
            "temperature": 0
        ]

        let body = try JSONSerialization.data(withJSONObject: payload, options: [])
        var lastError: Error = AIEndpointValidationError.noUsableEndpoint

        for endpoint in endpoints {
            do {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.timeoutInterval = 15
                request.httpBody = body
                applyHeaders(to: &request, apiKey: apiKey)

                let (data, response) = try await URLSession.shared.data(for: request)
                let httpResponse = try validateHTTP(response: response, data: data)
                guard (200...299).contains(httpResponse.statusCode) else { continue }

                if containsChoices(in: data) {
                    return "Connected successfully. Model `\(model)` is responding."
                }

                throw AIEndpointValidationError.serverError("The server responded but returned an empty completion.")
            } catch {
                lastError = error
            }
        }

        throw lastError
    }

    static func validateLanguageEnhancer(baseURL: String, apiKey: String, model: String) async throws -> String {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedModel.isEmpty {
            let endpoints = candidateURLs(from: baseURL, path: "chat/completions")
            guard !endpoints.isEmpty else {
                throw AIEndpointValidationError.invalidURL
            }

            let payload: [String: Any] = [
                "model": trimmedModel,
                "messages": [["role": "user", "content": "Hi"]],
                "max_tokens": 5,
                "temperature": 0
            ]

            let body = try JSONSerialization.data(withJSONObject: payload, options: [])
            var lastError: Error = AIEndpointValidationError.noUsableEndpoint

            for endpoint in endpoints {
                do {
                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 15
                    request.httpBody = body
                    applyHeaders(to: &request, apiKey: apiKey)

                    let (data, response) = try await URLSession.shared.data(for: request)
                    let httpResponse = try validateHTTP(response: response, data: data)
                    guard (200...299).contains(httpResponse.statusCode) else { continue }

                    if containsChoices(in: data) {
                        return "Connected successfully. Model `\(trimmedModel)` is responding."
                    }

                    throw AIEndpointValidationError.serverError("The server responded but returned an empty completion.")
                } catch {
                    lastError = error
                }
            }

            throw lastError
        }

        let models = try await fetchModels(baseURL: baseURL, apiKey: apiKey)
        if models.isEmpty {
            return "Connected successfully. The OpenAI-compatible server is responding."
        }

        let summary = models.prefix(3).joined(separator: ", ")
        return "Connected successfully. Models found: \(summary)"
    }

    static func fetchModels(baseURL: String, apiKey: String) async throws -> [String] {
        let endpoints = candidateURLs(from: baseURL, path: "models")
        guard !endpoints.isEmpty else {
            throw AIEndpointValidationError.invalidURL
        }

        var lastError: Error = AIEndpointValidationError.noUsableEndpoint

        for endpoint in endpoints {
            do {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "GET"
                request.timeoutInterval = 15
                applyHeaders(to: &request, apiKey: apiKey)

                let (data, response) = try await URLSession.shared.data(for: request)
                let httpResponse = try validateHTTP(response: response, data: data)
                guard (200...299).contains(httpResponse.statusCode) else { continue }

                return extractModelIDs(from: data)
            } catch {
                lastError = error
            }
        }

        throw lastError
    }

    private static func applyHeaders(to request: inout URLRequest, apiKey: String) {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if trimmedKey.isEmpty {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
        } else {
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        }
    }

    private static func validateHTTP(response: URLResponse, data: Data) throws -> HTTPURLResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIEndpointValidationError.serverError("The server returned an invalid response.")
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw AIEndpointValidationError.unauthorized
        }

        if !(200...299).contains(httpResponse.statusCode) {
            let message = extractErrorMessage(from: data) ?? "Server returned HTTP \(httpResponse.statusCode)."
            throw AIEndpointValidationError.serverError(message)
        }

        return httpResponse
    }

    private static func containsChoices(in data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]] else {
            return false
        }
        return !choices.isEmpty
    }

    private static func extractModelIDs(from data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        if let models = object["data"] as? [[String: Any]] {
            return models.compactMap { $0["id"] as? String }
        }

        return []
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

    private static func candidateURLs(from rawBaseURL: String, path: String) -> [URL] {
        let trimmed = rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let normalized = normalizedBaseURL(from: trimmed)
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

        let scheme = (isLocalHost || looksLikeIPAddress) ? "http://" : "https://"
        return scheme + value
    }
}
