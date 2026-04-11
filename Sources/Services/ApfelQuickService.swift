import Foundation

struct ApfelQuickService: QuickService, @unchecked Sendable {
    let baseURL: URL
    let modelName: String

    /// System prompt that keeps answers tight: no preamble, no postamble,
    /// no "as an AI" disclaimers, no apologies. Just the answer the user wants.
    static let systemPrompt: String = """
    You are a fast, direct assistant in a Spotlight-style overlay. \
    Answer only what is asked. No preamble, no postamble, no apologies, \
    no "as an AI" disclaimers, no safety moralizing, no invitations to ask \
    follow-ups. If the user asks a factual question, state the fact. If \
    they ask for code, give code. If they ask for a translation, give only \
    the translation. Be concise and direct.
    """

    init(baseURL: URL, modelName: String = "apple-foundationmodel") {
        self.baseURL = baseURL
        self.modelName = modelName
    }

    init(port: Int, modelName: String = "apple-foundationmodel") {
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
        self.modelName = modelName
    }

    func buildRequest(prompt: String) throws -> URLRequest {
        let url = URL(string: "/v1/chat/completions", relativeTo: baseURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": modelName,
            "stream": true,
            "messages": [
                ["role": "system", "content": Self.systemPrompt],
                ["role": "user", "content": prompt],
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    func send(prompt: String) -> AsyncThrowingStream<StreamDelta, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let urlRequest = try buildRequest(prompt: prompt)
                    let (bytes, httpResponse) = try await URLSession.shared.bytes(for: urlRequest)

                    if let statusCode = (httpResponse as? HTTPURLResponse)?.statusCode,
                       statusCode >= 400 {
                        var errorData = Data()
                        for try await byte in bytes { errorData.append(byte) }
                        let errorText = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                        continuation.finish(throwing: QuickServiceError.serverError(errorText))
                        return
                    }

                    for try await line in bytes.lines {
                        if line.hasPrefix("data: [DONE]") { break }
                        if let error = SSEParser.parseError(line: line) {
                            continuation.finish(throwing: QuickServiceError.streamError(error.message))
                            return
                        }
                        if let delta = SSEParser.parse(line: line) {
                            continuation.yield(delta)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(
                        throwing: QuickServiceError.connectionFailed(
                            "Connection failed: \(error.localizedDescription)"
                        )
                    )
                }
            }
        }
    }

    func healthCheck() async throws -> Bool {
        let url = URL(string: "/health", relativeTo: baseURL)!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            return false
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["modelAvailable"] as? Bool) == true
    }
}

enum QuickServiceError: Error {
    case serverError(String)
    case streamError(String)
    case connectionFailed(String)
}
