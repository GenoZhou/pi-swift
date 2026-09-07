import Foundation
import Synchronization
import PiAI

public typealias AgentEventSink = @Sendable (AgentEvent) async -> Void

public func agentLoop(
	prompts: [AgentMessage],
	context: AgentContext,
	config: AgentLoopConfig,
	signal: CancellationToken?,
	streamFn: @escaping StreamFn
) -> EventStream<AgentEvent, [AgentMessage]> {
	let stream = createAgentStream()
	Task {
		let messages = await runAgentLoop(
			prompts: prompts,
			context: context,
			config: config,
			emit: { event in
				await stream.push(event)
			},
			signal: signal,
			streamFn: streamFn
		)
		await stream.end(messages)
	}
	return stream
}

public func agentLoopContinue(
	context: AgentContext,
	config: AgentLoopConfig,
	signal: CancellationToken?,
	streamFn: @escaping StreamFn
) -> EventStream<AgentEvent, [AgentMessage]> {
	guard !context.messages.isEmpty else {
		fatalError("Cannot continue: no messages in context")
	}
	guard context.messages.last?.role != "assistant" else {
		fatalError("Cannot continue from message role: assistant")
	}

	let stream = createAgentStream()
	Task {
		let messages = await runAgentLoopContinue(
			context: context,
			config: config,
			emit: { event in
				await stream.push(event)
			},
			signal: signal,
			streamFn: streamFn
		)
		await stream.end(messages)
	}
	return stream
}

public func runAgentLoop(
	prompts: [AgentMessage],
	context: AgentContext,
	config: AgentLoopConfig,
	emit: @escaping AgentEventSink,
	signal: CancellationToken?,
	streamFn: StreamFn?
) async -> [AgentMessage] {
	var newMessages = prompts
	var currentContext = AgentContext(
		systemPrompt: context.systemPrompt,
		messages: context.messages + prompts,
		tools: context.tools
	)

	await emit(.agentStart)
	await emit(.turnStart)
	for prompt in prompts {
		await emit(.messageStart(message: prompt))
		await emit(.messageEnd(message: prompt))
	}

	await runLoop(
		currentContext: &currentContext,
		newMessages: &newMessages,
		config: config,
		signal: signal,
		emit: emit,
		streamFunction: streamFn ?? getDefaultStreamFn()
	)
	return newMessages
}

public func runAgentLoopContinue(
	context: AgentContext,
	config: AgentLoopConfig,
	emit: @escaping AgentEventSink,
	signal: CancellationToken?,
	streamFn: StreamFn?
) async -> [AgentMessage] {
	guard !context.messages.isEmpty else {
		fatalError("Cannot continue: no messages in context")
	}
	guard context.messages.last?.role != "assistant" else {
		fatalError("Cannot continue from message role: assistant")
	}

	var newMessages: [AgentMessage] = []
	var currentContext = context

	await emit(.agentStart)
	await emit(.turnStart)

	await runLoop(
		currentContext: &currentContext,
		newMessages: &newMessages,
		config: config,
		signal: signal,
		emit: emit,
		streamFunction: streamFn ?? getDefaultStreamFn()
	)
	return newMessages
}

private func createAgentStream() -> EventStream<AgentEvent, [AgentMessage]> {
	EventStream(
		isComplete: { event in
			if case .agentEnd = event { return true }
			return false
		},
		extractResult: { event in
			if case .agentEnd(let messages) = event { return messages }
			return []
		}
	)
}

private func runLoop(
	currentContext: inout AgentContext,
	newMessages: inout [AgentMessage],
	config: AgentLoopConfig,
	signal: CancellationToken?,
	emit: @escaping AgentEventSink,
	streamFunction: StreamFn
) async {
	var config = config
	var lastCompletedTurn: PrepareNextTurnContext?
	var pendingMessages = (await config.getSteeringMessages?()) ?? []

	while true {
		var hasMoreToolCalls = true

		while hasMoreToolCalls || !pendingMessages.isEmpty {
			if let lastCompletedTurn {
				if let nextTurnSnapshot = await config.prepareNextTurn?(lastCompletedTurn) {
					currentContext = nextTurnSnapshot.context ?? currentContext
					if let model = nextTurnSnapshot.model {
						config.model = model
					}
					if let thinkingLevel = nextTurnSnapshot.thinkingLevel {
						config.reasoning = thinkingLevel == .off ? nil : thinkingLevel
					}
				}
				if pendingMessages.isEmpty {
					pendingMessages = (await config.getSteeringMessages?()) ?? []
				}
				await emit(.turnStart)
			}

			if !pendingMessages.isEmpty {
				for message in pendingMessages {
					await emit(.messageStart(message: message))
					await emit(.messageEnd(message: message))
					currentContext.messages.append(message)
					newMessages.append(message)
				}
				pendingMessages = []
			}

			let message = await streamAssistantResponse(
				context: &currentContext,
				config: config,
				signal: signal,
				emit: emit,
				streamFunction: streamFunction
			)
			newMessages.append(.assistant(message))

			if message.stopReason == .error || message.stopReason == .aborted {
				await emit(.turnEnd(message: .assistant(message), toolResults: []))
				await emit(.agentEnd(messages: newMessages))
				return
			}

			let toolCalls = message.toolCalls
			var toolResults: [ToolResultMessage] = []
			hasMoreToolCalls = false
			if !toolCalls.isEmpty {
				let executedToolBatch: ExecutedToolCallBatch
				if message.stopReason == .length {
					executedToolBatch = await failToolCallsFromTruncatedMessage(toolCalls: toolCalls, emit: emit)
				} else {
					executedToolBatch = await executeToolCalls(
						currentContext: currentContext,
						assistantMessage: message,
						config: config,
						signal: signal,
						emit: emit
					)
				}
				toolResults.append(contentsOf: executedToolBatch.messages)
				hasMoreToolCalls = !executedToolBatch.terminate

				for result in toolResults {
					currentContext.messages.append(.toolResult(result))
					newMessages.append(.toolResult(result))
				}
			}

			await emit(.turnEnd(message: .assistant(message), toolResults: toolResults))

			let completedTurn = ShouldStopAfterTurnContext(
				message: message,
				toolResults: toolResults,
				context: currentContext,
				newMessages: newMessages
			)
			lastCompletedTurn = completedTurn

			if let shouldStop = await config.shouldStopAfterTurn?(completedTurn), shouldStop {
				await emit(.agentEnd(messages: newMessages))
				return
			}

			pendingMessages = (await config.getSteeringMessages?()) ?? []
		}

		let followUpMessages = (await config.getFollowUpMessages?()) ?? []
		if !followUpMessages.isEmpty {
			pendingMessages = followUpMessages
			continue
		}
		break
	}

	await emit(.agentEnd(messages: newMessages))
}

private func streamAssistantResponse(
	context: inout AgentContext,
	config: AgentLoopConfig,
	signal: CancellationToken?,
	emit: @escaping AgentEventSink,
	streamFunction: StreamFn
) async -> AssistantMessage {
	var messages = context.messages
	if let transformContext = config.transformContext {
		messages = await transformContext(messages, signal)
	}

	let llmMessages = await config.convertToLlm(messages)
	let llmContext = LLMContext(
		systemPrompt: context.systemPrompt,
		messages: llmMessages,
		tools: context.tools?.map(\.asTool)
	)

	let resolvedApiKey: String?
	if let getApiKey = config.getApiKey {
		resolvedApiKey = await getApiKey(config.model.provider) ?? config.apiKey
	} else {
		resolvedApiKey = config.apiKey
	}

	let options = SimpleStreamOptions(
		signal: signal,
		apiKey: resolvedApiKey,
		reasoning: config.reasoning,
		sessionId: config.sessionId,
		transport: config.transport,
		thinkingBudgets: config.thinkingBudgets,
		maxRetryDelayMs: config.maxRetryDelayMs,
		onPayload: config.onPayload,
		onResponse: config.onResponse
	)

	let response = await streamFunction(config.model, llmContext, options)
	var addedPartial = false

	for await event in response.events {
		switch event {
		case .start(let partial):
			context.messages.append(.assistant(partial))
			addedPartial = true
			await emit(.messageStart(message: .assistant(partial)))

		case .textStart, .textDelta, .textEnd,
			.thinkingStart, .thinkingDelta, .thinkingEnd,
			.toolCallStart, .toolCallDelta, .toolCallEnd:
			if let partial = event.partial {
				context.messages[context.messages.count - 1] = .assistant(partial)
				await emit(.messageUpdate(message: .assistant(partial), assistantMessageEvent: event))
			}

		case .done, .error:
			let finalMessage = await response.result()
			if addedPartial {
				context.messages[context.messages.count - 1] = .assistant(finalMessage)
			} else {
				context.messages.append(.assistant(finalMessage))
				await emit(.messageStart(message: .assistant(finalMessage)))
			}
			await emit(.messageEnd(message: .assistant(finalMessage)))
			return finalMessage
		}
	}

	let finalMessage = await response.result()
	if addedPartial {
		context.messages[context.messages.count - 1] = .assistant(finalMessage)
	} else {
		context.messages.append(.assistant(finalMessage))
		await emit(.messageStart(message: .assistant(finalMessage)))
	}
	await emit(.messageEnd(message: .assistant(finalMessage)))
	return finalMessage
}

private struct ExecutedToolCallBatch {
	var messages: [ToolResultMessage]
	var terminate: Bool
}

private struct PreparedToolCall {
	var toolCall: AgentToolCall
	var tool: AgentTool
	var args: [String: JSONValue]
}

private enum PrepareOutcome {
	case prepared(PreparedToolCall)
	case immediate(result: AgentToolResult, isError: Bool)
}

private struct FinalizedToolCallOutcome {
	var toolCall: AgentToolCall
	var result: AgentToolResult
	var isError: Bool
}

private func failToolCallsFromTruncatedMessage(
	toolCalls: [AgentToolCall],
	emit: @escaping AgentEventSink
) async -> ExecutedToolCallBatch {
	var messages: [ToolResultMessage] = []
	for toolCall in toolCalls {
		await emit(.toolExecutionStart(toolCallId: toolCall.id, toolName: toolCall.name, args: toolCall.arguments))
		let finalized = FinalizedToolCallOutcome(
			toolCall: toolCall,
			result: createErrorToolResult(
				"Tool call \"\(toolCall.name)\" was not executed: the response hit the output token limit, so its arguments may be truncated. Re-issue the tool call with complete arguments."
			),
			isError: true
		)
		await emitToolExecutionEnd(finalized, emit: emit)
		let toolResultMessage = createToolResultMessage(finalized)
		await emitToolResultMessage(toolResultMessage, emit: emit)
		messages.append(toolResultMessage)
	}
	return ExecutedToolCallBatch(messages: messages, terminate: false)
}

private func executeToolCalls(
	currentContext: AgentContext,
	assistantMessage: AssistantMessage,
	config: AgentLoopConfig,
	signal: CancellationToken?,
	emit: @escaping AgentEventSink
) async -> ExecutedToolCallBatch {
	let toolCalls = assistantMessage.toolCalls
	let hasSequential = toolCalls.contains { call in
		currentContext.tools?.first(where: { $0.name == call.name })?.executionMode == .sequential
	}
	if config.toolExecution == .sequential || hasSequential {
		return await executeToolCallsSequential(
			currentContext: currentContext,
			assistantMessage: assistantMessage,
			toolCalls: toolCalls,
			config: config,
			signal: signal,
			emit: emit
		)
	}
	return await executeToolCallsParallel(
		currentContext: currentContext,
		assistantMessage: assistantMessage,
		toolCalls: toolCalls,
		config: config,
		signal: signal,
		emit: emit
	)
}

private func executeToolCallsSequential(
	currentContext: AgentContext,
	assistantMessage: AssistantMessage,
	toolCalls: [AgentToolCall],
	config: AgentLoopConfig,
	signal: CancellationToken?,
	emit: @escaping AgentEventSink
) async -> ExecutedToolCallBatch {
	var finalizedCalls: [FinalizedToolCallOutcome] = []
	var messages: [ToolResultMessage] = []

	for toolCall in toolCalls {
		await emit(.toolExecutionStart(toolCallId: toolCall.id, toolName: toolCall.name, args: toolCall.arguments))
		let preparation = await prepareToolCall(
			currentContext: currentContext,
			assistantMessage: assistantMessage,
			toolCall: toolCall,
			config: config,
			signal: signal
		)
		let finalized: FinalizedToolCallOutcome
		switch preparation {
		case .immediate(let result, let isError):
			finalized = FinalizedToolCallOutcome(toolCall: toolCall, result: result, isError: isError)
		case .prepared(let prepared):
			let executed = await executePreparedToolCall(prepared, signal: signal, emit: emit)
			finalized = await finalizeExecutedToolCall(
				currentContext: currentContext,
				assistantMessage: assistantMessage,
				prepared: prepared,
				executed: executed,
				config: config,
				signal: signal
			)
		}
		await emitToolExecutionEnd(finalized, emit: emit)
		let toolResultMessage = createToolResultMessage(finalized)
		await emitToolResultMessage(toolResultMessage, emit: emit)
		finalizedCalls.append(finalized)
		messages.append(toolResultMessage)
		if signal?.isCancelled == true {
			break
		}
	}

	return ExecutedToolCallBatch(messages: messages, terminate: shouldTerminateToolBatch(finalizedCalls))
}

private func executeToolCallsParallel(
	currentContext: AgentContext,
	assistantMessage: AssistantMessage,
	toolCalls: [AgentToolCall],
	config: AgentLoopConfig,
	signal: CancellationToken?,
	emit: @escaping AgentEventSink
) async -> ExecutedToolCallBatch {
	enum Entry {
		case ready(FinalizedToolCallOutcome)
		case work(WorkBox)
	}

	final class WorkBox: @unchecked Sendable {
		let run: () async -> FinalizedToolCallOutcome
		init(_ run: @escaping () async -> FinalizedToolCallOutcome) {
			self.run = run
		}
	}

	var entries: [Entry] = []

	for toolCall in toolCalls {
		await emit(.toolExecutionStart(toolCallId: toolCall.id, toolName: toolCall.name, args: toolCall.arguments))
		let preparation = await prepareToolCall(
			currentContext: currentContext,
			assistantMessage: assistantMessage,
			toolCall: toolCall,
			config: config,
			signal: signal
		)
		switch preparation {
		case .immediate(let result, let isError):
			let finalized = FinalizedToolCallOutcome(toolCall: toolCall, result: result, isError: isError)
			await emitToolExecutionEnd(finalized, emit: emit)
			entries.append(.ready(finalized))
		case .prepared(let prepared):
			entries.append(.work(WorkBox {
				if signal?.isCancelled == true {
					let finalized = FinalizedToolCallOutcome(
						toolCall: toolCall,
						result: createErrorToolResult("Operation aborted"),
						isError: true
					)
					await emitToolExecutionEnd(finalized, emit: emit)
					return finalized
				}
				let executed = await executePreparedToolCall(prepared, signal: signal, emit: emit)
				let finalized = await finalizeExecutedToolCall(
					currentContext: currentContext,
					assistantMessage: assistantMessage,
					prepared: prepared,
					executed: executed,
					config: config,
					signal: signal
				)
				await emitToolExecutionEnd(finalized, emit: emit)
				return finalized
			}))
		}
		if signal?.isCancelled == true {
			break
		}
	}

	var ordered: [FinalizedToolCallOutcome] = []
	ordered.reserveCapacity(entries.count)
	await withTaskGroup(of: (Int, FinalizedToolCallOutcome).self) { group in
		var readyResults: [(Int, FinalizedToolCallOutcome)] = []
		for (index, entry) in entries.enumerated() {
			switch entry {
			case .ready(let finalized):
				readyResults.append((index, finalized))
			case .work(let box):
				group.addTask {
					(index, await box.run())
				}
			}
		}
		var asyncResults: [(Int, FinalizedToolCallOutcome)] = []
		for await item in group {
			asyncResults.append(item)
		}
		let all = (readyResults + asyncResults).sorted { $0.0 < $1.0 }
		ordered = all.map(\.1)
	}

	var messages: [ToolResultMessage] = []
	for finalized in ordered {
		let toolResultMessage = createToolResultMessage(finalized)
		await emitToolResultMessage(toolResultMessage, emit: emit)
		messages.append(toolResultMessage)
	}
	return ExecutedToolCallBatch(messages: messages, terminate: shouldTerminateToolBatch(ordered))
}

private func shouldTerminateToolBatch(_ finalizedCalls: [FinalizedToolCallOutcome]) -> Bool {
	!finalizedCalls.isEmpty && finalizedCalls.allSatisfy { $0.result.terminate == true }
}

private func prepareToolCall(
	currentContext: AgentContext,
	assistantMessage: AssistantMessage,
	toolCall: AgentToolCall,
	config: AgentLoopConfig,
	signal: CancellationToken?
) async -> PrepareOutcome {
	guard let tool = currentContext.tools?.first(where: { $0.name == toolCall.name }) else {
		return .immediate(result: createErrorToolResult("Tool \(toolCall.name) not found"), isError: true)
	}

	do {
		var preparedCall = toolCall
		if let prepareArguments = tool.prepareArguments {
			let preparedArguments = prepareArguments(toolCall.arguments)
			preparedCall.arguments = preparedArguments
		}
		let validatedArgs = try validateToolArguments(
			tool: tool.asTool,
			toolCall: preparedCall
		)
		if let beforeToolCall = config.beforeToolCall {
			let beforeResult = await beforeToolCall(
				BeforeToolCallContext(
					assistantMessage: assistantMessage,
					toolCall: toolCall,
					args: validatedArgs,
					context: currentContext
				),
				signal
			)
			if signal?.isCancelled == true {
				return .immediate(result: createErrorToolResult("Operation aborted"), isError: true)
			}
			if beforeResult?.block == true {
				var result = createErrorToolResult(beforeResult?.reason ?? "Tool execution was blocked")
				if beforeResult?.terminate == true {
					result.terminate = true
				}
				return .immediate(result: result, isError: true)
			}
		}
		if signal?.isCancelled == true {
			return .immediate(result: createErrorToolResult("Operation aborted"), isError: true)
		}
		return .prepared(PreparedToolCall(toolCall: toolCall, tool: tool, args: validatedArgs))
	} catch {
		return .immediate(result: createErrorToolResult(error.localizedDescription), isError: true)
	}
}

private func executePreparedToolCall(
	_ prepared: PreparedToolCall,
	signal: CancellationToken?,
	emit: @escaping AgentEventSink
) async -> (result: AgentToolResult, isError: Bool) {
	final class UpdateState: @unchecked Sendable {
		var acceptingUpdates = true
		var updateTasks: [Task<Void, Never>] = []
		let lock = Mutex(0)

		func withLock<T>(_ body: () -> T) -> T {
			lock.withLock { _ in body() }
		}
	}
	let updateState = UpdateState()

	do {
		let result = try await prepared.tool.execute(prepared.toolCall.id, prepared.args, signal) { partialResult in
			let accepting = updateState.withLock { updateState.acceptingUpdates }
			guard accepting else { return }
			let task = Task {
				await emit(
					.toolExecutionUpdate(
						toolCallId: prepared.toolCall.id,
						toolName: prepared.toolCall.name,
						args: prepared.toolCall.arguments,
						partialResult: partialResult
					)
				)
			}
			updateState.withLock { updateState.updateTasks.append(task) }
		}
		let tasks = updateState.withLock { () -> [Task<Void, Never>] in
			updateState.acceptingUpdates = false
			return updateState.updateTasks
		}
		for task in tasks {
			await task.value
		}
		return (result, false)
	} catch {
		let tasks = updateState.withLock { () -> [Task<Void, Never>] in
			updateState.acceptingUpdates = false
			return updateState.updateTasks
		}
		for task in tasks {
			await task.value
		}
		return (createErrorToolResult(error.localizedDescription), true)
	}
}

private func finalizeExecutedToolCall(
	currentContext: AgentContext,
	assistantMessage: AssistantMessage,
	prepared: PreparedToolCall,
	executed: (result: AgentToolResult, isError: Bool),
	config: AgentLoopConfig,
	signal: CancellationToken?
) async -> FinalizedToolCallOutcome {
	var result = executed.result
	var isError = executed.isError

	if let afterToolCall = config.afterToolCall {
		if let afterResult = await afterToolCall(
			AfterToolCallContext(
				assistantMessage: assistantMessage,
				toolCall: prepared.toolCall,
				args: prepared.args,
				result: result,
				isError: isError,
				context: currentContext
			),
			signal
		) {
			result = AgentToolResult(
				content: afterResult.content ?? result.content,
				details: afterResult.details ?? result.details,
				usage: afterResult.usage ?? result.usage,
				addedToolNames: result.addedToolNames,
				terminate: afterResult.terminate ?? result.terminate
			)
			isError = afterResult.isError ?? isError
		}
	}

	return FinalizedToolCallOutcome(toolCall: prepared.toolCall, result: result, isError: isError)
}

private func createErrorToolResult(_ message: String) -> AgentToolResult {
	AgentToolResult(content: [.text(TextContent(text: message))], details: .object([:]))
}

private func emitToolExecutionEnd(_ finalized: FinalizedToolCallOutcome, emit: @escaping AgentEventSink) async {
	await emit(
		.toolExecutionEnd(
			toolCallId: finalized.toolCall.id,
			toolName: finalized.toolCall.name,
			result: finalized.result,
			isError: finalized.isError
		)
	)
}

private func createToolResultMessage(_ finalized: FinalizedToolCallOutcome) -> ToolResultMessage {
	ToolResultMessage(
		toolCallId: finalized.toolCall.id,
		toolName: finalized.toolCall.name,
		content: finalized.result.content,
		details: finalized.result.details,
		usage: finalized.result.usage,
		addedToolNames: finalized.result.addedToolNames,
		isError: finalized.isError
	)
}

private func emitToolResultMessage(_ toolResultMessage: ToolResultMessage, emit: @escaping AgentEventSink) async {
	await emit(.messageStart(message: .toolResult(toolResultMessage)))
	await emit(.messageEnd(message: .toolResult(toolResultMessage)))
}
