# Dependency tree (`@earendil-works/pi-agent-core`)

Source package: [`packages/agent`](../../packages/agent) (`@earendil-works/pi-agent-core` @ 0.85.1).

## Direct dependencies

| Dependency | Used for | Swift status |
|------------|----------|--------------|
| `@earendil-works/pi-ai` | Message model, `StreamFn` / `AssistantMessageEventStream`, tool arg validation, `uuidv7` | **Partial** as `PiAI` (messages, stream, light validation). No provider catalog/SDK. |
| `@earendil-works/chord` | `Context` / cancel, `JsonValue`, delta ops (Harness + mobile wire) | Not started (`JSONValue` stub lives in `PiAI`). |
| `@earendil-works/pi-telemetry` | Typed spans | Deferred (NOOP sufficient for MVP). |
| `typebox` | Tool parameter schemas | Replaced by JSON Schema dictionaries. |
| `diff` | Edit-tool unified diffs | Deferred (Harness tools). |
| `ignore` | Skill discovery | Deferred. |
| `yaml` | Skill / prompt-template frontmatter | Deferred. |

Sibling (not a dep of agent-core): `@earendil-works/pi-session-backend-sqlite-node` → future Swift SQLite session backend.

## Downstream consumers (TS monorepo)

- `@earendil-works/pi-coding-agent`
- `@earendil-works/pi-server`
- `@earendil-works/pi-session-backend-sqlite-node`
- `@earendil-works/pi-evals` (via coding-agent)

## Two stacked products inside agent-core

```text
pi-agent-core
├── Simple Agent (~1.8k LOC)          ← Swift Layer 1 (this PR)
│   ├── types.ts / agent-loop.ts / agent.ts / stream-fn.ts / proxy.ts
│   └── depends on pi-ai message + stream contracts
└── AgentHarness (~22k+ LOC)         ← later layers
    ├── session / runtime/drive / tools / compaction / skills
    └── depends on chord Context + (later) delta
```

## Recommended port order

```text
Layer 0  PiAI subset          (done)
Layer 1  Agent loop + Agent   (done)
Layer 2  iOS ExecutionEnv     (Documents FS; no bash)
Layer 3  Session durability   (Memory → SQLite)
Layer 4  Harness accept/drive
Layer 5  Chord delta / mobile wire (see packages/agent/docs/mobile-handoff)
Layer 6  Plugins / facets     (optional)
```

## Node vs portable

| Portable (port) | Node-specific (skip / replace) |
|-----------------|--------------------------------|
| `agent.ts`, `agent-loop.ts`, `types.ts`, `proxy.ts` | `harness/env/nodejs.ts`, `./node` export |
| Session interfaces + memory storage | `child_process` bash tool |
| Drive/reducer algorithms | `isolated-vm` plugin sandbox |
| Compaction math | JSONL-on-disk (prefer SQLite on iOS) |
