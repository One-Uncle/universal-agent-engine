# project-details

Drop project spec, scope, design system, and brand voice docs here. Any format — Markdown, PDF, exported notes, screenshots, a pasted brief.

Then tell the agent: **initialize project**.

That runs the `init-project` intake, which reads every file in this directory, extracts the project facts, and writes them into the `env` block of `.claude/settings.json` (the `UAE_*` variables listed in [../CLAUDE.md](../CLAUDE.md)). It reports which keys it filled and which are still `UNSET`.

Files here are **inputs**. Agents read them; agents never edit them.
