---
name: init-project
description: Intake flow that turns dropped project documents into engine configuration. Use when the user says "initialize project", "set up project", "analyze project details", "fill env vars", "configure the engine", or points at new files in project-details/ — and whenever a needed UAE_* variable reads UNSET while project-details/ contains files. Reads every file in project-details/, extracts the 13 UAE_* values with quoted evidence, writes them into the env block of .claude/settings.json, and reports what is still UNSET.
---

# init-project

Fills the engine's single source of truth — the `env` block in `.claude/settings.json` — from whatever the user dropped into `project-details/`.

The engine ships project-agnostic: all 13 `UAE_*` keys start as `"UNSET"`. Agents resolve `${UAE_*}` placeholders by reading that env block. Until it is filled, waves cannot be dispatched with concrete OWNED/FORBIDDEN paths. This skill is how it gets filled.

## The 13 keys

| Key | Meaning | Example |
| --- | --- | --- |
| `UAE_PROJECT_NAME` | Human name of the project | `acme-docs` |
| `UAE_PROJECT_TYPE` | Shape of the thing being built | `marketing-site` \| `web-app` \| `api` \| `library` |
| `UAE_STACK` | Languages, frameworks, key tooling | `TypeScript, Next.js, Tailwind` |
| `UAE_HOSTING` | Where it runs | `cloud-platform` \| `self-hosted` \| `static` |
| `UAE_SOURCE_OF_TRUTH` | Where design/layout authority lives | `this repo` \| a named external canvas or CMS |
| `UAE_EXCLUSIVE_RESOURCES` | Comma list of single-tenant resources; max one worker per wave may touch each | `design canvas, shared browser session` |
| `UAE_COMPONENTS_PATH` | Repo path for components | `src/components` |
| `UAE_CONTENT_PATH` | Repo path for copy/content | `content` |
| `UAE_TOKENS_PATH` | Repo path for design tokens | `src/styles/tokens` |
| `UAE_AUDITS_PATH` | Repo path for audit/report artifacts | `docs/audits` |
| `UAE_DESIGN_SYSTEM` | Pointer to the design-system file or doc | `docs/design-system.md` |
| `UAE_BRAND_VOICE` | Pointer to the voice/style guide | `docs/brand-voice.md` |
| `UAE_DEPLOY_MODEL` | What merge/publish actually means here | `merge to main auto-deploys via CI` |

## Procedure

**1. Read everything in `project-details/`.**

`Glob` the directory (`project-details/**/*`), then `Read` every file — specs, scope docs, design systems, brand guides, PRDs, exported briefs, screenshots, any format. Do not sample; a single line in one file is often the only evidence for a key. If the directory is empty or missing, stop here and tell the user to drop project documents in, or to answer the 13 questions directly.

**2. Extract or infer each of the 13 values, with evidence.**

For every key, record the value and the exact quoted line(s) plus source file path that justify it. Direct statements beat inference. Inference is allowed when it is near-certain and mechanical — a repo listing showing `src/components/` justifies `UAE_COMPONENTS_PATH`, a `package.json` with `next` justifies part of `UAE_STACK`. Inference is not allowed for anything the documents merely imply socially: brand voice, deploy semantics, and exclusivity of resources must be stated somewhere or they stay `UNSET`.

**3. Write the values into `.claude/settings.json`.**

Use `Edit` on the `env` block only. Do not touch the `hooks` block — the `rtk hook claude || exit 0` entry must survive byte-identical. Keep all 13 keys present; a key you could not fill keeps the literal string `"UNSET"`. Verify the file is still valid JSON after editing.

**4. Leave unknowables `UNSET` and turn each into a question.**

For every key still `UNSET`, write one specific question the user can answer in a sentence — "Which path holds design tokens?" not "Tell me more about your project". Never invent a value to avoid an empty cell.

**5. Report.**

Return a table, one row per key: `key → value written → source file (or "question for user")`. Then list the open questions, then state whether the engine is ready to dispatch waves (ready = every key needed for the user's next task is filled; a partially filled env block is normal and usable).

## Rules

- **Never invent.** `UNSET` plus a question always beats a plausible guess. A wrong path silently sends a whole wave writing into the wrong directory.
- **Evidence per value.** If you cannot quote a source line for a value, it is a guess — treat it as `UNSET`.
- **Env block is the single source of truth.** Do not scatter project facts into agent files, `CLAUDE.md`, or docs; everything the agents need comes from `.claude/settings.json`.
- **Re-runnable.** Running this skill again after the user adds files must update changed keys and fill newly-answerable ones without clobbering values the user set by hand — if a stored value conflicts with new evidence, report the conflict instead of silently overwriting.
- **Report is caveman.** Terse fragments, exact technical terms; normal prose only for questions to the user where ambiguity would cost a round trip.
