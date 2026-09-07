# Port progress

Upstream baseline: monorepo package version **0.85.1** (`@earendil-works/pi-agent-core` on `earendil-works/pi`).
Update the "Upstream TS ref" when syncing via `git fetch upstream`.

## Layers

| Layer | Scope | Status | Upstream TS ref |
|-------|-------|--------|-----------------|
| 0 | `PiAI` message/stream/validation subset | **Done (MVP)** | `packages/ai` @ 0.85.1 |
| 1 | `Agent` + `agent-loop` + `stream-fn` + proxy | **Done (MVP)** | `packages/agent/src/{agent,agent-loop,types,stream-fn,proxy}.ts` |
| 2 | iOS `ExecutionEnv` (Documents FS; no bash) | Not started | `harness/types.ts` `ExecutionEnv` |
| 3 | Session memory + SQLite backend | Not started | `harness/session/*` |
| 4 | Harness accept/drive/reducer | Not started | `harness/runtime/*` |
| 5 | Chord delta / mobile wire | Not started | `packages/chord` + `docs/mobile-handoff` |
| 6 | Plugins / facets | Not started | `docs/mobile-handoff/02-plugins` |

## Module checklist (Layer 0–1)

| Module | Status | Tests |
|--------|--------|-------|
| `PiAI.Types` | Done | Codable covered indirectly |
| `PiAI.EventStream` | Done | Via agent loop |
| `PiAI.Validation` | Partial (required keys) | `ValidationTests` |
| `PiAI.Cancellation` | Done | Via agent abort path (manual) |
| `PiAgentCore.Types` | Done | |
| `PiAgentCore.StreamFn` | Done | |
| `PiAgentCore.AgentLoop` | Done | `promptWithoutTools`, `toolCallRoundTrip` |
| `PiAgentCore.Agent` | Done | Same |
| `PiAgentCore.Proxy` | Partial (SSE buffered on Linux; `/api/stream` + toolcall/thinking events; cancellable URLSessionTask) | `ProxyEventTests` |

## Explicitly out of scope for Layer 1

- Full provider SDKs (`packages/ai/src/providers/*`)
- Harness durability / lanes / compaction
- Node `ExecutionEnv` / bash tool
- TypeBox / `diff` / `yaml` / `ignore`
- Telemetry schema parity
- Custom `AgentMessage` declaration merging (use wrappers instead)

## How to extend

1. Pick next unchecked Layer row.
2. Add files under the mirrored path (see [MAPPING.md](MAPPING.md)).
3. Port TS tests where they exist (`packages/agent/test/agent*.ts` on upstream) before widening behavior.
4. Mark status here in the same PR.
