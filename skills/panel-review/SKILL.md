---
name: panel-review
description: >
  Run a parallel code review across multiple local CLI coding agents (codex, claude,
  opencode) and synthesize their findings. Use this skill whenever the user
  asks for a "panel review" / "panel-review", "second opinions on this change",
  "multi-agent review", "ensemble review", a "deep panel review" / "really dig into
  this PR" / "run the tests on this PR" (the deep mode that runs tests and greps
  callers in a real worktree checkout), asks to "have multiple agents/LLMs review
  this", "cross-check this with codex/claude/etc", "fan out a code review", or any
  similar phrasing asking for independent reviews from outside this conversation.
  Each panelist runs in a fresh non-interactive subprocess with no shared state —
  that is the point. Do NOT use when the user just wants the current session to
  review code itself; use the regular code-reviewer agent for that.
---

# panel-review

Spawns multiple local CLI coding agents in parallel to review the same code change, then
synthesizes their findings into one report. Each panelist runs in its own subprocess with
no shared conversation state — they only see the prompt and the diff.

## When to use

- User says "panel review", types `/panel-review`, asks for "second opinions on this
  change", "get a panel to review this", "multi-agent review", or similar.
- User wants reviews from agents that don't share this conversation's biases or context.

When _not_ to use:

- User wants you (this session) to review code → use the project's code-reviewer agent.
- User wants a single second opinion → spawn one external CLI directly, no need to fan out.

## Steps

1. **Pick a target.** Map the user's phrasing to a flag:
   - "PR 27" / "pr #27" / "/panel-review pr 27" / a `github.com/<owner>/<repo>/pull/N`
     URL → `--pr <N or URL>` (requires the `gh` CLI).
   - "vs main" / "against develop" without a PR number → `--base <branch>`.
   - Specific SHA → `--commit <sha>`.
   - "uncommitted", "my staged changes", "my dirty work" → `--uncommitted` / `--staged`.
   - **Otherwise: pass no target flag at all.** The script auto-detects via `gh pr view`
     whether the current branch has an open PR. If it does and the working tree is
     clean, it switches to `--pr <N>` automatically (logged to stderr). If the working
     tree is dirty, it stays on `--uncommitted` but logs that the PR exists with the
     `--pr <N>` override hint. This is the right default for a branch that has a PR
     because reviewing against your local `main` (which may be stale) flags commits
     that are not actually in the PR.
   - Ask only if the intent is genuinely ambiguous.
2. **Pick panelists.** Default: every supported CLI on `PATH` (codex, claude,
   opencode). The user may name a subset.
3. **Capture optional focus.** If the user gave context ("look closely at the auth
   changes"), pass `--focus`.
4. **Mode is automatic — there is no `--checkout` decision.** PR / `--base` /
   `--commit` reviews always run worktree-isolated with write/exec permissions
   (one throwaway worktree per panelist, pinned to the target ref). Panelists
   can read code, grep callers, and run tests / build / lint commands. Network
   and GitHub-write actions are forbidden by the prompt. `--uncommitted` /
   `--staged` reviews stay local-only with read-only / plan permissions — no
   worktree, no exec. The `--checkout` flag is accepted for backward compat
   but is now a deprecated no-op; do not pass it.
5. **Run the script** (path: `skills/panel-review/panel-review.sh`). You **MUST**
   launch it as a **background Bash** (`Bash` tool with `run_in_background: true`)
   and poll progress with `BashOutput` on the returned `bash_id` every **10
   seconds** until every panelist has emitted its `done (exit N)` heartbeat.

   This skill explicitly **overrides** the default harness guidance that says
   "do not poll background tasks — you'll be notified when they complete."
   That guidance is wrong for this workflow: the heartbeats and per-section
   streaming exist precisely so the coordinator can give the user live
   progress, and waiting for the single completion notification defeats that.
   Poll every 10 seconds. Do not back off to 30s/60s/90s — those long sleeps
   are the symptom of obeying the wrong guidance.

   **Do NOT launch the script via the `Agent` tool / `TaskCreate` / any
   subagent mechanism.** Subagents run in a separate Claude context and there
   is no streaming-output API for in-flight subagents — the only thing the
   parent sees is the subagent's final response when it terminates. The
   script's stderr heartbeats become invisible, the per-section streaming is
   useless, and progress polling silently degrades into hacks like
   `sleep 90 && grep panel-review: tasks/<id>.output | tail` against the
   subagent's transcript file. If you catch yourself reaching for the `Agent`
   tool here, stop and use background `Bash` instead.

   **Do NOT poll by shelling out to `sleep N && grep` against any output
   file.** `BashOutput` is the only correct progress-polling mechanism for
   this script — it returns new stdout/stderr since the last call, including
   the stderr heartbeats, with no parsing required.

   Reason all of this matters: panelists run in parallel, but Codex is slow
   and dominates wall clock. Without backgrounded Bash + `BashOutput`, the
   call blocks silently for minutes and the user sees nothing.

   If you absolutely cannot use `run_in_background` (rare — usually only when
   the harness lacks `BashOutput`), run it in the foreground and pass
   `timeout: 600000` (10 min) since the default 2-minute Bash timeout will
   kill the call before Codex returns. You will lose live progress in this
   mode; warn the user.

6. **Set up live progress UX.** Right before (or right after) launching the script:
   - Call `TodoWrite` with one todo per chosen panelist (`Review: codex`,
     `Review: claude`, …) plus a final `Synthesize findings` todo. Initial
     statuses: the first panelist's `in_progress`, the rest `pending`. (Some
     harnesses expose this as `TaskCreate` / `TaskUpdate` instead — use whichever
     todo-list tool your environment provides.)
   - Each `BashOutput` poll: scan stderr for `panel-review: <name> started`
     and `panel-review: <name> (<model>) done (exit N)`. On a `started`, set
     that panelist's todo to `in_progress` (re-call `TodoWrite` with the
     updated list). On a `done`, set it to `completed`, post a single-line
     user-visible status that **includes the model** the panelist self-reported
     (`✓ <name> (<model>) done — N findings, top severity <SEV>` or
     `✓ <name> (<model>) — NO_FINDINGS` / `✗ <name> (<model>) failed (exit N)`),
     **and immediately post that panelist's full
     `## <name> / <model> (exit N)` section to chat as soon as it appears in
     stdout**. Do not wait until every panelist is done — surfacing each section
     the moment it lands gives the user actionable findings 5–10 minutes before
     synthesis is possible. The synthesis step still adds value by deduping /
     ranking across panelists; it is not a substitute for the individual
     sections.
   - After the last `done` heartbeat, set `Synthesize findings` to `in_progress`,
     proceed to steps 7–8, then mark it `completed`.
7. **Read the script's combined output** — it prints one section per panelist with their
   raw findings, plus a tempdir path containing each panelist's stdout/stderr. Wait for
   _all_ panelists to finish before synthesizing; partial output is fine to _show_ the
   user during the wait, but consensus / disagreement analysis needs every panelist's
   verdict.
8. **Synthesize the findings** in your reply to the user. The synthesized summary is
   the primary deliverable — most readers will not scroll up to the per-panelist
   sections, so put the substance here.

   **Always carry the panelist's self-reported model into the summary.** Each
   panelist starts its output with a `Model: <id>` line; the script also exposes
   it in the `## <name> / <model> (exit N)` per-panelist section heading. Use
   the model name everywhere you would otherwise just say the panelist's name
   (e.g. `Raised by: codex (gpt-5.5)`, `### claude (claude-opus-4.7)`). If a
   panelist reported `Model: unknown`, surface that as `(unknown)` rather than
   silently omitting the model.

   **Tappable links to PR file:line.** When the target is a PR (the script's
   combined-output header shows `Target: PR #N` and emits `- PR URL: <url>`),
   wrap every `file:line` reference in the synthesized summary as a markdown
   link pointing at the PR file view, so the user can tap straight to the
   exact line on GitHub. Use the helper:

   ```
   bash skills/panel-review/pr-line-url.sh "$pr_url" "<file>" "<line-or-range>"
   ```

   Apply this in **Consensus findings**, **Unique findings**, **Disagreements**,
   and the **Action list** — every place a `file:line` appears in the synthesis.
   Leave per-panelist sections (the raw `## <name> / <model>` blocks) untouched
   so the panelist's verbatim output is preserved. For non-PR targets, skip the
   wrapping — leave bare `file:line` text since users can typically `cmd-click`
   in their terminal to open it locally.

   Example transformation. Panelist output:

   ```
   - [HIGH] auth/session.go:88 — TOCTOU between token check and claim load.
     Fix: take the cache lock before validating the signature.
   ```

   Synthesized consensus entry:

   ```
   - [HIGH] [auth/session.go:88](https://github.com/owner/repo/pull/27/files#diff-...R88) — TOCTOU between token check and claim load.
     Fix: take the cache lock before validating the signature.
     Raised by: codex (gpt-5.5), claude (claude-opus-4.7)
   ```

   **Every finding in every section below MUST include `file:line` and a `Fix:` line.**
   Drop any panelist finding that lacks a concrete location or a suggested fix — those
   are too speculative to surface. If the issue itself is real, infer the location
   from the diff/PR yourself; if you cannot, leave it out.

   Emit the synthesis using these section headings, in this exact order:

   ### Overview

   Two to four sentences for a human who has not seen the diff. State factually what
   files / areas changed, the kind of change (refactor, bug fix, new feature, config,
   dep bump, infra, …), and rough scope (lines added/removed, files touched). For PR
   mode pull this from `gh pr view --json files` and the diff; for non-PR targets
   infer from the diff. Do **not** editorialize — evaluation lives in Risk and
   Findings.

   ### Risk

   One of `LOW` / `MEDIUM` / `HIGH` / `CRITICAL`, then a one-sentence justification
   that points at observable signals (consensus findings, area touched, scope), not
   vibes. Rubric:
   - **LOW** — docs / tests / formatting / non-load-bearing refactor. No consensus
     findings. No HIGH/CRITICAL unique findings. All panelists agreed on the goal.
     No auth / payments / migrations / cryptography touched.
   - **MEDIUM** — touches business logic or non-trivial code paths. Findings exist
     but are fixable. No CRITICAL findings. Goal was clear or only mildly divergent
     across panelists.
   - **HIGH** — any of: at least one CRITICAL finding (verified per step 9); the
     change touches auth, session handling, payments, schema migrations, crypto, or
     production infra; panelists disagreed substantially on what the change does;
     the diff is unusually large (>500 lines) AND lacks a clear goal.
   - **CRITICAL** — verified bug in the change that would break production on merge,
     OR a known data-loss / security-bypass / credential-leak path introduced.

   Example: `Risk: HIGH — touches session-token validation; codex flagged a CRITICAL
timing-attack vulnerability at auth/session.go:88 (verified).`

   ### Goal check

   Each panelist starts its output with a `Goal:` line tagged `(clear)`,
   `(clear, matches description)`, `(clear, contradicts description)`, or `(unclear)`.
   Use those tags to decide what to print here:
   - **All panelists agreed on a clear goal** — state the goal in one sentence and
     move on. Example: `Goal: extract session-token validation into a reusable
helper. Codex, claude, opencode all agree.`
   - **Mixed clear / unclear** — surface the divergence. Quote what the unclear
     panelist(s) said was ambiguous. The change being non-self-explanatory is itself
     a HIGH-severity finding; add it to the action list.
   - **Panelists described different goals** — the change is likely doing several
     things at once or is genuinely confusing. Quote each panelist's goal verbatim
     so the user can decide whether to split the PR.
   - **Any panelist returned `Goal (clear, contradicts description):`** — quote what
     they said the actual goal is vs. what the description claims. MEDIUM/HIGH worth
     raising even if no one else flagged it.

   **Misinterpretation check (mandatory).** Beyond collating the `Goal:` tags,
   independently verify that each panelist's stated goal is actually consistent
   with what the diff does. A panelist can confidently tag itself `Goal (clear)`
   while having misread the change — that produces confidently-wrong findings
   further down. For each panelist:
   1. Read the diff yourself (or the PR via `gh pr view --json files,title,body`
      and `gh pr diff <ref>`) to form an independent understanding of intent.
   2. Compare your read against the panelist's `Goal:` line.
   3. If they disagree, that panelist **misinterpreted the change**. Surface
      it as a top-level note under Goal check:
      `- codex (gpt-5.5) appears to have misinterpreted the change. It said "<goal>" but the diff actually <what it really does>. Treat its findings below with skepticism — verify each one against the code before acting on it.`
   4. Apply step 9's verification more aggressively to that panelist's
      findings: drop any whose substance depends on the misread intent; keep
      only findings that still hold independent of the panelist's mistaken
      framing.

   Do not assume agreement among panelists implies correctness — two panelists
   can share a misread (especially if the diff is unusual or the description
   is misleading). When in doubt, your own read of the diff is the tiebreaker.

   ### Consensus findings

   Issues raised by 2+ panelists, deduplicated. Reference each panelist by name
   AND the model it self-reported on its `Model:` line, so the user can see
   which combinations agreed:

   ```
   - [SEVERITY] path/to/file.ext:LINE — one-sentence issue
     Fix: one-sentence suggested change.
     Raised by: codex (gpt-5.5), claude (claude-opus-4.7)
   ```

   ### Unique findings

   Group by panelist. Use `### <name> (<model>)` as the per-panelist heading so
   the model is visible alongside the findings. Only include findings no one
   else mentioned that still pass the "would a competent reviewer ask for this
   change" bar. Same shape (omit `Raised by:`, it's implicit in the grouping).
   Apply step 9's verification before promoting a unique CRITICAL or HIGH
   finding into the summary.

   ### Disagreements

   If panelists contradict each other on a finding, surface it explicitly with
   `file:line` for the disputed code. Do not pick a side; lay out both. Use step 9
   verification if you can resolve the disagreement yourself.

   ### Action list

   `must-fix` (CRITICAL/HIGH) → `should-fix` (MEDIUM) → `polish` (LOW). One line per
   item, each referencing `file:line` so the user can jump straight to it.

9. **Verify questionable findings before surfacing them.** A panelist's finding is
   questionable when any of these holds:
   - It is unique to one panelist AND its severity is CRITICAL/HIGH (high-impact claim
     with no second opinion).
   - The `Fix:` line does not obviously address the stated issue.
   - The line number is suspicious (referenced line is unchanged in the diff, or out
     of range for the file).
   - Two panelists disagree on whether the same code is buggy.
   - The panelist's reasoning depends on context outside the diff (caller behavior,
     framework guarantees, downstream consumers) that they did not actually verify.

   For each questionable finding, open the actual diff/file (use `gh pr diff`,
   `gh api .../files`, or `Read` against the local checkout) and confirm the bug
   exists as described before surfacing it. If verification disproves the finding,
   drop it and note the correction in the **Disagreements** section. If verification
   sharpens the finding (e.g., you find the right line number), promote the corrected
   version into the summary. Never repeat a panelist claim into the summary that you
   could have falsified in 30 seconds with a Read tool call.

10. **Don't paraphrase or invent.** Surface what the panelists actually said. If a
    panelist returned `NO_FINDINGS`, note it; don't drop the panelist from the report.
    You may correct a panelist's line number if it is clearly off (e.g., they cited a
    pre-image line and the file is now post-image), but never invent a line number to
    satisfy the format. The verification step in step 9 is the _only_ license to
    rewrite a finding's substance — and only when you have actually checked the code.

## Reference

CLI flags, env vars, and examples: run `bash skills/panel-review/panel-review.sh --help`.

The script handles two cases internally:

- **Local targets** (`--uncommitted` / `--staged`): builds the diff with `git`,
  embeds it in the prompt, runs panelists read-only against the working tree.
- **Committed targets** (`--pr` / `--base` / `--commit`): one throwaway git
  worktree per panelist pinned to the target ref, panelists run with
  workspace-write / bypass permissions so they can grep callers, run tests,
  and install dev deps. PR targets additionally use an instruction-style prompt
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
