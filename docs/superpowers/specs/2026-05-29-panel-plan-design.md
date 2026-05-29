# panel-plan skill — design

## Summary

A new skill, `panel-plan`, that applies the `panel-review` parallel-ensemble
machinery to a **plan `.md` file** instead of a code diff, wrapped in an
**auto-iterating review loop** that hardens the plan round by round.

The user discusses and writes a plan (typically via brainstorming /
`writing-plans`), then hands it to the panel. Multiple independent external CLI
agents (codex, claude, opencode) review the plan in parallel; the coordinator
synthesizes their findings, applies clear fixes directly, raises genuine
judgment calls to the user, updates the plan, and re-runs the panel — looping
until the plan converges.

This is the planning-time analog of `panel-review` (which reviews shipped code).
It is **not** a replacement for the single-agent `plan-*-review` skills; the
defining property — same as `panel-review` — is that each panelist runs in a
fresh subprocess with **no shared state**, giving genuinely independent reviews.

## Goals

- Take an existing plan `.md` and pressure-test it with an independent panel.
- Surface to the user *only* what genuinely needs a human decision; auto-apply
  the rest.
- Iterate automatically until the plan stops attracting significant concerns.
- Keep the plan file clean; record the review history separately.

## Non-goals

- Reviewing code diffs (that is `panel-review`).
- Writing the plan from scratch (that is brainstorming / `writing-plans`).
- Single-agent interactive plan critique (that is the gstack `plan-*-review`
  skills).

## Positioning & triggers

Downstream of brainstorming / `writing-plans`. Triggers: `/panel-plan`, "have
the panel review my plan", "panel-review this plan", "iterate on this plan with
the panel", "panel plan".

## Components

| File | Purpose |
|---|---|
| `skills/panel-plan/SKILL.md` | Coordinator instructions: target selection, the round loop, triage (auto-fix vs. raise-to-user), convergence, output. |
| `skills/panel-plan/panel-plan.sh` | Lightweight parallel launcher. Mirrors `panel-review`'s *local read-only* path: no diff, no worktree, no `gh`. Embeds the plan file's contents into the prompt and runs each panelist **read-only against the working tree** so they can check the plan's assumptions against real code. Reuses heartbeat / timeout / out-dir / `--panelist` conventions. |
| `skills/panel-plan/prompts/plan-review.md` | The plan-review prompt template (the main new artifact). |
| `skills/panel-plan/README.md` | Short reference, like `panel-review`'s. |

SKILL.md stays DRY by **referencing** `panel-review`'s shared operational
conventions (background `Bash` + heartbeat polling at a 10s cadence, `TodoWrite`
one todo per panelist, streaming each panelist's section to chat the moment it
lands, patience guidance for quiet polls) rather than recopying them verbatim.

## `panel-plan.sh`

A simplified launcher derived from `panel-review.sh`'s local read-only path.

- **Flags:** `--plan <file>` (required), `--focus TEXT`, `--panelist NAME`
  (repeatable; default = every supported CLI on `PATH`), `--out-dir DIR`,
  `--timeout SECS` (default `$PANEL_PLAN_TIMEOUT` or 600), `-h/--help`.
- **No** `--pr` / `--base` / `--commit` / `--uncommitted` / `--staged` /
  `--checkout`, **no** worktrees, **no** `gh`, **no** diff construction, **no**
  `MAX_DIFF_BYTES` cap (plans are small markdown files).
- **Payload:** reads the plan file and embeds its full contents into the
  `plan-review.md` prompt (with line numbers preserved so panelists can cite
  `plan.md:LINE`).
- **Permissions:** each panelist runs **read-only against the working tree**
  (Read / Glob / Grep, no exec) — the same posture as `panel-review`'s
  `--uncommitted` mode — so panelists can verify the plan's claims about the
  existing codebase but cannot mutate anything.
- **Output:** prints one section per panelist with raw findings, plus a tempdir
  path holding each panelist's stdout/stderr. Emits the same stderr heartbeats
  as `panel-review` (`panel-plan: <name> started`,
  `panel-plan: <name> (<model>) done (exit N)`), and the same per-panelist
  section heading format (`## <name> / <model> (exit N)`) so the coordinator's
  streaming/synthesis logic is identical.
- Per-panelist `timeout` enforced by the script; a failed/timed-out panelist
  does not abort the others.

## `prompts/plan-review.md`

Panelists read the embedded plan **and** the repo it targets, then report
against plan-specific dimensions:

- **Goal clarity** — is the objective clear and well-scoped? Uses the same
  `Goal (clear)` / `Goal (clear, matches description)` /
  `Goal (clear, contradicts description)` / `Goal (unclear)` tags as
  `panel-review` so the coordinator's agreement-detection logic carries over.
- **Feasibility / correctness** — will it actually work? Wrong assumptions about
  the codebase (verified via read access), API misuse, infeasible steps.
- **Completeness / gaps** — missing steps, unhandled cases, undefined behavior,
  ignored dependencies, absent verification strategy.
- **Approach / altitude** — right layer? over/under-engineering, YAGNI. Reuses
  the `Approach (sound)` / `Approach (questionable)` block (with its
  three-evidence-component bar for `questionable`).
- **Sequencing** — steps in an impossible order, hidden prerequisites.
- **Risk / blast radius** — migrations, irreversible or security/data-sensitive
  steps.
- **Open questions** — ambiguities an implementer would have to *guess* on,
  emitted in a **dedicated `Open questions` block**. These are the raw material
  for the coordinator's "raise to the user" path.

**Panelist output contract** (first lines fixed, same as `panel-review`):

```
Model: <model-id>
Goal (<tag>): <one or two sentences>
Approach (<tag>): <one or two sentences>

<findings list>

Open questions:
- <question an implementer cannot resolve without the author>
```

**Finding shape** — same skeleton as `panel-review`, but the location is a plan
reference and the `Fix:` is a suggested *plan edit*:

```
- [SEVERITY] plan.md:LINE — one-sentence issue.
  Fix: one-sentence suggested change to the plan.
```

Severity (`CRITICAL | HIGH | MEDIUM | LOW`) is anchored by **blast radius on the
resulting implementation** (a plan gap that would ship a broken migration is
CRITICAL; a vague-but-recoverable step is MEDIUM; a wording nit is LOW). The
CRITICAL/HIGH/MEDIUM/LOW vocabulary is reused deliberately (rather than a
plan-specific BLOCKER/CONCERN/QUESTION/NIT set) so the coordinator's existing
synthesis, dedup, and bucketing logic applies unchanged. The distinct
plan concept — questions needing a human decision — lives in the separate
`Open questions` block, not in the severity scale.

`NO_FINDINGS` is still allowed (after the mandatory `Model:` / `Goal:` /
`Approach:` lines), and an empty `Open questions` block is fine.

## The round loop (SKILL.md coordinator)

**Pre-flight:** resolve the plan file (CLI arg → else the most-recent spec in
the conversation/`docs/.../specs` → else ask the user), confirm panelists,
capture optional focus.

**Each Round N:**

1. Launch `panel-plan.sh` in background; poll heartbeats at the 10s cadence;
   stream each panelist's section to chat as it lands (identical UX to
   `panel-review`, including the `TodoWrite` per-panelist progress list and the
   "quiet poll is not a hang" patience rules — referenced, not recopied).
2. **Synthesize:** dedup findings across panelists, bucket by severity, collect
   the union of `Open questions`. Apply `panel-review`'s verification discipline
   to questionable/unique high-severity findings before surfacing them.
3. **Triage every item** into exactly one path:
   - **Auto-fix** (coordinator edits the plan directly): clear, uncontested
     technical corrections — filling obvious gaps, fixing verified-wrong
     codebase assumptions, sequencing fixes, adding missing steps.
   - **Raise to user** (via `AskUserQuestion`): open questions, trade-offs with
     no clear winner, scope expansions/reductions, panelist disagreements, and
     anything that changes *what the plan is trying to do*. Apply the user's
     decisions after they answer.
4. **Apply edits** to the plan `.md`. Append this round to the **separate
   review-notes file** `<plan-basename>.review.md` (concerns + flagged-by +
   resolution; open questions + answers; edits applied).
5. **Convergence check:** if the round surfaced **no new CRITICAL/HIGH/MEDIUM**
   findings, tell the user the panel has converged and **ask whether to stop or
   run another round**. Otherwise auto-launch Round N+1 against the *updated*
   plan.
6. **Safety cap:** default **4 rounds**. If hit, stop and report remaining open
   items. (Configurable; surfaced to the user when reached.)

Because each round re-runs fresh subprocesses against the current plan,
panelists always judge the latest version with no cross-round contamination.

### Auto-fix vs. raise-to-user — the rule

The user's central requirement is "anything that should be raised to the user
should be raised." Concretely:

- **Raise:** open questions; trade-offs without a clear winner; scope changes;
  product/UX decisions; panelist disagreements; any edit that changes the plan's
  intent or success criteria.
- **Auto-fix:** uncontested mechanical/technical improvements — fill an obvious
  gap, correct a verified-wrong assumption about the codebase, fix step
  ordering, add a missing error/rollback/verification step.

When in doubt, raise it.

## Review-notes file shape (`<plan-basename>.review.md`)

```markdown
# Panel review log — docs/specs/2026-05-29-foo-design.md

## Round 1 — codex (gpt-5.5), claude (opus-4.7), opencode (qwen3.6)
### Concerns
- [HIGH] plan.md:42 — migration runs before the table exists. Flagged by 2: codex, claude
  Resolution: reordered steps 3↔4 in the plan.
### Open questions raised to user
- Q: Should the cache be per-tenant or global? → A (user): per-tenant. Plan §5 updated.
### Edits applied
- Reordered §3 steps; added rollback note to §6.

## Round 2 — …
```

## Alternatives considered (rejected)

- **Extend `panel-review.sh` with a `--plan` target** — rejected: a plan needs
  none of the git/worktree/`gh` machinery; a separate lightweight script is
  cleaner and keeps `panel-review.sh` from growing.
- **User-gated every round** — rejected in favor of auto-loop; a user gate is
  retained only at *convergence* and for *judgment calls* (the chosen hybrid).
- **Inline changelog inside the plan** — rejected in favor of a separate notes
  file to keep the plan pristine (git diffs still capture plan edits).
- **Plan-specific severity vocabulary (BLOCKER/CONCERN/QUESTION/NIT)** —
  rejected in favor of reusing CRITICAL/HIGH/MEDIUM/LOW so the existing
  synthesis machinery applies unchanged; "questions" are handled by a dedicated
  output block instead.

## Open questions

None — the four core decisions (auto-loop with user gate at convergence;
coordinator auto-fixes but raises judgment calls; new lightweight script;
separate review-notes file) plus the three confirmed details (4-round cap,
read-only-against-working-tree panelist access, reused severity vocabulary) are
settled.
