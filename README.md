# Universal Agent Engine

A portable three-layer agent orchestration engine. Drop it onto any project — marketing site, web app, API, library — and every substantive task gets decomposed into bounded work items, run by a parallel swarm, verified, and reported back compressed.

Nothing here is project-specific. The engine reads what it needs to know about your project from environment variables in [.claude/settings.json](.claude/settings.json), filled once by the `init-project` intake from docs you drop into [project-details/](project-details/).

What you get:

- **Orchestration** — Fable-tier orchestrator, Opus-tier `swarm-worker` swarm, Sonnet-tier `chat-responder` relay. Protocol, dispatch contract, and collision doctrine in [CLAUDE.md](CLAUDE.md).
- **Token efficiency** — two default-on compression layers (caveman model output + `rtk` shell-output proxy). Details: [docs/token-efficiency.md](docs/token-efficiency.md).
- **Playbook** — worked task decompositions and mechanical verification examples: [docs/orchestration-playbook.md](docs/orchestration-playbook.md).
- **Self-extension** — the `skill-manager` agent finds, installs, or authors skills (with a security review gate on anything third-party); the `agent-builder` agent creates and updates agent definitions to house rules.

## Quick start

1. **Install the engine into your codebase.** The repo is private, so the one-liners authenticate through the [GitHub CLI](https://cli.github.com/) — install `gh` and run `gh auth login` once (with an account that can read `One-Uncle/universal-agent-engine`), then from the codebase root:

   ```bash
   gh api repos/One-Uncle/universal-agent-engine/contents/install.sh -H "Accept: application/vnd.github.raw" | sh
   ```

   Windows PowerShell:

   ```powershell
   gh api repos/One-Uncle/universal-agent-engine/contents/install.ps1 -H "Accept: application/vnd.github.raw" | Set-Content -Encoding UTF8 uae-install.ps1; powershell -ExecutionPolicy Bypass -File uae-install.ps1; Remove-Item uae-install.ps1
   ```

   Both fetch the installer, which then downloads the rest of the engine through the same `gh` token. Or skip the one-liner entirely and install from a clone: `git clone` this repo, then `sh install.sh /path/to/your/project` / `install.ps1 -TargetDir <path>`. (Cloning this repo standalone and working inside it also works — it already ships in installed form. If the repo ever goes public, plain `curl -fsSL https://raw.githubusercontent.com/One-Uncle/universal-agent-engine/main/install.sh | sh` works too — the installers fall back to anonymous download automatically.)

   The installer never clobbers existing work: engine files are skip-if-exists (`--force` / `-Force` to overwrite), an existing `.claude/settings.json` is merged — your keys, values, and hooks are preserved, missing `UAE_*` keys are added as `UNSET`, and the rtk hook entry is appended — an existing `CLAUDE.md` just gains an appended `@.claude/UAE.md` import, and `.gitattributes` gains `*.sh text eol=lf`. Idempotent: rerun anytime; `--dry-run` / `-DryRun` prints the plan without writing. If no `python3`/`python` is on PATH for the JSON merge, the engine settings land in `.claude/settings.uae.json` with a manual-merge note instead.
2. **Drop your docs.** Put project spec, scope, design-system, and brand-voice docs into `project-details/`. Any format. Nothing to reformat.
3. **Initialize.** Open Claude Code in the repo and say **"initialize project"**. That runs the `init-project` skill: it reads every file in `project-details/`, extracts project facts, and writes them into the `env` block of `.claude/settings.json`.
4. **Review.** Check the filled values in `.claude/settings.json`. `init-project` reports which keys it filled and which are still `UNSET`; fill the leftovers by hand or add the missing doc and re-run.
5. **Work.** Give it a task. Every substantive task runs the swarm — decompose, parallel dispatch, mechanical verify, compressed report.

## Human setup

- Run the Claude Code session on **Fable 5** (model picker / `/model`). The session is chat + orchestrator in one loop. (Or delegate to the `orchestrator` subagent, whose model is pinned regardless of session model.)
- Swarm workers (**Opus** tier) and the chat relay (**Sonnet** tier) are pinned in [.claude/agents/](.claude/agents/) and need no setup.
- Install [rtk](https://github.com/rtk-ai/rtk) (shell-output compression proxy) with the bundled installer — it detects your OS and CPU architecture, runs the matching official install method (Homebrew / prebuilt release binary / official install script / cargo), and registers the global hook (`rtk init -g --auto-patch`):

  ```bash
  sh scripts/install-rtk.sh          # macOS / Linux / Git Bash
  ```

  ```powershell
  powershell -ExecutionPolicy Bypass -File scripts\install-rtk.ps1   # Windows
  ```

  Both are idempotent and take a `--dry-run` / `-DryRun` flag that prints the plan without changing anything. After installing: restart Claude Code, then approve this repo's project-level hook prompt on first run. Optional — the hook ends in `|| exit 0`, so a machine without the binary degrades gracefully to uncompressed output. Without it the agents still work, they just burn 60–90% more tokens on command output.

## Project variables

Single source of truth: the `env` block in `.claude/settings.json`. All default to `UNSET`. Keep this table in sync with [CLAUDE.md](CLAUDE.md).

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

Resolution rule: read the value → if `UNSET` and `project-details/` has files, run `init-project` → if `UNSET` and `project-details/` is empty, ask. Agents never guess a project fact.
