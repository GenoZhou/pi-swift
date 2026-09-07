import Foundation

/// Async event stream matching upstream `packages/ai/src/utils/event-stream.ts`.
public actor EventStream<Event: Sendable, Result: Sendable> {
	private var queue: [Event] = []
	private var queueHead = 0
	private var waiters: [CheckedContinuation<Event?, Never>] = []
	private var done = false
	private var finalResult: Result?
	private var resultWaiters: [CheckedContinuation<Result, Never>] = []
	private let isComplete: @Sendable (Event) -> Bool
	private let extractResult: @Sendable (Event) -> Result

	public init(
		isComplete: @escaping @Sendable (Event) -> Bool,
		extractResult: @escaping @Sendable (Event) -> Result
	) {
		self.isComplete = isComplete
		self.extractResult = extractResult
	}

	public func push(_ event: Event) {
		if done { return }

		if isComplete(event) {
			done = true
			let result = extractResult(event)
			finalResult = result
			let pending = resultWaiters
			resultWaiters.removeAll()
			for waiter in pending {
				waiter.resume(returning: result)
			}
		}

		if !waiters.isEmpty {
			let waiter = waiters.removeFirst()
			waiter.resume(returning: event)
		} else {
			queue.append(event)
		}
	}

	public func end(_ result: Result? = nil) {
		done = true
		if let result {
			finalResult = result
		}
		let pendingWaiters = waiters
		waiters.removeAll()
		let pendingResultWaiters = resultWaiters
		resultWaiters.removeAll()
		let resolved = finalResult

		for waiter in pendingWaiters {
			waiter.resume(returning: nil)
		}
		if let resolved {
			for waiter in pendingResultWaiters {
				waiter.resume(returning: resolved)
			}
		}
	}

	public nonisolated var events: AsyncStream<Event> {
		AsyncStream { continuation in
			Task {
				while true {
					let next = await self.nextEvent()
					if let next {
						continuation.yield(next)
					} else {
						continuation.finish()
						return
					}
				}
			}
		}
	}

	public func result() async -> Result {
		if let finalResult {
			return finalResult
		}
		return await withCheckedContinuation { continuation in
			resultWaiters.append(continuation)
		}
	}

	private func nextEvent() async -> Event? {
		if queueHead < queue.count {
			let event = queue[queueHead]
			queueHead += 1
			if queueHead > 32, queueHead * 2 >= queue.count {
				queue.removeFirst(queueHead)
				queueHead = 0
			}
			return event
		}
		if done {
			return nil
		}
		return await withCheckedContinuation { continuation in
			waiters.append(continuation)
		}
	}
}

/// Ordered wrapper over ``EventStream`` for assistant protocol events.
///
/// `push`/`end` are async and await the actor so producers cannot reorder events
/// (unlike fire-and-forget `Task`s).
public final class AssistantMessageEventStream: @unchecked Sendable {
	private let stream: EventStream<AssistantMessageEvent, AssistantMessage>

	public init() {
		stream = EventStream(
			isComplete: { event in
				switch event {
				case .done, .error:
					return true
				default:
					return false
				}
			},
			extractResult: { event in
				switch event {
				case .done(_, let message):
					return message
				case .error(_, let error):
					return error
				default:
					preconditionFailure("Unexpected event type for final result")
				}
			}
		)
	}

	public func push(_ event: AssistantMessageEvent) async {
		await stream.push(event)
	}

	public func end(_ message: AssistantMessage? = nil) async {
		await stream.end(message)
	}

	public var events: AsyncStream<AssistantMessageEvent> {
		stream.events
	}

	public func result() async -> AssistantMessage {
		await stream.result()
	}
}
