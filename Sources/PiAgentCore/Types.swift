import Foundation
import Synchronization
import PiAI

public typealias ThinkingLevel = PiAI.ThinkingLevel

/// Stream function used by the agent loop.
///
/// Contract (same as TypeScript):
/// - Must not throw for request/model/runtime failures.
/// - Failures must be encoded in the returned stream via protocol events and a
///   final `AssistantMessage` with stopReason `error` or `aborted`.
public typealias StreamFn = @Sendable (
	_ model: Model,
	_ context: LLMContext,
	_ options: SimpleStreamOptions?
) async -> AssistantMessageEventStream

public enum ToolExecutionMode: String, Sendable, Hashable, Codable {
	case sequential
	case parallel
}

public enum QueueMode: String, Sendable, Hashable, Codable {
	case all
	case oneAtATime = "one-at-a-time"
}

public typealias AgentToolCall = ToolCall

public struct BeforeToolCallResult: Sendable {
	public var block: Bool?
	public var reason: String?
	public var terminate: Bool?

	public init(block: Bool? = nil, reason: String? = nil, terminate: Bool? = nil) {
		self.block = block
		self.reason = reason
		self.terminate = terminate
	}
}

public struct AfterToolCallResult: Sendable {
	public var content: [UserContentBlock]?
	public var details: JSONValue?
	public var isError: Bool?
	public var usage: Usage?
	public var terminate: Bool?

	public init(
		content: [UserContentBlock]? = nil,
		details: JSONValue? = nil,
		isError: Bool? = nil,
		usage: Usage? = nil,
		terminate: Bool? = nil
	) {
		self.content = content
		self.details = details
		self.isError = isError
		self.usage = usage
		self.terminate = terminate
	}
}

public struct AgentToolResult: Sendable {
	public var content: [UserContentBlock]
	public var details: JSONValue
	public var usage: Usage?
	public var addedToolNames: [String]?
	public var terminate: Bool?

	public init(
		content: [UserContentBlock],
		details: JSONValue = .object([:]),
		usage: Usage? = nil,
		addedToolNames: [String]? = nil,
		terminate: Bool? = nil
	) {
		self.content = content
		self.details = details
		self.usage = usage
		self.addedToolNames = addedToolNames
		self.terminate = terminate
	}
}

public typealias AgentToolUpdateCallback = @Sendable (AgentToolResult) -> Void

/// Tool definition used by the agent runtime.
public struct AgentTool: Sendable {
	public var name: String
	public var description: String
	public var label: String
	public var parametersSchema: [String: JSONValue]
	public var prepareArguments: (@Sendable ([String: JSONValue]) -> [String: JSONValue])?
	public var execute: @Sendable (
		_ toolCallId: String,
		_ params: [String: JSONValue],
		_ signal: CancellationToken?,
		_ onUpdate: AgentToolUpdateCallback?
	) async throws -> AgentToolResult
	public var replay: String?
	public var executionMode: ToolExecutionMode?

	public init(
		name: String,
		description: String,
		label: String,
		parametersSchema: [String: JSONValue] = ["type": .string("object"), "properties": .object([:])],
		prepareArguments: (@Sendable ([String: JSONValue]) -> [String: JSONValue])? = nil,
		execute: @escaping @Sendable (
			_ toolCallId: String,
			_ params: [String: JSONValue],
			_ signal: CancellationToken?,
			_ onUpdate: AgentToolUpdateCallback?
		) async throws -> AgentToolResult,
		replay: String? = nil,
		executionMode: ToolExecutionMode? = nil
	) {
		self.name = name
		self.description = description
		self.label = label
		self.parametersSchema = parametersSchema
		self.prepareArguments = prepareArguments
		self.execute = execute
		self.replay = replay
		self.executionMode = executionMode
	}

	public var asTool: Tool {
		Tool(name: name, description: description, parametersSchema: parametersSchema)
	}
}

/// Agent-level message. Custom app roles can be added later via associated values / wrappers.
public enum AgentMessage: Sendable, Hashable {
	case llm(Message)

	public var role: String {
		switch self {
		case .llm(let message):
			return message.role
		}
	}

	public var asMessage: Message? {
		switch self {
		case .llm(let message):
			return message
		}
	}

	public static func user(_ message: UserMessage) -> AgentMessage {
		.llm(.user(message))
	}

	public static func assistant(_ message: AssistantMessage) -> AgentMessage {
		.llm(.assistant(message))
	}

	public static func toolResult(_ message: ToolResultMessage) -> AgentMessage {
		.llm(.toolResult(message))
	}
}

public struct AgentContext: Sendable {
	public var systemPrompt: String
	public var messages: [AgentMessage]
	public var tools: [AgentTool]?

	public init(systemPrompt: String, messages: [AgentMessage], tools: [AgentTool]? = nil) {
		self.systemPrompt = systemPrompt
		self.messages = messages
		self.tools = tools
	}
}

public struct BeforeToolCallContext: Sendable {
	public var assistantMessage: AssistantMessage
	public var toolCall: AgentToolCall
	public var args: [String: JSONValue]
	public var context: AgentContext
}

public struct AfterToolCallContext: Sendable {
	public var assistantMessage: AssistantMessage
	public var toolCall: AgentToolCall
	public var args: [String: JSONValue]
	public var result: AgentToolResult
	public var isError: Bool
	public var context: AgentContext
}

public struct ShouldStopAfterTurnContext: Sendable {
	public var message: AssistantMessage
	public var toolResults: [ToolResultMessage]
	public var context: AgentContext
	public var newMessages: [AgentMessage]
}

public typealias PrepareNextTurnContext = ShouldStopAfterTurnContext

public struct AgentLoopTurnUpdate: Sendable {
	public var context: AgentContext?
	public var model: Model?
	public var thinkingLevel: ThinkingLevel?

	public init(context: AgentContext? = nil, model: Model? = nil, thinkingLevel: ThinkingLevel? = nil) {
		self.context = context
		self.model = model
		self.thinkingLevel = thinkingLevel
	}
}

public struct AgentLoopConfig: Sendable {
	public var model: Model
	public var reasoning: ThinkingLevel?
	public var sessionId: String?
	public var transport: Transport?
	public var thinkingBudgets: ThinkingBudgets?
	public var maxRetryDelayMs: Double?
	public var apiKey: String?
	public var toolExecution: ToolExecutionMode?
	public var onPayload: (@Sendable (JSONValue, Model) async -> JSONValue?)?
	public var onResponse: (@Sendable (ProviderResponse, Model) async -> Void)?

	public var convertToLlm: @Sendable ([AgentMessage]) async -> [Message]
	public var transformContext: (@Sendable ([AgentMessage], CancellationToken?) async -> [AgentMessage])?
	public var getApiKey: (@Sendable (String) async -> String?)?
	public var shouldStopAfterTurn: (@Sendable (ShouldStopAfterTurnContext) async -> Bool)?
	public var prepareNextTurn: (@Sendable (PrepareNextTurnContext) async -> AgentLoopTurnUpdate?)?
	public var getSteeringMessages: (@Sendable () async -> [AgentMessage])?
	public var getFollowUpMessages: (@Sendable () async -> [AgentMessage])?
	public var beforeToolCall: (@Sendable (BeforeToolCallContext, CancellationToken?) async -> BeforeToolCallResult?)?
	public var afterToolCall: (@Sendable (AfterToolCallContext, CancellationToken?) async -> AfterToolCallResult?)?

	public init(
		model: Model,
		reasoning: ThinkingLevel? = nil,
		sessionId: String? = nil,
		transport: Transport? = nil,
		thinkingBudgets: ThinkingBudgets? = nil,
		maxRetryDelayMs: Double? = nil,
		apiKey: String? = nil,
		toolExecution: ToolExecutionMode? = nil,
		onPayload: (@Sendable (JSONValue, Model) async -> JSONValue?)? = nil,
		onResponse: (@Sendable (ProviderResponse, Model) async -> Void)? = nil,
		convertToLlm: @escaping @Sendable ([AgentMessage]) async -> [Message],
		transformContext: (@Sendable ([AgentMessage], CancellationToken?) async -> [AgentMessage])? = nil,
		getApiKey: (@Sendable (String) async -> String?)? = nil,
		shouldStopAfterTurn: (@Sendable (ShouldStopAfterTurnContext) async -> Bool)? = nil,
		prepareNextTurn: (@Sendable (PrepareNextTurnContext) async -> AgentLoopTurnUpdate?)? = nil,
		getSteeringMessages: (@Sendable () async -> [AgentMessage])? = nil,
		getFollowUpMessages: (@Sendable () async -> [AgentMessage])? = nil,
		beforeToolCall: (@Sendable (BeforeToolCallContext, CancellationToken?) async -> BeforeToolCallResult?)? = nil,
		afterToolCall: (@Sendable (AfterToolCallContext, CancellationToken?) async -> AfterToolCallResult?)? = nil
	) {
		self.model = model
		self.reasoning = reasoning
		self.sessionId = sessionId
		self.transport = transport
		self.thinkingBudgets = thinkingBudgets
		self.maxRetryDelayMs = maxRetryDelayMs
		self.apiKey = apiKey
		self.toolExecution = toolExecution
		self.onPayload = onPayload
		self.onResponse = onResponse
		self.convertToLlm = convertToLlm
		self.transformContext = transformContext
		self.getApiKey = getApiKey
		self.shouldStopAfterTurn = shouldStopAfterTurn
		self.prepareNextTurn = prepareNextTurn
		self.getSteeringMessages = getSteeringMessages
		self.getFollowUpMessages = getFollowUpMessages
		self.beforeToolCall = beforeToolCall
		self.afterToolCall = afterToolCall
	}
}

public enum AgentEvent: Sendable {
	case agentStart
	case agentEnd(messages: [AgentMessage])
	case turnStart
	case turnEnd(message: AgentMessage, toolResults: [ToolResultMessage])
	case messageStart(message: AgentMessage)
	case messageUpdate(message: AgentMessage, assistantMessageEvent: AssistantMessageEvent)
	case messageEnd(message: AgentMessage)
	case toolExecutionStart(toolCallId: String, toolName: String, args: [String: JSONValue])
	case toolExecutionUpdate(toolCallId: String, toolName: String, args: [String: JSONValue], partialResult: AgentToolResult)
	case toolExecutionEnd(toolCallId: String, toolName: String, result: AgentToolResult, isError: Bool)

	public var typeName: String {
		switch self {
		case .agentStart: return "agent_start"
		case .agentEnd: return "agent_end"
		case .turnStart: return "turn_start"
		case .turnEnd: return "turn_end"
		case .messageStart: return "message_start"
		case .messageUpdate: return "message_update"
		case .messageEnd: return "message_end"
		case .toolExecutionStart: return "tool_execution_start"
		case .toolExecutionUpdate: return "tool_execution_update"
		case .toolExecutionEnd: return "tool_execution_end"
		}
	}
}

public final class AgentState: Sendable {
	private struct Storage {
		var systemPrompt: String
		var model: Model
		var thinkingLevel: ThinkingLevel
		var tools: [AgentTool]
		var messages: [AgentMessage]
		var isStreaming = false
		var streamingMessage: AgentMessage?
		var pendingToolCalls = Set<String>()
		var errorMessage: String?
	}

	private let storage: Mutex<Storage>

	public init(
		systemPrompt: String = "",
		model: Model = .unknown,
		thinkingLevel: ThinkingLevel = .off,
		tools: [AgentTool] = [],
		messages: [AgentMessage] = []
	) {
		storage = Mutex(
			Storage(
				systemPrompt: systemPrompt,
				model: model,
				thinkingLevel: thinkingLevel,
				tools: tools,
				messages: messages
			)
		)
	}

	public var systemPrompt: String {
		get { storage.withLock(\.systemPrompt) }
		set { storage.withLock { $0.systemPrompt = newValue } }
	}

	public var model: Model {
		get { storage.withLock(\.model) }
		set { storage.withLock { $0.model = newValue } }
	}

	public var thinkingLevel: ThinkingLevel {
		get { storage.withLock(\.thinkingLevel) }
		set { storage.withLock { $0.thinkingLevel = newValue } }
	}

	public var tools: [AgentTool] {
		get { storage.withLock(\.tools) }
		set { storage.withLock { $0.tools = newValue } }
	}

	public var messages: [AgentMessage] {
		get { storage.withLock(\.messages) }
		set { storage.withLock { $0.messages = newValue } }
	}

	public var isStreaming: Bool {
		get { storage.withLock(\.isStreaming) }
		set { storage.withLock { $0.isStreaming = newValue } }
	}

	public var streamingMessage: AgentMessage? {
		get { storage.withLock(\.streamingMessage) }
		set { storage.withLock { $0.streamingMessage = newValue } }
	}

	public var pendingToolCalls: Set<String> {
		get { storage.withLock(\.pendingToolCalls) }
		set { storage.withLock { $0.pendingToolCalls = newValue } }
	}

	public var errorMessage: String? {
		get { storage.withLock(\.errorMessage) }
		set { storage.withLock { $0.errorMessage = newValue } }
	}
}
