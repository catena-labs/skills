# triage-pr-comments

Walk through every review comment on a PR — understand the code, weigh the ramifications of fixing vs not fixing, and recommend a verdict (Fix / Fix follow-up / Dismiss) for each one. Then optionally apply the fixes, push them, and post reply comments on GitHub.

## Install

```
npx skills add catena-labs/skills --skill triage-pr-comments
```

## How to use it

Just ask Claude Code in plain English — defaults to the current branch's PR when no target is given:

- "triage the PR comments"
- "go through the review comments on this PR"
- "respond to the reviewers"
- "address the comments on PR 42"
- "deal with the review feedback on owner/repo#42"
- "triage https://github.com/owner/repo/pull/42"

## What it does

- **Auto-detects the target PR** from the current branch via `gh pr view`. Also accepts a full URL, `owner/repo#N`, or a bare PR number.
- **Filters out noise before any analysis.** Drops the PR author's own comments, threads marked resolved or outdated, threads the author has already replied to, and bot comments that are purely stylistic (docstring nags, naming suggestions, "consider moving X"). Keeps every human comment regardless of category, and keeps bot comments that flag correctness / security / production impact.
- **Fans out to parallel analysis agents.** Each agent reads the comment, the code at the comment location, surrounding context, and any cross-file callers — then weighs ramifications both ways and produces a verdict with a confidence level. Each agent is required to challenge its own recommendation before committing to it.
- **Presents one ranked report** with a per-comment breakdown (understanding, code context, if-fixed / if-not-fixed, verdict + reasoning) and a summary table.
- **Walks through each Fix interactively.** The walkthrough is a fresh investigation, not a recap — the coordinator re-reads the code, tests the reviewer's claim, and is allowed to flip the initial verdict if the parallel agent got it wrong.
- **Commits, pushes, and replies in the right order.** Fixes land on the branch first so reviewers can see them on GitHub before the reply comment arrives, then the skill posts inline replies and resolves the threads via GraphQL.

## Gotchas

- **Requires the `gh` CLI** authenticated against the target repo. The skill uses `gh pr view`, `gh pr diff`, `gh api` REST calls, and `gh api graphql`.
- **Initial verdicts can be wrong — that's why Step 4 re-investigates.** The Step 2 parallel agents move fast with limited context and sometimes miss validation that lives in middleware, a caller, or the type system. Trust the walkthrough's verdict over the initial summary when they disagree.
- **The "already replied to by the author" filter is aggressive on purpose.** If you've left even a one-line reply on a thread, the skill treats it as engaged and drops it. Mark a thread unresolved and delete your reply if you actually want it re-triaged.
- **Bot stylistic comments are dropped silently and never get a reply.** That's intentional — replying to every CodeRabbit nit pollutes the PR. If you want bot nits considered, you'll need to reword the bot-filter heuristic in Step 1.
- **Reply + resolve happens after push, not before.** If push fails (protected branch, stale base), no replies get posted — fix the push first, then re-run Step 5.
