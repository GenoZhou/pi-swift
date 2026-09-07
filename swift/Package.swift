// swift-tools-version: 6.0
import PackageDescription

let package = Package(
	name: "PiAgent",
	platforms: [
		.iOS(.v16),
		.macOS(.v13),
	],
	products: [
		.library(name: "PiAI", targets: ["PiAI"]),
		.library(name: "PiAgentCore", targets: ["PiAgentCore"]),
	],
	targets: [
		.target(
			name: "PiAI",
			path: "Sources/PiAI"
		),
		.target(
			name: "PiAgentCore",
			dependencies: ["PiAI"],
			path: "Sources/PiAgentCore"
		),
		.testTarget(
			name: "PiAgentCoreTests",
			dependencies: ["PiAI", "PiAgentCore"],
			path: "Tests/PiAgentCoreTests"
		),
	]
)
