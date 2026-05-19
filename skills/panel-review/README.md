# panel-review

Fan a code review out to multiple local CLI coding agents (codex, claude, opencode) running in parallel, then synthesize their findings into one report. For PR / branch / commit targets, each agent gets its own isolated git worktree so they can run tests and chase downstream effects in parallel without stepping on each other.

## Install

```
npx skills add catena-labs/skills --skill panel-review
```

## How to use it

Just ask Claude Code in plain English — the skill picks up the target and panelists from your phrasing:

- "panel review" — auto-detects an open PR for the current branch via `gh` and reviews that; falls back to uncommitted work if there is no PR or your tree is dirty
- "panel review my latest changes on this branch"
- "panel review my staged changes"
- "panel review PR 27"
- "panel review this branch against main"
- "panel review the auth changes, focus on session handling"
- "panel review with just codex and claude"

Add "deep" / "verify each finding" / "dig into the findings" to opt into deep mode: after the panelists finish, the coordinator spins off verification subagents for every finding, then synthesizes their evidence, concrete fixes, and fix rationale. Token-heavy — routine reviews should stick with the standard synthesis.

## What it does

- Auto-detects whether the current branch has an open GitHub PR and switches to PR mode by default — no more "stale local main" reviews flagging commits that are not actually in the PR.
- For PR targets, panelists fetch the live diff and existing review comments themselves via `gh` (no embedded diff in the prompt). For `--base` / `--commit` targets it builds a unified diff with `git` and embeds it in the prompt. For `--uncommitted` / `--staged` it embeds the local diff.
- For any target with a real ref (`--pr` / `--base` / `--commit`), spins up **a dedicated, throwaway git worktree per panelist** pinned to the same commit. Panelists can run tests, install deps, and grep callers in parallel without racing each other's `node_modules/` / `target/` / `.next/`. One network fetch up front, then local-only worktree creation; everything is torn down on exit.
- `--uncommitted` / `--staged` skip the worktree (the changes only exist locally) and panelists run read-only against your working tree.
- Spawns each panelist as a fresh, non-interactive subprocess with no shared conversation state — the whole point is independent second opinions.
- Streams each panelist's section back as it lands, then groups results into a synthesized summary with overview / risk / goal-check / consensus / unique findings / disagreements / action list. Every line in the summary points at `file:line` with a suggested fix; for PR targets, the lines are tappable links straight to the PR file view.

## Gotchas

- **Background Bash + `BashOutput` polling is required.** Codex dominates wall clock, so foreground calls block silently for minutes. Do not launch `panel-review.sh` via the `Agent` tool / subagents — there's no streaming-output API for in-flight subagents and the heartbeats become invisible. Deep mode's post-processing verification subagents are the exception, and only run after panelists finish.
- **Worktree mode is strictly less safe than the local-diff mode.** It gives panelists write/exec access in their worktree and shares your parent repo's `.git` objects, so a stray `git push` from a panelist would publish from your machine. The prompt forbids it, but the prompt is a firewall, not a sandbox.
- **Diff-embed targets cap at 200KB.** `--base` / `--commit` reviews of big rename / refactor changes blow past it — bump `PANEL_REVIEW_MAX_DIFF_BYTES` rather than trimming. PR mode bypasses this cap entirely (no embedded diff).
- Panelists pick up the project's `AGENTS.md` / `CLAUDE.md` — that's intentional, but worth knowing if the file biases their review.
