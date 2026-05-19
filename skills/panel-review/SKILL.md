---
name: panel-review
description: >
  Run a parallel code review across multiple local CLI coding agents (codex,
  claude, opencode) and synthesize their findings. Use this skill whenever the
  user asks for a "panel review" / "panel-review", "second opinions on this
  change", "multi-agent review", "ensemble review", a "deep panel review" /
  "deep review" / "deep review the findings" / "dig deep into the findings" /
  "verify each finding" (opt-in deep mode where the coordinator dispatches
  verification subagents for every finding, then synthesizes their evidence,
  concrete fixes, and fix rationale — see the "Deep mode" section in SKILL.md
  for the procedure and output shape), asks to "have multiple agents/LLMs review
  this", "cross-check this with codex/claude/etc", "fan out a code review", or
  any similar phrasing asking for independent reviews from outside this
  conversation. Each panelist runs in a fresh non-interactive subprocess with no
  shared state — that is the point. Do NOT use when the user just wants the
  current session to review code itself; use the regular code-reviewer agent for
  that.
---

# panel-review

Spawns multiple local CLI coding agents in parallel to review the same code
change, then synthesizes their findings into one report. Each panelist runs in
its own subprocess with no shared conversation state — they only see the prompt
and the diff.

## When to use

- User says "panel review", types `/panel-review`, asks for "second opinions on
  this change", "get a panel to review this", "multi-agent review", or similar.
- User wants reviews from agents that don't share this conversation's biases or
  context.

When _not_ to use:

- User wants you (this session) to review code → use the project's code-reviewer
  agent.
- User wants a single second opinion → spawn one external CLI directly, no need
  to fan out.

## Steps

1. **Pick a target.** Map the user's phrasing to a flag:
   - "PR 27" / "pr #27" / "/panel-review pr 27" / a
     `github.com/<owner>/<repo>/pull/N` URL → `--pr <N or URL>` (requires the
     `gh` CLI).
   - "vs main" / "against develop" without a PR number → `--base <branch>`.
   - Specific SHA → `--commit <sha>`.
   - "uncommitted", "my staged changes", "my dirty work" → `--uncommitted` /
     `--staged`.
   - **Otherwise: pass no target flag at all.** The script auto-detects via
     `gh pr view` whether the current branch has an open PR. If it does and the
     working tree is clean, it switches to `--pr <N>` automatically (logged to
     stderr). If the working tree is dirty, it stays on `--uncommitted` but logs
     that the PR exists with the `--pr <N>` override hint. This is the right
     default for a branch that has a PR because reviewing against your local
     `main` (which may be stale) flags commits that are not actually in the PR.
   - Ask only if the intent is genuinely ambiguous.
   - **If the script's auto-detection rejects the current branch's PR — most
     commonly because the PR is MERGED ("branch has PR #N (state: MERGED) — not
     auto-switching"), the branch has no PR, or `gh pr view` returns
     unresolvable head metadata — and the user gave no explicit target, STOP and
     ask which branch / PR / commit they meant.** Do NOT silently fall back to
     `--base main`, `--uncommitted`, or any other target. A local branch can sit
     20+ commits ahead of the PR that originally spawned it (review-fix commits,
     post-merge cleanup, accidental WIP from another feature), so `--base main`
     quietly reviews a much larger and possibly unrelated scope than the user
     expects. The cost of one clarifying question is trivial; the cost of
     synthesizing a 6-finding report against the wrong diff is the entire skill
     invocation. When in doubt, also list nearby open PRs
     (`gh pr list --author "@me" --state open --json number,title,headRefName`)
     so the user can pick from a concrete menu rather than retype a branch name.
2. **Pick panelists.** Default: every supported CLI on `PATH` (codex, claude,
   opencode). The user may name a subset.
3. **Capture optional focus.** If the user gave context ("look closely at the
   auth changes"), pass `--focus`.
4. **Mode is automatic — there is no `--checkout` decision.** PR / `--base` /
   `--commit` reviews always run worktree-isolated with write/exec permissions
   (one throwaway worktree per panelist, pinned to the target ref). Panelists
   can read code, grep callers, and run tests / build / lint commands. Network
   and GitHub-write actions are forbidden by the prompt. `--uncommitted` /
   `--staged` reviews stay local-only with read-only / plan permissions — no
   worktree, no exec. The `--checkout` flag is accepted for backward compat but
   is now a deprecated no-op; do not pass it.
5. **Run the script** (path: `skills/panel-review/panel-review.sh`). You
   **MUST** launch it as a **background Bash** (`Bash` tool with
   `run_in_background: true`) and poll progress with `BashOutput` on the
   returned `bash_id` every **10 seconds** until every panelist has emitted its
   `done (exit N)` heartbeat.

   This skill explicitly **overrides** the default harness guidance that says
   "do not poll background tasks — you'll be notified when they complete." That
   guidance is wrong for this workflow: the heartbeats and per-section streaming
   exist precisely so the coordinator can give the user live progress, and
   waiting for the single completion notification defeats that. Poll every 10
   seconds. Do not back off to 30s/60s/90s — those long sleeps are the symptom
   of obeying the wrong guidance.

   **Do NOT launch the script via the `Agent` tool / `TaskCreate` / any subagent
   mechanism.** Subagents run in a separate Claude context and there is no
   streaming-output API for in-flight subagents — the only thing the parent sees
   is the subagent's final response when it terminates. The script's stderr
   heartbeats become invisible, the per-section streaming is useless, and
   progress polling silently degrades into hacks like
   `sleep 90 && grep panel-review: tasks/<id>.output | tail` against the
   subagent's transcript file. If you catch yourself reaching for the `Agent`
   tool here, stop and use background `Bash` instead.

   **Do NOT poll by shelling out to `sleep N && grep` against any output file.**
   `BashOutput` is the only correct progress-polling mechanism for this script —
   it returns new stdout/stderr since the last call, including the stderr
   heartbeats, with no parsing required.

   Reason all of this matters: panelists run in parallel, but Codex is slow and
   dominates wall clock. Without backgrounded Bash + `BashOutput`, the call
   blocks silently for minutes and the user sees nothing.

   If you absolutely cannot use `run_in_background` (rare — usually only when
   the harness lacks `BashOutput`), run it in the foreground and pass
   `timeout: 600000` (10 min) since the default 2-minute Bash timeout will kill
   the call before Codex returns. You will lose live progress in this mode; warn
   the user.

6. **Set up live progress UX.** Right before (or right after) launching the
   script:
   - Call `TodoWrite` with one todo per chosen panelist (`Review: codex`,
     `Review: claude`, …) plus a final `Synthesize findings` todo. Initial
     statuses: the first panelist's `in_progress`, the rest `pending`. (Some
     harnesses expose this as `TaskCreate` / `TaskUpdate` instead — use
     whichever todo-list tool your environment provides.)
   - Each `BashOutput` poll: scan stderr for `panel-review: <name> started` and
     `panel-review: <name> (<model>) done (exit N)`. On a `started`, set that
     panelist's todo to `in_progress` (re-call `TodoWrite` with the updated
     list). On a `done`, set it to `completed`, post a single-line user-visible
     status that **includes the model** the panelist self-reported
     (`✓ <name> (<model>) done — N findings, top severity <SEV>` or
     `✓ <name> (<model>) — NO_FINDINGS` / `✗ <name> (<model>) failed (exit N)`),
     **and immediately post that panelist's full `## <name> / <model> (exit N)`
     section to chat as soon as it appears in stdout**. Do not wait until every
     panelist is done — surfacing each section the moment it lands gives the
     user actionable findings 5–10 minutes before synthesis is possible. The
     synthesis step still adds value by deduping / ranking across panelists; it
     is not a substitute for the individual sections.
   - After the last `done` heartbeat, set `Synthesize findings` to
     `in_progress`, proceed to steps 7–8, then mark it `completed`.
7. **Read the script's combined output** — it prints one section per panelist
   with their raw findings, plus a tempdir path containing each panelist's
   stdout/stderr. Wait for _all_ panelists to finish before synthesizing;
   partial output is fine to _show_ the user during the wait, but consensus /
   disagreement analysis needs every panelist's verdict.
8. **Synthesize the findings** in your reply to the user. The synthesized
   summary is the primary deliverable — most readers will not scroll up to the
   per-panelist sections, so put the substance here.

   **If the user asked for a deep review** (see the **Deep mode** section after
   step 10), dispatch the per-finding verification subagents and wait for their
   results _before_ emitting the synthesis below. The section structure and
   per-finding skeleton (`[SEVERITY] file:line — issue.` / `Fix: …` /
   `Flagged by: …`) stay identical to standard mode; deep mode inserts two extra
   lines (`Why:` and `Verified by:`) between `Fix:` and `Flagged by:` so a
   reader's eye lands on the same anchor lines in both modes.

   **Always carry the panelist's self-reported model into the summary.** Each
   panelist starts its output with a `Model: <id>` line; the script also exposes
   it in the `## <name> / <model> (exit N)` per-panelist section heading. Use
   the model name everywhere you would otherwise just say the panelist's name
   (e.g. `Flagged by: codex (gpt-5.5)`, or in a misinterpretation callout like
   `codex (gpt-5.5) appears to have misinterpreted the change`). If a panelist
   reported `Model: unknown`, surface that as `(unknown)` rather than silently
   omitting the model.

   **Tappable links to PR file:line.** When the target is a PR (the script's
   combined-output header shows `Target: PR #N` and emits `- PR URL: <url>`),
   wrap every `file:line` reference in the synthesized summary as a markdown
   link pointing at the PR file view, so the user can tap straight to the exact
   line on GitHub. Use the helper:

   ```
   bash skills/panel-review/pr-line-url.sh "$pr_url" "<file>" "<line-or-range>"
   ```

   Apply this everywhere `file:line` appears in the synthesis — every finding
   bullet under **must-fix**, **should-fix**, **polish**, plus any callout or
   **Disagreements** entry. Leave per-panelist sections (the raw
   `## <name> / <model>` blocks) untouched so the panelist's verbatim output is
   preserved. For non-PR targets, skip the wrapping — leave bare `file:line`
   text since users can typically `cmd-click` in their terminal to open it
   locally.

   Example transformation. Panelist output:

   ```
   - [HIGH] auth/session.go:88 — TOCTOU between token check and claim load.
     Fix: take the cache lock before validating the signature.
   ```

   Synthesized entry:

   ```
   - [HIGH] [auth/session.go:88](https://github.com/owner/repo/pull/27/files#diff-...R88) — TOCTOU between token check and claim load.
     Fix: take the cache lock before validating the signature.
     Flagged by 2: codex (gpt-5.5), claude (claude-opus-4.7)
   ```

   **Every finding MUST include `file:line` (or a named root-cause location for
   substantiated `Approach (questionable):` items) AND a `Fix:` line.** Drop any
   panelist finding that lacks a concrete location or a suggested fix — those
   are too speculative to surface. If the issue itself is real, infer the
   location from the diff/PR yourself; if you cannot, leave it out.

   **Section structure.** The synthesis renders sections in this fixed order,
   but most sections are conditional — emit a heading only when it has content.
   The conditional behavior matters: blank sections, "none" placeholders, and
   ceremonial labels make the report feel robotic and bury the real signal.
   - `### Overview` — always.
   - `### Risk` — always.
   - **Misinterpretation callout** — only when a panelist's stated goal
     disagrees with the actual diff. Renders as a
     `**Misinterpretation detected:** …` block between `### Risk` and the next
     section. No callout when nothing's wrong.
   - `### Goal check` — only when goals are contested (mixed clear/unclear,
     panelists describe different goals, or any panelist tagged
     `(clear, contradicts description)`). When all agree, omit the section
     entirely; the Overview lead already states the goal.
   - `### Approach check` — only when at least one panelist flagged
     `Approach (questionable):` with all three evidence components present and
     you verified them. When all-sound (or all under-evidenced), omit the
     section; `Approach: sound.` appears inline at the end of `### Risk`.
   - `### must-fix` — CRITICAL/HIGH findings. Omit if empty.
   - `### should-fix` — MEDIUM findings. Omit if empty.
   - `### polish` — LOW findings. Omit if empty.
   - `### Disagreements` — only when panelists actually contradict each other on
     a finding (one flags it, another examined the same code and said it's fine;
     or verification falsified a raised finding). Omit when there's nothing to
     surface — do NOT emit a "Disagreements: none." line.

   ### Overview

   Lead the section with one **target line** before either prose paragraph, so
   the user can spot a wrong-target review the instant they scan the output.
   Render verbatim as a bold label + the target string, no other prose on the
   line. Shapes by mode:
   - PR mode: `**Reviewing:** PR #<N> on <head-branch> — "<PR title>".`
   - `--base`:
     `**Reviewing:** <N> commits on <current-branch> vs <base-branch>.`
   - `--commit`: `**Reviewing:** commit <short-sha> ("<commit subject>").`
   - `--uncommitted` / `--staged`:
     `**Reviewing:** uncommitted changes on <current-branch>.`

   This is non-optional even when the target seems obvious — the failure mode it
   prevents is silent scope drift (e.g. `--base main` quietly reviewing 20+
   commits when the user expected a 2-commit feature branch). After the target
   line, leave a blank line and write the two paragraphs below.

   **Paragraph 1: lead with the goal (uncontested case only).** When all
   panelists agreed on a clear goal (no goal-check section will be emitted),
   open with the goal in plain human language — one sentence, no `Goal:` label,
   no "all panelists agree" suffix. The absence of a goal-check section below is
   the implicit signal that everyone agreed. Example:

   ```
   Stand up the @bank/evm package as the foundation for future send-saga work — viem-backed primitives for the EVM transaction lifecycle.
   ```

   If the goal is contested (any case that would trigger a goal-check section
   per the conditional rules above), **skip paragraph 1 entirely**. The reader's
   signal that the goal is contested is the presence of the goal-check section
   further down; absence of a lead in Overview lines up with that.

   **Paragraph 2: factual scope.** Two to four sentences for a human who has not
   seen the diff. State factually what files / areas changed, the kind of change
   (refactor, bug fix, new feature, config, dep bump, infra, …), and rough scope
   (lines added/removed, files touched). For PR mode pull this from
   `gh pr view --json files` and the diff; for non-PR targets infer from the
   diff. Do **not** editorialize — evaluation lives in `### Risk` and the
   finding buckets.

   ### Risk

   One of `LOW` / `MEDIUM` / `HIGH` / `CRITICAL`, then a one-sentence
   justification that points at observable signals (multi-panelist findings,
   area touched, scope), not vibes. When every panelist tagged
   `Approach (sound):` and there are no questionable claims to surface, append
   `Approach: sound.` as a second sentence so the verdict stays visible without
   a separate section. When a `### Approach check` section will be emitted
   below, omit the inline `Approach:` line — the section carries the detail.

   Rubric:
   - **LOW** — docs / tests / formatting / non-load-bearing refactor. No
     multi-panelist findings. No HIGH/CRITICAL findings. All panelists agreed on
     the goal. All panelists tagged `Approach (sound):`. No auth / payments /
     migrations / cryptography touched.
   - **MEDIUM** — touches business logic or non-trivial code paths. Findings
     exist but are fixable. No CRITICAL findings. Goal was clear or only mildly
     divergent across panelists. No verified `Approach (questionable):`.
   - **HIGH** — any of:
     - a verified HIGH finding raised by 2+ panelists;
     - a verified `Approach (questionable):` flag (the change is fixing the
       wrong layer — even a correct implementation is short-term relief at the
       cost of future bugs);
     - the change touches auth, session handling, payments, schema migrations,
       crypto, or production infra;
     - panelists disagreed substantially on what the change does;
     - the diff is unusually large (>500 lines) AND lacks a clear goal.
   - **CRITICAL** — any verified CRITICAL finding (a bug in the change that
     would break production on merge, or a known data-loss / security-bypass /
     credential-leak path introduced) escalates the whole change to this bucket
     regardless of the area touched. A verified `Approach (questionable):` that
     ALSO independently satisfies another HIGH trigger (e.g. wrong-layer fix in
     auth/payments code) lands here too.

   This is the single source of truth for severity assignment. The
   `### Approach check` section promotes substantiated `(questionable):` flags
   into `### must-fix` as HIGH-severity findings — it does not separately mutate
   Risk. Risk is whatever the rubric above evaluates to.

   Examples:
   - `Risk: CRITICAL — codex flagged a verified timing-attack vulnerability in session-token validation at auth/session.go:88.`
   - `Risk: LOW — docs-only change to the panel-review skill instructions; no consensus findings. Approach: sound.`

   **Misinterpretation check (mandatory; emits a callout only when triggered).**
   Beyond collating the panelists' `Goal:` tags, independently verify that each
   panelist's stated goal is actually consistent with what the diff does. A
   panelist can confidently tag itself `Goal (clear)` while having misread the
   change — that produces confidently-wrong findings further down. For each
   panelist:
   1. Read the diff yourself (or the PR via `gh pr view --json files,title,body`
      and `gh pr diff <ref>`) to form an independent understanding of intent.
   2. Compare your read against the panelist's `Goal:` line.
   3. If they disagree, emit a callout between `### Risk` and the next section:

      ```
      **Misinterpretation detected:** codex (gpt-5) appears to have misinterpreted the change. It said "<goal>" but the diff actually <what it really does>. Treat its findings below with skepticism — verify each one against the code before acting on it.
      ```

   4. Apply step 9's verification more aggressively to that panelist's findings:
      drop any whose substance depends on the misread intent; keep only findings
      that still hold independent of the panelist's mistaken framing.

   No misinterpretation → no callout. Do NOT emit a "no misinterpretations
   detected" placeholder. Do not assume agreement among panelists implies
   correctness — two panelists can share a misread (especially if the diff is
   unusual or the description is misleading). When in doubt, your own read of
   the diff is the tiebreaker.

   ### Goal check (only when goals contested)

   Each panelist starts its output with a `Goal:` line tagged `(clear)`,
   `(clear, matches description)`, `(clear, contradicts description)`, or
   `(unclear)`. Emit this section only when at least one of these holds:
   - **Mixed clear / unclear** — surface the divergence. Quote what the unclear
     panelist(s) said was ambiguous. The change being non-self-explanatory is
     itself a HIGH-severity finding; add it to `### must-fix`.
   - **Panelists described different goals** — the change is likely doing
     several things at once or is genuinely confusing. Quote each panelist's
     goal verbatim so the user can decide whether to split the PR.
   - **Any panelist returned `Goal (clear, contradicts description):`** — quote
     what they said the actual goal is vs. what the description claims.
     MEDIUM/HIGH worth raising even if no one else flagged it.

   When all panelists agreed on a clear goal, omit this section entirely — the
   Overview lead already states the goal in plain language.

   ### Approach check (only when questionable verified)

   Each panelist outputs an `Approach:` line immediately after `Goal:`, tagged
   `(sound)` or `(questionable)`. This block asks whether the change is being
   made at the right layer — a UI fix for a server bug, a client validator for a
   missing DB constraint, etc.

   Emit this section only when one of these holds:
   - **One or more `Approach (questionable):` with all three evidence components
     present** (root cause named, root-cause fix location specified, reason the
     current change is symptomatic), and you verified them against the code.
     Quote the substantiated claim:

     ```
     - questionable (raised by: codex (gpt-5.5)): the diff adds client-side validation in `web/src/forms/order.tsx:42`, but the root cause is that the `orders` table allows duplicate `(user_id, idempotency_key)` rows. Real fix lives in a migration on `orders`. This is the third caller to re-implement the same validation — grep shows two prior copies in `web/src/forms/`.
     ```

     Also promote this finding into `### must-fix` as a HIGH-severity entry (use
     the named root-cause location in place of `file:line`).

   - **Panelists disagree (one sound, another questionable)** — surface both
     verdicts. The questionable side wins by default if its three evidence
     components hold up under your own verification (apply step 9); if the
     evidence doesn't hold, drop the questionable claim and note the
     falsification under `### Disagreements`.

   Otherwise — all-sound, or questionable claims dropped because evidence didn't
   hold — omit this section. `Approach: sound.` appears inline at the end of
   `### Risk` instead.

   **Verify before promoting (mandatory).** Treat a `questionable` flag like any
   unique CRITICAL/HIGH claim — open the named root-cause location, confirm the
   bug actually recurs there or that the constraint is actually missing, and
   only then surface it. A wrong `Approach (questionable):` is worse than a
   missed one because it derails the entire review toward a phantom redesign.

   ### Findings buckets (must-fix / should-fix / polish)

   The three severity buckets ARE the findings list — there are no separate
   "Consensus" or "Unique" sections. Bucketing is by severity:
   - `### must-fix` — CRITICAL and HIGH findings.
   - `### should-fix` — MEDIUM findings.
   - `### polish` — LOW findings.

   Omit any bucket that has no entries — no empty headings, no "none" lines.

   **Per-finding shape (CRITICAL / HIGH / MEDIUM):**

   ```
   - [SEVERITY] file:line — one-sentence issue.
     Fix: one-sentence suggested change.
     Flagged by: codex (gpt-5.5)
   ```

   When 2+ panelists raised the same finding, list every panelist on the
   `Flagged by:` line and prefix with the count. The count is the implicit
   consensus signal — no separate "CONSENSUS" badge, no separate section:

   ```
   - [MEDIUM] packages/evm/src/receipts.ts:130 + packages/evm/src/errors.ts:364 — `RETRYABLE_RPC_CODES` duplicated verbatim across two files.
     Fix: export from errors.ts and import in receipts.ts.
     Flagged by 2: claude (claude-opus-4.7), opencode (qwen3.6-plus)
   ```

   When panelists assigned different severities to the same finding, use the
   higher and add a short note inline on the `Flagged by:` line:

   ```
   Flagged by 2: claude (claude-opus-4.7) [LOW], opencode (qwen3.6-plus) [MEDIUM] — using higher.
   ```

   **Per-finding shape (LOW).** Collapse to a single line. LOW items rarely need
   a sentence of repair guidance; the issue description and `Flagged by:` are
   enough:

   ```
   - [LOW] packages/evm/src/broadcast.ts:299-307 — `stripSerialized` is unreachable post-`sanitizeMessage`. Flagged by: claude (claude-opus-4.7)
   ```

   If a LOW finding genuinely needs a `Fix:` line (e.g. the change is
   non-obvious), keep the two-line shape — but ask yourself whether it belongs
   in `### should-fix` instead.

   **Per-finding shape (substantiated `Approach (questionable):`).** Lives under
   `### must-fix` as a HIGH-severity entry. Use the named root-cause location in
   place of `file:line`:

   ```
   - [HIGH] root cause: `orders` table allows duplicate `(user_id, idempotency_key)` rows — the diff adds client-side validation in `web/src/forms/order.tsx:42` that papers over it; this is the third caller to re-implement the same validation.
     Fix: add a unique constraint on `orders(user_id, idempotency_key)` (or equivalent migration), then drop the per-caller client validators.
     Flagged by: codex (gpt-5.5)
   ```

   Put the Approach entry at the top of `### must-fix` — if the approach is
   wrong, the per-line findings below may not survive the rework.

   **Order within a bucket.** Within a severity, items raised by more panelists
   go first (consensus first), then single-flag items. Within a tie, group by
   file path so related findings sit together. CRITICAL above HIGH inside
   `### must-fix`.

   **Dedup logic.** Two panelists raised the "same" finding when they cite the
   same `file:line` (or overlapping ranges) AND the underlying claim is
   substantively the same. A different fix suggestion at the same location is
   still consensus on the bug; either pick the better fix and note the other
   inline, or record both on the `Fix:` line as alternatives. A different bug at
   the same line is NOT consensus — list as two separate findings.

   ### Disagreements (only when panelists actually contradict)

   Emit this section only when panelists disagree on whether a piece of code is
   buggy at all (one flags it, another examined the same code and said it's
   fine), or when verification falsified a raised finding. Omit the heading when
   there is nothing to surface — do NOT emit a "Disagreements: none." line.

   Surface each disagreement with `file:line` for the disputed code. Do not pick
   a side unless step 9 verification resolves it; lay out both positions.
   Severity-only splits (e.g. claude LOW vs opencode MEDIUM on the same issue)
   do NOT belong here — those are noted inline on the finding's `Flagged by:`
   line.

9. **Verify questionable findings before surfacing them.** A panelist's finding
   is questionable when any of these holds:
   - It is unique to one panelist AND its severity is CRITICAL/HIGH (high-impact
     claim with no second opinion).
   - The `Fix:` line does not obviously address the stated issue.
   - The line number is suspicious (referenced line is unchanged in the diff, or
     out of range for the file).
   - Two panelists disagree on whether the same code is buggy.
   - The panelist's reasoning depends on context outside the diff (caller
     behavior, framework guarantees, downstream consumers) that they did not
     actually verify.

   For each questionable finding, open the actual diff/file (use `gh pr diff`,
   `gh api .../files`, or `Read` against the local checkout) and confirm the bug
   exists as described before surfacing it. If verification disproves the
   finding, drop it and note the correction in `### Disagreements`. If
   verification sharpens the finding (e.g., you find the right line number),
   promote the corrected version into the summary. Never repeat a panelist claim
   into the summary that you could have falsified in 30 seconds with a Read tool
   call.

10. **Don't paraphrase or invent.** Surface what the panelists actually said. If
    a panelist returned `NO_FINDINGS`, note it; don't drop the panelist from the
    report. You may correct a panelist's line number if it is clearly off (e.g.,
    they cited a pre-image line and the file is now post-image), but never
    invent a line number to satisfy the format. The verification step in step 9
    is the _only_ license to rewrite a finding's substance — and only when you
    have actually checked the code.

## Deep mode

**Trigger.** User asked for a "deep panel review", "deep review", "deep review
the findings", "dig deep into the findings", "verify each finding", "explain
each finding", or similar. If the request just says "panel review" with no
"deep" / "verify" / "dig in" qualifier, stay in standard mode.

**Why opt-in.** Deep mode is token-expensive — every finding gets its own
verification subagent, code read-through, and hand-written explanation. The
standard synthesis from step 8 is the right default for routine reviews.

**Note on the term.** "Deep" used to be a trigger for worktree-mode (panelists
running tests, grepping callers). That mode is now automatic for committed
targets and no longer needs a trigger. The phrase is repurposed: it now opts
into the per-finding verification + explanation pass below. There is no
script-side flag — `panel-review.sh` is unchanged; deep mode is purely a
coordinator-side post-processing step.

**Procedure.** After step 7 (panelists finished, sections streamed) and _before_
emitting step 8's synthesis, enumerate every finding from every panelist —
CRITICAL through LOW, consensus and unique alike. Apply the same verification
pass to every `Approach (questionable):` flag too: verify the three evidence
components against the code, draft the actual cross-layer fix (often a migration
/ schema / API contract change, not a line edit), and explain how it resolves
the symptom seen in the diff. If the user explicitly scoped the request ("deep
review the auth findings", "verify only the criticals"), apply the scope;
otherwise default to all findings _and_ all `Approach (questionable):` flags.

1. **Create verification tasks.** Build one task per in-scope raw finding, plus
   one task per in-scope `Approach (questionable):` flag. Preserve the original
   panelist, model, severity, `file:line` (or named root-cause location for
   Approach tasks), claim, and `Fix:` line. If two panelists raised the same
   underlying issue, each raw finding still gets represented in a task; you may
   include the duplicate context for the verifier, but do not skip a finding
   without counting it as intentionally out of scope.

2. **Spin off verification subagents.** Launch a dedicated subagent for each
   task. If the harness caps concurrent subagents, queue them in small batches,
   but every in-scope finding must receive a verifier before synthesis. The "Do
   NOT launch the script via the Agent tool / subagent mechanism" rule in step 5
   still applies only to `panel-review.sh`; deep-mode verification happens after
   the script completes.

   Give each verifier only the task-local context it needs:
   - target type and PR URL / base / commit metadata;
   - combined-output tempdir path and relevant worktree path if available;
   - original panelist name + model;
   - raw finding text, severity, cited `file:line`, and proposed fix;
   - instruction to inspect code/diff and return evidence, not to implement
     changes.

   Use this output contract for every verifier:

   ```md
   Status: VERIFIED | FALSIFIED | CORRECTED | INCONCLUSIVE Evidence: concrete
   files/lines read and what they show. Corrected finding: only when Status is
   CORRECTED. Fix: concrete change anchored at file:line, with a short snippet
   for non-trivial fixes. Why: one or two sentences naming the mechanism.
   Confidence: high | medium | low
   ```

   The verifier's `Evidence`, `Fix`, and `Why` fields feed the synthesis's
   `Verified by:`, `Fix:`, and `Why:` lines respectively — same labels, no
   remapping.

3. **Reconcile verifier results.** Treat `VERIFIED` and `CORRECTED` as eligible
   for the synthesis. Use the corrected version when the verifier found a better
   line, narrower scope, or different mechanism. Drop `FALSIFIED` findings from
   the main findings sections and note the falsification under **Disagreements**
   with the verifier's evidence. Do not promote `INCONCLUSIVE` findings unless
   you personally do one more code read and can resolve them; otherwise list
   them under **Disagreements** as unverified.

4. **Draft the final fix and rationale from verifier evidence.** Don't repeat
   the panelist's `Fix:` line verbatim if it's vague. Use the verifier's
   concrete fix, tighten it if needed, and include a 3–10 line code snippet for
   non-trivial fixes. Explain what cause-effect chain the fix interrupts or what
   invariant it restores.

**Declare deep mode at the top of the synthesis (mandatory).** Right after the
per-panelist sections and _before_ the `### Overview` heading, emit a single
line so the user can verify deep mode actually ran without reading every entry:

```md
**Deep mode:** ON — verification subagents checked N findings across M
panelists; dropped K as falsified, surfaced V.
```

The numbers must be real (count them as you go). If you skipped verification on
any finding because the user scoped the request, say so:
`**Deep mode:** ON (scope: criticals only) — verification subagents checked 3 / surfaced 3 / dropped 0; 4 LOW findings carried over from panelists without verification.`
This declaration is the single source of truth for "did deep mode run" — if it
isn't present, the synthesis was standard mode regardless of trigger phrasing.

**Output shape.** Each finding entry in `### must-fix`, `### should-fix`, and
`### Disagreements` uses the same `[SEVERITY] / Fix / Flagged by` skeleton as
standard mode, with two extra detail lines (`Why:` and `Verified by:`) inserted
between `Fix:` and `Flagged by:`. Same anchor lines, same labels — deep mode
just interleaves evidence:

```md
- [SEVERITY] [file:line](url) — one-sentence issue. Fix: concrete change, with a
  code snippet for non-trivial cases, anchored at file:line. Why: one or two
  sentences on the mechanism (e.g. "serializing check + load behind the same
  mutex closes the TOCTOU window — no goroutine can mutate claims between
  validation and use"). Verified by: subagent read auth/session.go:80–96 — the
  signature check at line 84 reads tok.claims before the cache load at line 88
  acquires the mutex; a second goroutine can swap claims in the window. Cite
  files/lines; do not assert without evidence. Flagged by 2: codex (gpt-5.5),
  claude (claude-opus-4.7)
```

LOW findings in `### polish` stay collapsed to one line in deep mode too —
verifying every LOW is high cost for low decision-value, and the single-line
shape keeps `### polish` skimmable in both modes. The exception is items the
verifier promoted out of LOW (`Status: CORRECTED` with a severity bump): those
findings have already moved into `### should-fix` or `### must-fix` and use the
full deep-mode shape there.

A substantiated `Approach (questionable):` entry in `### must-fix` follows the
same skeleton under deep mode, but the leading `file:line` is replaced with the
root-cause location as in standard mode:

```md
- [HIGH] root cause: <named location> —
  <one-sentence summary of the wrong-layer fix>. Fix: <concrete cross-layer
  change — often a migration / schema / API contract change, not a line edit>,
  anchored at the root-cause location. Why: <one or two sentences on the
  mechanism — what invariant the cross-layer fix restores>. Verified by:
  <how the verifier confirmed the root cause exists and the current change is symptomatic>.
  Flagged by: codex (gpt-5.5)
```

If `### Approach check` is emitted as its own section (questionable flag
verified), its quoted-panelist block stays as in standard mode — the
verification and proposed-fix detail lives on the corresponding `### must-fix`
entry, not duplicated in `### Approach check`.

**If many findings drop during verification**, surface that in **Risk** —
panelist signal-to-noise is part of the picture and worth telling the user about
("3 of 7 codex findings falsified on read-through; treat the remaining 2 as the
real signal").

## Reference

CLI flags, env vars, and examples: run
`bash skills/panel-review/panel-review.sh --help`.

The script handles two cases internally:

- **Local targets** (`--uncommitted` / `--staged`): builds the diff with `git`,
  embeds it in the prompt, runs panelists read-only against the working tree.
- **Committed targets** (`--pr` / `--base` / `--commit`): one throwaway git
  worktree per panelist pinned to the target ref, panelists run with
  workspace-write / bypass permissions so they can grep callers, run tests, and
  install dev deps. PR targets additionally use an instruction-style prompt
  where panelists fetch the diff and existing review comments via `gh`
  themselves (live remote state — no stale-base drift, no diff-size cap).

Other behavior worth knowing:

- If a panelist times out or fails, the script keeps the others' output and
  exits 2. Surface the failure in the synthesized report rather than dropping
  the panelist.
- The combined output references a tempdir (`/tmp/panel-review-XXXXXX/`) — read
  any panelist's full stdout/stderr from there if the inline excerpt is not
  enough.
- Panelists pick up the project's `AGENTS.md` / `CLAUDE.md` — intentional, but
  worth knowing if those files would bias the review.
