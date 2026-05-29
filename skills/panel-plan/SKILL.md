---
name: panel-plan
description: >
  Harden a written plan by iterating it through a panel of independent local CLI
  coding agents (codex, claude, opencode). Use this skill whenever the user asks
  to "panel plan" / "panel-plan", "have the panel review my plan", "panel-review
  this plan", "get second opinions on this plan", "iterate on this plan with the
  panel", "fan out a plan review", or any similar phrasing asking for independent
  multi-agent review of a design / implementation *plan* (a markdown file),
  before any code is written. Each panelist runs in a fresh non-interactive
  subprocess with no shared state and reads the plan + the repo it targets, then
  reports gaps, wrong assumptions, infeasible steps, risks, and open questions.
  The coordinator synthesizes the round, applies clear fixes to the plan
  directly, raises genuine judgment calls to the user, updates the plan, and
  re-runs the panel — looping until the plan converges. This is the
  planning-time analog of panel-review (which reviews shipped code). Do NOT use
  for reviewing a code diff or PR (that is panel-review), or when the user just
  wants this session to critique the plan itself.
---

# panel-plan

Iterates a written plan through multiple independent local CLI agents. Each
panelist runs in its own subprocess with no shared conversation state — they see
only the plan, the repo it targets (read-only), and the review prompt. The
coordinator runs the panel, synthesizes findings, applies the clear fixes,
raises the judgment calls to the user, updates the plan, and runs the panel
again — round after round, until the plan stops attracting significant concerns.

This is the planning-time sibling of `panel-review`. It reuses panel-review's
launch / progress / synthesis machinery; the differences are (1) the payload is
a plan `.md`, not a diff, (2) the review is iterative with a human gate, and (3)
panelists report **open questions** alongside findings.

## When to use

- User has a written plan (a design / implementation `.md`, e.g. from
  brainstorming or `writing-plans`) and wants an independent panel to harden it
  before implementation.
- User says "panel plan", "have the panel review my plan", "iterate this plan
  with the panel", or similar.

When _not_ to use:

- Reviewing a code diff or PR → use `panel-review`.
- User wants *this* session to critique the plan → just do it inline; no fan-out.
- The plan does not exist yet → brainstorming / `writing-plans` first.

## Pre-flight (before round 1)

1. **Resolve the plan file.** In priority order: an explicit path the user gave
   (`/panel-plan docs/specs/foo.md`) → the most recent plan/spec produced in this
   conversation → ask the user which file. The plan must be a markdown file that
   exists on disk. If the plan only lives in the conversation, write it to a file
   first (confirm the path with the user).
2. **Pick panelists.** Default: every supported CLI on `PATH` (codex, claude,
   opencode). The user may name a subset.
3. **Capture optional focus.** If the user gave context ("focus on the migration
   strategy"), pass `--focus`.
4. **Name the review-notes file.** `<plan-dir>/<plan-basename>.review.md` (e.g.
   `docs/specs/foo.review.md`). You will append a round entry here each round —
   the plan file itself stays free of review chatter.

## Each round

### Step 1 — Run the panel

Run `skills/panel-plan/panel-plan.sh --plan <file>` (plus `--focus` / `--panelist`
as chosen). Launch and monitor it **exactly** the way `panel-review` does — those
operational rules apply verbatim here and are not repeated in full:

- Launch as a **background Bash** (`run_in_background: true`) and poll with
  `BashOutput` on the returned `bash_id` **every 10 seconds** until every
  panelist has emitted its `done (exit N)` heartbeat. This overrides the default
  "don't poll background tasks" guidance — the heartbeats and per-section
  streaming exist precisely so you can show live progress.
- Do **not** launch via the `Agent` tool / `TaskCreate` / any subagent mechanism
  (no streaming-output API for in-flight subagents). Do **not** poll via
  `sleep N && grep`. `BashOutput` is the only correct progress mechanism.
- A quiet `BashOutput` is **not** a hang. The only stderr signals are
  `panel-plan: <name> started` and `panel-plan: <name> (<model>) done (exit N)`;
  between them a panelist can go many minutes silent. The script enforces a
  per-panelist `timeout` (default 600s); your job is to wait it out. Intervene
  only if the `bash_id` itself exits, an obvious failure surfaces (panic / OOM /
  CLI-not-found), or the run vastly exceeds `timeout × panelists` with zero
  `done` heartbeats.
- **Live progress UX (same as panel-review):** `TodoWrite` one todo per panelist
  (`Round N: codex`, …) plus a `Synthesize round N` todo; flip each to
  `in_progress` on its `started` heartbeat and `completed` on its `done`
  heartbeat; post a one-line status including the self-reported model
  (`✓ codex (gpt-5.5) — N findings, M open questions`); and **stream each
  panelist's full `## <name> / <model>` section to chat the moment it lands**.

### Step 2 — Synthesize the round

Read the script's combined output (one section per panelist + a tempdir path).
Wait for **all** panelists to finish before synthesizing. Then:

- **Dedup findings** across panelists by `<plan>:LINE` (or overlapping ranges)
  AND substantively-same claim; list every panelist on a `Flagged by:` line and
  prefix with the count when ≥2 raised it. Use the higher severity when they
  differ and note it inline.
- **Bucket by severity:** must-fix (CRITICAL/HIGH), should-fix (MEDIUM), polish
  (LOW). Omit empty buckets.
- **Collect the union of `Open questions`** from every panelist; dedup.
- **Verify questionable findings before surfacing them.** Same discipline as
  panel-review: a unique CRITICAL/HIGH claim, a `Fix:` that doesn't address the
  issue, a suspicious line reference, panelist disagreement, or reasoning that
  depends on codebase behavior the panelist didn't actually check — open the
  plan and/or the referenced code (`Read`/`Grep`) and confirm before acting on
  it. Drop what you can falsify; note the correction.
- **Misinterpretation check.** If a panelist's `Goal:` line disagrees with what
  the plan actually says, call it out and treat that panelist's findings with
  extra skepticism — a misread goal produces confidently-wrong findings.

### Step 3 — Triage every item: auto-fix vs. raise to the user

This is the heart of the skill. Sort every finding and every open question into
exactly one path:

- **Auto-fix — edit the plan directly.** Clear, uncontested improvements that do
  not change *what the plan is trying to do*: filling an obvious gap, correcting
  a verified-wrong assumption about the codebase, fixing step ordering, adding a
  missing error / rollback / verification step, tightening a vague step into a
  specific one.
- **Raise to the user — ask before editing.** Anything that needs a human
  decision: every **open question**, any trade-off with no clear winner, any
  scope expansion or reduction, product/UX decisions, panelist disagreements you
  could not resolve by verification, and any edit that would change the plan's
  intent or success criteria. Surface these with `AskUserQuestion` (or prose if
  open-ended), and apply the user's decisions afterward.

**When in doubt, raise it.** The user's explicit requirement is that anything
worth a human's attention reaches the human. It is better to ask one extra
question than to silently bake a debatable decision into the plan.

Present the round to the user as a compact synthesis (same section shape as
panel-review: a short **Overview** of what this round found, a **Risk** read on
the plan, then the must-fix / should-fix / polish buckets and any
**Disagreements**), clearly separating "I'm fixing these directly" from "I need
you to decide these."

### Step 4 — Update the plan and the review-notes file

- Apply the auto-fixes and the user's decisions to the plan `.md`.
- Append a round entry to `<plan>.review.md` (see shape below): the concerns +
  who flagged them + how each was resolved, the open questions + the user's
  answers, and the concrete edits applied.

### Step 5 — Convergence check

- **If this round surfaced no new CRITICAL/HIGH/MEDIUM findings** (only LOW /
  nitpicks, or `NO_FINDINGS` across the board), the plan has converged. Tell the
  user so, summarize the plan's current state, and **ask whether to stop here or
  run another round.** Do not silently keep looping past convergence.
- **Otherwise**, automatically launch the next round (back to Step 1) against the
  *updated* plan. Briefly tell the user you're iterating again and why.
- **Safety cap: 4 rounds.** If you reach round 4 without convergence, stop, report
  the remaining open items, and ask the user how to proceed rather than looping
  indefinitely.

Each round re-runs fresh subprocesses against the current plan, so panelists
always judge the latest version with no cross-round contamination.

## Review-notes file shape

`<plan-basename>.review.md`, alongside the plan:

```markdown
# Panel review log — docs/specs/2026-05-29-foo-design.md

## Round 1 — codex (gpt-5.5), claude (opus-4.7), opencode (qwen3.6)

### Concerns
- [HIGH] foo-design.md:42 — migration step runs before the table is created.
  Flagged by 2: codex, claude. Resolution: reordered steps 3↔4 in the plan.
- [MEDIUM] foo-design.md:88 — no rollback described for the data backfill.
  Flagged by: codex. Resolution: added a rollback note to §6.

### Open questions raised to user
- Q: Per-tenant or global cache? → A (user): per-tenant. Plan §5 updated.

### Edits applied
- Reordered §3 steps; added rollback note to §6; specified cache scope in §5.

## Round 2 — …
```

## Output discipline

- **Carry the panelist's self-reported model everywhere** you name a panelist
  (`Flagged by: codex (gpt-5.5)`), exactly as panel-review does. Surface
  `(unknown)` rather than omitting it.
- **Don't paraphrase or invent.** Surface what the panelists actually said;
  correct an obviously-wrong line reference, but never fabricate one to satisfy
  the format. A `NO_FINDINGS` panelist is still reported, not dropped.
- The synthesis you show each round is the primary deliverable — most readers
  won't scroll up to the raw per-panelist sections, so put the substance there.

## Reference

CLI flags and env vars: run `bash skills/panel-plan/panel-plan.sh --help`.

The script:
- Embeds the plan file (with line numbers via `nl`) into the prompt so panelists
  can cite `<plan>:LINE`.
- Runs every panelist **read-only** against the working tree (codex
  `--sandbox read-only`, claude `--permission-mode plan`, opencode `plan`
  agent) — they can read the codebase the plan targets to check feasibility but
  cannot modify anything. No diff, no git worktrees, no `gh`.
- Emits the same stderr heartbeats and `## <name> / <model> (exit N)` section
  headings as panel-review, so the progress / streaming logic above is identical.
- If a panelist times out or fails, the others' output is kept and the script
  exits 2 — surface the failure rather than dropping the panelist.
- Panelists pick up the project's `AGENTS.md` / `CLAUDE.md` — intentional, but
  worth knowing if those would bias the review.
