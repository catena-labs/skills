---
name: optimize-agents-md
description: Create, audit, or prune AGENTS.md and CLAUDE.md files following current best practices. Use this whenever the user asks to set up, create, add, update, fix, clean up, restructure, or audit an AGENTS.md or CLAUDE.md — or uses casual phrasings like "set this up for Claude", "set this up for agents", "make a claude.md", "add agent instructions", "onboard this for Claude Code / Cursor / Codex / Copilot / Gemini / Windsurf", "make Claude follow my conventions", or "my CLAUDE.md is too long". Covers the AGENTS.md open standard, cross-tool setups, and monorepo nesting decisions. Also use it proactively when you notice an existing CLAUDE.md / AGENTS.md is long, repetitive, or full of self-evident advice.
---

# optimize-agents-md

Write lean, high-compliance `AGENTS.md` files and wire `CLAUDE.md` to them via `@AGENTS.md` so every AI coding tool reads the same source of truth.

## Core philosophy

Frontier LLMs reliably follow only **~150-200 instructions per session**, and Claude Code's system prompt already consumes about 50 of those slots. Every line added to `AGENTS.md` dilutes compliance across _all_ rules, not just the newest ones. Ruthless curation is the foundational practice: a focused 60-80 line file Claude actually follows beats a 300-line file it mostly ignores.

Compliance also decays over long conversations — from 95%+ at messages 1-2 to 20-60% by messages 6-10. This is why the file should encode _preferences_, not hard _requirements_. Hard requirements belong in hooks, formatters, or CI. `AGENTS.md` is for the stuff that's hard to enforce mechanically.

**The litmus test for every line:** _"Would removing this line cause Claude to make a mistake it wouldn't otherwise make?"_ If no, cut it.

## Workflow

Run these stages in order. Stages 1-2 are autonomous discovery. Stage 3 is interactive but adaptive — don't pepper the user with questions if the answers are obvious from the code.

### 1. Survey the existing state

Read whatever exists in the project:

- `AGENTS.md`, `CLAUDE.md`, `CLAUDE.local.md`
- `.claude/` directory (rules, skills, settings)
- `.cursor/rules/`, `.cursorrules`, `.github/copilot-instructions.md`
- `README.md` and any `CONTRIBUTING.md` — commands and conventions worth extracting often live here

Note the current line count, how much looks like genuine non-obvious knowledge vs filler, and whether the file has grown by accretion without pruning.

**Treat existing AGENTS.md / CLAUDE.md content as hypotheses, not ground truth.** Bloated files routinely describe a stack that drifted years ago — libraries that were removed, conventions that were abandoned, architectural patterns that never shipped. Before carrying any stack claim forward (e.g. "uses React Router / Zustand / Tailwind / MSW"), verify it against the actual `package.json`, lockfile, and a quick look at the source. Writing an `AGENTS.md` full of phantom dependencies is worse than writing nothing — it actively misleads every future agent that reads it.

### 2. Discover objective facts

These are the highest-leverage entries in any `AGENTS.md`. Detect them from the repo directly rather than asking:

- **Package / dependency manager** — inspect lockfiles: `pnpm-lock.yaml`, `bun.lockb`, `yarn.lock`, `package-lock.json`, `uv.lock`, `poetry.lock`, `Pipfile.lock`, `Cargo.lock`, `go.sum`. Naming a specific tool like `uv` or `bun` has been shown to make agents use it ~160x more often, so this is one of the most valuable things to include.
- **Test / lint / format / typecheck commands** — extract from `package.json` scripts, `Makefile`, `justfile`, `pyproject.toml`, `Cargo.toml`, `mix.exs`, etc. Prefer the exact invocation with flags.
- **Unusual tooling** — `bun`, `just`, `mise`, `asdf`, `nix`, `devbox`, `turbo`, `nx`, `rush`, custom wrappers.
- **Framework / runtime** — only when it informs a non-obvious convention. "Uses Next.js" is noise; "Uses Next.js App Router, not Pages Router" may earn its place.
- **Monorepo structure** — workspace files (`pnpm-workspace.yaml`, `turbo.json`, `nx.json`, `lerna.json`, `rush.json`, `Cargo.toml` workspace, `go.work`) and top-level layout (`apps/`, `packages/`, `services/`, `infra/`). See the Monorepo section below.

### 3. Interview the user (only when needed)

The skill can't discover subjective conventions. Adapt interactivity to the situation:

- **If the user said "ask me" / "interview me"** — walk through each proposed section before writing.
- **If the user said "just do it"** — draft from survey + discovery and present the result for feedback.
- **Default** — use judgment. Ask only when there's genuine ambiguity the repo can't resolve.

Good questions when you do ask:

- "What has Claude (or Cursor / Codex) been getting wrong in this project?"
- "Any conventions here that go against common patterns for [detected stack]?"
- "Is there a file, module, or domain concept it keeps failing to find?"

### 4. Decide on structure

Single-package project: one root `AGENTS.md`. Monorepo: see the Monorepo section below before drafting.

### 5. Draft

Use the template in the Output Format section. Apply every rule in the Writing Patterns section. Before writing the file, run the Final Checks at the end of this document.

### 6. Wire up CLAUDE.md

Write `CLAUDE.md` with a single line: `@AGENTS.md`

This gives wider tool support — `AGENTS.md` is read natively by Claude Code, Codex CLI, Cursor, Copilot, Gemini CLI, and Windsurf — while preserving Claude Code's import behavior.

**Exception:** if the project has genuinely Claude-specific content (plan mode, specific skills, Claude Code hooks), put it below the import:

```markdown
@AGENTS.md

## Claude-specific

- Use plan mode for changes in src/billing/
```

Only do this for behaviors other tools don't share. Cross-tool rules belong in `AGENTS.md`.

## What earns its place

- **Exact commands with flags.** `pnpm test --filter=api` beats "run the tests for the api package".
- **Non-obvious tooling choices.** "Use `bun`, not `npm`" — because Claude's default is usually `npm`.
- **Architectural decisions that contradict what the code implies.** "Auth uses session tokens with Redis — not the JWT setup still in `src/auth-legacy/`."
- **Team conventions that go against common patterns.** "All imports use `@/` aliases; never use relative paths across module boundaries."
- **Domain concepts Claude keeps rediscovering.** Describe the _concept_, not the file path. Paths change; concepts survive refactors.
- **Failure-driven rules.** Rules added because Claude actually failed at something specific, with a short note on what went wrong.

## What wastes your budget

Cut these aggressively, especially when auditing an existing file:

- **Personality instructions.** "Act like a senior engineer." Adds noise, changes nothing.
- **Style guides.** Semicolons, tabs vs spaces, import ordering, naming conventions — these belong in ESLint, Prettier, Ruff, rustfmt, gofmt. Never send an LLM to do a linter's job.
- **Directory trees and codebase overviews.** Claude discovers structure on its own.
- **Code snippets.** They go stale fast and burn tokens every session.
- **Self-evident practices.** "Write clean code", "handle errors gracefully", "add tests", "follow DRY" are all noise.
- **Anything Claude already does correctly without being told.**
- **Duplicates of information in README, package.json, tsconfig, or CI configs.** One study found 28.7% of lines in real cursor rules duplicated info the AI could already access.

When pruning, err on the side of cutting. If you're uncertain whether a line earns its place, cut it and let the user ask for it back. The file's job is to stay under the compliance budget.

## Writing patterns

Apply these to every line.

**Imperative, not descriptive.**

- Yes: `Use named exports exclusively.`
- No: `It's preferred that default exports be avoided.`

**Positive, not negative.** Negated concepts still activate the concept being negated — flipping negatives to positives has been shown to cut rule violations roughly in half.

- Yes: `Use the logger utility in src/lib/logger.ts`
- No: `Never use console.log`

**Every prohibition carries a rationale and an alternative.** This lets Claude generalize to related situations it wasn't explicitly told about.

- Yes: `Never force-push to shared branches — it rewrites history other collaborators depend on. Use --force-with-lease on personal branches only.`
- No: `Never force-push.`

Specific negative rules are OK when they describe a concrete failure mode Claude has hit ("don't add event handlers when the framework handles reactivity"). The test is specificity: vague negatives are the problem, not negatives in general.

**Commands in code fences, not prose.** `pytest -xvs` in a fence gets followed; "run pytest" in prose gets buried.

**One instruction per bullet.** Combining multiple rules in one line reduces compliance with all of them.

**Use MUST / IMPORTANT sparingly.** Reserve them for 3-5 rules that truly cannot be broken. If everything is IMPORTANT, nothing is.

**Document domain concepts, not file paths.** "Authentication uses session tokens with Redis-backed storage" survives refactors; "auth logic lives in src/auth/handlers.ts" breaks the moment someone moves the file.

**Primacy and recency anchoring.** LLMs weight the beginning and end of context most heavily. Put the 3 most-critical rules in the first section _and_ the last section, with intentional duplication. Less critical content goes in the middle.

## Output format

Use this skeleton as the starting point. Adjust section names when it makes sense, but keep the primacy/recency anchoring and stay lean. Target 60-80 lines for a typical project; 40 is fine; over 120 is a red flag.

```markdown
# CRITICAL — Read first

- [Most-violated rule #1, with rationale]
- [Most-violated rule #2, with rationale]
- [Most-violated rule #3, with rationale]

## Commands

- `exact command` — what it does

## Conventions

- Convention — why it matters

## Architecture

Brief prose description of non-obvious patterns and key decisions. Reference deeper docs by path: see `docs/api-guide.md`. Use prose references, not @-imports — @ expands the file into context every session, eating your token budget even when irrelevant.

# CRITICAL — Read last

- [Same 3 critical rules repeated]
```

Heading rules: H1 for the critical anchors and any top-level split; H2 for sections; H3 for subsections only when needed; never H4+. Flat beats deep.

Do not strip markdown formatting. Headers and bold serve as parsing landmarks, especially for smaller models like Haiku.

## Monorepo handling

Claude Code and similar tools walk up the directory tree from the current working directory, loading every `AGENTS.md` / `CLAUDE.md` they find. Files in _child_ directories load lazily, only when the agent actually touches files in that subtree. Siblings never cross-contaminate. This is what makes nested files work: they scope automatically without any explicit wiring.

**Decision rule for the root file:** include a rule at the root only if it applies to ~30%+ of the codebase. Everything else belongs in a nested file.

**When to create a nested AGENTS.md** (in `apps/web/`, `services/api/`, `infra/`, etc.):

- The package has a distinct tech stack (e.g., `apps/web` is Next.js, `services/ingest` is Go, `apps/mobile` is Expo).
- The package has commands or conventions that differ meaningfully from the rest of the repo.
- The package has its own domain concepts that would confuse an agent working elsewhere.
- `infra/` almost always warrants its own file — Terraform / CDK / Pulumi conventions rarely apply to app code.

**When not to:** if a package just has slightly different lint config or one minor convention, keep it in the root file. Creating a 10-line nested file for one rule is usually worse than adding that rule to the root.

**Monorepo root file** should contain:

- Workspace-level commands (`pnpm -r test`, `turbo run build`, `cargo test --workspace`)
- Cross-cutting conventions that apply across packages
- A brief map of which subdirectories have their own `AGENTS.md`

The map helps humans and agents know what exists. Use prose references, not `@`-imports — the nested files load automatically when Claude works in those directories. Example:

```markdown
## Package-specific rules

- `apps/web/` — Next.js App Router conventions and component patterns
- `services/ingest/` — Go style and error handling
- `infra/` — Terraform module conventions
```

**Nested files follow all the same rules** as the root — lean, imperative, positive, failure-driven. They should contain _only_ what's specific to that subtree. Never duplicate root rules in nested files; the loader concatenates them.

## Handling an existing bloated file

When asked to audit, clean up, or update an existing `CLAUDE.md` or `AGENTS.md`:

1. **Read the whole file and classify each line** against the "earns its place" and "wastes your budget" criteria above.
2. **Propose the pruned version to the user before writing.** Show what's being kept, what's being cut, and why. The user may want to rescue something you flagged as filler because of context you don't have.
3. **Preserve failure-driven rules.** If a line looks odd but specific ("don't add event handlers when the framework handles reactivity"), it probably exists because of a real incident. Keep it unless the user confirms it's obsolete.
4. **Consolidate, don't duplicate.** If the project has both `CLAUDE.md` and `AGENTS.md`, merge into `AGENTS.md` and replace `CLAUDE.md` with `@AGENTS.md`.
5. **Flag graduation candidates.** Rules like "always run the formatter" or "never commit without typechecking" should graduate to hooks or pre-commit checks — note these to the user even though this skill won't implement them.

## Final checks

Re-read the draft against this checklist before writing the file:

- [ ] Under 120 lines? (Target 60-80.)
- [ ] Does every line pass the litmus test ("would removing this cause a mistake")?
- [ ] Does every prohibition have a rationale and an alternative?
- [ ] Imperative and positive phrasing throughout?
- [ ] MUST / IMPORTANT used at most 3-5 times?
- [ ] Top 3 rules mirrored at the start and end?
- [ ] No code snippets that will go stale?
- [ ] No style-guide content a linter could enforce?
- [ ] Commands in code fences with exact flags?
- [ ] File paths avoided in favor of domain concepts where possible?
- [ ] For monorepos: root contains only cross-cutting rules; package-specific rules live in nested files?
- [ ] `CLAUDE.md` set to `@AGENTS.md` (plus Claude-specific additions only if genuinely Claude-only)?

If any check fails, fix it before writing.

# CRITICAL — Read last

- **Wire `CLAUDE.md` to `@AGENTS.md`.** One source of truth, every AI tool reads it. Put Claude-specific rules under the import, not in a separate file.
- **Ruthless curation over completeness.** Every line competes for a finite compliance budget. When in doubt, cut.
- **Every prohibition carries rationale + alternative.** Let the model generalize instead of memorizing.
