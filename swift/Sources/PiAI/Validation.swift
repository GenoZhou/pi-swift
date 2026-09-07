import Foundation

public enum ToolValidationError: Error, LocalizedError, Sendable {
	case toolNotFound(String)
	case invalidArguments(String)

	public var errorDescription: String? {
		switch self {
		case .toolNotFound(let name):
			return "Tool \"\(name)\" not found"
		case .invalidArguments(let message):
			return message
		}
	}
}

/// Lightweight JSON Schema check for tool arguments.
///
/// Full TypeBox parity (`packages/ai/src/utils/validation.ts`) is deferred.
/// This validates `type: object` and `required` keys when present in `parametersSchema`.
public func validateToolArguments(tool: Tool, toolCall: ToolCall) throws -> [String: JSONValue] {
	let args = toolCall.arguments
	let schema = tool.parametersSchema

	if let type = schema["type"]?.stringValue, type != "object" {
		throw ToolValidationError.invalidArguments(
			"Validation failed for tool \"\(toolCall.name)\": expected object schema"
		)
	}

	if case .array(let required)? = schema["required"] {
		for item in required {
			guard let key = item.stringValue else { continue }
			if args[key] == nil || args[key] == .null {
				throw ToolValidationError.invalidArguments(
					"Validation failed for tool \"\(toolCall.name)\":\n  - /\(key): Required property"
				)
			}
		}
	}

	return args
}
