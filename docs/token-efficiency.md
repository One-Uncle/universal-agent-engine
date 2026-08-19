# Token Efficiency

Token efficiency is a default property of this engine's agent architecture, not a per-task decision. Two independent layers compress two different streams:

| Layer | Compresses | Mechanism | Where configured |
| --- | --- | --- | --- |
| 1. Caveman | Model-generated text (replies, worker returns, dispatch prompts) | Prompt-level style rule | `## Token efficiency` section in each `.claude/agents/*.md`; `# Response Style` + `# Token Efficiency` in `CLAUDE.md` |
| 2. rtk | Shell command output entering context | PreToolUse hook rewriting Bash commands | `.claude/settings.json` |

They compose without interacting: rtk shrinks what goes *into* the model, caveman shrinks what comes *out*.

Both layers are project-agnostic. Neither reads any `${UAE_*}` project variable — they apply identically whatever the host project turns out to be.

## Layer 1 — caveman

Canonical rules, embedded verbatim in every agent definition:

> Terse fragments. Drop articles (a/an/the), filler (just/really/basically/actually/simply), pleasantries, hedging. Short synonyms (big not extensive, fix not "implement a solution for"). Technical terms exact. Code blocks unchanged. Errors quoted exact. Exceptions (normal prose): code, commit messages, PR text, security warnings, irreversible-action confirmations, multi-step sequences where fragment order risks misread.

The exception list is load-bearing. Compression is a formatting rule, never a content rule — no fact, path, line number, or error string may be dropped to save tokens. If a sentence can't be shortened without losing precision, leave it long.

## Layer 2 — rtk

### What it is

[rtk](https://github.com/rtk-ai/rtk) ("Rust Token Killer") is a Rust CLI proxy. It wraps common developer commands and re-emits their output in a compact, agent-readable format — dropping decorative framing, redundant columns, unchanged context, and passing noise. It is a machine-level install, not vendored into the repo; check the local version with `rtk --version`.

### Measured reduction by command class

| Command class | Typical reduction |
| --- | --- |
| `git` (status, diff, log, branch) | 70–90% |
| Test runners | ~90% (failures-only output) |
| `cargo` / build tooling | 75–80% |
| Linters | 60–85% |
| `ls`, `tree`, `cat`, `grep`, `find`, `diff`, `docker`, `kubectl`, `gh` | compact formats, varies |

Overall band: **60–90%** of shell output tokens removed before the agent ever reads them.

### Hook mechanism

Integration is a Claude Code `PreToolUse` hook on the `Bash` tool. Before a Bash command executes, `rtk hook claude` inspects it and rewrites it in place if rtk has a handler — `git status` becomes `rtk git status`. Otherwise the command passes through unchanged.

`.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "rtk hook claude || exit 0"
          }
        ]
      }
    ]
  }
}
```

Three properties make this the right layer to intervene at:

- **Zero per-command context overhead.** No instructions to carry, no reminders to re-read, nothing the model can forget. The rewrite happens outside the model.
- **100% adoption, including subagents.** The hook is a session-level tool interceptor, so it fires for every Bash call made by the orchestrator, every `swarm-worker`, and `chat-responder` alike. Subagents inherit it without their definitions mentioning it.
- **Graceful degradation.** The `|| exit 0` fallback makes the rtk binary an optional accelerator, not a hard dependency: on a machine without rtk on PATH, the hook exits 0 with no rewrite and every command runs normally — just uncompressed. Verified in both `cmd` and `sh`; nothing blocks, nothing breaks. The repo owns the integration; the binary is a per-machine install like git itself.

Because it's project-scoped in `.claude/settings.json`, a fresh clone of the engine gets the behavior on any machine. A user-level `~/.claude/settings.json` copy of the same hook would only cover the one machine it was written on.

### Limitations and escape hatches

- **Built-in tools bypass rtk.** Read, Grep, and Glob are not Bash calls, so the hook never sees them. This is fine: their output is already structured and cheap. Agents should prefer them over shell `cat` / `grep` / `find` — that path is both cheaper *and* not dependent on rtk being installed.
- **Failures tee full output.** When a proxied command fails, rtk writes the complete raw output to a local tee directory (`~/.local/share/rtk/tee/` on Unix) and points at it. Read the tee file rather than re-running the command with `rtk proxy` — re-running costs time and can have side effects.
- **Opting a command out.** Add it to `exclude_commands` in `~/.config/rtk/config.toml` if a specific command's compaction ever loses information you need routinely. For one-off debugging use `rtk proxy <cmd>` instead of editing config.
- **Compaction is lossy by design.** For anything where exact byte-level output matters (parsing, reproducing a bug report verbatim), use `rtk proxy`.

### Meta commands

Never rewritten by the hook; call these with an explicit `rtk` prefix:

| Command | Purpose |
| --- | --- |
| `rtk gain` | Token savings analytics |
| `rtk gain --history` | Per-command usage history with savings |
| `rtk discover` | Scan Claude Code history for missed compression opportunities |
| `rtk proxy <cmd>` | Raw passthrough, no filtering (debugging) |
| `rtk init --show` | Verify install / show resolved config |

Outside these, agents must **not** manually prefix `rtk`. Double-prefixing is a bug, and hand-written prefixes rot when rtk's handler list changes.

### New-machine setup

1. Install the rtk binary — see [github.com/rtk-ai/rtk](https://github.com/rtk-ai/rtk).
2. Run `rtk init -g` (global config).
3. Restart Claude Code so the hook config is picked up.
4. Open this repo and approve the project-level hook prompt when Claude Code asks.
5. Verify: `rtk --version` (expect `rtk X.Y.Z`) and `rtk gain` (must not error).

Name collision warning: an unrelated project also ships a binary called `rtk` (reachingforthejack/rtk, "Rust Type Kit"). If `rtk gain` fails, check `which rtk` — you have the wrong one.

## How the two layers compose in orchestration

One swarm cycle, following the flow in `CLAUDE.md`:

1. **Orchestrator writes dispatch prompts** — terse, but complete. Workers inherit no conversation context, so a dispatch prompt is the one place where completeness outranks brevity. Compress phrasing, never content. Any `${UAE_*}` value a worker needs must be resolved to its literal value in the prompt, not passed through as a placeholder.
2. **Workers run shell commands** — every Bash call is intercepted by `rtk hook claude`, so 60–90% of build/test/git output never enters the worker's context. More budget left for actual reasoning.
3. **Workers return results in caveman** — structured fragments, absolute file paths with line numbers, exact error strings. The orchestrator aggregates several of these, so worker verbosity multiplies; this is the highest-leverage compression point in the cycle.
4. **Orchestrator verifies mechanically** — done-criteria checks are shell commands or built-in tool calls, both cheap by layer 2 / built-in bypass.
5. **`chat-responder` relays** — receives the aggregated worker output inlined, emits the user-facing report in caveman per `# Response Style`.

Net effect: the expensive middle of the pipeline (workers reading tool output, orchestrator reading worker returns) is compressed on both sides, and the user-facing end stays terse by the same rule that governs the rest.
