import Foundation
import PiAI

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ProxyError: Error, LocalizedError, Sendable {
	case badURL(String)
	case httpStatus(Int, String?)
	case protocolError(String)

	public var errorDescription: String? {
		switch self {
		case .badURL(let value):
			return "Invalid proxy URL: \(value)"
		case .httpStatus(let code, let message):
			if let message, !message.isEmpty { return "Proxy error: \(message)" }
			return "Proxy error: \(code)"
		case .protocolError(let message):
			return message
		}
	}
}

/// Options for ``streamProxy``, the iOS-friendly LLM transport.
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

/// Builds a `StreamFn` that POSTs to a backend proxy.
///
/// `authToken` is resolved per request so short-lived tokens can refresh.
public func makeProxyStreamFn(
	proxyUrl: String,
	authToken: @escaping @Sendable () async -> String
) -> StreamFn {
	{ model, context, options in
		await streamProxy(
			model: model,
			context: context,
			options: ProxyStreamOptions(
				signal: options?.signal,
				authToken: await authToken(),
				proxyUrl: proxyUrl,
				temperature: options?.temperature,
				maxTokens: options?.maxTokens,
				reasoning: options?.reasoning,
				sessionId: options?.sessionId,
				transport: options?.transport,
				thinkingBudgets: options?.thinkingBudgets,
				maxRetryDelayMs: options?.maxRetryDelayMs,
				headers: options?.headers?.compactMapValues { $0 }
			)
		)
	}
}

/// Convenience overload with a fixed token (prefer the async provider when tokens expire).
public func makeProxyStreamFn(proxyUrl: String, authToken: String) -> StreamFn {
	makeProxyStreamFn(proxyUrl: proxyUrl, authToken: { authToken })
}

/// Stream through a proxy server. Failures are encoded in the returned stream.
///
/// Note: the response body is read to completion before SSE lines are applied (Linux
/// `FoundationNetworking` lacks `URLSession.bytes`). Cancellation still aborts the
/// in-flight `URLSessionTask`.
public func streamProxy(
	model: Model,
	context: LLMContext,
	options: ProxyStreamOptions
) async -> AssistantMessageEventStream {
	let stream = AssistantMessageEventStream()

	Task {
		var partial = AssistantMessage(
			api: model.api,
			provider: model.provider,
			model: model.id,
			stopReason: .pending
		)
		var toolPartialJson: [Int: String] = [:]
		var sawTerminal = false
		var cancelId: UUID?

		do {
			let base = options.proxyUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
			guard let url = URL(string: base + "/api/stream") else {
				throw ProxyError.badURL(options.proxyUrl)
			}

			var request = URLRequest(url: url)
			request.httpMethod = "POST"
			request.setValue("application/json", forHTTPHeaderField: "Content-Type")
			request.setValue("Bearer \(options.authToken)", forHTTPHeaderField: "Authorization")
			if let headers = options.headers {
				for (key, value) in headers where key.lowercased() != "authorization" {
					request.setValue(value, forHTTPHeaderField: key)
				}
			}

			let body = ProxyRequestBody(
				model: model,
				context: context,
				options: ProxyRequestOptions(
					temperature: options.temperature,
					maxTokens: options.maxTokens,
					reasoning: options.reasoning.flatMap { $0 == .off ? nil : $0.rawValue },
					sessionId: options.sessionId,
					transport: options.transport?.rawValue,
					maxRetryDelayMs: options.maxRetryDelayMs
				)
			)
			request.httpBody = try JSONEncoder().encode(body)

			if options.signal?.isCancelled == true {
				throw CancellationError()
			}

			let (data, response) = try await performDataRequest(request, signal: options.signal, cancelId: &cancelId)
			if let cancelId {
				options.signal?.removeOnCancel(cancelId)
			}

			guard let http = response as? HTTPURLResponse else {
				throw ProxyError.httpStatus(-1, nil)
			}
			guard (200..<300).contains(http.statusCode) else {
				let message = String(data: data, encoding: .utf8)
				throw ProxyError.httpStatus(http.statusCode, message)
			}

			await stream.push(.start(partial: partial))

			let decoder = JSONDecoder()
			let text = String(decoding: data, as: UTF8.self)
			for rawLine in text.split(whereSeparator: \.isNewline) {
				if options.signal?.isCancelled == true {
					throw CancellationError()
				}
				let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
				guard trimmed.hasPrefix("data:") else { continue }
				let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
				if payload.isEmpty || payload == "[DONE]" { continue }
				guard let eventData = payload.data(using: .utf8) else { continue }
				let wire = try decoder.decode(ProxyWireEvent.self, from: eventData)
				if let event = try processProxyEvent(wire, partial: &partial, toolPartialJson: &toolPartialJson) {
					await stream.push(event)
					if wire.isTerminal {
						sawTerminal = true
						break
					}
				}
			}

			if !sawTerminal {
				partial.stopReason = .stop
				await stream.push(.done(reason: .stop, message: partial))
			}
			await stream.end(partial)
		} catch is CancellationError {
			partial.stopReason = .aborted
			partial.errorMessage = "aborted"
			await stream.push(.error(reason: .aborted, error: partial))
			await stream.end(partial)
		} catch {
			partial.stopReason = .error
			partial.errorMessage = error.localizedDescription
			await stream.push(.error(reason: .error, error: partial))
			await stream.end(partial)
		}
	}

	return stream
}

// MARK: - Request helpers

private func performDataRequest(
	_ request: URLRequest,
	signal: CancellationToken?,
	cancelId: inout UUID?
) async throws -> (Data, URLResponse) {
	final class Once: @unchecked Sendable {
		private let lock = NSLock()
		private var resumed = false
		private var continuation: CheckedContinuation<(Data, URLResponse), Error>?

		init(_ continuation: CheckedContinuation<(Data, URLResponse), Error>) {
			self.continuation = continuation
		}

		func resume(_ result: Result<(Data, URLResponse), Error>) {
			lock.lock()
			guard !resumed, let continuation else {
				lock.unlock()
				return
			}
			resumed = true
			self.continuation = nil
			lock.unlock()
			continuation.resume(with: result)
		}
	}

	return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
		let once = Once(continuation)
		let task = URLSession.shared.dataTask(with: request) { data, response, error in
			if let error {
				once.resume(.failure(error))
				return
			}
			guard let data, let response else {
				once.resume(.failure(URLError(.badServerResponse)))
				return
			}
			once.resume(.success((data, response)))
		}
		cancelId = signal?.onCancel {
			task.cancel()
		}
		task.resume()
	}
}

private struct ProxyRequestOptions: Encodable {
	var temperature: Double?
	var maxTokens: Int?
	var reasoning: String?
	var sessionId: String?
	var transport: String?
	var maxRetryDelayMs: Double?
}

private struct ProxyRequestBody: Encodable {
	var model: Model
	var context: LLMContext
	var options: ProxyRequestOptions
}

struct ProxyWireToolCall: Decodable {
	var id: String?
	var name: String?
	var arguments: [String: JSONValue]?
}

struct ProxyWireEvent: Decodable {
	var type: String
	var contentIndex: Int?
	var delta: String?
	var content: String?
	var contentSignature: String?
	var id: String?
	var toolName: String?
	var toolCall: ProxyWireToolCall?
	var reason: String?
	var errorMessage: String?
	var usage: Usage?
	var providerThinkingLevel: String?

	var isTerminal: Bool {
		type == "done" || type == "error"
	}

	init(
		type: String,
		contentIndex: Int? = nil,
		delta: String? = nil,
		content: String? = nil,
		contentSignature: String? = nil,
		id: String? = nil,
		toolName: String? = nil,
		toolCall: ProxyWireToolCall? = nil,
		reason: String? = nil,
		errorMessage: String? = nil,
		usage: Usage? = nil,
		providerThinkingLevel: String? = nil
	) {
		self.type = type
		self.contentIndex = contentIndex
		self.delta = delta
		self.content = content
		self.contentSignature = contentSignature
		self.id = id
		self.toolName = toolName
		self.toolCall = toolCall
		self.reason = reason
		self.errorMessage = errorMessage
		self.usage = usage
		self.providerThinkingLevel = providerThinkingLevel
	}
}

/// Mirrors upstream `processProxyEvent`: mutate `partial`, return the protocol event to push.
func processProxyEvent(
	_ wire: ProxyWireEvent,
	partial: inout AssistantMessage,
	toolPartialJson: inout [Int: String]
) throws -> AssistantMessageEvent? {
	switch wire.type {
	case "start":
		return .start(partial: partial)

	case "text_start":
		let index = wire.contentIndex ?? partial.content.count
		padContent(&partial.content, to: index)
		partial.content[index] = .text(TextContent(text: ""))
		return .textStart(contentIndex: index, partial: partial)

	case "text_delta":
		let index = requiredIndex(wire.contentIndex, count: partial.content.count)
		guard case .text(var block) = partial.content[safe: index] else {
			throw ProxyError.protocolError("Received text_delta for non-text content")
		}
		block.text += wire.delta ?? ""
		partial.content[index] = .text(block)
		return .textDelta(contentIndex: index, delta: wire.delta ?? "", partial: partial)

	case "text_end":
		let index = requiredIndex(wire.contentIndex, count: partial.content.count)
		guard case .text(var block) = partial.content[safe: index] else {
			throw ProxyError.protocolError("Received text_end for non-text content")
		}
		if let signature = wire.contentSignature {
			block.textSignature = signature
			partial.content[index] = .text(block)
		}
		return .textEnd(contentIndex: index, content: wire.content ?? block.text, partial: partial)

	case "thinking_start":
		let index = wire.contentIndex ?? partial.content.count
		padContent(&partial.content, to: index)
		partial.content[index] = .thinking(ThinkingContent(thinking: ""))
		return .thinkingStart(contentIndex: index, partial: partial)

	case "thinking_delta":
		let index = requiredIndex(wire.contentIndex, count: partial.content.count)
		guard case .thinking(var block) = partial.content[safe: index] else {
			throw ProxyError.protocolError("Received thinking_delta for non-thinking content")
		}
		block.thinking += wire.delta ?? ""
		partial.content[index] = .thinking(block)
		return .thinkingDelta(contentIndex: index, delta: wire.delta ?? "", partial: partial)

	case "thinking_end":
		let index = requiredIndex(wire.contentIndex, count: partial.content.count)
		guard case .thinking(var block) = partial.content[safe: index] else {
			throw ProxyError.protocolError("Received thinking_end for non-thinking content")
		}
		if let signature = wire.contentSignature {
			block.thinkingSignature = signature
			partial.content[index] = .thinking(block)
		}
		return .thinkingEnd(contentIndex: index, content: wire.content ?? block.thinking, partial: partial)

	case "toolcall_start":
		let index = wire.contentIndex ?? partial.content.count
		padContent(&partial.content, to: index)
		partial.content[index] = .toolCall(
			ToolCall(
				id: wire.id ?? UUID().uuidString,
				name: wire.toolName ?? "",
				arguments: [:]
			)
		)
		toolPartialJson[index] = ""
		return .toolCallStart(contentIndex: index, partial: partial)

	case "toolcall_delta":
		let index = requiredIndex(wire.contentIndex, count: partial.content.count)
		guard case .toolCall(var call) = partial.content[safe: index] else {
			throw ProxyError.protocolError("Received toolcall_delta for non-toolCall content")
		}
		var json = toolPartialJson[index] ?? ""
		json += wire.delta ?? ""
		toolPartialJson[index] = json
		call.arguments = parseStreamingJSONObject(json)
		partial.content[index] = .toolCall(call)
		return .toolCallDelta(contentIndex: index, delta: wire.delta ?? "", partial: partial)

	case "toolcall_end":
		let index = requiredIndex(wire.contentIndex, count: partial.content.count)
		guard case .toolCall(var call) = partial.content[safe: index] else {
			return nil
		}
		if let wireCall = wire.toolCall {
			if let id = wireCall.id { call.id = id }
			if let name = wireCall.name { call.name = name }
			if let arguments = wireCall.arguments { call.arguments = arguments }
		}
		toolPartialJson[index] = nil
		partial.content[index] = .toolCall(call)
		return .toolCallEnd(contentIndex: index, toolCall: call, partial: partial)

	case "done":
		partial.stopReason = StopReason(rawValue: wire.reason ?? "stop") ?? .stop
		if let usage = wire.usage { partial.usage = usage }
		if let level = wire.providerThinkingLevel { partial.providerThinkingLevel = level }
		return .done(reason: partial.stopReason, message: partial)

	case "error":
		partial.stopReason = StopReason(rawValue: wire.reason ?? "error") ?? .error
		partial.errorMessage = wire.errorMessage
		if let usage = wire.usage { partial.usage = usage }
		if let level = wire.providerThinkingLevel { partial.providerThinkingLevel = level }
		return .error(reason: partial.stopReason, error: partial)

	default:
		return nil
	}
}

private func parseStreamingJSONObject(_ raw: String) -> [String: JSONValue] {
	guard let data = raw.data(using: .utf8),
		let object = try? JSONDecoder().decode(JSONValue.self, from: data),
		case .object(let dict) = object
	else {
		return [:]
	}
	return dict
}

private func padContent(_ content: inout [AssistantContentBlock], to index: Int) {
	while content.count <= index {
		content.append(.text(TextContent(text: "")))
	}
}

private func requiredIndex(_ contentIndex: Int?, count: Int) -> Int {
	contentIndex ?? max(count - 1, 0)
}

private extension Array {
	subscript(safe index: Int) -> Element? {
		indices.contains(index) ? self[index] : nil
	}
}

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
