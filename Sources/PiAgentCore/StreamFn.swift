import Foundation
import Synchronization
import PiAI

private struct DefaultStreamFnBox: Sendable {
	var value: StreamFn?
}

private let defaultStreamFn = Mutex(DefaultStreamFnBox())

/// Configure the fallback used when callers omit `streamFn`.
public func setDefaultStreamFn(_ streamFn: StreamFn?) {
	defaultStreamFn.withLock { $0.value = streamFn }
}

public func getDefaultStreamFn() -> StreamFn {
	guard let value = defaultStreamFn.withLock(\.value) else {
		fatalError("No default stream function configured. Pass streamFn explicitly or call setDefaultStreamFn().")
	}
	return value
}
