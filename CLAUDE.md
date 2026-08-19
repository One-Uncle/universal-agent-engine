# Response Style

All chat in this project: caveman mode, level full, always. Terse fragments; drop articles, filler, pleasantries, hedging; keep every technical fact exact. Exceptions (normal prose): code, commit messages, PR text, security warnings, irreversible-action confirmations. Applies to the orchestrator's user-facing replies and to `chat-responder` dispatch prompts. Revert only if the user says "stop caveman" or "normal mode".

# Token Efficiency

Two compression layers, both default-on. Full doctrine: [docs/token-efficiency.md](docs/token-efficiency.md).

**Layer 1 — caveman (model output).** Baked into every agent definition as a `## Token efficiency` section in `.claude/agents/*.md`. Compresses all user-facing output and all worker returns: terse fragments, no articles/filler/hedging, short synonyms, technical terms exact. Exceptions = same as Response Style (code, commit messages, PR text, security warnings, irreversible-action confirmations, multi-step sequences).

**Layer 2 — rtk (shell output).** `rtk` is a CLI proxy; cuts shell output 60–90% before agent reads it. Wired as a PreToolUse hook in `.claude/settings.json`, matcher `Bash`, command `rtk hook claude || exit 0` (fallback makes rtk optional — machine without the binary degrades to uncompressed output, nothing blocks). Hook rewrites Bash commands transparently (`git status` → `rtk git status`) and fires on every Bash call — orchestrator's and every subagent's. Rules:

- Never manually prefix `rtk`. Hook does it. Manual prefix only for meta commands: `rtk gain`, `rtk gain --history`, `rtk discover`, `rtk proxy <cmd>`, `rtk init --show`.
- Read/Grep/Glob built-ins bypass the hook. They're already cheap — prefer them over shell `cat`/`grep`/`find`.
- Command fails → rtk tees full raw output to its tee dir. Read it there; don't re-run.

# Orchestration Structure

Three-layer orchestration. In Claude Code, chat + orchestrator are one loop (see Constraint):

```
User Chat + Orchestrator (Fable 5, one loop) → Agent Swarm (Opus 5) → chat-responder (Sonnet 5, report relay) → user
```

## Layers

- **Orchestrator — Fable tier**: two valid entry points, same protocol either way:
  - *Inline* — the main Claude Code session runs the protocol itself, in its own loop.
  - *Delegated* — dispatch `orchestrator` (`.claude/agents/orchestrator.md`, `model: fable`), a standalone subagent that decomposes, dispatches the swarm, verifies, and relays on its own. Use this when the caller wants a whole task handed off, or when running a swarm cycle from a Workflow/automation that isn't itself the chat session.
- **Agent Swarm — Opus tier**: `swarm-worker` subagents (`.claude/agents/swarm-worker.md`, `model: opus`). Spawn several in parallel — one bounded work item each.
- **Chat relay — Sonnet tier**: `chat-responder` subagent (`.claude/agents/chat-responder.md`, `model: sonnet`) turns aggregated swarm output into the user-facing report.

Utility agents outside the swarm cycle, dispatched directly when their trigger fires:

- **`skill-manager`** (`.claude/agents/skill-manager.md`, `model: opus`) — finds, installs, or authors Claude Code skills. Resolution order: installed → marketplace/public repos → author new. Security-reviews every third-party skill before install.
- **`agent-builder`** (`.claude/agents/agent-builder.md`, `model: opus`) — writes and updates `.claude/agents/*.md` definitions to house rules (tier aliases, least-privilege tools, recursion guard, mandatory Project scope + Token efficiency sections).

`model: opus` / `model: sonnet` are tier aliases that resolve to the current generation (Opus 5 / Sonnet 5 today). The architecture pins tiers, not generations.

## Protocol

1. On a substantive task, the orchestrator decomposes it into 2–4 independent work items. Each work item carries: scope, owned (writable) paths, forbidden paths, interface contract, deliverable format, and done-criteria the orchestrator will mechanically check.
2. Dispatch one `swarm-worker` per item, in parallel (one message, multiple subagent-dispatch calls). If dispatching inline agents instead (e.g. a Workflow script with `model: 'opus'`), paste the swarm-worker rules of engagement into each prompt verbatim — inline agents do not load `.claude/agents/` definitions.
3. Subagents inherit no conversation context. Every dispatch prompt must contain everything the worker needs — including any `${UAE_*}` values the worker depends on, resolved to literals before dispatch.
4. The orchestrator aggregates worker results, verifies them mechanically (worked examples in `docs/orchestration-playbook.md`), and re-dispatches any failed item alone — never the whole wave.
5. Dispatch `chat-responder` with the full aggregated worker output inlined in the prompt; its output is the basis of the reply to the user.

Trivial/conversational turns skip the swarm — the orchestrator answers directly.

Parallel-write collision doctrine: disjoint write paths > worktree isolation > serialization. At most one worker per wave may touch any resource listed in `${UAE_EXCLUSIVE_RESOURCES}` — those are single-tenant (one editor at a time) and cannot be split across a parallel wave.

## Constraint

In Claude Code the chat model and the inline orchestrator are the same loop, and the session model is user-selected — it cannot be set from repo config. The `orchestrator` subagent sidesteps this (its `model: fable` is fixed regardless of session model) but is a delegated call, not the chat loop itself. Human setup steps live in `README.md`. The Sonnet chat layer from the architecture diagram is implemented as the `chat-responder` relay agent.

# Project Scope

This engine is project-agnostic. Nothing about the host project is hardcoded — every project-specific fact lives in the `env` block of `.claude/settings.json` and is referenced in prose as `${UAE_*}`.

## Variables

| Key | Meaning |
| --- | --- |
| `UAE_PROJECT_NAME` | Human name of the project this engine drives. |
| `UAE_PROJECT_TYPE` | Kind of thing being built (e.g. `marketing-site`, `web-app`, `api`, `library`). |
| `UAE_STACK` | Languages, frameworks, and build tooling in use. |
| `UAE_HOSTING` | Where it runs (e.g. `cloud-platform`, `self-hosted`, `static`). |
| `UAE_SOURCE_OF_TRUTH` | Where design/layout authority lives (e.g. an external design canvas, or `this repo`). |
| `UAE_EXCLUSIVE_RESOURCES` | Comma list of single-tenant resources; max one worker per wave may touch each (e.g. `design canvas, shared browser session`). |
| `UAE_COMPONENTS_PATH` | Repo path holding UI components / modules. |
| `UAE_CONTENT_PATH` | Repo path holding copy and content source of truth. |
| `UAE_TOKENS_PATH` | Repo path holding design tokens / theme values. |
| `UAE_AUDITS_PATH` | Repo path where audit and review reports are written. |
| `UAE_DESIGN_SYSTEM` | Pointer to the design-system file or doc. |
| `UAE_BRAND_VOICE` | Pointer to the voice / style guide. |
| `UAE_DEPLOY_MODEL` | What merge and publish mean here (branch ↔ environment mapping, who presses publish). |

## Resolution rule

Agents resolve `${UAE_*}` by reading the `env` block in `.claude/settings.json` (Claude Code also injects these into the shell environment). Then:

1. Value present and not `UNSET` → use it.
2. Value is `UNSET` **and** `project-details/` contains files → run the `init-project` intake first (`.claude/skills/init-project/SKILL.md`); it reads every file in `project-details/`, extracts values, writes them into the `env` block, and reports filled vs still-`UNSET`.
3. Value is `UNSET` **and** `project-details/` is empty → ask the user. Never guess a project fact.

Defaults ship as `UNSET` on purpose — an unfilled variable is a question to ask, not a blank to invent.
