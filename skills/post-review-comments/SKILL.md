---
name: post-review-comments
description: >
  Interactively triage code review findings (typically from a prior
  `panel-review`) and post the approved ones as inline comments on a
  GitHub PR via a single batched review. Walks the user through each
  finding, offers to soften/tighten/rewrite the wording before posting,
  and appends a small footer crediting the panelist. Use any time the
  user has review findings with `file:line` references in conversation
  context and wants to selectively get them onto a PR — phrasings include
  "post these comments", "post these as inline comments", "let me triage
  and post", "comment these on the PR", "open a review on PR <N> with
  these", or casual asks like "let's get these onto the PR". Pairs
  naturally with `panel-review` but works on any structured findings list
  with file:line refs. Do NOT use when the user wants you to *generate*
  the findings (run a review skill first), or when they want a single
  bulk summary comment instead of inline ones.
---

# post-review-comments

Walks a list of review findings one at a time, optionally rewrites each one
to match the desired tone, and batches the approved ones into a single
GitHub PR review.

## When to use

- After a `panel-review` (or any review) produced findings with `file:line`
  references and the user wants to post some/all of them to GitHub.
- Trigger phrases: "post these comments", "let me triage and post", "turn
  these into PR comments", "comment these on the PR".

When _not_ to use:

- The user wants to discuss findings without posting → just answer in chat.
- The user hasn't run a review yet → run the review skill first.
- The user wants one bulk summary comment, not inline → use `gh pr comment`.

## Inputs the caller must provide

1. **The findings.** Usually the synthesized output from a prior
   `panel-review`. Each finding needs at minimum: panelist name, severity
   (HIGH / MEDIUM / LOW), file path, line number (or range), and body text.
   Ideally also a **recommendation** (must-fix / should-fix / optional polish);
   if missing, derive from severity (HIGH→Must fix, MEDIUM→Should fix,
   LOW→Optional polish) and let the user override during triage.

   If a finding lacks a file/line, ask before triaging it — GitHub inline
   comments need a concrete location.

2. **The PR reference.** A PR number or URL. The caller already knows this
   from how the review was scoped (e.g. "panel-review PR 85"). Do **not**
   auto-detect from the current branch — the user may have switched branches
   between the review and the post step. If the PR ref is missing, ask once.

## Steps

### 1. Resolve PR metadata

```bash
gh pr view <PR_REF> --json number,url,headRefOid,baseRefName,headRefName,nameWithOwner
```

Capture: `number`, `url`, `headRefOid` (used as `commit_id` in the review
payload), and `nameWithOwner` (the `OWNER/REPO` slug). Surface the resolved
PR back to the user briefly (`PR #85: <title> — <url>`) before triaging —
cheap sanity check that you're targeting the right PR.

### 2. Triage findings one at a time

Walk findings in HIGH → MEDIUM → LOW order; within a severity, group by file.
Reason: HIGHs deserve the user's freshest attention — burying them under
twelve LOW polish notes wastes both.

For each finding:

1. **Build a deep-link to the line** so the user can verify context before
   deciding. Run `scripts/pr-line-url.sh <pr-url> <path> <line-or-range>`;
   it returns the GitHub PR diff-anchor URL. For findings on lines that
   are _outside_ the PR diff (unchanged context), use the blob-fallback
   form instead — see [GitHub deep-links](#github-deep-links).

2. **Ask via `AskUserQuestion`** what to do. The `question` field is the
   user's main interface for this decision — they see the modal in
   isolation, often after scrolling away from chat. **Self-contain the
   finding inside the question text**; don't make them remember or scroll
   back to figure out which finding this is. That friction is exactly what
   pushes people toward rubber-stamping.

   Question text should include, in order: panelist + severity tag,
   file:line, the deep-link **as a plain URL on its own line** (markdown
   link syntax hides the URL preview), the finding body verbatim, the
   suggested fix line if any, and a short trailing prompt.

   Concrete example:

   ```
   **Codex (MEDIUM, security)** — apps/web/src/routes/__root.tsx:240

   https://github.com/catena-labs/example-repo/pull/85/files#diff-<hex>R240

   External OAuth callbacks redirect to /v1/auth/oauth2/authorize while the
   post-signup onboarding gate is active. A new CLI/MCP magic-link signup
   can receive an access token without completing KYB.

   **Fix:** defer the non-console OAuth redirect until
   postSignupOnboardingActive is false.

   What should we do with this comment?
   ```

   Bad version (don't do this — strips the user of context):

   ```
   What should we do with finding 2?
   ```

   Then the option set. Defaults below cover most PRs; adapt them to
   context (e.g., on an OSS PR, swap "Soften the tone" for "Make more
   diplomatic"; on a security review, add "Emphasize the risk"):
   - **Post as-is** — body unchanged (header + footer still appended).
   - **Soften the tone** — less direct phrasing, fewer imperatives.
   - **Make more concise** — trim to the essential claim + fix.
   - **Skip this one** — drop the finding, move on.

   `AskUserQuestion` always offers an "Other" option. Treat free-text as
   either a custom rewrite directive ("emphasize impact", "frame as a
   follow-up not a blocker") or as the exact body to post ("just post:
   <text>").

3. **If the user picked a transform**, rewrite the body, show the new
   version, and ask one follow-up: post this / try a different tone /
   edit manually. Don't loop more than 2-3 times — if the user is
   struggling to land on wording, offer to skip and revisit later.

4. **Stage the approved comment** in an in-memory list with: `path`,
   `line` (and `start_line` if it's a range), `body` (final text + header
   - footer), `panelist`, `severity`. Don't post yet.

**Bulk decisions are fine.** If the user says "post the HIGH and MEDIUM
ones, skip the LOW ones" upfront, honor that without prompting per-LOW.
Still walk the kept findings one at a time so they get the tone-check pass.

**If the user skips every finding**, do not call the reviews API with an
empty `comments` array (GitHub rejects it, and an empty review is just
noise). Tell the user nothing was posted and stop.

### 3. Compose the comment body

Each approved finding becomes one inline comment with this body shape:

```markdown
**Recommendation:** <Must fix | Should fix | Optional polish>
**Severity:** <High | Medium | Low>

<final body text, possibly rewritten>

<optional fix line if the panelist provided one>

---

<sub>generated by <panelist> via [panel-review](https://github.com/catena-labs/skills)</sub>
```

- **Recommendation** and **Severity** are Title Case sentence form (`Must
fix`, `High`) — not the `must-fix` slug or all-caps `HIGH` panelists
  emit. The all-caps shouts in an inline comment.
- Both labels go on their own lines with a blank line before the body.
  Two lines, not one — separating them is what makes them scannable in
  the GitHub UI.
- Don't drop either label. If the recommendation or severity is genuinely
  unknown, ask the user to assign one.
- Always include the footer in `<sub>` tags, even on user-edited bodies —
  it makes provenance auditable later. Drop only if the user explicitly
  says "no footer".

### 4. Batch-post as one PR review

Post _all_ approved comments in a single `POST /pulls/{pr}/reviews` call.
One review = one notification, all comments grouped together in the PR's
Files Changed tab.

**Order `comments[]` by severity** (HIGH → MEDIUM → LOW; within a severity,
group by file) — same order as the triage walk. Reason: this controls the
order in the user's email notification and in GitHub's "View files"
sidebar; severity order keeps the most important issues at the top.

```bash
gh api repos/<OWNER/REPO>/pulls/<PR_NUMBER>/reviews -X POST --input payload.json
```

Where `payload.json` is:

```json
{
  "commit_id": "<headRefOid from step 1>",
  "body": "Posted N findings from a panel-review (codex, claude, opencode).",
  "event": "COMMENT",
  "comments": [
    {
      "path": "apps/web/src/routes/__root.tsx",
      "line": 240,
      "side": "RIGHT",
      "body": "**Recommendation:** Must fix\n**Severity:** High\n\nExternal OAuth callbacks redirect to ...\n\n---\n<sub>generated by codex via [panel-review](https://github.com/catena-labs/skills)</sub>"
    }
  ]
}
```

Use `event: "COMMENT"` — never `"REQUEST_CHANGES"` or `"APPROVE"`. This
skill posts review _comments_; whether to block the PR is the user's call,
not the panel's.

For multi-line findings, include `start_line` _and_ `line` (`line` is the
end of the range). Both must reference the right side (`side: "RIGHT"`).

### 5. Confirm + report

After the API call returns:

- The review URL (returned in the response as `html_url`).
- A one-line summary: `Posted N comments to PR #X (M skipped, K rewritten)`.
- If GitHub rejected any individual comment (e.g., line outside the diff
  hunk), the response contains an error per comment — report which
  findings were dropped and why so the user can post them manually.

## Gotchas

- **GitHub only allows inline comments on lines in the PR diff.** If a
  panelist flags a line in unchanged context, the API rejects just that
  comment (the rest still post). Detect this in the response and tell the
  user — don't silently swallow it.
- **Don't auto-detect the PR from the current branch.** The user may have
  switched branches between the review and the post step. The caller has
  the PR ref from the review's scope; pass it through explicitly.
- **One review, not many.** Posting each comment via
  `POST /pulls/{pr}/comments` separately scatters them across the PR
  timeline and spams notifications. Always batch through the reviews API.
- **Don't paraphrase the finding before showing it to the user.** They
  need the raw panelist output to decide. Only rewrite _after_ they pick
  a transform option.
- **The footer link is intentionally generic.** It points at the skills
  repo, not at any per-run artifact, because `panel-review` doesn't post a
  tracking comment. If the user wants a richer link, ask them.

## GitHub deep-links

Default is `scripts/pr-line-url.sh` (symlinked from `panel-review`), which
emits the diff-anchor form for lines inside the PR diff:

```
https://github.com/<OWNER>/<REPO>/pull/<N>/files#diff-<HEX>R<LINE>
```

For lines **outside** the diff hunk (e.g. a panelist flagged unchanged
context), the diff anchor scrolls to nothing useful — use a blob link
pinned to the PR's head SHA instead:

```
https://github.com/<OWNER>/<REPO>/blob/<HEAD_SHA>/<PATH>#L<LINE>
```

Pin to the head SHA (not `main`) so the link survives later commits that
move the line. For ranges use `#L<START>-L<END>`.

If you don't know whether a line is inside the diff, default to the
diff-anchor form — it's the more useful link when it works, and degrades
to "scrolls to top of file" when it doesn't, which is still better than no
link. If you _do_ know a line is unchanged context (the user told you, or
you fetched the diff and checked), use the blob fallback.

## Dry-run mode

If the user (or a test harness) asks for a dry run — phrasings like "don't
actually post", "just show me the payload", or sets
`POST_REVIEW_COMMENTS_DRY_RUN=1` — do everything up to step 4 normally,
then write the final review payload to `./payload.json` (or a path the
user named) instead of calling `gh api`. Also write a `triage_transcript.md`
with one section per finding containing:

- The finding (panelist + severity + file:line + body + fix line)
- The deep-link URL
- The exact text that **would have been shown** in the `AskUserQuestion`
  question field (per step 2 — restating the finding inline) so the
  question text is auditable without an interactive user
- The disposition (posted as-is / softened / made concise / skipped / etc.)

The transcript is the persistent record of what _would_ have been shown.
Useful for evals and for users who want to inspect the payload first.
