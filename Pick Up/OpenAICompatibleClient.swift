import Foundation

actor OpenAICompatibleClient: AICompleting {
    private let session: URLSession
    private var schemaUnsupportedHosts: Set<String> = []

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.timeoutIntervalForRequest = 45
            configuration.timeoutIntervalForResource = 60
            configuration.waitsForConnectivity = false
            self.session = URLSession(
                configuration: configuration,
                delegate: SecureRedirectDelegate(),
                delegateQueue: nil
            )
        }
    }

    func complete(
        systemPrompt: String,
        userPrompt: String,
        schema: AIOutputSchema,
        configuration: AIProviderConfiguration
    ) async throws -> String {
        let hostKey = configuration.baseURL.absoluteString
        let useSchema = !schemaUnsupportedHosts.contains(hostKey)

        do {
            return try await perform(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                responseFormat: useSchema ? .jsonSchema(schema) : .jsonObject(schema),
                configuration: configuration
            )
        } catch let error as HTTPStatusError where useSchema && (error.status == 400 || error.status == 422) {
            schemaUnsupportedHosts.insert(hostKey)
            do {
                return try await perform(
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    responseFormat: .jsonObject(schema),
                    configuration: configuration
                )
            } catch let fallbackError as HTTPStatusError {
                throw map(status: fallbackError.status)
            } catch is CancellationError {
                throw CancellationError()
            } catch let fallbackError as URLError {
                switch fallbackError.code {
                case .timedOut: throw AIServiceError.timeout
                case .cancelled: throw CancellationError()
                default: throw AIServiceError.network
                }
            } catch let fallbackError as AIServiceError {
                throw fallbackError
            } catch {
                throw AIServiceError.invalidResponse
            }
        } catch let error as HTTPStatusError {
            throw map(status: error.status)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            switch error.code {
            case .timedOut: throw AIServiceError.timeout
            case .cancelled: throw CancellationError()
            default: throw AIServiceError.network
            }
        } catch let error as AIServiceError {
            throw error
        } catch {
            throw AIServiceError.invalidResponse
        }
    }

    private enum ResponseFormat {
        case jsonSchema(AIOutputSchema)
        case jsonObject(AIOutputSchema)
    }

    private func perform(
        systemPrompt: String,
        userPrompt: String,
        responseFormat: ResponseFormat,
        configuration: AIProviderConfiguration
    ) async throws -> String {
        let endpoint = configuration.baseURL.appendingPathComponent("chat/completions")
        _ = try AIEndpointPolicy.validate(endpoint.deletingLastPathComponent().deletingLastPathComponent().absoluteString)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey = configuration.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        var effectiveSystemPrompt = systemPrompt
        let formatBody: [String: Any]
        switch responseFormat {
        case .jsonSchema(let schema):
            guard let schemaObject = try? JSONSerialization.jsonObject(with: schema.jsonData) else {
                throw AIServiceError.invalidResponse
            }
            formatBody = [
                "type": "json_schema",
                "json_schema": [
                    "name": schema.name,
                    "strict": true,
                    "schema": schemaObject
                ]
            ]
        case .jsonObject(let schema):
            guard let schemaText = String(data: schema.jsonData, encoding: .utf8) else {
                throw AIServiceError.invalidResponse
            }
            effectiveSystemPrompt += """

            当前服务只支持 JSON Object。必须只返回一个 JSON 对象，并逐字段符合下面的 Schema；不得改名、遗漏字段或添加说明文字：
            \(schemaText)
            """
            formatBody = ["type": "json_object"]
        }
        let body: [String: Any] = [
            "model": configuration.model,
            "messages": [
                ["role": "system", "content": effectiveSystemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "temperature": 0.2,
            "response_format": formatBody
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw HTTPStatusError(status: http.statusCode) }

        let decoded: ChatCompletionResponse
        do {
            decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        } catch {
            throw AIServiceError.invalidResponse
        }
        guard let message = decoded.choices.first?.message,
              message.refusal == nil,
              let content = message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            if decoded.choices.first?.message.refusal != nil { throw AIServiceError.refused }
            throw AIServiceError.invalidResponse
        }
        return content
    }

    private func map(status: Int) -> AIServiceError {
        switch status {
        case 401, 403: .authentication
        case 404: .modelUnavailable
        case 408: .timeout
        case 429: .rateLimited
        default: .server(status: status)
        }
    }
}

private struct HTTPStatusError: Error {
    let status: Int
}

nonisolated private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
            let refusal: String?
        }
        let message: Message
    }
    let choices: [Choice]
}

private final class SecureRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              (try? AIEndpointPolicy.validate(url.absoluteString)) != nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
