---
name: triage-pr-comments
description: >
  Analyze PR review comments, deeply understand the code and each comment's
  concern, assess the ramifications of fixing vs not fixing, and recommend a
  course of action with reasoning. Use this skill whenever the user asks to
  "triage PR comments", "go through review comments", "respond to the review",
  "deal with the reviewers' feedback", "decide which comments to fix",
  "address review comments on PR N", or any similar phrasing about working
  through a pull request's review feedback. Defaults to the current branch's
  PR when no argument is given. Covers inline code comments, review-level
  summaries, and root-level (issue) comments on the PR conversation. Filters
  out the PR author's own comments, resolved/outdated threads, threads the
  author already replied to, and bot stylistic noise. Spawns parallel agents
  for first-pass analysis and then re-investigates each Fix verdict from
  scratch during the walkthrough.
argument-hint: "[pr-url or owner/repo#number] (defaults to current branch's PR)"
---

# triage-pr-comments

Analyze every review comment on a PR. For each comment, deeply understand the concern and the code, assess the ramifications of fixing vs not fixing, and recommend whether to fix. Double-check each recommendation.

## Step 1: Parse Input and Gather Data

Parse `$ARGUMENTS` to extract repository and PR number. Support:
- **No arguments (default):** Run `gh pr view --json number,url -q .number` to find the PR associated with the current branch. If no PR exists for the current branch, tell the user and stop.
- Full URL: `https://github.com/owner/repo/pull/42`
- Shorthand: `owner/repo#42`
- Bare number: `42` (assumes current repo from `gh repo view --json nameWithOwner -q .nameWithOwner`)

Fetch PR metadata:

```bash
gh pr view {number} -R {repo} --json title,body,baseRefName,headRefName,headRefOid,files,additions,deletions,changedFiles,url
```

Fetch the full diff:

```bash
gh pr diff {number} -R {repo}
```

Fetch ALL review comments (inline comments on code):

```bash
gh api repos/{owner}/{repo}/pulls/{number}/comments --paginate
```

Also fetch top-level review bodies (the summary text reviewers submit with their review):

```bash
gh api repos/{owner}/{repo}/pulls/{number}/reviews --paginate
```

Filter to reviews where `body` is non-empty and `state` is not `DISMISSED`.

Also fetch root-level PR comments (standalone comments on the PR conversation, not attached to a review or inline on code — under the hood these are issue comments since PRs are issues):

```bash
gh api repos/{owner}/{repo}/issues/{number}/comments --paginate
```

These have no `path` or `line` — they're general comments on the PR. Treat them like review-level comments for downstream analysis (no file/line context, just a body).

Combine inline comments, review-level comments, and root-level comments into a single list. Group inline comments by the review they belong to (via `pull_request_review_id`) so you can see which review body accompanies which set of inline comments. Root-level comments stand on their own.

### Filter out the PR author's own comments

Determine the PR author by reading `author.login` from `gh pr view {number} -R {repo} --json author -q .author.login`. Drop all comments where `user.login` matches that login. The author's own comments (dev notes, self-annotations, design rationale) are not review feedback and should never appear in the findings.

### Filter out resolved, outdated, and already-replied comments

Use the GraphQL API to fetch review thread resolution status and reply history:

```bash
gh api graphql --paginate -f query='
  query($owner: String!, $repo: String!, $pr: Int!, $endCursor: String) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $pr) {
        reviewThreads(first: 100, after: $endCursor) {
          pageInfo { hasNextPage endCursor }
          nodes {
            id
            isResolved
            isOutdated
            comments(first: 100) {
              nodes {
                databaseId
                createdAt
                author { login }
              }
            }
          }
        }
      }
    }
  }
' -f owner='{owner}' -f repo='{repo}' -F pr='{number}'
```

`gh api graphql --paginate` follows the `pageInfo`/`endCursor` cursor automatically as long as the query exposes them and accepts an `$endCursor` variable, so this covers PRs with more than 100 threads. The nested `comments(first: 100)` is left un-paginated because GitHub's `gh` GraphQL pagination only follows one connection at a time — if a single thread ever exceeds 100 comments (rare), fall back to a per-thread fetch using the thread `id`. Capture each thread's `id` here; Step 5 needs it to resolve the thread.

Drop any inline comment whose review thread meets **any** of these conditions:

1. **Resolved** (`isResolved: true`) — already addressed and marked resolved.
2. **Outdated** (`isOutdated: true`) — left on code that has since been updated, meaning the author likely already addressed them.
3. **Already replied to by the PR author** — drop the thread if it contains a PR-author comment whose `createdAt` is later than the `createdAt` of the most recent reviewer comment in the same thread. Compare timestamps explicitly rather than relying on node order, and anchor the comparison to the most recent reviewer comment so a reviewer follow-up that arrived after the author's reply still surfaces for triage.

Root-level (issue) comments don't have review threads and can't be "resolved" via GitHub's UI, so this filter doesn't apply to them. Instead, drop a root-level comment if a later root-level comment from the PR author appears to reply to it (e.g., quotes it, addresses it directly, or follows it chronologically and is clearly a response). When in doubt, keep the root-level comment — it's better to surface a stale one than to silently drop unaddressed feedback.

### Filter out bot noise

Identify bot reviewers by checking `user.type == "Bot"` or login suffixes like `[bot]` (e.g., `coderabbitai[bot]`, `github-actions[bot]`).

For bot comments, only keep comments that flag **correctness, security, or production-impact concerns** (e.g., CodeRabbit's "Critical" or "Potential issue" labels). Drop bot comments that are purely stylistic: docstring requests, naming suggestions, comment suggestions, code organization nitpicks, or "consider moving X" proposals. When in doubt about a bot comment, keep it -- but bias toward dropping.

Always keep all comments from human reviewers regardless of category.

If zero comments remain after filtering, tell the user and stop.

## Step 2: Spawn Analysis Agents

For efficiency, spawn parallel Agent subagents to analyze comments. Group comments by file (inline comments), plus one group for review-level comments, plus one group for root-level (issue) comments.

Assign each comment a stable sequential number (starting at 1) **before** distributing to agents. This numbering persists through the entire workflow — analysis, presentation, summary table, and interactive resolution all use the same numbers.

Each agent receives:
- The full PR diff
- The PR description/body
- The comment(s) it is responsible for analyzing, **with their assigned numbers**
- The head SHA for `git show {sha}:{path}` access

For each comment, the agent must perform the following analysis:

### 2a. Understand the Comment

- What specific concern is the reviewer raising?
- Is this about correctness, security, performance, style, architecture, testing, or something else?
- Is the reviewer asking a question, suggesting a change, or flagging a risk?
- If ambiguous, state the most likely interpretation and note the ambiguity.

### 2b. Understand the Code

- For inline comments: read the code at the comment location using `git show {headRefOid}:{file_path}`
- For review-level and root-level comments with no file/line: identify which files or behaviors the comment is talking about from the diff and PR description, then read those
- Read surrounding context (the full function/method/class, not just the commented line)
- If the comment references behavior in other files, trace call chains and read those files too
- Understand what the code does, why it was written this way, and what alternatives exist

### 2c. Assess Ramifications

**If fixed:**
- What changes in behavior, safety, correctness, or maintainability?
- How much effort is the fix? (trivial one-liner, moderate refactor, significant rework)
- Does the fix introduce any new risks or complexity?
- Does it affect other code paths or systems?

**If not fixed:**
- What is the concrete risk? Be specific: "could cause X in scenario Y", not "might be an issue"
- How likely is the risk to materialize? (certain, likely, unlikely, theoretical)
- What is the blast radius if it does materialize? (single user, all users, data loss, security breach)
- Is this a ticking time bomb or a stable known limitation?

### 2d. Recommend

Classify each comment into one of:

| Verdict | Meaning | When to use |
|---------|---------|-------------|
| **Fix** | Address before merging | Correctness bug, security issue, likely production impact, or low-effort improvement with clear benefit |
| **Fix (follow-up)** | Address in a separate PR | Valid concern but orthogonal to this PR's scope, or requires significant rework that shouldn't block shipping |
| **Dismiss** | Do not fix | Reviewer misunderstood the code, concern is theoretical/inapplicable, or the current approach is intentionally better |

### 2e. Double-Check

Before finalizing, the agent must challenge its own recommendation:

- If recommending **Fix**: "Am I overreacting? Is the current code actually fine? Could the fix introduce worse problems?"
- If recommending **Dismiss**: "Am I being too dismissive? What if the reviewer knows something I don't? What's the worst case if they're right and I'm wrong?"
- If recommending **Fix (follow-up)**: "Is this really safe to defer? Could it become much harder to fix later? Am I just avoiding work?"

Revise the recommendation if the challenge reveals a flaw. State the final verdict with confidence level (high, medium, low).

### Agent Output Format

For each comment, return:

For inline comments use `{file_path}:{line}` as the location. For review-level comments use `review summary`. For root-level comments use `PR conversation (root-level)`.

```
## #{number}: Comment by {author} on {location}

**Comment:** {comment text, truncated to first 200 chars if longer}

**Category:** {correctness | security | performance | style | architecture | testing | question}

**Understanding:** {1-3 sentences: what the reviewer is concerned about}

**Code context:** {2-4 sentences: what the code does and why}

**If fixed:** {2-3 sentences: what changes, effort level, any new risks}

**If not fixed:** {2-3 sentences: concrete risk, likelihood, blast radius}

**Verdict:** {Fix | Fix (follow-up) | Dismiss}
**Confidence:** {high | medium | low}
**Reasoning:** {2-4 sentences: the core argument for this verdict, including the result of the double-check}
```

## Step 3: Present Results

Print a summary header:

```
## PR Comment Triage: {pr_title}

{N} comments analyzed from {M} reviewers.

Verdicts: {X} fix, {Y} fix (follow-up), {Z} dismiss
```

Then present each comment analysis, ordered by verdict priority: Fix first, then Fix (follow-up), then Dismiss.

For each, print the full analysis from the agent output. After each comment's analysis, print a horizontal rule (`---`) as separator.

After presenting all analyses, print a summary table:

```
## Summary

| # | File | Reviewer | Category | Verdict | Confidence | One-line reason |
|---|------|----------|----------|---------|------------|-----------------|
| 1 | ... | ... | ... | Fix | high | ... |
| 2 | ... | ... | ... | Dismiss | medium | ... |
```

## Step 4: Interactive Resolution

After presenting results, use **AskUserQuestion**:

```
How would you like to proceed?
- "fix all" -- I'll implement all Fix verdicts
- "walk through" -- go through each Fix one by one
- "done" -- just use the analysis as reference
```

If **"fix all"**: implement all Fix verdicts without individual confirmation.

If **"walk through"**: go through each Fix verdict one by one. The walkthrough is a fresh investigation — do NOT simply repeat the initial analysis. For each comment:

### 4a. Re-investigate from scratch

The initial analysis in Step 2 was done quickly by parallel agents with limited context. Now, independently verify that the initial findings and theory are correct:

- **Re-read the code at the comment location** using `git show` or Read. Read the full function/class, not just the flagged lines. Trace into callers and callees if the comment's concern involves cross-function behavior.
- **Test the reviewer's claim.** If they say "this could NPE" — trace whether `null` can actually reach that point. If they say "race condition" — identify the concurrent access paths. If they say "missing validation" — check whether validation happens elsewhere (middleware, caller, type system). Don't take the reviewer's claim at face value; verify it against the actual code.
- **Check if the initial verdict still holds.** The parallel agent may have missed context, misread the code, or drawn the wrong conclusion. State explicitly whether you agree or disagree with the initial analysis and why. If you disagree, update the verdict (Fix → Dismiss, Dismiss → Fix, etc.) and explain what the initial analysis got wrong.

### 4b. Explain the comment in depth

Present the verified understanding to the user:

1. **What the reviewer said and why it matters.** Explain the comment in plain language — not just what they wrote, but what underlying concern they're raising. Connect it to the specific code: quote the relevant lines, explain what those lines do in the context of the surrounding function/module, and clarify why the reviewer flagged them. If the comment references a concept (race condition, missing validation, edge case), explain concretely how that concept applies here with a specific scenario.

2. **Whether the concern is valid.** After your re-investigation, state clearly: is the reviewer right? Partially right? Wrong? Support your conclusion with evidence from the code (e.g., "The reviewer is correct — `user` can be `null` here because `findById` returns `null` when the ID doesn't exist, and there's no guard before line 42" or "The reviewer's concern doesn't apply here because the caller already validates this in `middleware/auth.ts:28`").

### 4c. Propose a fix (if the verdict is still Fix)

If after re-investigation the verdict remains Fix:

- Show the exact code change you intend to make as a before/after diff.
- Explain what the fix does and why it addresses the reviewer's concern.
- If there are multiple valid approaches, briefly mention alternatives and why you chose this one.
- Call out any behavioral changes the fix introduces (e.g., "this will now return a 400 instead of silently proceeding") and any files beyond the commented location that need to change.

If re-investigation changed the verdict to Dismiss, explain why and move on.

### 4d. Confirm with the user

Use **AskUserQuestion** before applying each fix:
```
Apply this fix? (yes / no / edit — describe what you'd change)
```
If the user says "edit", incorporate their feedback and re-present the updated fix before applying.

If **"done"**: end the skill.

## Step 5: Commit and Reply

After all fixes are implemented and verified (tests pass, linter clean):

1. **Commit and push first.** Create a commit with all fix changes, then push to the remote branch before posting any PR comments. The reviewer must be able to see the fixes on GitHub before they receive replies.
2. **Then reply to each comment.** The reply mechanism depends on the comment type:
   - **Inline review comments:** post an inline reply via `repos/{owner}/{repo}/pulls/{number}/comments/{comment_id}/replies`.
   - **Review-level comments:** the review summary itself isn't a thread, so address it inside the relevant inline-comment replies if it's been broken out into individual line comments, or post a single root-level reply on the PR (`repos/{owner}/{repo}/issues/{number}/comments`) that addresses the summary as a whole.
   - **Root-level (issue) comments:** post a new root-level comment via `repos/{owner}/{repo}/issues/{number}/comments` that quotes or `@`-mentions the original commenter and addresses their point. GitHub doesn't support nested replies on root-level PR comments.
   - For **Fix** verdicts: briefly describe the fix applied.
   - For **Dismiss** verdicts: explain concisely why the concern does not apply (e.g., "no existing rows", "subsumed by the runtime guard", "naming convention is self-documenting").
   - For bot nitpick comments that were filtered out in Step 1: ignore them entirely. Do not reply or acknowledge.
3. **Resolve all inline-comment threads** using the GraphQL `resolveReviewThread` mutation. Pass the thread `id` captured in Step 1 (not the comment `databaseId`):

   ```bash
   gh api graphql -f query='
     mutation($threadId: ID!) {
       resolveReviewThread(input: { threadId: $threadId }) {
         thread { isResolved }
       }
     }
   ' -f threadId='{thread_id}'
   ```

   Root-level comments and review-level summaries have no thread to resolve — leave them as-is once replied to.

### Error handling

The commit/push/reply/resolve sequence has a strict ordering — partial failures should not leave the PR in a half-applied state.

- **Push fails (protected branch, stale base, rejected hook):** stop immediately. Do not post any replies and do not resolve any threads. Report the push error to the user so they can fix the branch state and re-run Step 5.
- **A single reply fails (rate limit, transient network error, invalid comment id):** log the failure, continue with the remaining replies, and surface every failure at the end so the user can retry or post them manually.
- **A `resolveReviewThread` mutation fails:** log and continue. Thread resolution is best-effort — the reply itself is what matters for the reviewer.
- **At the end:** print a summary listing which comments got replies, which threads got resolved, and which operations failed. Never claim success while errors are outstanding.
