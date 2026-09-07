# PiAgent (Swift)

Swift Package Manager port of `@earendil-works/pi-agent-core`, aimed at iOS AI-native apps.

This directory is a **self-contained SPM package**. Keep TypeScript sources under `packages/*` as the source of truth; keep Swift under `swift/` and sync via the mapping docs.

## Products

| Product | Role |
|---------|------|
| `PiAI` | LLM message model, stream protocol, cancellation, light tool validation (subset of `@earendil-works/pi-ai`) |
| `PiAgentCore` | Agent loop + stateful `Agent` + HTTP proxy stream (subset of `@earendil-works/pi-agent-core`) |

## Why `swift/` at repo root

1. **Upstream alignment** — mirrors `packages/ai` + `packages/agent` without mixing npm build artifacts into SPM.
2. **Submodule / local package** — other iOS apps can depend on this folder as a path package or extract it to its own git repo later. SPM remote deps require `Package.swift` at the git root of the depended repo; until extraction, use:

```swift
// Package.swift of the host iOS app
dependencies: [
  .package(path: "../pi-mono/swift"),
],
targets: [
  .target(name: "MyApp", dependencies: ["PiAgentCore"]),
]
```

Or in Xcode: *File → Add Package Dependencies… → Add Local…* → select `swift/`.

3. **Eventual extraction** — move `swift/` to a dedicated repo (`pi-agent-swift`) without rewriting import paths; `docs/MAPPING.md` stays the sync contract with this monorepo.

## Build / test

Requires Swift 6.0+.

```bash
cd swift
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
    streamFn: makeProxyStreamFn(proxyUrl: "https://api.example.com", authToken: token)
  )
)

try await agent.prompt(text: "Hello")
await agent.waitForIdle()
```

## Docs

- [DEPENDENCY-TREE.md](docs/DEPENDENCY-TREE.md) — TS dependency analysis
- [MAPPING.md](docs/MAPPING.md) — TS ↔ Swift file/symbol map
- [PROGRESS.md](docs/PROGRESS.md) — port layers and status
