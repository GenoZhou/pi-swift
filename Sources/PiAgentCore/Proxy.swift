import Foundation
import PiAI

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Options for {@link streamProxy}, the iOS-friendly LLM transport.
public struct ProxyStreamOptions: Sendable {
	public var signal: CancellationToken?
	public var authToken: String
	public var proxyUrl: String
	public var temperature: Double?
	public var maxTokens: Int?
	public var reasoning: ThinkingLevel?
	public var sessionId: String?
	public var transport: Transport?
	public var thinkingBudgets: ThinkingBudgets?
	public var maxRetryDelayMs: Double?
	public var headers: [String: String]?

	public init(
		signal: CancellationToken? = nil,
		authToken: String,
		proxyUrl: String,
		temperature: Double? = nil,
		maxTokens: Int? = nil,
		reasoning: ThinkingLevel? = nil,
		sessionId: String? = nil,
		transport: Transport? = nil,
		thinkingBudgets: ThinkingBudgets? = nil,
		maxRetryDelayMs: Double? = nil,
		headers: [String: String]? = nil
	) {
		self.signal = signal
		self.authToken = authToken
		self.proxyUrl = proxyUrl
		self.temperature = temperature
		self.maxTokens = maxTokens
		self.reasoning = reasoning
		self.sessionId = sessionId
		self.transport = transport
		self.thinkingBudgets = thinkingBudgets
		self.maxRetryDelayMs = maxRetryDelayMs
		self.headers = headers
	}
}

/// Builds a `StreamFn` that POSTs to a backend proxy instead of calling providers directly.
///
/// This is the recommended transport for iOS apps: the server owns provider credentials.
public func makeProxyStreamFn(proxyUrl: String, authToken: String) -> StreamFn {
	{ model, context, options in
		await streamProxy(
			model: model,
			context: context,
			options: ProxyStreamOptions(
				signal: options?.signal,
				authToken: authToken,
				proxyUrl: proxyUrl,
				temperature: options?.temperature,
				maxTokens: options?.maxTokens,
				reasoning: options?.reasoning,
				sessionId: options?.sessionId,
				transport: options?.transport,
				thinkingBudgets: options?.thinkingBudgets,
				maxRetryDelayMs: options?.maxRetryDelayMs
			)
		)
	}
}

/// Stream through a proxy server. Failures are encoded in the returned stream.
public func streamProxy(
	model: Model,
	context: LLMContext,
	options: ProxyStreamOptions
) async -> AssistantMessageEventStream {
	let stream = AssistantMessageEventStream()

	Task {
		do {
			guard let url = URL(string: options.proxyUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/stream") else {
				throw URLError(.badURL)
			}

			var request = URLRequest(url: url)
			request.httpMethod = "POST"
			request.setValue("application/json", forHTTPHeaderField: "Content-Type")
			request.setValue("Bearer \(options.authToken)", forHTTPHeaderField: "Authorization")
			if let headers = options.headers {
				for (key, value) in headers {
					request.setValue(value, forHTTPHeaderField: key)
				}
			}

			let body = ProxyRequestBody(
				model: model,
				context: context,
				temperature: options.temperature,
				maxTokens: options.maxTokens,
				reasoning: options.reasoning?.rawValue,
				sessionId: options.sessionId
			)
			request.httpBody = try JSONEncoder().encode(body)

			if options.signal?.isCancelled == true {
				throw CancellationError()
			}

			let (data, response) = try await URLSession.shared.data(for: request)
			guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
				let status = (response as? HTTPURLResponse)?.statusCode ?? -1
				throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Proxy HTTP \(status)"])
			}

			var partial = AssistantMessage(
				api: model.api,
				provider: model.provider,
				model: model.id,
				stopReason: .pending
			)
			stream.push(.start(partial: partial))

			let text = String(decoding: data, as: UTF8.self)
			for line in text.split(whereSeparator: \.isNewline) {
				if options.signal?.isCancelled == true {
					throw CancellationError()
				}
				let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
				guard trimmed.hasPrefix("data:") else { continue }
				let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
				if payload == "[DONE]" { break }
				guard let eventData = payload.data(using: .utf8) else { continue }
				let event = try JSONDecoder().decode(ProxyWireEvent.self, from: eventData)
				apply(event: event, to: &partial, stream: stream)
				if event.isTerminal { break }
			}

			if partial.stopReason == .pending {
				partial.stopReason = .stop
				stream.push(.done(reason: .stop, message: partial))
			}
		} catch is CancellationError {
			let aborted = AssistantMessage(
				api: model.api,
				provider: model.provider,
				model: model.id,
				stopReason: .aborted,
				errorMessage: "aborted"
			)
			stream.push(.error(reason: .aborted, error: aborted))
		} catch {
			let failed = AssistantMessage(
				api: model.api,
				provider: model.provider,
				model: model.id,
				stopReason: .error,
				errorMessage: error.localizedDescription
			)
			stream.push(.error(reason: .error, error: failed))
		}
	}

	return stream
}

private struct ProxyRequestBody: Encodable {
	var model: Model
	var context: LLMContext
	var temperature: Double?
	var maxTokens: Int?
	var reasoning: String?
	var sessionId: String?
}

private struct ProxyWireEvent: Decodable {
	var type: String
	var contentIndex: Int?
	var delta: String?
	var content: String?
	var id: String?
	var toolName: String?
	var reason: String?
	var errorMessage: String?
	var usage: Usage?

	var isTerminal: Bool {
		type == "done" || type == "error"
	}
}

private func apply(event: ProxyWireEvent, to partial: inout AssistantMessage, stream: AssistantMessageEventStream) {
	switch event.type {
	case "text_start":
		partial.content.append(.text(TextContent(text: "")))
		stream.push(.textStart(contentIndex: event.contentIndex ?? partial.content.count - 1, partial: partial))
	case "text_delta":
		let index = event.contentIndex ?? max(partial.content.count - 1, 0)
		if case .text(var block) = partial.content[safe: index] {
			block.text += event.delta ?? ""
			partial.content[index] = .text(block)
			stream.push(.textDelta(contentIndex: index, delta: event.delta ?? "", partial: partial))
		}
	case "text_end":
		let index = event.contentIndex ?? max(partial.content.count - 1, 0)
		if case .text(let block) = partial.content[safe: index] {
			stream.push(.textEnd(contentIndex: index, content: event.content ?? block.text, partial: partial))
		}
	case "toolcall_start":
		partial.content.append(
			.toolCall(
				ToolCall(
					id: event.id ?? UUID().uuidString,
					name: event.toolName ?? "",
					arguments: [:]
				)
			)
		)
		stream.push(.toolCallStart(contentIndex: event.contentIndex ?? partial.content.count - 1, partial: partial))
	case "done":
		partial.stopReason = StopReason(rawValue: event.reason ?? "stop") ?? .stop
		if let usage = event.usage { partial.usage = usage }
		stream.push(.done(reason: partial.stopReason, message: partial))
	case "error":
		partial.stopReason = StopReason(rawValue: event.reason ?? "error") ?? .error
		partial.errorMessage = event.errorMessage
		if let usage = event.usage { partial.usage = usage }
		stream.push(.error(reason: partial.stopReason, error: partial))
	default:
		break
	}
}

private extension Array {
	subscript(safe index: Int) -> Element? {
		indices.contains(index) ? self[index] : nil
	}
}

// LLMContext is not Codable by default because Tool is not Codable; encode a slim payload.
extension LLMContext: Encodable {
	enum CodingKeys: String, CodingKey {
		case systemPrompt, messages, tools
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encodeIfPresent(systemPrompt, forKey: .systemPrompt)
		try container.encode(messages, forKey: .messages)
		if let tools {
			struct EncodedTool: Encodable {
				var name: String
				var description: String
				var parameters: [String: JSONValue]
			}
			try container.encode(
				tools.map { EncodedTool(name: $0.name, description: $0.description, parameters: $0.parametersSchema) },
				forKey: .tools
			)
		}
	}
}
