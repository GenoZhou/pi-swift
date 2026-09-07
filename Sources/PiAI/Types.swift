import Foundation

// MARK: - Content blocks

public struct TextContent: Sendable, Hashable, Codable {
	public var type: String = "text"
	public var text: String
	public var textSignature: String?

	public init(text: String, textSignature: String? = nil) {
		self.text = text
		self.textSignature = textSignature
	}
}

public struct ThinkingContent: Sendable, Hashable, Codable {
	public var type: String = "thinking"
	public var thinking: String
	public var thinkingSignature: String?
	public var redacted: Bool?

	public init(thinking: String, thinkingSignature: String? = nil, redacted: Bool? = nil) {
		self.thinking = thinking
		self.thinkingSignature = thinkingSignature
		self.redacted = redacted
	}
}

public struct ImageContent: Sendable, Hashable, Codable {
	public var type: String = "image"
	public var data: String
	public var mimeType: String

	public init(data: String, mimeType: String) {
		self.data = data
		self.mimeType = mimeType
	}
}

public struct ToolCall: Sendable, Hashable, Codable {
	public var type: String = "toolCall"
	public var id: String
	public var name: String
	public var arguments: [String: JSONValue]
	public var thoughtSignature: String?
	public var namespace: String?

	public init(
		id: String,
		name: String,
		arguments: [String: JSONValue] = [:],
		thoughtSignature: String? = nil,
		namespace: String? = nil
	) {
		self.id = id
		self.name = name
		self.arguments = arguments
		self.thoughtSignature = thoughtSignature
		self.namespace = namespace
	}
}

public enum AssistantContentBlock: Sendable, Hashable, Codable {
	case text(TextContent)
	case thinking(ThinkingContent)
	case toolCall(ToolCall)

	private enum CodingKeys: String, CodingKey {
		case type
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let type = try container.decode(String.self, forKey: .type)
		switch type {
		case "text":
			self = .text(try TextContent(from: decoder))
		case "thinking":
			self = .thinking(try ThinkingContent(from: decoder))
		case "toolCall":
			self = .toolCall(try ToolCall(from: decoder))
		default:
			throw DecodingError.dataCorruptedError(
				forKey: .type,
				in: container,
				debugDescription: "Unknown assistant content type: \(type)"
			)
		}
	}

	public func encode(to encoder: Encoder) throws {
		switch self {
		case .text(let value):
			try value.encode(to: encoder)
		case .thinking(let value):
			try value.encode(to: encoder)
		case .toolCall(let value):
			try value.encode(to: encoder)
		}
	}

	public var toolCall: ToolCall? {
		if case .toolCall(let value) = self { return value }
		return nil
	}
}

public enum UserContentBlock: Sendable, Hashable, Codable {
	case text(TextContent)
	case image(ImageContent)

	private enum CodingKeys: String, CodingKey {
		case type
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let type = try container.decode(String.self, forKey: .type)
		switch type {
		case "text":
			self = .text(try TextContent(from: decoder))
		case "image":
			self = .image(try ImageContent(from: decoder))
		default:
			throw DecodingError.dataCorruptedError(
				forKey: .type,
				in: container,
				debugDescription: "Unknown user content type: \(type)"
			)
		}
	}

	public func encode(to encoder: Encoder) throws {
		switch self {
		case .text(let value):
			try value.encode(to: encoder)
		case .image(let value):
			try value.encode(to: encoder)
		}
	}
}

// MARK: - Usage / stop

public struct CostBreakdown: Sendable, Hashable, Codable {
	public var input: Double
	public var output: Double
	public var cacheRead: Double
	public var cacheWrite: Double
	public var total: Double

	public init(
		input: Double = 0,
		output: Double = 0,
		cacheRead: Double = 0,
		cacheWrite: Double = 0,
		total: Double = 0
	) {
		self.input = input
		self.output = output
		self.cacheRead = cacheRead
		self.cacheWrite = cacheWrite
		self.total = total
	}

	public static let zero = CostBreakdown()
}

public struct Usage: Sendable, Hashable, Codable {
	public var input: Int
	public var output: Int
	public var cacheRead: Int
	public var cacheWrite: Int
	public var cacheWrite1h: Int?
	public var reasoning: Int?
	public var totalTokens: Int
	public var cost: CostBreakdown

	public init(
		input: Int = 0,
		output: Int = 0,
		cacheRead: Int = 0,
		cacheWrite: Int = 0,
		cacheWrite1h: Int? = nil,
		reasoning: Int? = nil,
		totalTokens: Int = 0,
		cost: CostBreakdown = .zero
	) {
		self.input = input
		self.output = output
		self.cacheRead = cacheRead
		self.cacheWrite = cacheWrite
		self.cacheWrite1h = cacheWrite1h
		self.reasoning = reasoning
		self.totalTokens = totalTokens
		self.cost = cost
	}

	public static let empty = Usage()
}

public enum StopReason: String, Sendable, Hashable, Codable {
	case pending
	case stop
	case length
	case toolUse
	case error
	case aborted
	case deferred
}

public struct DeferredHandle: Sendable, Hashable, Codable {
	public var provider: String
	public var modelId: String
	public var api: String
	public var id: String
	public var expiresAt: Double?
	public var pollAfterMs: Double?
	public var data: JSONValue?

	public init(
		provider: String,
		modelId: String,
		api: String,
		id: String,
		expiresAt: Double? = nil,
		pollAfterMs: Double? = nil,
		data: JSONValue? = nil
	) {
		self.provider = provider
		self.modelId = modelId
		self.api = api
		self.id = id
		self.expiresAt = expiresAt
		self.pollAfterMs = pollAfterMs
		self.data = data
	}
}

// MARK: - Messages

public struct UserMessage: Sendable, Hashable, Codable {
	public var role: String = "user"
	public var content: UserMessageContent
	public var timestamp: Double

	public enum UserMessageContent: Sendable, Hashable, Codable {
		case text(String)
		case blocks([UserContentBlock])

		public init(from decoder: Decoder) throws {
			let container = try decoder.singleValueContainer()
			if let text = try? container.decode(String.self) {
				self = .text(text)
			} else {
				self = .blocks(try container.decode([UserContentBlock].self))
			}
		}

		public func encode(to encoder: Encoder) throws {
			var container = encoder.singleValueContainer()
			switch self {
			case .text(let text):
				try container.encode(text)
			case .blocks(let blocks):
				try container.encode(blocks)
			}
		}
	}

	public init(content: UserMessageContent, timestamp: Double = Date().timeIntervalSince1970 * 1000) {
		self.content = content
		self.timestamp = timestamp
	}

	public init(text: String, timestamp: Double = Date().timeIntervalSince1970 * 1000) {
		self.init(content: .blocks([.text(TextContent(text: text))]), timestamp: timestamp)
	}
}

public struct AssistantMessage: Sendable, Hashable, Codable {
	public var role: String = "assistant"
	public var content: [AssistantContentBlock]
	public var api: String
	public var provider: String
	public var model: String
	public var responseModel: String?
	public var responseId: String?
	public var providerThinkingLevel: String?
	public var usage: Usage
	public var stopReason: StopReason
	public var deferred: DeferredHandle?
	public var errorMessage: String?
	public var rawStopReason: String?
	public var endTurn: Bool?
	public var timestamp: Double

	public init(
		content: [AssistantContentBlock] = [],
		api: String,
		provider: String,
		model: String,
		responseModel: String? = nil,
		responseId: String? = nil,
		providerThinkingLevel: String? = nil,
		usage: Usage = .empty,
		stopReason: StopReason = .pending,
		deferred: DeferredHandle? = nil,
		errorMessage: String? = nil,
		rawStopReason: String? = nil,
		endTurn: Bool? = nil,
		timestamp: Double = Date().timeIntervalSince1970 * 1000
	) {
		self.content = content
		self.api = api
		self.provider = provider
		self.model = model
		self.responseModel = responseModel
		self.responseId = responseId
		self.providerThinkingLevel = providerThinkingLevel
		self.usage = usage
		self.stopReason = stopReason
		self.deferred = deferred
		self.errorMessage = errorMessage
		self.rawStopReason = rawStopReason
		self.endTurn = endTurn
		self.timestamp = timestamp
	}

	public var toolCalls: [ToolCall] {
		content.compactMap(\.toolCall)
	}
}

public struct ToolResultMessage: Sendable, Hashable, Codable {
	public var role: String = "toolResult"
	public var toolCallId: String
	public var toolName: String
	public var content: [UserContentBlock]
	public var details: JSONValue?
	public var usage: Usage?
	public var addedToolNames: [String]?
	public var isError: Bool
	public var timestamp: Double

	public init(
		toolCallId: String,
		toolName: String,
		content: [UserContentBlock],
		details: JSONValue? = nil,
		usage: Usage? = nil,
		addedToolNames: [String]? = nil,
		isError: Bool,
		timestamp: Double = Date().timeIntervalSince1970 * 1000
	) {
		self.toolCallId = toolCallId
		self.toolName = toolName
		self.content = content
		self.details = details
		self.usage = usage
		self.addedToolNames = addedToolNames
		self.isError = isError
		self.timestamp = timestamp
	}
}

public enum Message: Sendable, Hashable, Codable {
	case user(UserMessage)
	case assistant(AssistantMessage)
	case toolResult(ToolResultMessage)

	public var role: String {
		switch self {
		case .user: return "user"
		case .assistant: return "assistant"
		case .toolResult: return "toolResult"
		}
	}

	private enum CodingKeys: String, CodingKey {
		case role
	}

	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		let role = try container.decode(String.self, forKey: .role)
		switch role {
		case "user":
			self = .user(try UserMessage(from: decoder))
		case "assistant":
			self = .assistant(try AssistantMessage(from: decoder))
		case "toolResult":
			self = .toolResult(try ToolResultMessage(from: decoder))
		default:
			throw DecodingError.dataCorruptedError(forKey: .role, in: container, debugDescription: "Unknown role: \(role)")
		}
	}

	public func encode(to encoder: Encoder) throws {
		switch self {
		case .user(let value):
			try value.encode(to: encoder)
		case .assistant(let value):
			try value.encode(to: encoder)
		case .toolResult(let value):
			try value.encode(to: encoder)
		}
	}
}

// MARK: - Model / tools / context

public struct ModelCostRates: Sendable, Hashable, Codable {
	public var input: Double
	public var output: Double
	public var cacheRead: Double
	public var cacheWrite: Double

	public init(input: Double = 0, output: Double = 0, cacheRead: Double = 0, cacheWrite: Double = 0) {
		self.input = input
		self.output = output
		self.cacheRead = cacheRead
		self.cacheWrite = cacheWrite
	}

	public static let zero = ModelCostRates()
}

public struct Model: Sendable, Hashable, Codable {
	public var id: String
	public var name: String
	public var api: String
	public var provider: String
	public var baseUrl: String
	public var reasoning: Bool
	public var input: [String]
	public var cost: ModelCostRates
	public var contextWindow: Int
	public var maxTokens: Int

	public init(
		id: String,
		name: String,
		api: String,
		provider: String,
		baseUrl: String = "",
		reasoning: Bool = false,
		input: [String] = ["text"],
		cost: ModelCostRates = .zero,
		contextWindow: Int = 0,
		maxTokens: Int = 0
	) {
		self.id = id
		self.name = name
		self.api = api
		self.provider = provider
		self.baseUrl = baseUrl
		self.reasoning = reasoning
		self.input = input
		self.cost = cost
		self.contextWindow = contextWindow
		self.maxTokens = maxTokens
	}

	public static let unknown = Model(
		id: "unknown",
		name: "unknown",
		api: "unknown",
		provider: "unknown"
	)
}

/// Tool definition for LLM context.
///
/// TypeScript uses TypeBox `TSchema` for `parameters`. The Swift port stores a
/// JSON Schema object (`parametersSchema`) so iOS hosts can validate without TypeBox.
public struct Tool: Sendable {
	public var name: String
	public var description: String
	public var parametersSchema: [String: JSONValue]

	public init(name: String, description: String, parametersSchema: [String: JSONValue] = [:]) {
		self.name = name
		self.description = description
		self.parametersSchema = parametersSchema
	}
}

public struct LLMContext: Sendable {
	public var systemPrompt: String?
	public var messages: [Message]
	public var tools: [Tool]?

	public init(systemPrompt: String? = nil, messages: [Message], tools: [Tool]? = nil) {
		self.systemPrompt = systemPrompt
		self.messages = messages
		self.tools = tools
	}
}

public enum ThinkingLevel: String, Sendable, Hashable, Codable {
	case off
	case minimal
	case low
	case medium
	case high
	case xhigh
	case max
}

public enum Transport: String, Sendable, Hashable, Codable {
	case sse
	case websocket
	case websocketCached = "websocket-cached"
	case auto
}

public struct ThinkingBudgets: Sendable, Hashable, Codable {
	public var minimal: Int?
	public var low: Int?
	public var medium: Int?
	public var high: Int?

	public init(minimal: Int? = nil, low: Int? = nil, medium: Int? = nil, high: Int? = nil) {
		self.minimal = minimal
		self.low = low
		self.medium = medium
		self.high = high
	}
}

public struct ProviderResponse: Sendable, Hashable {
	public var status: Int
	public var headers: [String: String]

	public init(status: Int, headers: [String: String] = [:]) {
		self.status = status
		self.headers = headers
	}
}

/// Subset of TypeScript `SimpleStreamOptions` needed by the agent loop and proxy.
public struct SimpleStreamOptions: Sendable {
	public var signal: CancellationToken?
	public var apiKey: String?
	public var temperature: Double?
	public var maxTokens: Int?
	public var reasoning: ThinkingLevel?
	public var sessionId: String?
	public var transport: Transport?
	public var thinkingBudgets: ThinkingBudgets?
	public var maxRetryDelayMs: Double?
	public var headers: [String: String?]?
	public var onPayload: (@Sendable (JSONValue, Model) async -> JSONValue?)?
	public var onResponse: (@Sendable (ProviderResponse, Model) async -> Void)?

	public init(
		signal: CancellationToken? = nil,
		apiKey: String? = nil,
		temperature: Double? = nil,
		maxTokens: Int? = nil,
		reasoning: ThinkingLevel? = nil,
		sessionId: String? = nil,
		transport: Transport? = nil,
		thinkingBudgets: ThinkingBudgets? = nil,
		maxRetryDelayMs: Double? = nil,
		headers: [String: String?]? = nil,
		onPayload: (@Sendable (JSONValue, Model) async -> JSONValue?)? = nil,
		onResponse: (@Sendable (ProviderResponse, Model) async -> Void)? = nil
	) {
		self.signal = signal
		self.apiKey = apiKey
		self.temperature = temperature
		self.maxTokens = maxTokens
		self.reasoning = reasoning
		self.sessionId = sessionId
		self.transport = transport
		self.thinkingBudgets = thinkingBudgets
		self.maxRetryDelayMs = maxRetryDelayMs
		self.headers = headers
		self.onPayload = onPayload
		self.onResponse = onResponse
	}
}

// MARK: - Assistant stream events

public enum AssistantMessageEvent: Sendable {
	case start(partial: AssistantMessage)
	case textStart(contentIndex: Int, partial: AssistantMessage)
	case textDelta(contentIndex: Int, delta: String, partial: AssistantMessage)
	case textEnd(contentIndex: Int, content: String, partial: AssistantMessage)
	case thinkingStart(contentIndex: Int, partial: AssistantMessage)
	case thinkingDelta(contentIndex: Int, delta: String, partial: AssistantMessage)
	case thinkingEnd(contentIndex: Int, content: String, partial: AssistantMessage)
	case toolCallStart(contentIndex: Int, partial: AssistantMessage)
	case toolCallDelta(contentIndex: Int, delta: String, partial: AssistantMessage)
	case toolCallEnd(contentIndex: Int, toolCall: ToolCall, partial: AssistantMessage)
	case done(reason: StopReason, message: AssistantMessage)
	case error(reason: StopReason, error: AssistantMessage)

	public var typeName: String {
		switch self {
		case .start: return "start"
		case .textStart: return "text_start"
		case .textDelta: return "text_delta"
		case .textEnd: return "text_end"
		case .thinkingStart: return "thinking_start"
		case .thinkingDelta: return "thinking_delta"
		case .thinkingEnd: return "thinking_end"
		case .toolCallStart: return "toolcall_start"
		case .toolCallDelta: return "toolcall_delta"
		case .toolCallEnd: return "toolcall_end"
		case .done: return "done"
		case .error: return "error"
		}
	}

	public var partial: AssistantMessage? {
		switch self {
		case .start(let partial),
			.textStart(_, let partial),
			.textDelta(_, _, let partial),
			.textEnd(_, _, let partial),
			.thinkingStart(_, let partial),
			.thinkingDelta(_, _, let partial),
			.thinkingEnd(_, _, let partial),
			.toolCallStart(_, let partial),
			.toolCallDelta(_, _, let partial),
			.toolCallEnd(_, _, let partial):
			return partial
		case .done, .error:
			return nil
		}
	}
}
