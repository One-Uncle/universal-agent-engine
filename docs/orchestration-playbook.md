# Orchestration Playbook — worked examples

> The three examples below are templates, not project facts. Path and surface names appear as `${UAE_*}` placeholders. Resolve each one by reading the `env` block in `.claude/settings.json` (Claude Code also injects those keys into the shell env). If a variable you need is `UNSET`: run the `init-project` intake first when `project-details/` has files in it; ask the user when it is empty. Never guess a value.
>
> The dispatch contract, the collision doctrine, and the verification gates are the normative part of this document — the example decompositions are illustrative and expected to be re-cut per project.

## Resolved surfaces used below

| Placeholder | Meaning in a dispatch |
| --- | --- |
| `${UAE_COMPONENTS_PATH}` | Component / UI code root |
| `${UAE_CONTENT_PATH}` | Copy source of truth (structured content files) |
| `${UAE_TOKENS_PATH}` | Design tokens (color, type, space, radius, motion) |
| `${UAE_AUDITS_PATH}` | Audit outputs, conventionally `<AUDITS>/<YYYY-MM-DD>/*.md` |
| `${UAE_DESIGN_SYSTEM}` | Pointer to the design-system doc/file that governs visual decisions |
| `${UAE_BRAND_VOICE}` | Pointer to the voice/style guide that governs prose |
| `${UAE_SOURCE_OF_TRUTH}` | Where design/layout authority actually lives (a visual editor, this repo, a CMS) |
| `${UAE_EXCLUSIVE_RESOURCES}` | Comma list of single-tenant resources — **at most one worker per wave may touch each** |
| `${UAE_DEPLOY_MODEL}` | What merge/publish means for this project |

Whenever `${UAE_SOURCE_OF_TRUTH}` names something outside git (a hosted visual editor, a CMS), that surface is not path-isolatable → it belongs in `${UAE_EXCLUSIVE_RESOURCES}` and gets **exactly one writer per wave**; everything else parallelizes in the repo.

## Cross-cutting dispatch contract

Every work item carries six fields:

1. scope
2. OWNED paths (write)
3. FORBIDDEN paths (read-only or untouchable)
4. interface contract (names/keys fixed by the orchestrator *before* dispatch, so workers never negotiate at runtime)
5. deliverable format
6. done-criteria the orchestrator will mechanically check

Collision doctrine: disjoint write paths > worktree isolation > serialization. Never rely on workers "being careful."

---

## (a) "Build the page / ship the feature"

**Pre-dispatch (orchestrator, ~5 min, not delegated):** freeze the interface — token names (`color.bg`, `color.accent`, `space.*`, `type.*`) taken from `${UAE_DESIGN_SYSTEM}`, content keys (`hero.headline`, `hero.sub`, `hero.cta`, `proof.*`, `features[].*`, `faq[].*`, `cta.*`), component names + props (`<Hero>`, `<FeatureGrid>`, `<LogoWall>`, `<CTABand>`), and section/route order. Written into every dispatch prompt verbatim, with every `${UAE_*}` already resolved to a literal path. Without this, three workers invent three incompatible vocabularies and aggregation fails.

- **W1 — Visual foundation.** OWNS `${UAE_TOKENS_PATH}`, `${UAE_DESIGN_SYSTEM}`. FORBIDDEN `${UAE_COMPONENTS_PATH}/**`, `${UAE_CONTENT_PATH}/**`. Delivers: full token set (color, type scale, spacing, radius, motion), section-by-section layout spec at 3 breakpoints, contrast-verified pairs.
- **W2 — Copy.** OWNS the feature's file(s) under `${UAE_CONTENT_PATH}`, `${UAE_BRAND_VOICE}`. FORBIDDEN `${UAE_COMPONENTS_PATH}/**`, `${UAE_TOKENS_PATH}`. Delivers: every frozen content key filled, 2 hero variants marked `A`/`B`, char-budget compliant (H1 ≤60, meta 150–160), no key invented outside the contract.
- **W3 — Components.** OWNS `${UAE_COMPONENTS_PATH}/*` (exact named list). FORBIDDEN writing `${UAE_TOKENS_PATH}`, `${UAE_CONTENT_PATH}/*` (imports both, edits neither). Delivers: components consuming tokens by import and content by key — **zero literal hex/px, zero literal copy strings in component source** — plus whatever prop-metadata mechanism `${UAE_STACK}` provides (prop controls, propTypes, schema), responsive variants.
- **W4 — Assembly in `${UAE_SOURCE_OF_TRUTH}` (optional; sole writer of that resource).** OWNS the surface named in `${UAE_EXCLUSIVE_RESOURCES}` plus `docs/assembly.md`. No repo code paths. Runs only after W1–W3 land, or in the same wave if it merely documents the assembly steps for a human.

**Aggregation verification (mechanical, orchestrator runs before relay):**

- grep: every token identifier referenced in `${UAE_COMPONENTS_PATH}/**` exists in `${UAE_TOKENS_PATH}`; every content key used exists in the `${UAE_CONTENT_PATH}` file; report orphan keys both directions.
- grep: no `#[0-9a-f]{3,6}`, no `\d+px`, no sentence-case string literals inside `${UAE_COMPONENTS_PATH}/**`.
- typecheck/build if the `${UAE_STACK}` toolchain exists; otherwise verify each component exports default + declares its props.
- a11y: exactly one `h1`, monotonic heading order, alt on every image, WCAG AA on every token color pair W1 declared.
- Coherence check no worker could do alone: does W2's copy length actually fit W1's layout spec at 375px? Re-dispatch the shorter loop (usually W2) on failure.

**To chat-relay:** what the page/feature now is (sections or routes, in order), the hero A/B decision the user must make, what still requires a human in `${UAE_SOURCE_OF_TRUTH}` (assembly, asset upload, domain/publish per `${UAE_DEPLOY_MODEL}`), file paths touched. Not: which worker did what.

---

## (b) "SEO + performance audit of the live product"

**Pre-dispatch:** orchestrator supplies the identical URL/endpoint list, device/viewport profile, and one run timestamp to all workers, so numbers are comparable. **Browser contention is the real collision here, not files** — a shared browser session is single-tenant and must be listed in `${UAE_EXCLUSIVE_RESOURCES}`: W3 owns the live browser session; W1/W2 work from fetched HTML source; W4 gets the browser after W3 releases it (or a second tab explicitly assigned).

- **W1 — Crawlability & indexation.** OWNS `${UAE_AUDITS_PATH}/<date>/technical-seo.md`. ASPECT: robots.txt, sitemap.xml, canonicals, redirect chains, status codes, hreflang, noindex, URL structure, head tags generated by the hosting platform (`${UAE_HOSTING}`).
- **W2 — On-page & structured data.** OWNS `${UAE_AUDITS_PATH}/<date>/onpage-seo.md`. ASPECT: titles, meta descriptions, heading hierarchy, internal linking, JSON-LD/schema, OG/Twitter cards, image **alt text and semantics only**.
- **W3 — Performance / Core Web Vitals.** OWNS `${UAE_AUDITS_PATH}/<date>/performance.md` + the browser session. ASPECT: LCP/INP/CLS/TBT, render-blocking, image **bytes/format/dimensions/lazy only**, font loading strategy, third-party scripts, caching headers.
- **W4 — Accessibility & mobile.** OWNS `${UAE_AUDITS_PATH}/<date>/a11y-mobile.md`. ASPECT: contrast, focus order, keyboard traps, landmarks, tap targets, viewport meta, motion preferences.

Attach whatever installed skills match the aspect (SEO-audit, on-page-SEO, web-perf plugins) in the dispatch prompt; omit silently if not installed.

**Contested-surface rulings (stated in the dispatch, because these overlap by default):**

- Images: alt/semantics→W2 · bytes/format/lazy→W3 · contrast/tap-target→W4.
- Fonts: loading & FOIT/FOUT→W3 only. Typography legibility→W4.
- Redirects: W1 owns the verdict; W3 may cite chain latency but must defer, not recommend.
- Schema markup: W2 only.

**Aggregation verification:**

- Evidence gate: reject any finding lacking URL + measured value + timestamp. Assertions from memory get dropped, not softened.
- Deduplicate across the four reports; merge the same root cause reported four ways into one item.
- **Reconcile contradictions** — the orchestrator's main value here (e.g. W3 "preload the webfont" vs W4 "system stack is more legible"; W2 "add FAQ schema" vs W1 "that page is noindexed"). Pick one, record the loser and why.
- Normalize severity against one rubric (P0 blocks indexing/conversion · P1 measurable CWV or ranking loss · P2 hygiene).
- Tag each fix with its executor: `${UAE_SOURCE_OF_TRUTH}` · code component · host/DNS · content. Anything not actionable in-repo gets flagged as a user action, not a task.

**To chat-relay:** top 5 ranked fixes with expected impact and where each is done, the contradictions resolved and how, what could not be verified and why (e.g. no search-console/analytics access), path to the audit folder under `${UAE_AUDITS_PATH}`.

---

## (c) "Product-wide copy / brand-voice pass"

**Pre-dispatch:** a **frozen voice charter** is mandatory. If `${UAE_BRAND_VOICE}` is `UNSET` or the file it points at does not exist, run charter creation as a single serial pre-wave item — do not let three rewriters each infer a voice. The charter fixes: product name capitalization, tagline, CTA verb set, person/tense, forbidden words, claim policy. Also fixed before dispatch: whether copy currently lives inline in component source — if so, extraction into `${UAE_CONTENT_PATH}` is its own pre-wave item, because rewriters must never edit component code.

Scope by **page/route, never by aspect** — aspect-splitting on prose guarantees two workers rewriting the same sentence.

- **W1 — Home + primary landing.** OWNS `${UAE_CONTENT_PATH}/home.*`, `${UAE_CONTENT_PATH}/landing.*`.
- **W2 — Product surface.** OWNS `${UAE_CONTENT_PATH}/features.*`, `${UAE_CONTENT_PATH}/pricing.*`, `${UAE_CONTENT_PATH}/how-it-works.*`.
- **W3 — Company, legal, and global chrome.** OWNS `${UAE_CONTENT_PATH}/about.*`, `${UAE_CONTENT_PATH}/contact.*`, `${UAE_CONTENT_PATH}/legal/*`, **and** `${UAE_CONTENT_PATH}/global.*` (nav labels, footer, form labels, error/empty states, 404, email-capture microcopy) — global chrome belongs to exactly one worker or every page-worker will "improve" the nav.
- **W4 — Read-only inventory (parallel, writes no content).** OWNS `${UAE_AUDITS_PATH}/<date>/copy-inventory.md`. Builds the **before**-state terminology inventory, every factual/comparative claim in the product with its source-or-unsourced status, and per-string char budgets + current target keywords per page. Orchestrator reuses this as the verification baseline. Read-only, so it collides with nothing.
- **W5 — Assembly / publish into `${UAE_SOURCE_OF_TRUTH}` (only if content does not flow automatically).** Sole toucher of the relevant entry in `${UAE_EXCLUSIVE_RESOURCES}`; runs serially after W1–W3 land. If `${UAE_SOURCE_OF_TRUTH}` is "this repo", this worker does not exist.

ALL rewriting workers FORBIDDEN: `${UAE_COMPONENTS_PATH}/**`, `${UAE_TOKENS_PATH}`, and each other's content files.

**Aggregation verification:**

- Charter conformance: forbidden words, person/tense, product-name capitalization — grep against the charter's own lists in `${UAE_BRAND_VOICE}`.
- **Full-corpus dedupe** — the failure mode unique to this task is three workers independently inventing three different taglines / three CTA vocabularies. Diff W1/W2/W3 output against W4's inventory and against each other; unify centrally, don't re-dispatch.
- Claims gate: any claim added that W4's inventory doesn't already substantiate is quarantined for human sign-off, never shipped silently.
- SEO regression: target keyword still present in title/H1 per W4's baseline; meta 150–160 chars; nav labels within char budget.
- Key integrity: no content key added or removed relative to before-state (components would break); diff key sets.

**To chat-relay:** the voice in one line, before/after for hero and the top CTAs, the terminology decisions taken (and which page's wording won), the list of claims needing factual/legal sign-off, pages deliberately left untouched, confirmation nothing in `${UAE_COMPONENTS_PATH}` changed, and what remains to publish per `${UAE_DEPLOY_MODEL}`.

---

## Failure handling (all three)

- Worker returns blocked → orchestrator re-dispatches that item alone with the missing input supplied; it does not re-run the wave.
- Worker breached its path scope → revert its out-of-scope edits, re-dispatch with the boundary restated.
- Two workers wrote the same file → the wave was mis-decomposed; the orchestrator merges by hand and fixes the scope split before the next wave, rather than asking workers to reconcile.
- Worker blocked on an `UNSET` `${UAE_*}` value → that is an intake failure, not a work failure: run `init-project` (or ask the user), then re-dispatch the item with the resolved literal.
- Two workers touched the same entry in `${UAE_EXCLUSIVE_RESOURCES}` → treat as data loss until proven otherwise; inspect that resource's current state before any further wave.
