import Foundation
import Synchronization

/// Cooperative cancellation token analogous to the web `AbortSignal` / `AbortController` pair.
public final class CancellationToken: Sendable {
	private struct State {
		var isCancelled = false
		var listeners: [UUID: @Sendable () -> Void] = [:]
	}

	private let state = Mutex(State())

	public init() {}

	public var isCancelled: Bool {
		state.withLock(\.isCancelled)
	}

	public func cancel() {
		let callbacks: [@Sendable () -> Void] = state.withLock { state in
			if state.isCancelled {
				return []
			}
			state.isCancelled = true
			let callbacks = Array(state.listeners.values)
			state.listeners.removeAll()
			return callbacks
		}
		for callback in callbacks {
			callback()
		}
	}

	@discardableResult
	public func onCancel(_ listener: @escaping @Sendable () -> Void) -> UUID {
		state.withLock { state in
			if state.isCancelled {
				DispatchQueue.global().async { listener() }
				return UUID()
			}
			let id = UUID()
			state.listeners[id] = listener
			return id
		}
	}

	public func removeOnCancel(_ id: UUID) {
		state.withLock { state in
			state.listeners.removeValue(forKey: id)
		}
	}
}

/// Creates and owns a {@link CancellationToken}, matching `AbortController`.
public final class CancellationController: Sendable {
	public let token = CancellationToken()

	public init() {}

	public func cancel() {
		token.cancel()
	}
}
