# PiAgent (Swift)

Swift Package Manager port of [`@earendil-works/pi-agent-core`](https://github.com/earendil-works/pi/tree/main/packages/agent) for iOS / macOS AI-native apps.

This repository is a **standalone Swift package** (not a GitHub fork of the TypeScript monorepo). The git root is the SPM package root (`Package.swift`), so host apps can depend on it via submodule or SPM without a subdirectory path.

## Products

| Product | Role |
|---------|------|
| `PiAI` | LLM message model, stream protocol, cancellation, light tool validation (subset of `@earendil-works/pi-ai`) |
| `PiAgentCore` | Agent loop + stateful `Agent` + HTTP proxy stream (subset of `@earendil-works/pi-agent-core`) |

## Add as git submodule

```bash
git submodule add -b main https://github.com/GenoZhou/pi-swift.git Vendor/PiAgent
```

Then in the host `Package.swift`:

```swift
dependencies: [
  .package(path: "Vendor/PiAgent"),
],
targets: [
  .target(name: "MyApp", dependencies: ["PiAgentCore"]),
]
```

Or in Xcode: *File → Add Package Dependencies…* with the repo URL (branch `main`), or *Add Local…* pointing at the submodule.

## Align with upstream TypeScript

The TypeScript source of truth remains [`earendil-works/pi`](https://github.com/earendil-works/pi) (`packages/ai`, `packages/agent`). Do **not** merge that monorepo into this repo.

```bash
git remote add upstream https://github.com/earendil-works/pi.git   # once
git fetch upstream main
# Inspect TS files without checking them out onto main, e.g.:
git show upstream/main:packages/agent/src/agent-loop.ts | less
```

Port changes using [docs/MAPPING.md](docs/MAPPING.md) and update [docs/PROGRESS.md](docs/PROGRESS.md).

## Build / test

Requires Swift 6.0+, **macOS 15+** or **iOS 18+** (uses `Mutex` from Synchronization).

```bash
swift build
swift test
```

## Quick start

```swift
import PiAI
import PiAgentCore

let model = Model(id: "gpt-…", name: "…", api: "openai-responses", provider: "openai")
let agent = Agent(
  options: AgentOptions(
    initialState: AgentState(systemPrompt: "You are helpful.", model: model),
    streamFn: makeProxyStreamFn(proxyUrl: "https://api.example.com", authToken: { token })
  )
)

try await agent.prompt(text: "Hello")
await agent.waitForIdle()
```

## Docs

- [DEPENDENCY-TREE.md](docs/DEPENDENCY-TREE.md) — TS dependency analysis
- [MAPPING.md](docs/MAPPING.md) — TS ↔ Swift file/symbol map
- [PROGRESS.md](docs/PROGRESS.md) — port layers and status
