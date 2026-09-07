import Foundation
import PiAI
@testable import PiAgentCore
import Testing

private final class StringListBox: @unchecked Sendable {
	private let lock = NSLock()
	private var values: [String] = []
	func append(_ value: String) {
		lock.lock()
		values.append(value)
		lock.unlock()
	}
	func snapshot() -> [String] {
		lock.lock()
		defer { lock.unlock() }
		return values
	}
}

private final class CounterBox: @unchecked Sendable {
	private let lock = NSLock()
	private var value = 0
	func bump() -> Int {
		lock.lock()
		defer { lock.unlock() }
		value += 1
		return value
	}
}

@Suite("Agent loop")
struct AgentLoopTests {
	@Test("prompt runs one assistant turn without tools")
	func promptWithoutTools() async throws {
		let model = Model(id: "test", name: "test", api: "test", provider: "test")
		let streamFn: StreamFn = { model, _, _ in
			let stream = AssistantMessageEventStream()
			Task {
				var partial = AssistantMessage(
					content: [.text(TextContent(text: ""))],
					api: model.api,
					provider: model.provider,
					model: model.id,
					stopReason: .pending
				)
				await stream.push(.start(partial: partial))
				partial.content = [.text(TextContent(text: "hello"))]
				await stream.push(.textDelta(contentIndex: 0, delta: "hello", partial: partial))
				partial.stopReason = .stop
				await stream.push(.done(reason: .stop, message: partial))
				await stream.end(partial)
			}
			return stream
		}

		let agent = Agent(
			options: AgentOptions(
				initialState: AgentState(systemPrompt: "sys", model: model),
				streamFn: streamFn
			)
		)

		let eventTypes = StringListBox()
		_ = agent.subscribe { event, _ in
			eventTypes.append(event.typeName)
		}

		try await agent.prompt(text: "hi")
		await agent.waitForIdle()

		let types = eventTypes.snapshot()
		#expect(types.first == "agent_start")
		#expect(types.contains("turn_start"))
		#expect(types.contains("message_end"))
		#expect(types.last == "agent_end")
		#expect(agent.state.messages.count == 2)
		#expect(agent.state.messages[0].role == "user")
		#expect(agent.state.messages[1].role == "assistant")
		#expect(agent.state.isStreaming == false)
	}

	@Test("tool call executes and returns tool result")
	func toolCallRoundTrip() async throws {
		let model = Model(id: "test", name: "test", api: "test", provider: "test")
		let echo = AgentTool(
			name: "echo",
			description: "echo",
			label: "Echo",
			parametersSchema: [
				"type": .string("object"),
				"properties": .object([
					"text": .object(["type": .string("string")]),
				]),
				"required": .array([.string("text")]),
			]
		) { _, params, _, _ in
			let text = params["text"]?.stringValue ?? ""
			return AgentToolResult(content: [.text(TextContent(text: text))])
		}

		let callCount = CounterBox()
		let streamFn: StreamFn = { model, _, _ in
			let stream = AssistantMessageEventStream()
			Task {
				let count = callCount.bump()
				if count == 1 {
					let partial = AssistantMessage(
						content: [
							.toolCall(
								ToolCall(
									id: "call_1",
									name: "echo",
									arguments: ["text": .string("pong")]
								)
							),
						],
						api: model.api,
						provider: model.provider,
						model: model.id,
						stopReason: .toolUse
					)
					await stream.push(.start(partial: partial))
					await stream.push(.done(reason: .toolUse, message: partial))
					await stream.end(partial)
				} else {
					let partial = AssistantMessage(
						content: [.text(TextContent(text: "done"))],
						api: model.api,
						provider: model.provider,
						model: model.id,
						stopReason: .stop
					)
					await stream.push(.start(partial: partial))
					await stream.push(.done(reason: .stop, message: partial))
					await stream.end(partial)
				}
			}
			return stream
		}

		let agent = Agent(
			options: AgentOptions(
				initialState: AgentState(systemPrompt: "sys", model: model, tools: [echo]),
				streamFn: streamFn
			)
		)

		try await agent.prompt(text: "ping")
		await agent.waitForIdle()

		#expect(agent.state.messages.count == 4)
		#expect(agent.state.messages[0].role == "user")
		#expect(agent.state.messages[1].role == "assistant")
		#expect(agent.state.messages[2].role == "toolResult")
		#expect(agent.state.messages[3].role == "assistant")
		if case .toolResult(let result) = agent.state.messages[2].asMessage {
			#expect(result.toolName == "echo")
			#expect(result.isError == false)
			if case .text(let text)? = result.content.first {
				#expect(text.text == "pong")
			} else {
				Issue.record("Expected text tool result")
			}
		} else {
			Issue.record("Expected toolResult message")
		}
	}

	@Test("continue without messages throws")
	func continueRequiresMessages() async {
		let agent = Agent(
			options: AgentOptions(
				streamFn: { _, _, _ in AssistantMessageEventStream() }
			)
		)
		await #expect(throws: AgentError.self) {
			try await agent.continue()
		}
	}
}

@Suite("Validation")
struct ValidationTests {
	@Test("required fields are enforced")
	func requiredFields() throws {
		let tool = Tool(
			name: "echo",
			description: "echo",
			parametersSchema: [
				"type": .string("object"),
				"required": .array([.string("text")]),
			]
		)
		#expect(throws: ToolValidationError.self) {
			_ = try validateToolArguments(
				tool: tool,
				toolCall: ToolCall(id: "1", name: "echo", arguments: [:])
			)
		}
	}
}

@Suite("Proxy event processing")
struct ProxyEventTests {
	@Test("toolcall delta accumulates arguments")
	func toolcallDelta() throws {
		var partial = AssistantMessage(api: "t", provider: "t", model: "t", stopReason: .pending)
		var json: [Int: String] = [:]

		_ = try processProxyEvent(
			ProxyWireEvent(type: "toolcall_start", contentIndex: 0, id: "c1", toolName: "echo"),
			partial: &partial,
			toolPartialJson: &json
		)
		_ = try processProxyEvent(
			ProxyWireEvent(type: "toolcall_delta", contentIndex: 0, delta: #"{"text":"hi"}"#),
			partial: &partial,
			toolPartialJson: &json
		)
		guard case .toolCall(let call) = partial.content[0] else {
			Issue.record("expected tool call")
			return
		}
		#expect(call.arguments["text"]?.stringValue == "hi")
	}
}
