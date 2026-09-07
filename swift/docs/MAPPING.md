# TS ↔ Swift mapping

Convention: Swift files under `swift/Sources/` mirror TypeScript modules under `packages/{ai,agent}/src/`.
When upstream TS changes, update the mapped Swift file and tick the row in [PROGRESS.md](PROGRESS.md).

## Package map

| TypeScript package | Swift target | Path |
|--------------------|--------------|------|
| `@earendil-works/pi-ai` | `PiAI` | `Sources/PiAI` |
| `@earendil-works/pi-agent-core` | `PiAgentCore` | `Sources/PiAgentCore` |
| `@earendil-works/chord` | *(future `Chord`)* | — |
| `@earendil-works/pi-telemetry` | *(future / NOOP)* | — |

## File map — Layer 0 (`PiAI`)

| TypeScript | Swift | Notes |
|------------|-------|-------|
| `packages/ai/src/types.ts` (Message, Model, Usage, events…) | `Sources/PiAI/Types.swift` | Subset; no provider compat structs |
| `packages/ai/src/types.ts` `JsonValue` | `Sources/PiAI/JSONValue.swift` | |
| `packages/ai/src/utils/event-stream.ts` | `Sources/PiAI/EventStream.swift` | |
| `packages/ai/src/utils/validation.ts` | `Sources/PiAI/Validation.swift` | Required-keys only; TypeBox parity deferred |
| web `AbortSignal` / `AbortController` | `Sources/PiAI/Cancellation.swift` | |
| `packages/ai/src/providers/*` | — | Out of scope; use proxy `StreamFn` |

## File map — Layer 1 (`PiAgentCore`)

| TypeScript | Swift | Notes |
|------------|-------|-------|
| `packages/agent/src/types.ts` | `Sources/PiAgentCore/Types.swift` | |
| `packages/agent/src/stream-fn.ts` | `Sources/PiAgentCore/StreamFn.swift` | |
| `packages/agent/src/agent-loop.ts` | `Sources/PiAgentCore/AgentLoop.swift` | Behavior-preserving port |
| `packages/agent/src/agent.ts` | `Sources/PiAgentCore/Agent.swift` | |
| `packages/agent/src/proxy.ts` | `Sources/PiAgentCore/Proxy.swift` | NDJSON/`data:` SSE subset; extend as proxy protocol stabilizes |

## Symbol map (core)

| TypeScript | Swift |
|------------|-------|
| `Agent` | `Agent` |
| `agentLoop` / `runAgentLoop` | `agentLoop` / `runAgentLoop` |
| `AgentMessage` | `AgentMessage` |
| `AgentTool` | `AgentTool` |
| `AgentEvent` | `AgentEvent` |
| `StreamFn` | `StreamFn` |
| `streamProxy` | `streamProxy` / `makeProxyStreamFn` |
| `AssistantMessageEventStream` | `AssistantMessageEventStream` |
| `validateToolArguments` | `validateToolArguments` |
| `ThinkingLevel` | `ThinkingLevel` (`PiAI`) |

## Sync workflow

1. Diff upstream: `git log -p -- packages/agent/src/{types,agent,agent-loop,stream-fn,proxy}.ts packages/ai/src/types.ts packages/ai/src/utils/event-stream.ts`
2. Apply equivalent change in the mapped Swift file.
3. Update the **Upstream TS ref** column in PROGRESS.md (commit SHA or version).
4. Run `cd swift && swift test`.
5. Prefer small, reviewable ports over drive-by refactors so the map stays honest.
