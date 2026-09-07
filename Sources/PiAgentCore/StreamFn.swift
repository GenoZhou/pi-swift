import Foundation
import Synchronization
import PiAI

private let defaultStreamFn = Mutex<StreamFn?>(nil)

/// Configure the fallback used when callers omit `streamFn`.
public func setDefaultStreamFn(_ streamFn: StreamFn?) {
	defaultStreamFn.withLock { $0 = streamFn }
}

public func getDefaultStreamFn() throws -> StreamFn {
	guard let value = defaultStreamFn.withLock({ $0 }) else {
		throw AgentError.noDefaultStreamFn
	}
	return value
}
