import Foundation
import Synchronization
import PiAI

public struct AgentOptions: Sendable {
	public var initialState: AgentState?
	public var convertToLlm: (@Sendable ([AgentMessage]) async -> [Message])?
	public var transformContext: (@Sendable ([AgentMessage], CancellationToken?) async -> [AgentMessage])?
	public var streamFn: StreamFn
	public var getApiKey: (@Sendable (String) async -> String?)?
	public var onPayload: (@Sendable (JSONValue, Model) async -> JSONValue?)?
	public var onResponse: (@Sendable (ProviderResponse, Model) async -> Void)?
	public var beforeToolCall: (@Sendable (BeforeToolCallContext, CancellationToken?) async -> BeforeToolCallResult?)?
	public var afterToolCall: (@Sendable (AfterToolCallContext, CancellationToken?) async -> AfterToolCallResult?)?
	public var shouldStopAfterTurn: (@Sendable (ShouldStopAfterTurnContext, CancellationToken?) async -> Bool)?
	public var prepareNextTurn: (@Sendable (CancellationToken?) async -> AgentLoopTurnUpdate?)?
	public var prepareNextTurnWithContext: (@Sendable (PrepareNextTurnContext, CancellationToken?) async -> AgentLoopTurnUpdate?)?
	public var steeringMode: QueueMode
	public var followUpMode: QueueMode
	public var temperature: Double?
	public var samplingParams: [String: JSONValue]?
	public var maxTokens: Int?
	public var cacheRetention: CacheRetention?
	public var sessionId: String?
	public var metadata: [String: JSONValue]?
	public var thinkingBudgets: ThinkingBudgets?
	public var transport: Transport
	public var maxRetryDelayMs: Double?
	public var headers: [String: String?]?
	public var toolExecution: ToolExecutionMode

	public init(
		initialState: AgentState? = nil,
		convertToLlm: (@Sendable ([AgentMessage]) async -> [Message])? = nil,
		transformContext: (@Sendable ([AgentMessage], CancellationToken?) async -> [AgentMessage])? = nil,
		streamFn: @escaping StreamFn,
		getApiKey: (@Sendable (String) async -> String?)? = nil,
		onPayload: (@Sendable (JSONValue, Model) async -> JSONValue?)? = nil,
		onResponse: (@Sendable (ProviderResponse, Model) async -> Void)? = nil,
		beforeToolCall: (@Sendable (BeforeToolCallContext, CancellationToken?) async -> BeforeToolCallResult?)? = nil,
		afterToolCall: (@Sendable (AfterToolCallContext, CancellationToken?) async -> AfterToolCallResult?)? = nil,
		shouldStopAfterTurn: (@Sendable (ShouldStopAfterTurnContext, CancellationToken?) async -> Bool)? = nil,
		prepareNextTurn: (@Sendable (CancellationToken?) async -> AgentLoopTurnUpdate?)? = nil,
		prepareNextTurnWithContext: (@Sendable (PrepareNextTurnContext, CancellationToken?) async -> AgentLoopTurnUpdate?)? = nil,
		steeringMode: QueueMode = .oneAtATime,
		followUpMode: QueueMode = .oneAtATime,
		temperature: Double? = nil,
		samplingParams: [String: JSONValue]? = nil,
		maxTokens: Int? = nil,
		cacheRetention: CacheRetention? = nil,
		sessionId: String? = nil,
		metadata: [String: JSONValue]? = nil,
		thinkingBudgets: ThinkingBudgets? = nil,
		transport: Transport = .auto,
		maxRetryDelayMs: Double? = nil,
		headers: [String: String?]? = nil,
		toolExecution: ToolExecutionMode = .parallel
	) {
		self.initialState = initialState
		self.convertToLlm = convertToLlm
		self.transformContext = transformContext
		self.streamFn = streamFn
		self.getApiKey = getApiKey
		self.onPayload = onPayload
		self.onResponse = onResponse
		self.beforeToolCall = beforeToolCall
		self.afterToolCall = afterToolCall
		self.shouldStopAfterTurn = shouldStopAfterTurn
		self.prepareNextTurn = prepareNextTurn
		self.prepareNextTurnWithContext = prepareNextTurnWithContext
		self.steeringMode = steeringMode
		self.followUpMode = followUpMode
		self.temperature = temperature
		self.samplingParams = samplingParams
		self.maxTokens = maxTokens
		self.cacheRetention = cacheRetention
		self.sessionId = sessionId
		self.metadata = metadata
		self.thinkingBudgets = thinkingBudgets
		self.transport = transport
		self.maxRetryDelayMs = maxRetryDelayMs
		self.headers = headers
		self.toolExecution = toolExecution
	}
}

private final class PendingMessageQueue: Sendable {
	private struct State {
		var messages: [AgentMessage] = []
		var mode: QueueMode
	}

	private let state: Mutex<State>

	init(mode: QueueMode) {
		state = Mutex(State(mode: mode))
	}

	var mode: QueueMode {
		get { state.withLock(\.mode) }
		set { state.withLock { $0.mode = newValue } }
	}

	func enqueue(_ message: AgentMessage) {
		state.withLock { $0.messages.append(message) }
	}

	func hasItems() -> Bool {
		state.withLock { !$0.messages.isEmpty }
	}

	func drain() -> [AgentMessage] {
		state.withLock { state in
			switch state.mode {
			case .all:
				let drained = state.messages
				state.messages = []
				return drained
			case .oneAtATime:
				guard let first = state.messages.first else { return [] }
				state.messages = Array(state.messages.dropFirst())
				return [first]
			}
		}
	}

	func clear() {
		state.withLock { $0.messages = [] }
	}
}

private final class IdleBox: Sendable {
	private struct State {
		var continuation: CheckedContinuation<Void, Never>?
		var isResumed = false
	}

	private let state = Mutex(State())

	func wait() async {
		await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
			let shouldResumeNow = state.withLock { state -> Bool in
				if state.isResumed {
					return true
				}
				state.continuation = cont
				return false
			}
			if shouldResumeNow {
				cont.resume()
			}
		}
	}

	func resume() {
		let cont = state.withLock { state -> CheckedContinuation<Void, Never>? in
			state.isResumed = true
			let cont = state.continuation
			state.continuation = nil
			return cont
		}
		cont?.resume()
	}
}

private struct ActiveRun: Sendable {
	var idle: IdleBox
	var abortController: CancellationController
}

/// Stateful wrapper around the low-level agent loop.
public final class Agent: Sendable {
	public let state: AgentState
	private struct ListenerState {
		var listeners: [UUID: @Sendable (AgentEvent, CancellationToken) async -> Void] = [:]
	}

	private let listeners = Mutex(ListenerState())
	private let steeringQueue: PendingMessageQueue
	private let followUpQueue: PendingMessageQueue
	private let activeRun = Mutex<ActiveRun?>(nil)

	private struct Hooks: Sendable {
		var convertToLlm: @Sendable ([AgentMessage]) async -> [Message]
		var transformContext: (@Sendable ([AgentMessage], CancellationToken?) async -> [AgentMessage])?
		var streamFunction: StreamFn
		var getApiKey: (@Sendable (String) async -> String?)?
		var onPayload: (@Sendable (JSONValue, Model) async -> JSONValue?)?
		var onResponse: (@Sendable (ProviderResponse, Model) async -> Void)?
		var beforeToolCall: (@Sendable (BeforeToolCallContext, CancellationToken?) async -> BeforeToolCallResult?)?
		var afterToolCall: (@Sendable (AfterToolCallContext, CancellationToken?) async -> AfterToolCallResult?)?
		var shouldStopAfterTurn: (@Sendable (ShouldStopAfterTurnContext, CancellationToken?) async -> Bool)?
		var prepareNextTurn: (@Sendable (CancellationToken?) async -> AgentLoopTurnUpdate?)?
		var prepareNextTurnWithContext: (@Sendable (PrepareNextTurnContext, CancellationToken?) async -> AgentLoopTurnUpdate?)?
		var temperature: Double?
		var samplingParams: [String: JSONValue]?
		var maxTokens: Int?
		var cacheRetention: CacheRetention?
		var sessionId: String?
		var metadata: [String: JSONValue]?
		var thinkingBudgets: ThinkingBudgets?
		var transport: Transport
		var maxRetryDelayMs: Double?
		var headers: [String: String?]?
		var toolExecution: ToolExecutionMode
	}

	private let hooks: Mutex<Hooks>

	public init(options: AgentOptions) {
		state = options.initialState ?? AgentState()
		hooks = Mutex(
			Hooks(
				convertToLlm: options.convertToLlm ?? { messages in
					messages.map(\.asMessage)
				},
				transformContext: options.transformContext,
				streamFunction: options.streamFn,
				getApiKey: options.getApiKey,
				onPayload: options.onPayload,
				onResponse: options.onResponse,
				beforeToolCall: options.beforeToolCall,
				afterToolCall: options.afterToolCall,
				shouldStopAfterTurn: options.shouldStopAfterTurn,
				prepareNextTurn: options.prepareNextTurn,
				prepareNextTurnWithContext: options.prepareNextTurnWithContext,
				temperature: options.temperature,
				samplingParams: options.samplingParams,
				maxTokens: options.maxTokens,
				cacheRetention: options.cacheRetention,
				sessionId: options.sessionId,
				metadata: options.metadata,
				thinkingBudgets: options.thinkingBudgets,
				transport: options.transport,
				maxRetryDelayMs: options.maxRetryDelayMs,
				headers: options.headers,
				toolExecution: options.toolExecution
			)
		)
		steeringQueue = PendingMessageQueue(mode: options.steeringMode)
		followUpQueue = PendingMessageQueue(mode: options.followUpMode)
	}

	public var streamFunction: StreamFn {
		get { hooks.withLock(\.streamFunction) }
		set { hooks.withLock { $0.streamFunction = newValue } }
	}

	public var convertToLlm: @Sendable ([AgentMessage]) async -> [Message] {
		get { hooks.withLock(\.convertToLlm) }
		set { hooks.withLock { $0.convertToLlm = newValue } }
	}

	public var sessionId: String? {
		get { hooks.withLock(\.sessionId) }
		set { hooks.withLock { $0.sessionId = newValue } }
	}

	public var toolExecution: ToolExecutionMode {
		get { hooks.withLock(\.toolExecution) }
		set { hooks.withLock { $0.toolExecution = newValue } }
	}

	@discardableResult
	public func subscribe(
		_ listener: @escaping @Sendable (AgentEvent, CancellationToken) async -> Void
	) -> @Sendable () -> Void {
		let id = UUID()
		listeners.withLock { state in
			state.listeners[id] = listener
		}
		return {
			self.listeners.withLock { state in
				state.listeners[id] = nil
			}
		}
	}

	public var steeringMode: QueueMode {
		get { steeringQueue.mode }
		set { steeringQueue.mode = newValue }
	}

	public var followUpMode: QueueMode {
		get { followUpQueue.mode }
		set { followUpQueue.mode = newValue }
	}

	public func steer(_ message: AgentMessage) {
		steeringQueue.enqueue(message)
	}

	public func followUp(_ message: AgentMessage) {
		followUpQueue.enqueue(message)
	}

	public func clearSteeringQueue() {
		steeringQueue.clear()
	}

	public func clearFollowUpQueue() {
		followUpQueue.clear()
	}

	public func clearAllQueues() {
		clearSteeringQueue()
		clearFollowUpQueue()
	}

	public func hasQueuedMessages() -> Bool {
		steeringQueue.hasItems() || followUpQueue.hasItems()
	}

	public var signal: CancellationToken? {
		activeRun.withLock { $0?.abortController.token }
	}

	public func abort() {
		activeRun.withLock { $0?.abortController }?.cancel()
	}

	public func waitForIdle() async {
		let idle = activeRun.withLock { $0?.idle }
		await idle?.wait()
	}

	public func reset() throws {
		if activeRun.withLock({ $0 != nil }) {
			throw AgentError.alreadyProcessing
		}
		state.messages = []
		state.isStreaming = false
		state.streamingMessage = nil
		state.pendingToolCalls = []
		state.errorMessage = nil
		clearAllQueues()
	}

	public func prompt(text: String, images: [ImageContent] = []) async throws {
		try await prompt(messages: normalizePromptInput(text, images: images))
	}

	public func prompt(message: AgentMessage) async throws {
		try await prompt(messages: [message])
	}

	public func prompt(messages: [AgentMessage]) async throws {
		try ensureIdle()
		await runPromptMessages(messages)
	}

	public func `continue`() async throws {
		try ensureIdle()

		guard let lastMessage = state.messages.last else {
			throw AgentError.noMessagesToContinue
		}

		if lastMessage.role == "assistant" {
			let queuedSteering = steeringQueue.drain()
			if !queuedSteering.isEmpty {
				await runPromptMessages(queuedSteering, skipInitialSteeringPoll: true)
				return
			}
			let queuedFollowUps = followUpQueue.drain()
			if !queuedFollowUps.isEmpty {
				await runPromptMessages(queuedFollowUps)
				return
			}
			throw AgentError.cannotContinueFromAssistant
		}

		await runContinuation()
	}

	private func ensureIdle() throws {
		if activeRun.withLock({ $0 != nil }) {
			throw AgentError.alreadyProcessing
		}
	}

	private func normalizePromptInput(_ input: String, images: [ImageContent]) -> [AgentMessage] {
		var content: [UserContentBlock] = [.text(TextContent(text: input))]
		content.append(contentsOf: images.map { .image($0) })
		return [.user(UserMessage(content: .blocks(content)))]
	}

	private func runPromptMessages(
		_ messages: [AgentMessage],
		skipInitialSteeringPoll: Bool = false
	) async {
		await runWithLifecycle { signal in
			_ = try await runAgentLoop(
				prompts: messages,
				context: self.createContextSnapshot(),
				config: self.createLoopConfig(skipInitialSteeringPoll: skipInitialSteeringPoll),
				emit: { event in
					await self.processEvents(event)
				},
				signal: signal,
				streamFn: self.hooks.withLock(\.streamFunction)
			)
		}
	}

	private func runContinuation() async {
		await runWithLifecycle { signal in
			_ = try await runAgentLoopContinue(
				context: self.createContextSnapshot(),
				config: self.createLoopConfig(),
				emit: { event in
					await self.processEvents(event)
				},
				signal: signal,
				streamFn: self.hooks.withLock(\.streamFunction)
			)
		}
	}

	private func createContextSnapshot() -> AgentContext {
		AgentContext(
			systemPrompt: state.systemPrompt,
			messages: state.messages,
			tools: state.tools
		)
	}

	private func createLoopConfig(skipInitialSteeringPoll: Bool = false) -> AgentLoopConfig {
		final class SkipFlag: @unchecked Sendable {
			var value: Bool
			init(_ value: Bool) { self.value = value }
		}
		let skip = SkipFlag(skipInitialSteeringPoll)
		let h = hooks.withLock { $0 }

		let prepareNextTurnHook: (@Sendable (PrepareNextTurnContext) async -> AgentLoopTurnUpdate?)?
		if let withContext = h.prepareNextTurnWithContext {
			prepareNextTurnHook = { context in
				await withContext(context, self.signal)
			}
		} else if let prepare = h.prepareNextTurn {
			prepareNextTurnHook = { _ in
				await prepare(self.signal)
			}
		} else {
			prepareNextTurnHook = nil
		}

		let shouldStopHook: (@Sendable (ShouldStopAfterTurnContext) async -> Bool)?
		if let stop = h.shouldStopAfterTurn {
			shouldStopHook = { context in
				await stop(context, self.signal)
			}
		} else {
			shouldStopHook = nil
		}

		let getSteering: @Sendable () async -> [AgentMessage] = {
			if skip.value {
				skip.value = false
				return []
			}
			return self.steeringQueue.drain()
		}
		let getFollowUp: @Sendable () async -> [AgentMessage] = {
			self.followUpQueue.drain()
		}

		return AgentLoopConfig(
			model: state.model,
			temperature: h.temperature,
			samplingParams: h.samplingParams,
			maxTokens: h.maxTokens,
			reasoning: state.thinkingLevel == .off ? nil : state.thinkingLevel,
			cacheRetention: h.cacheRetention,
			sessionId: h.sessionId,
			metadata: h.metadata,
			transport: h.transport,
			thinkingBudgets: h.thinkingBudgets,
			maxRetryDelayMs: h.maxRetryDelayMs,
			headers: h.headers,
			toolExecution: h.toolExecution,
			onPayload: h.onPayload,
			onResponse: h.onResponse,
			convertToLlm: h.convertToLlm,
			transformContext: h.transformContext,
			getApiKey: h.getApiKey,
			shouldStopAfterTurn: shouldStopHook,
			prepareNextTurn: prepareNextTurnHook,
			getSteeringMessages: getSteering,
			getFollowUpMessages: getFollowUp,
			beforeToolCall: h.beforeToolCall,
			afterToolCall: h.afterToolCall
		)
	}

	private func runWithLifecycle(_ executor: (CancellationToken) async throws -> Void) async {
		let abortController = CancellationController()
		let idle = IdleBox()
		activeRun.withLock { $0 = ActiveRun(idle: idle, abortController: abortController) }

		state.isStreaming = true
		state.streamingMessage = nil
		state.errorMessage = nil

		do {
			try await executor(abortController.token)
		} catch {
			await handleRunFailure(error, aborted: abortController.token.isCancelled)
		}

		state.isStreaming = false
		state.streamingMessage = nil
		state.pendingToolCalls = []
		activeRun.withLock { $0 = nil }
		idle.resume()
	}

	private func handleRunFailure(_ error: Error, aborted: Bool) async {
		let failureMessage = AssistantMessage(
			content: [.text(TextContent(text: ""))],
			api: state.model.api,
			provider: state.model.provider,
			model: state.model.id,
			usage: .empty,
			stopReason: aborted ? .aborted : .error,
			errorMessage: error.localizedDescription
		)
		await processEvents(.messageStart(message: .assistant(failureMessage)))
		await processEvents(.messageEnd(message: .assistant(failureMessage)))
		await processEvents(.turnEnd(message: .assistant(failureMessage), toolResults: []))
		await processEvents(.agentEnd(messages: [.assistant(failureMessage)]))
	}

	private func processEvents(_ event: AgentEvent) async {
		switch event {
		case .messageStart(let message), .messageUpdate(let message, _):
			state.streamingMessage = message
		case .messageEnd(let message):
			state.streamingMessage = nil
			state.messages.append(message)
		case .toolExecutionStart(let toolCallId, _, _):
			var pending = state.pendingToolCalls
			pending.insert(toolCallId)
			state.pendingToolCalls = pending
		case .toolExecutionEnd(let toolCallId, _, _, _):
			var pending = state.pendingToolCalls
			pending.remove(toolCallId)
			state.pendingToolCalls = pending
		case .turnEnd(let message, _):
			switch message {
			case .llm(.assistant(let assistant)):
				if let errorMessage = assistant.errorMessage {
					state.errorMessage = errorMessage
				}
			default:
				break
			}
		case .agentEnd:
			state.streamingMessage = nil
		case .agentStart, .turnStart, .toolExecutionUpdate:
			break
		}

		guard let signal = signal else {
			assertionFailure("Agent listener invoked outside active run")
			return
		}
		let currentListeners = Array(listeners.withLock(\.listeners.values))
		for listener in currentListeners {
			await listener(event, signal)
		}
	}
}

public enum AgentError: Error, LocalizedError, Sendable {
	case alreadyProcessing
	case noMessagesToContinue
	case cannotContinueFromAssistant
	case noDefaultStreamFn
	case listenerOutsideActiveRun

	public var errorDescription: String? {
		switch self {
		case .alreadyProcessing:
			return "Agent is already processing a prompt. Use steer() or followUp() to queue messages, or wait for completion."
		case .noMessagesToContinue:
			return "No messages to continue from"
		case .cannotContinueFromAssistant:
			return "Cannot continue from message role: assistant"
		case .noDefaultStreamFn:
			return "No default stream function configured. Pass streamFn explicitly or call setDefaultStreamFn()."
		case .listenerOutsideActiveRun:
			return "Agent listener invoked outside active run"
		}
	}
}
